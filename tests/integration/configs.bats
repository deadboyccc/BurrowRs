#!/usr/bin/env bats
# The real telemt and Caddy binaries accept every config burrowrs can render.

setup_file() {
	load ../helpers
	have_docker || return 0
	docker image inspect "$(pinned_image telemt)" >/dev/null 2>&1 || docker pull -q "$(pinned_image telemt)" >/dev/null
	docker image inspect "$(pinned_image decoy)" >/dev/null 2>&1 || docker pull -q "$(pinned_image decoy)" >/dev/null
}

setup() {
	load ../helpers
	require_docker
	isolate
	NAME=burrowrs-cfg-test-$$-$RANDOM
}

teardown() {
	[[ -z ${NAME-} ]] || docker rm -f "$NAME" >/dev/null 2>&1 || true
}

# telemt_accepts: start the real telemt, offline, on the rendered files, the
# way compose runs it (read-only, uid 65534). With config_strict, a bad key or
# value stops it at once; a config it accepts keeps it running.
telemt_accepts() {
	burrowrs render >/dev/null
	docker run -d --name "$NAME" --network none --memory 128m --read-only --user 65534:65534 \
		--tmpfs /run/telemt:uid=65534,gid=65534,mode=0700 --tmpfs /var/lib/telemt:uid=65534,gid=65534,mode=0700 \
		-w /run/telemt -v "$BURROWRS_STATE_DIR/telemt:/etc/telemt:ro" \
		--entrypoint /app/telemt "$(pinned_image telemt)" run /etc/telemt/config.toml >/dev/null
	local i running=false
	for i in {1..30}; do
		running=$(docker inspect -f '{{.State.Running}}' "$NAME")
		[[ $running == true ]] && docker logs "$NAME" 2>&1 | grep -q 'Telemt MTProxy' && break
		[[ $running == true ]] || break
		sleep 0.2
	done
	sleep 2 # past the config and users parse
	run docker inspect -f '{{.State.Running}}' "$NAME"
	if [[ $output != true ]]; then
		docker logs "$NAME" >&2 || true
	fi
	assert_output true
	run docker logs "$NAME"
	refute_output --partial "Config error"
}

caddy_accepts() {
	burrowrs render >/dev/null
	run docker run --rm --network none --memory 128m \
		-v "$BURROWRS_STATE_DIR/Caddyfile:/etc/caddy/Caddyfile:ro" "$(pinned_image decoy)" \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
	assert_success
	assert_output --partial "Valid configuration"
}

@test "telemt: stealth defaults (shared secret)" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --quiet
	telemt_accepts
}

@test "telemt: simple mode" {
	burrowrs init --cover-domain www.example.com --ipv4 203.0.113.7 --quiet
	telemt_accepts
}

@test "telemt: users mode with every kind of limit, IPv6, ad tag and debug logging" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --ipv6 2001:db8::7 --enable-ipv6 --access users --quiet
	burrowrs config set AD_TAG 0123456789abcdef0123456789abcdef LOG_LEVEL debug MAX_CONNECTIONS 500 >/dev/null # gitleaks:allow
	burrowrs user add alice --days 30 --quota 50G --period monthly --ips 2 >/dev/null
	burrowrs user add bob --forever --quota 1T --period weekly --ips none >/dev/null
	burrowrs user add carol --until 2020-01-01 --quota none >/dev/null
	burrowrs user add dave --quota 10M --period daily >/dev/null
	burrowrs user disable carol >/dev/null
	telemt_accepts
}

@test "telemt: rejects a broken config (the check above can fail)" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --quiet
	burrowrs render >/dev/null
	sed -i 's/^beobachten = false/beobachtenX = false/' "$BURROWRS_STATE_DIR/telemt/config.toml"
	run docker run --rm --network none --memory 128m --read-only --user 65534:65534 \
		-v "$BURROWRS_STATE_DIR/telemt:/etc/telemt:ro" --entrypoint /app/telemt "$(pinned_image telemt)" \
		run /etc/telemt/config.toml
	assert_failure
	assert_output --partial "unknown config keys"
}

@test "caddy: production (ACME) config" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --email ops@example.org --quiet
	caddy_accepts
}

@test "caddy: staging CA" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 \
		--acme-ca https://acme-staging-v02.api.letsencrypt.org/directory --quiet
	caddy_accepts
}

@test "caddy: internal TLS (tests and try)" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --tls internal --quiet
	caddy_accepts
}

@test "tools image runs unprivileged on a read-only root" {
	docker image inspect "burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" >/dev/null 2>&1 ||
		docker build --quiet --target runtime -t "burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" "$BURROWRS_ROOT/tools" >/dev/null
	run docker run --rm --read-only --network none --cap-drop ALL "burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" --version
	assert_success
	run docker image inspect -f '{{.Config.User}}' "burrowrs-tools:$(burrowrs version | cut -d' ' -f2)"
	assert_output 65534:65534
}
