#!/usr/bin/env bats
# Simple mode (no domain, fronting to a real third-party site) and `burrowrs try`.

setup() {
	load ../helpers
	require_docker
}

@test "simple mode: proxy works and probes reach the real cover site" {
	[[ ${BURROWRS_E2E_OFFLINE:-0} != 1 ]] || skip "needs the internet (cover site + Telegram)"
	isolate
	port() { (
		# shellcheck source=/dev/null
		source "$BURROWRS_ROOT/lib/common.sh"
		free_port
	); }
	burrowrs init --cover-domain example.com --ipv4 127.0.0.1 --bind 127.0.0.1 --port "$(port)" \
		--metrics-port "$(port)" --subnet "$(random_subnet)" --quiet
	run burrowrs up
	assert_success
	run burrowrs smoke
	burrowrs down --volumes >/dev/null 2>&1 || true
	assert_success
	assert_output --partial "browsers and probes see example.com over real TLS"
}

@test "try: a throwaway instance comes up, passes smoke tests, and goes away" {
	[[ ! -e $BURROWRS_ROOT/.try ]] || skip "a trial instance already exists in this checkout"
	run burrowrs try
	status_try=$status
	output_try=$output
	run burrowrs try --down
	assert_success
	[[ ! -e $BURROWRS_ROOT/.try ]]
	output=$output_try status=$status_try
	assert_success
	assert_output --partial "Try it:"
	assert_output --partial "tg://proxy?server=127.0.0.1"
	assert_output --partial "checks passed"
}
