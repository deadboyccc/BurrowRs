#!/usr/bin/env bats
# ACCESS_MODE=users on a real stack: every user gets their own secret and
# limits, and telemt enforces them live, without restarting.
#
# Needs Docker and the internet: a user who is cut off still completes the
# FakeTLS handshake (they hold a valid key), so "cut off" is checked with a
# real Telegram round trip. BURROWRS_E2E_OFFLINE=1 skips this file.

DOMAIN=users.burrowrs.test

setup_file() {
	load ../helpers
	have_docker || return 0
	[[ ${BURROWRS_E2E_OFFLINE:-0} != 1 ]] || return 0
	export BURROWRS_ENV_FILE=$BATS_FILE_TMPDIR/.env BURROWRS_STATE_DIR=$BATS_FILE_TMPDIR/state
	export BURROWRS_USERS_FILE=$BATS_FILE_TMPDIR/users.tsv
	export BURROWRS_PROJECT=burrowrs-e2e-users-$$
	PROXY_PORT=$(free_port_host) HTTP_PORT=$(free_port_host) METRICS_PORT=$(free_port_host)
	export PROXY_PORT HTTP_PORT METRICS_PORT
	burrowrs init --domain "$DOMAIN" --tls internal --bind 127.0.0.1 --port "$PROXY_PORT" \
		--http-port "$HTTP_PORT" --metrics-port "$METRICS_PORT" --ipv4 127.0.0.1 --link-host 127.0.0.1 \
		--subnet "$(random_subnet)" --access users --quiet
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
	[[ ${BURROWRS_E2E_OFFLINE:-0} != 1 ]] || skip "needs Telegram (BURROWRS_E2E_OFFLINE=1)"
}

free_port_host() {
	(
		# shellcheck source=/dev/null
		source "$BURROWRS_ROOT/lib/common.sh"
		free_port
	)
}

container() { docker compose -p "$BURROWRS_PROJECT" ps -q "$1"; }
started_at() { docker inspect -f '{{.State.StartedAt}}' "$(container telemt)"; }

# reaches NAME|owner: does a Telegram round trip work with this user's link?
reaches() {
	local secret
	if [[ $1 == owner ]]; then secret=$(burrowrs link --format secret); else secret=$(burrowrs user link "$1" --format secret); fi
	BURROWRS_SECRET=$secret docker run --rm --network host -e BURROWRS_SECRET \
		"burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" probe --host 127.0.0.1 --port "$PROXY_PORT" --telegram --retries "${2:-3}" --retry-delay 1
}

@test "smoke: every check passes in users mode (the owner's link)" {
	run burrowrs smoke
	assert_success
	assert_output --partial "checks passed"
}

@test "added users work at once, each with a secret of their own, and nothing restarts" {
	before=$(started_at)
	run burrowrs user add alice --days 30 --quota 50G --period monthly --ips 2
	assert_success
	assert_output --partial "added alice: expires"
	burrowrs user add bob --forever >/dev/null
	[[ $(burrowrs user link alice --format secret) != "$(burrowrs user link bob --format secret)" ]]
	run reaches alice
	assert_success
	run reaches bob
	assert_success
	run reaches owner
	assert_success
	[[ $(started_at) == "$before" ]]
}

@test "user list shows live connections and traffic from the proxy" {
	reaches alice >/dev/null
	run burrowrs user list
	assert_success
	assert_output --partial "LIVE"
	alice_line=$(grep '^alice ' <<<"$output")
	[[ $alice_line == *"active"* && $alice_line == *"/50G m"* ]]
	refute_line --regexp '^alice .* 0B$'
}

@test "disable cuts a user off; enable lets them back in" {
	burrowrs user disable bob >/dev/null
	run reaches bob 0
	assert_failure
	run reaches alice
	assert_success
	burrowrs user enable bob >/dev/null
	run reaches bob
	assert_success
}

@test "an expired user is refused until renewed" {
	burrowrs user add carol --until 2020-01-01 >/dev/null
	run burrowrs user show carol
	assert_output --partial "(expired"
	run reaches carol 0
	assert_failure
	burrowrs user renew carol --days 3 >/dev/null
	run reaches carol
	assert_success
}

@test "a used-up quota stops a user, and survives a restart of the proxy" {
	burrowrs user add dave --quota 1K >/dev/null
	local i
	for i in {1..8}; do reaches dave 0 >/dev/null 2>&1 || break; done
	((i > 1)) # the first connections fit in the quota
	run reaches dave 0
	assert_failure
	burrowrs restart >/dev/null 2>&1
	run reaches dave 0
	assert_failure
	run reaches alice
	assert_success
}

@test "rotate gives a user a new link; the old one gets the decoy" {
	old=$(burrowrs user link alice --format secret)
	run burrowrs user rotate alice --yes
	assert_success
	new=$(burrowrs user link alice --format secret)
	[[ $old != "$new" ]]
	BURROWRS_SECRET=$old run docker run --rm --network host -e BURROWRS_SECRET \
		"burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" probe --host 127.0.0.1 --port "$PROXY_PORT" --expect fronted --retries 10
	assert_success
	run reaches alice
	assert_success
}

@test "remove deletes a user and their secret" {
	old=$(burrowrs user link bob --format secret)
	run burrowrs user remove bob --yes
	assert_success
	run burrowrs user list
	refute_output --partial "bob"
	BURROWRS_SECRET=$old run docker run --rm --network host -e BURROWRS_SECRET \
		"burrowrs-tools:$(burrowrs version | cut -d' ' -f2)" probe --host 127.0.0.1 --port "$PROXY_PORT" --expect fronted --retries 10
	assert_success
}

@test "user secrets never reach the logs" {
	run burrowrs logs telemt
	assert_success
	refute_output --partial "$(cut -f2 "$BURROWRS_USERS_FILE" | grep -v '^#' | head -n 1)"
	refute_output --partial "tg://proxy"
}

@test "back to shared mode: the owner link stays the same, users are switched off" {
	owner=$(burrowrs link --format secret)
	burrowrs config set ACCESS_MODE shared >/dev/null
	run burrowrs up
	assert_success
	[[ $(burrowrs link --format secret) == "$owner" ]]
	run reaches owner
	assert_success
	run reaches alice 0
	assert_failure
	run burrowrs user list
	assert_failure
	assert_output --partial "ACCESS_MODE=users"
}
