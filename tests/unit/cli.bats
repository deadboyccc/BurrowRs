#!/usr/bin/env bats
# The CLI without Docker: argument handling, init, config, links.

setup() {
	load ../helpers
	isolate
}

init_stealth() {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --quiet "$@"
}

@test "help and version" {
	run burrowrs help
	assert_success
	assert_output --partial "Telegram proxy"
	assert_output --partial "user       add | list"
	run burrowrs version
	assert_output --regexp '^burrowrs [0-9]+\.[0-9]+\.[0-9]+$'
}

@test "unknown commands and options fail clearly" {
	run burrowrs frobnicate
	assert_failure
	assert_output --partial "unknown command: frobnicate"
	run burrowrs init --bogus
	assert_failure
	assert_output --partial "unknown option: --bogus"
}

@test "init: stealth mode needs a domain, simple mode a cover domain" {
	run burrowrs init --ipv4 203.0.113.7
	assert_failure
	assert_output --partial "needs --domain"
	run burrowrs init --mode simple --ipv4 203.0.113.7
	assert_failure
	assert_output --partial "needs --cover-domain"
}

@test "init: writes a private, valid .env with a fresh secret" {
	run init_stealth --email me@example.org
	assert_success
	[[ $(stat -c %a "$BURROWRS_ENV_FILE") == 600 ]]
	grep -Eq '^SECRET=[0-9a-f]{32}$' "$BURROWRS_ENV_FILE"
	grep -q '^ACME_EMAIL=me@example.org$' "$BURROWRS_ENV_FILE"
	grep -q '^ACCESS_MODE=shared$' "$BURROWRS_ENV_FILE"
}

@test "init --access users: per-user mode, and the next step says how to add users" {
	run init_stealth --access users
	assert_success
	grep -q '^ACCESS_MODE=users$' "$BURROWRS_ENV_FILE"
	run burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --access users --force
	assert_success
	assert_output --partial "./burrowrs user add"
	run burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --access everyone --force
	assert_failure
	assert_output --partial ACCESS_MODE
}

@test "init: lowercases domains and infers simple mode" {
	run burrowrs init --cover-domain WWW.Example.COM --ipv4 203.0.113.7 --quiet
	assert_success
	grep -q '^BURROWRS_MODE=simple$' "$BURROWRS_ENV_FILE"
	grep -q '^COVER_DOMAIN=www.example.com$' "$BURROWRS_ENV_FILE"
}

@test "init: refuses to overwrite an existing secret without --force" {
	init_stealth
	first=$(grep ^SECRET= "$BURROWRS_ENV_FILE")
	run init_stealth
	assert_failure
	assert_output --partial "--force"
	run init_stealth --force
	assert_success
	[[ $(grep ^SECRET= "$BURROWRS_ENV_FILE") != "$first" ]]
}

@test "init: rejects invalid input before writing anything" {
	run burrowrs init --domain 'notes.example.org;id' --ipv4 203.0.113.7
	assert_failure
	[[ ! -e $BURROWRS_ENV_FILE ]]
	run burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --port 70000
	assert_failure
	assert_output --partial PROXY_PORT
}

@test "init --subnet derives the decoy address" {
	init_stealth --subnet 10.250.1.32/28
	run burrowrs config get DECOY_IP
	assert_output 10.250.1.42
}

@test "config show redacts the secret" {
	init_stealth
	secret=$(burrowrs config get SECRET)
	run burrowrs config show
	assert_success
	assert_output --partial "DOMAIN=notes.example.org"
	refute_output --partial "$secret"
	assert_output --partial "SECRET=${secret:0:6}…"
}

@test "config set checks every pair before writing anything" {
	init_stealth
	before=$(<"$BURROWRS_ENV_FILE")
	run burrowrs config set PROXY_PORT 8443 NOT_A_KEY 1
	assert_failure
	[[ $(<"$BURROWRS_ENV_FILE") == "$before" ]]
	run burrowrs config set ACME_EMAIL "a'b@example.org"
	assert_failure
	[[ $(<"$BURROWRS_ENV_FILE") == "$before" ]]
	run ls -A "$(dirname "$BURROWRS_ENV_FILE")"
	refute_output --partial ".env."
}

@test "config set DOMAIN keeps the secret but warns that every link changes" {
	init_stealth
	old=$(burrowrs config get SECRET)
	old_link=$(burrowrs link --format tg)
	run burrowrs config set DOMAIN blog.example.net
	assert_success
	assert_output --partial "every link changes"
	[[ $(burrowrs config get SECRET) == "$old" ]]
	[[ $(burrowrs link --format tg) != "$old_link" ]]
	[[ $(stat -c %a "$BURROWRS_ENV_FILE") == 600 ]]
	# The port is in every link too; settings outside the links are not.
	run burrowrs config set PROXY_PORT 8443
	assert_success
	assert_output --partial "every link changes"
	run burrowrs config set LOGGING off
	assert_success
	refute_output --partial "every link changes"
}

@test "config set without a .env explains instead of creating one" {
	run burrowrs config set PROXY_PORT 8443
	assert_failure
	assert_output --partial "burrowrs init"
	[[ ! -e $BURROWRS_ENV_FILE ]]
}

@test "failures are failures: init into an unwritable place exits non-zero" {
	mkdir -p "$BATS_TEST_TMPDIR/ro"
	chmod 0500 "$BATS_TEST_TMPDIR/ro"
	if ((EUID == 0)); then skip "root can write anywhere"; fi
	BURROWRS_ENV_FILE=$BATS_TEST_TMPDIR/ro/.env run burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --quiet
	assert_failure
	refute_output --partial "wrote"
}

@test "failures are failures: down exits non-zero when Docker fails" {
	init_stealth
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/sh\necho "docker: broken" >&2\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/docker"
	chmod +x "$BATS_TEST_TMPDIR/bin/docker"
	PATH=$BATS_TEST_TMPDIR/bin:$PATH run burrowrs down
	assert_failure
	refute_output --partial "stopped"
}

@test "smoke --link accepts base64 secrets and checks links before needing Docker" {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/docker"
	chmod +x "$BATS_TEST_TMPDIR/bin/docker"
	# A valid base64 link (fake secret) gets past parsing and only then needs Docker.
	PATH=$BATS_TEST_TMPDIR/bin:$PATH run burrowrs smoke --link "tg://proxy?server=203.0.113.7&port=443&secret=7gARIjNEVWZ3iJmqu8zd7v9ub3Rlcy5leGFtcGxlLm9yZw" # gitleaks:allow (fake fixture)
	assert_failure
	assert_output --partial "Docker daemon"
	# A legacy (non-FakeTLS) secret is rejected before Docker is consulted.
	PATH=$BATS_TEST_TMPDIR/bin:$PATH run burrowrs smoke --link "tg://proxy?server=203.0.113.7&port=443&secret=3QARIjNEVWZ3iJmqu8zd7v9ub3Rlcy5leGFtcGxlLm9yZw" # gitleaks:allow (fake fixture)
	assert_failure
	assert_output --partial "does not carry a FakeTLS secret"
	refute_output --partial "Docker daemon"
}

@test "--help never runs the command (uninstall, rotate, up, down)" {
	init_stealth
	burrowrs render >/dev/null
	before=$(<"$BURROWRS_ENV_FILE")
	printf 'keep\tme\n' >"$BURROWRS_USERS_FILE"
	for cmd in uninstall rotate up down status doctor share watchdog try update restart render user; do
		run burrowrs "$cmd" --help
		assert_success
		assert_output --partial "Usage: burrowrs"
	done
	[[ $(<"$BURROWRS_ENV_FILE") == "$before" ]]
	[[ -d $BURROWRS_STATE_DIR && $(<"$BURROWRS_USERS_FILE") == $'keep\tme' ]]
	run burrowrs user add alice --help
	assert_success
	assert_output --partial "Usage: burrowrs user"
	[[ $(<"$BURROWRS_USERS_FILE") == $'keep\tme' ]]
}

@test "commands reject arguments they don't understand" {
	init_stealth
	for args in "up --bogus" "down --purge" "rotate now" "uninstall --volumes" "status x"; do
		# shellcheck disable=SC2086 # word splitting intended
		run burrowrs $args
		assert_failure
		assert_output --partial "unknown argument"
	done
}

@test "rotate refuses to run unattended without --yes" {
	init_stealth
	before=$(burrowrs config get SECRET)
	run burrowrs rotate </dev/null
	assert_failure
	assert_output --partial "--yes"
	[[ $(burrowrs config get SECRET) == "$before" ]]
}

@test "config set leaves no copy of the secret behind on failure" {
	init_stealth
	printf 'garbage line\n' >>"$BURROWRS_ENV_FILE"
	run burrowrs config set LOGGING off
	assert_failure
	run find "$(dirname "$BURROWRS_ENV_FILE")" -maxdepth 1 -name '.env.*'
	assert_output ""
}

@test "status before the first up explains instead of failing obscurely" {
	require_docker
	init_stealth
	run burrowrs status
	assert_failure
	assert_output --partial "has not been started here yet"
	refute_output --partial "failed (exit"
}

@test "paths with quotes or backslashes are refused" {
	run env BURROWRS_STATE_DIR="$BATS_TEST_TMPDIR/bad\\" "$BURROWRS_ROOT/burrowrs" version
	assert_failure
	assert_output --partial "unsupported characters"
}

@test "attacker-controlled link fields never reach the terminal raw" {
	run burrowrs smoke --link 'tg://proxy?server=x%1b]0;pwned%07%0dall-good&port=443&secret=ee00'
	assert_failure
	[[ $output != *$'\e'* && $output != *$'\r'* ]]
}

@test "link errors never echo the secret" {
	require_docker
	run burrowrs smoke --link "tg://proxy?server=bad_host!&port=443&secret=ee0011223344556677889900aabbccddeeff" # gitleaks:allow (fake fixture)
	assert_failure
	refute_output --partial "ee0011223344556677889900"
}

@test "config set validates, and rolls back on error" {
	init_stealth
	run burrowrs config set PROXY_PORT 8443 ACME_EMAIL ops@example.org
	assert_success
	[[ $(burrowrs config get PROXY_PORT) == 8443 ]]
	before=$(<"$BURROWRS_ENV_FILE")
	run burrowrs config set PROXY_PORT 99999
	assert_failure
	[[ $(<"$BURROWRS_ENV_FILE") == "$before" ]]
	run burrowrs config set SECRET 00112233445566778899aabbccddeeff # gitleaks:allow (fake fixture)
	assert_failure
	assert_output --partial "burrowrs rotate"
	run burrowrs config set NOT_A_KEY 1
	assert_failure
}

@test "link prints app and web links on stdout" {
	init_stealth
	key=$(burrowrs config get SECRET)
	secret=ee${key}6e6f7465732e6578616d706c652e6f7267
	run burrowrs link
	assert_success
	assert_line --index 0 "tg://proxy?server=notes.example.org&port=443&secret=$secret"
	assert_line --index 1 "https://t.me/proxy?server=notes.example.org&port=443&secret=$secret"
	run burrowrs link --format secret
	assert_output "$secret"
	run burrowrs link --format tme
	assert_output "https://t.me/proxy?server=notes.example.org&port=443&secret=$secret"
	run burrowrs link --format qr
	assert_failure
	assert_output --partial "unknown format"
}

@test "link uses LINK_HOST when set" {
	init_stealth --link-host 203.0.113.7
	run burrowrs link --format tg
	assert_output --regexp '^tg://proxy\?server=203\.0\.113\.7&port=443&secret=ee'
}

@test "rotate replaces the secret and keeps everything else" {
	init_stealth --email me@example.org
	old=$(burrowrs config get SECRET)
	run burrowrs rotate --yes
	assert_success
	assert_output --partial "not running"
	assert_output --partial "Share your proxy"
	new=$(burrowrs config get SECRET)
	[[ $new != "$old" && $new =~ ^[0-9a-f]{32}$ ]]
	[[ $(burrowrs config get ACME_EMAIL) == me@example.org ]]
	[[ $(stat -c %a "$BURROWRS_ENV_FILE") == 600 ]]
}

@test "rotate in users mode changes only the owner's secret" {
	init_stealth --access users
	burrowrs user add alice >/dev/null 2>&1
	alice=$(burrowrs user link alice --format secret)
	old=$(burrowrs config get SECRET)
	run burrowrs rotate --yes
	assert_success
	assert_output --partial "Your own link"
	[[ $(burrowrs config get SECRET) != "$old" ]]
	[[ $(burrowrs user link alice --format secret) == "$alice" ]]
}

@test "render writes state without Docker" {
	init_stealth
	run burrowrs render
	assert_success
	[[ -f $BURROWRS_STATE_DIR/telemt/config.toml && -f $BURROWRS_STATE_DIR/telemt/users.toml ]]
	[[ -f $BURROWRS_STATE_DIR/Caddyfile && -f $BURROWRS_STATE_DIR/compose.env ]]
}

@test "paths are made absolute, so compose.env names the same state wherever it runs from" {
	init_stealth
	cd "$BATS_TEST_TMPDIR"
	BURROWRS_STATE_DIR=state BURROWRS_ENV_FILE=.env run "$BURROWRS_ROOT/burrowrs" render
	assert_success
	grep -qx "BURROWRS_STATE_DIR='$BATS_TEST_TMPDIR/state'" "$BATS_TEST_TMPDIR/state/compose.env"
}

@test "commands that need a config say how to create one" {
	run burrowrs link
	assert_failure
	assert_output --partial "burrowrs init"
}

@test "deploy validates its arguments before connecting anywhere" {
	run burrowrs deploy
	assert_failure
	assert_output --partial "root@203.0.113.7"
	run burrowrs deploy root@203.0.113.7 --ssh-port 0
	assert_failure
	run burrowrs deploy root@203.0.113.7 --dir relative/path
	assert_failure
}

@test "smoke --link rejects malformed links" {
	require_docker
	run burrowrs smoke --link "https://example.org/nothing"
	assert_failure
	assert_output --partial "not a proxy link"
}
