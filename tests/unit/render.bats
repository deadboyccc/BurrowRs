#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
	isolate
	STATE_DIR=$BURROWRS_STATE_DIR
	USERS_FILE=$BURROWRS_USERS_FILE
	stealth_config
}

@test "config.toml (stealth): FakeTLS only, masks to the decoy by IP on 8443" {
	run render_telemt_toml
	assert_success
	assert_line 'config_strict = true'
	assert_output --partial $'[general.modes]\nclassic = false\nsecure = false\ntls = true'
	assert_line 'port = 3128'
	assert_line 'tls_domain = "notes.example.org"'
	assert_line 'unknown_sni_action = "mask"'
	assert_output --partial $'mask = true\nmask_host = "10.204.47.10"\nmask_port = 8443'
	assert_line 'tls_emulation = true'
	assert_line 'tls_front_dir = "/run/telemt/tlsfront"'
	assert_line 'quota_state_path = "/var/lib/telemt/quota.json"'
	assert_line 'max_connections = 10000'
	assert_line 'metrics_listen = "0.0.0.0:3129"'
	assert_line 'metrics_whitelist = ["127.0.0.0/8", "10.204.47.0/28"]'
	assert_line 'stun_use = false'
	# Users come from the included file, so user changes never touch this one.
	assert_line 'include = "/etc/telemt/users.toml"'
	refute_output --partial "$SECRET"
	refute_output --partial '[access.users]'
}

@test "config.toml: the include directive is the last line" {
	render_telemt_toml >"$BATS_TEST_TMPDIR/config.toml"
	[[ $(tail -n 1 "$BATS_TEST_TMPDIR/config.toml") == 'include = "/etc/telemt/users.toml"' ]]
}

@test "config.toml (simple): masks to the cover domain itself" {
	BURROWRS_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2
	run render_telemt_toml
	assert_line 'tls_domain = "www.example.com"'
	assert_line 'mask = true'
	refute_output --partial 'mask_host'
	refute_output --partial 'mask_port'
}

@test "config.toml: IPv6 adds a second listener" {
	run render_telemt_toml
	refute_line 'ip = "::"'
	ENABLE_IPV6=true
	run render_telemt_toml
	assert_line 'ip = "0.0.0.0"'
	assert_line 'ip = "::"'
}

@test "config.toml: AD_TAG switches to Telegram's middle proxies with our public IP" {
	run render_telemt_toml
	assert_line 'use_middle_proxy = false'
	refute_output --partial 'ad_tag'
	AD_TAG=00112233445566778899aabbccddeeff PUBLIC_IPV4=203.0.113.7 # gitleaks:allow (fake fixture)
	run render_telemt_toml
	assert_line 'use_middle_proxy = true'
	assert_line 'ad_tag = "00112233445566778899aabbccddeeff"' # gitleaks:allow (fake fixture)
	assert_line 'middle_proxy_nat_ip = "203.0.113.7"'
}

@test "config.toml: the control API is read-only and loopback-only" {
	run render_telemt_toml
	assert_output --partial $'[server.api]'
	assert_line 'listen = "127.0.0.1:9091"'
	assert_line 'whitelist = ["127.0.0.1/32"]'
	assert_line 'read_only = true'
}

@test "config.toml: capacity and log level come from .env" {
	MAX_CONNECTIONS=2048 LOG_LEVEL=normal
	run render_telemt_toml
	assert_line 'max_connections = 2048'
	assert_line 'log_level = "normal"'
}

@test "users.toml (shared): only the owner, with SECRET" {
	ACCESS_MODE=shared
	users_reset
	run render_users_toml
	assert_success
	assert_output --partial $'[access.users]\n"owner" = "'"$SECRET"'"'
	refute_output --partial 'user_expirations'
	refute_output --partial 'user_data_quota'
}

@test "users.toml (shared): users.tsv is ignored" {
	ACCESS_MODE=shared
	write_users alice
	render_all
	run cat "$STATE_DIR/telemt/users.toml"
	refute_output --partial alice
}

write_users() { # write_users NAME...: one default row per name in users.tsv
	local name
	{
		printf '%s\n' "$USERS_HEADER"
		for name in "$@"; do
			printf '%s\t%s\tnever\tnone\tnone\tnone\ton\t2026-11-18\n' "$name" "$(key_new)"
		done
	} >"$USERS_FILE"
}

@test "users.toml (users): every table, with the right values" {
	ACCESS_MODE=users
	{
		printf 'alice\t00000000000000000000000000000001\t2026-12-31T23:59:59Z\t50G\tmonthly\t2\ton\t2026-11-18\n'
		printf 'bob\t00000000000000000000000000000002\tnever\tnone\tnone\tnone\toff\t2026-11-18\n'
		printf 'carol\t00000000000000000000000000000003\t2027-01-15T23:59:59Z\t512m\tnone\t1\ton\t2026-11-18\n'
	} >"$USERS_FILE"
	users_load "$USERS_FILE"
	run render_users_toml
	assert_success
	assert_output "# Rendered by burrowrs. Do not edit: use ./burrowrs user

[access.users]
\"owner\" = \"$SECRET\"
\"alice\" = \"00000000000000000000000000000001\"
\"bob\" = \"00000000000000000000000000000002\"
\"carol\" = \"00000000000000000000000000000003\"

[access.user_enabled]
\"bob\" = false

[access.user_expirations]
\"alice\" = \"2026-12-31T23:59:59Z\"
\"carol\" = \"2027-01-15T23:59:59Z\"

[access.user_data_quota]
\"alice\" = 53687091200
\"carol\" = 536870912

[access.user_quota_periods]
\"alice\" = \"monthly\"

[access.user_max_unique_ips]
\"alice\" = 2
\"carol\" = 1"
}

@test "users.toml (users): no users yet is just the owner and empty tables" {
	ACCESS_MODE=users
	render_all
	run cat "$STATE_DIR/telemt/users.toml"
	assert_output --partial $'[access.users]\n"owner" = "'"$SECRET"$'"\n\n[access.user_enabled]'
	[[ $(grep -c '^"' "$STATE_DIR/telemt/users.toml") == 1 ]]
}

@test "Caddyfile: internal TLS for tests, ACME settings for production" {
	run render_caddyfile
	assert_output --partial $'notes.example.org {\n\ttls internal'
	assert_output --partial "skip_install_trust"
	assert_output --partial "protocols h1 h2"
	assert_output --partial "admin off"
	assert_output --partial 'redir https://{host}{uri} permanent'

	TLS_MODE=acme ACME_EMAIL=me@example.org ACME_CA=https://acme-staging-v02.api.letsencrypt.org/directory
	run render_caddyfile
	refute_output --partial "tls internal"
	refute_output --partial "skip_install_trust"
	assert_output --partial $'\temail me@example.org'
	assert_output --partial $'\tacme_ca https://acme-staging-v02.api.letsencrypt.org/directory'
}

@test "site name and accent are derived from the domain" {
	run site_name notes.alice.dev
	assert_output Alice
	run site_name my-garden.example
	assert_output "My garden"
	a=$(site_accent notes.alice.dev)
	[[ $a == "$(site_accent notes.alice.dev)" && $a =~ ^#[0-9a-f]{6}$ ]]
}

@test "render_all: personalised site with no template markers left" {
	render_all
	run grep -rl '{{' "$STATE_DIR/site"
	assert_failure
	grep -q "<title>Example · notes</title>" "$STATE_DIR/site/index.html"
	grep -q "notes.example.org" "$STATE_DIR/site/notes/film.html"
}

@test "render_all: permissions keep the secret private" {
	render_all
	[[ $(stat -c %a "$STATE_DIR") == 700 ]]
	[[ $(stat -c %a "$STATE_DIR/telemt") == 755 ]]
	[[ $(stat -c %a "$STATE_DIR/telemt/config.toml") == 644 ]]
	[[ $(stat -c %a "$STATE_DIR/telemt/users.toml") == 644 ]]
	[[ $(stat -c %a "$STATE_DIR/compose.env") == 600 ]]
	[[ $(stat -c %a "$STATE_DIR/share") == 700 ]]
	[[ $(stat -c %a "$STATE_DIR/site/index.html") == 644 ]]
}

@test "render_all: unchanged config keeps inodes, so running containers stay attached" {
	ACCESS_MODE=users
	write_users alice
	render_all
	site=$(stat -c %i "$STATE_DIR/site") conf=$(stat -c %i "$STATE_DIR/telemt/config.toml")
	users=$(stat -c %i "$STATE_DIR/telemt/users.toml") env=$(stat -c %i "$STATE_DIR/compose.env")
	render_all
	assert_equal "$(stat -c %i "$STATE_DIR/site") $(stat -c %i "$STATE_DIR/telemt/config.toml")" "$site $conf"
	assert_equal "$(stat -c %i "$STATE_DIR/telemt/users.toml") $(stat -c %i "$STATE_DIR/compose.env")" "$users $env"
}

@test "render_all: hashes change exactly when their inputs change" {
	render_all
	before=$(<"$STATE_DIR/compose.env")
	telemt_before=$(grep TELEMT_CONFIG_HASH <<<"$before") decoy_before=$(grep DECOY_CONFIG_HASH <<<"$before")
	MAX_CONNECTIONS=1024
	render_all
	after=$(<"$STATE_DIR/compose.env")
	[[ $(grep TELEMT_CONFIG_HASH <<<"$after") != "$telemt_before" ]]
	[[ $(grep DECOY_CONFIG_HASH <<<"$after") == "$decoy_before" ]]
}

@test "render_all: user changes rewrite users.toml but never the proxy's config hash" {
	ACCESS_MODE=users
	write_users alice
	render_all
	hash=$(grep TELEMT_CONFIG_HASH "$STATE_DIR/compose.env")
	write_users alice bob carol
	render_all
	grep -q '^"bob" = ' "$STATE_DIR/telemt/users.toml"
	SECRET=$(key_new)
	render_all
	grep -q "^\"owner\" = \"$SECRET\"" "$STATE_DIR/telemt/users.toml"
	assert_equal "$(grep TELEMT_CONFIG_HASH "$STATE_DIR/compose.env")" "$hash"
}

@test "render_users: rewrites users.toml alone, from users.tsv" {
	ACCESS_MODE=users
	render_all
	conf=$(stat -c %i "$STATE_DIR/telemt/config.toml") env=$(<"$STATE_DIR/compose.env")
	write_users dave
	render_users
	grep -q '^"dave" = ' "$STATE_DIR/telemt/users.toml"
	[[ $(stat -c %i "$STATE_DIR/telemt/config.toml") == "$conf" && $(<"$STATE_DIR/compose.env") == "$env" ]]
}

@test "render_all: a custom site.local/ wins over the template" {
	export BURROWRS_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROWRS_ROOT/site.local"
	printf '<h1>{{SITE_NAME}} custom</h1>\n' >"$BURROWRS_ROOT/site.local/index.html"
	render_all
	[[ $(<"$STATE_DIR/site/index.html") == "<h1>Example custom</h1>" ]]
}

@test "render_all: simple mode still provides the bind sources compose checks" {
	BURROWRS_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2
	render_all
	[[ -f $STATE_DIR/Caddyfile && -d $STATE_DIR/site && -f $STATE_DIR/telemt/config.toml ]]
}

@test "compose_args picks profiles and overlays from the config" {
	compose_args
	[[ " ${COMPOSE_ARGS[*]} " == *" --profile stealth "* ]]
	[[ " ${COMPOSE_ARGS[*]} " != *compose.ipv6.yaml* ]]
	ENABLE_IPV6=true LOGGING=off BURROWRS_MODE=simple
	compose_args
	[[ " ${COMPOSE_ARGS[*]} " == *compose.ipv6.yaml* && " ${COMPOSE_ARGS[*]} " == *compose.nolog.yaml* ]]
	[[ " ${COMPOSE_ARGS[*]} " != *"--profile stealth"* ]]
}

@test "Caddyfile: redirects keep a non-standard proxy port and dotfiles stay hidden" {
	run render_caddyfile
	assert_output --partial 'redir https://{host}{uri} permanent'
	assert_output --partial 'hide .*'
	PROXY_PORT=8443
	run render_caddyfile
	assert_output --partial 'redir https://{host}:8443{uri} permanent'
}

@test "compose.env: values are single-quoted; IPv6 binding follows BIND_ADDR" {
	render_all
	grep -qx "BIND_ADDR6='::'" "$STATE_DIR/compose.env"
	grep -qx "BURROWRS_STATE_DIR='$STATE_DIR'" "$STATE_DIR/compose.env"
	BIND_ADDR=127.0.0.1
	render_all
	grep -qx "BIND_ADDR6='::1'" "$STATE_DIR/compose.env"
}

@test "render_all: changed site content is synced into the same directory" {
	export BURROWRS_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROWRS_ROOT/site.local"
	printf 'one\n' >"$BURROWRS_ROOT/site.local/index.html"
	render_all
	inode=$(stat -c %i "$STATE_DIR/site")
	printf 'two\n' >"$BURROWRS_ROOT/site.local/index.html"
	render_all
	[[ $(stat -c %i "$STATE_DIR/site") == "$inode" ]]
	[[ $(<"$STATE_DIR/site/index.html") == two ]]
	run find "$STATE_DIR" -maxdepth 1 -name 'site.new*'
	assert_output ""
}

@test "render_all: re-synced sites stay readable by the unprivileged decoy" {
	export BURROWRS_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROWRS_ROOT/site.local/notes"
	printf 'one\n' >"$BURROWRS_ROOT/site.local/index.html"
	printf 'old\n' >"$BURROWRS_ROOT/site.local/old.html"
	printf 'n\n' >"$BURROWRS_ROOT/site.local/notes/a.html"
	render_all
	printf 'two\n' >"$BURROWRS_ROOT/site.local/index.html"
	rm "$BURROWRS_ROOT/site.local/old.html"
	render_all
	[[ $(<"$STATE_DIR/site/index.html") == two && ! -e $STATE_DIR/site/old.html ]]
	run find "$STATE_DIR/site" -type f ! -perm 0644
	assert_output ""
	run find "$STATE_DIR/site" -type d ! -perm 0755
	assert_output ""
}

@test "render_all: a symlinked site directory is refused" {
	mkdir -p "$STATE_DIR" "$BATS_TEST_TMPDIR/elsewhere"
	ln -s "$BATS_TEST_TMPDIR/elsewhere" "$STATE_DIR/site"
	run render_all
	assert_failure
	assert_output --partial "not a symlink"
}

@test "Caddyfile: the CSP allows self-hosted fonts" {
	run render_caddyfile
	assert_output --partial "font-src 'self'"
}

@test "render_all: dotfiles in site.local are never published" {
	export BURROWRS_ROOT=$BATS_TEST_TMPDIR/root
	mkdir -p "$BURROWRS_ROOT/site.local/.git" "$BURROWRS_ROOT/site.local/notes"
	printf 'hi\n' >"$BURROWRS_ROOT/site.local/index.html"
	printf '[user]\nemail = me@example.org\n' >"$BURROWRS_ROOT/site.local/.git/config"
	: >"$BURROWRS_ROOT/site.local/notes/.DS_Store"
	render_all
	run find "$STATE_DIR/site" -name '.*'
	assert_output ""
	[[ -f $STATE_DIR/site/index.html ]]
}

@test "privacy: the decoy never keeps access logs" {
	run render_caddyfile
	refute_output --regexp '(^|[[:space:]])log([[:space:]]|$)'
	TLS_MODE=acme ACME_EMAIL=me@example.org
	run render_caddyfile
	refute_output --regexp '(^|[[:space:]])log([[:space:]]|$)'
}

@test "privacy: telemt logs warnings only by default, keeps no per-IP observations and never logs links" {
	config_reset
	DOMAIN=notes.example.org
	config_set_defaults
	SECRET=$(key_new)
	run render_telemt_toml
	assert_line 'log_level = "silent"'
	assert_line 'beobachten = false'
	assert_output --partial $'[general.links]\n# Never print links (they contain secrets) to the logs.\nshow = []'
}

@test "privacy: the telemt service keeps no per-IP observation file" {
	run grep -n 'beobachten' "$BURROWRS_ROOT/compose.yaml"
	assert_failure
}

@test "privacy: every LOG_LEVEL's log filter switches off telemt::links" {
	local level got=()
	for level in silent normal verbose debug; do
		LOG_LEVEL=$level
		got+=("$(telemt_rust_log)")
	done
	assert_equal "${got[*]}" \
		"warn,telemt::links=off info,telemt::links=off debug,telemt::links=off trace,telemt::links=off"
}

@test "privacy: compose.env carries the filter and compose passes it to telemt as RUST_LOG" {
	run render_compose_env telemthash decoyhash
	assert_line "TELEMT_RUST_LOG='warn,telemt::links=off'"
	# shellcheck disable=SC2016 # the literal compose interpolation is the point
	run grep -nE '^ +RUST_LOG: \$\{TELEMT_RUST_LOG:\?' "$BURROWRS_ROOT/compose.yaml"
	assert_success
	# ... in the telemt service, not somewhere else.
	run awk '/^  [a-z-]+:$/ {svc=$1} /RUST_LOG:/ {print svc}' "$BURROWRS_ROOT/compose.yaml"
	assert_output "telemt:"
}

@test "compose: the proxy container gets the host's per-namespace TCP tuning" {
	# These settings are per network namespace: the host profile never reaches
	# the proxy's sockets unless compose.yaml repeats them for the telemt container.
	local key host container drift=""
	for key in net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.tcp_slow_start_after_idle \
		net.ipv4.tcp_mtu_probing net.ipv4.tcp_notsent_lowat net.ipv4.tcp_fin_timeout \
		net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes; do
		host=$(sed -n "s/^${key//./\\.} = //p" "$BURROWRS_ROOT/deploy/sysctl/99-burrowrs.conf")
		container=$(sed -n "s/^ *${key//./\\.}: \"\(.*\)\"$/\1/p" "$BURROWRS_ROOT/compose.yaml")
		[[ -n $host && $host == "$container" ]] || drift+="$key: host '$host', telemt container '$container'"$'\n'
	done
	assert_equal "$drift" ""
}

@test "compose.env: memory limits and both config hashes" {
	TELEMT_MEMORY_LIMIT=256m DECOY_MEMORY_LIMIT=128m
	run render_compose_env telemthash decoyhash
	assert_output --partial "TELEMT_MEMORY_LIMIT='256m'"
	assert_output --partial "DECOY_MEMORY_LIMIT='128m'"
	assert_output --partial "TELEMT_CONFIG_HASH='telemthash'"
	assert_output --partial "DECOY_CONFIG_HASH='decoyhash'"
	refute_output --partial GOMEMLIMIT
}

@test "compose: the users directory is mounted read-only, never single files" {
	# shellcheck disable=SC2016 # the literal compose interpolation is the point
	run grep -A3 'source: ${BURROWRS_STATE_DIR:?render with ./burrowrs up}/telemt$' "$BURROWRS_ROOT/compose.yaml"
	assert_success
	assert_output --partial 'target: /etc/telemt'
	assert_output --partial 'read_only: true'
}
