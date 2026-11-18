#!/usr/bin/env bats
# A real stealth-mode stack on 127.0.0.1: the same images and config as
# production, except a self-signed certificate (TLS_MODE=internal) because
# Let's Encrypt cannot reach a test machine.
#
# Needs Docker. Telegram round trips need the internet; set
# BURROWRS_E2E_OFFLINE=1 to skip only those.

DOMAIN=e2e.burrowrs.test

setup_file() {
	load ../helpers
	have_docker || return 0
	export BURROWRS_ENV_FILE=$BATS_FILE_TMPDIR/.env BURROWRS_STATE_DIR=$BATS_FILE_TMPDIR/state
	export BURROWRS_USERS_FILE=$BATS_FILE_TMPDIR/users.tsv
	export BURROWRS_PROJECT=burrowrs-e2e-$$
	PROXY_PORT=$(free_port_host) HTTP_PORT=$(free_port_host) METRICS_PORT=$(free_port_host)
	export PROXY_PORT HTTP_PORT METRICS_PORT
	burrowrs init --domain "$DOMAIN" --tls internal --bind 127.0.0.1 --port "$PROXY_PORT" \
		--http-port "$HTTP_PORT" --metrics-port "$METRICS_PORT" --ipv4 127.0.0.1 --link-host 127.0.0.1 \
		--subnet "$(random_subnet)" --quiet
	burrowrs up >&3 2>&1
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	burrowrs down --volumes >/dev/null 2>&1 || true
}

setup() {
	load ../helpers
	require_docker
}

free_port_host() {
	(
		# shellcheck source=/dev/null
		source "$BURROWRS_ROOT/lib/common.sh"
		free_port
	)
}

container() { docker compose -p "$BURROWRS_PROJECT" ps -q "$1"; }
telegram_flag() { [[ ${BURROWRS_E2E_OFFLINE:-0} == 1 ]] && echo --no-telegram || true; }

# tools_in_edge_http HOST PORT PATH: an HTTP GET from a container on the
# stack's edge network (where the decoy and probes live).
tools_in_edge_http() {
	docker run --rm --network "${BURROWRS_PROJECT}_edge" --entrypoint python \
		"burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" -c \
		'import sys, urllib.request; urllib.request.urlopen(f"http://{sys.argv[1]}:{sys.argv[2]}{sys.argv[3]}", timeout=3)' "$@"
}

tools_host() { # tools_host SECRET ARGS...
	local secret=$1
	shift
	BURROWRS_SECRET=$secret docker run --rm --network host -e BURROWRS_SECRET \
		"burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" "$@"
}

@test "smoke: every check passes from inside the stack" {
	# shellcheck disable=SC2046
	run burrowrs smoke $(telegram_flag)
	assert_success
	assert_output --partial "checks passed"
}

@test "smoke --link: the share link works from the host, as an app would use it" {
	# shellcheck disable=SC2046
	run burrowrs smoke --link "$(burrowrs link --format tg)" --insecure $(telegram_flag)
	assert_success
}

@test "smoke --link: links with the base64 form of the secret work too" {
	b64=$(python3 -c 'import base64, sys; print(base64.urlsafe_b64encode(bytes.fromhex(sys.argv[1])).decode().rstrip("="))' \
		"$(burrowrs link --format secret)")
	run burrowrs smoke --link "tg://proxy?server=127.0.0.1&port=$PROXY_PORT&secret=$b64" --insecure --no-telegram
	assert_success
}

@test "status reports a healthy proxy and traffic counters" {
	run burrowrs status
	assert_success
	assert_output --partial "FakeTLS handshake succeeds"
	assert_output --partial "not valid clients"
}

@test "status and smoke leave the caller's stdin alone (ssh host 'bash -s' <script)" {
	# status runs probes inside the stack, smoke --link on the host: both paths.
	local link
	link=$(burrowrs link --format tg)
	run bash -c 'printf "next line\n" | {
		"$1" status >/dev/null 2>&1
		"$1" smoke --link "$2" --insecure --no-telegram >/dev/null 2>&1
		cat
	}' _ "$BURROWRS_ROOT/burrowrs" "$link"
	assert_success
	assert_output "next line"
}

@test "the proxy container has the TCP tuning (its network namespace doesn't inherit the host's)" {
	# The telemt image has no shell tools: read /proc/sys/net from a throwaway
	# container that joins telemt's network namespace.
	local busybox
	busybox=$(sed -n 's/^ *image: \(busybox:.*\)$/\1/p' "$BURROWRS_ROOT/compose.yaml" | head -n 1)
	run docker run --rm --network "container:$(container telemt)" "$busybox" cat \
		/proc/sys/net/ipv4/tcp_slow_start_after_idle /proc/sys/net/ipv4/tcp_mtu_probing \
		/proc/sys/net/ipv4/tcp_max_syn_backlog
	assert_success
	assert_output $'0\n1\n8192'
}

@test "running containers are hardened" {
	for svc in telemt decoy; do
		run docker inspect -f '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}} {{.Config.User}} {{.HostConfig.RestartPolicy.Name}}' "$(container "$svc")"
		assert_output "true [ALL] [no-new-privileges:true] 65534:65534 unless-stopped"
		read -r memory pids < <(docker inspect -f '{{.HostConfig.Memory}} {{json .HostConfig.PidsLimit}}' "$(container "$svc")")
		((memory > 0 && pids > 0))
	done
}

@test "only the intended ports are published, metrics on loopback only" {
	run docker port "$(container telemt)"
	assert_output --partial "3128/tcp -> 127.0.0.1:$PROXY_PORT"
	assert_output --partial "3129/tcp -> 127.0.0.1:$METRICS_PORT"
	assert_equal "${#lines[@]}" 2
	run docker port "$(container decoy)"
	assert_output "8080/tcp -> 127.0.0.1:$HTTP_PORT"
}

@test "the decoy website: personalised pages, 404s, security headers" {
	base=(curl -sk --max-time 10 --resolve "$DOMAIN:$PROXY_PORT:127.0.0.1")
	run "${base[@]}" "https://$DOMAIN:$PROXY_PORT/"
	assert_success
	assert_output --partial "<title>Burrowrs · notes</title>"
	refute_output --partial "{{"
	run "${base[@]}" -o /dev/null -w '%{http_code}' "https://$DOMAIN:$PROXY_PORT/notes/film.html"
	assert_output 200
	run "${base[@]}" -w '\n%{http_code}' "https://$DOMAIN:$PROXY_PORT/wp-login.php"
	[[ ${lines[-1]} == 404 ]]
	assert_output --partial "Not found"
	headers=$("${base[@]}" -I "https://$DOMAIN:$PROXY_PORT/")
	grep -qi '^strict-transport-security: max-age=31536000' <<<"$headers"
	grep -qi '^x-content-type-options: nosniff' <<<"$headers"
	grep -qi '^server: Caddy' <<<"$headers"
}

@test "plain HTTP redirects to the public HTTPS port, never the internal one" {
	run curl -s --max-time 10 -o /dev/null -w '%{http_code} %{redirect_url}' -H "Host: $DOMAIN" "http://127.0.0.1:$HTTP_PORT/about.html"
	# The test stack's proxy port is not 443, so the redirect must carry it.
	assert_output "301 https://$DOMAIN:$PROXY_PORT/about.html"
	refute_output --partial ":8443"
}

@test "metrics count connections that were not valid clients" {
	run curl -fsS --max-time 5 "http://127.0.0.1:$METRICS_PORT/metrics"
	assert_success
	bad=$(awk '/^telemt_connections_bad_total / {print $2}' <<<"$output")
	((${bad%.*} > 0))
}

@test "metrics and the API are not reachable from the edge network" {
	# The API listens on 127.0.0.1 inside telemt's namespace only.
	run tools_in_edge_http telemt 9091 /v1/users
	assert_failure
}

@test "share writes private QR files" {
	run burrowrs share
	assert_success
	[[ $(head -c 8 "$BURROWRS_STATE_DIR/share/burrowrs-proxy.png" | od -An -tx1 | tr -d ' \n') == 89504e470d0a1a0a ]]
	[[ $(stat -c %a "$BURROWRS_STATE_DIR/share/burrowrs-proxy.png") == 600 ]]
	grep -q '<svg' "$BURROWRS_STATE_DIR/share/burrowrs-proxy.svg"
}

@test "logs are available and never contain the secret or a link" {
	run burrowrs logs telemt
	assert_success
	refute_output --partial "$(burrowrs config get SECRET)"
	refute_output --partial "tg://proxy"
}

@test "a config change recreates only the container it affects" {
	telemt_before=$(container telemt) decoy_before=$(container decoy)
	burrowrs config set MAX_CONNECTIONS 4096
	run burrowrs up
	assert_success
	[[ $(container telemt) != "$telemt_before" ]]
	[[ $(container decoy) == "$decoy_before" ]]
	grep -q '^max_connections = 4096$' "$BURROWRS_STATE_DIR/telemt/config.toml"
}

@test "rotate: the old link stops working, the new one works, without a restart" {
	before=$(docker inspect -f '{{.State.StartedAt}}' "$(container telemt)")
	old=$(burrowrs link --format secret)
	run burrowrs rotate --yes
	assert_success
	new=$(burrowrs link --format secret)
	[[ $old != "$new" ]]
	run tools_host "$old" probe --host 127.0.0.1 --port "$PROXY_PORT" --expect fronted --retries 10
	assert_success
	run tools_host "$new" probe --host 127.0.0.1 --port "$PROXY_PORT" --retries 5
	assert_success
	[[ $(docker inspect -f '{{.State.StartedAt}}' "$(container telemt)") == "$before" ]]
}

@test "a crashed proxy is restarted by Docker" {
	pid=$(docker inspect -f '{{.State.Pid}}' "$(container telemt)")
	if ((EUID == 0)); then kill -9 "$pid"; elif sudo -n true 2>/dev/null; then sudo kill -9 "$pid"; else skip "needs root to kill the container process"; fi
	for _ in {1..30}; do
		[[ $(docker inspect -f '{{.RestartCount}}' "$(container telemt)") -ge 1 ]] && break
		sleep 1
	done
	run tools_host "$(burrowrs link --format secret)" probe --host 127.0.0.1 --port "$PROXY_PORT" --retries 20
	assert_success
}

@test "the watchdog recreates a hung proxy" {
	before=$(container telemt)
	docker pause "$before" >/dev/null
	BURROWRS_WATCHDOG_TIMEOUT=3 run burrowrs watchdog
	assert_success
	[[ $(container telemt) != "$before" ]]
	run burrowrs watchdog
	assert_output --partial "proxy healthy"
}

@test "doctor passes (findings that are expected with self-signed TLS are warnings)" {
	run burrowrs doctor
	assert_success
	assert_output --partial "is valid (stealth mode)"
}

@test "down keeps the certificate volume; up brings everything back" {
	run burrowrs down
	assert_success
	docker volume inspect "${BURROWRS_PROJECT}_decoy-data" >/dev/null
	run burrowrs up
	assert_success
	run burrowrs smoke --no-telegram
	assert_success
}
