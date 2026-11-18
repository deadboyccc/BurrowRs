#!/usr/bin/env bats
# `burrowrs deploy` end to end. A fake ssh (tests/e2e/fake-ssh) runs the "remote"
# side on this machine, in its own install directory, so the real upload,
# init, up, smoke and link steps all execute.

setup_file() {
	load ../helpers
	have_docker || return 0
	export REMOTE_DIR=$BATS_FILE_TMPDIR/server/opt/burrowrs
	export BURROWRS_PROJECT=burrowrs-e2e-deploy-$$
	export FAKE_BIN=$BATS_FILE_TMPDIR/bin
	mkdir -p "$FAKE_BIN"
	ln -s "$BURROWRS_ROOT/tests/e2e/fake-ssh" "$FAKE_BIN/ssh"
	# Non-root runs: keep BURROWRS_PROJECT across the "remote" sudo calls, so
	# test stacks never share a Compose project.
	ln -s "$BURROWRS_ROOT/tests/e2e/fake-sudo" "$FAKE_BIN/sudo"
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	if [[ -x $REMOTE_DIR/burrowrs ]]; then
		as_remote "$REMOTE_DIR/burrowrs" down --volumes >/dev/null 2>&1 || true
	fi
	if ((EUID != 0)) && sudo -n true 2>/dev/null; then sudo rm -rf -- "$BATS_FILE_TMPDIR/server"; fi
}

setup() {
	load ../helpers
	require_docker
	unset BURROWRS_ENV_FILE BURROWRS_STATE_DIR # the "server" uses its own install dir
	# Deploy runs the full smoke test, Telegram round trip included.
	[[ ${BURROWRS_E2E_OFFLINE:-0} != 1 ]] || skip "needs the internet (Telegram)"
}

as_remote() { if ((EUID == 0)); then "$@"; else sudo -n env BURROWRS_PROJECT="$BURROWRS_PROJECT" "$@"; fi; }

port() { (
	# shellcheck source=/dev/null
	source "$BURROWRS_ROOT/lib/common.sh"
	free_port
); }

deploy() {
	local args=("$@")
	[[ " ${args[*]} " == *" --dir "* ]] || args=(--dir "$REMOTE_DIR" "${args[@]}")
	PATH=$FAKE_BIN:$PATH burrowrs deploy root@server.test --no-host-setup "${args[@]}"
}

@test "first deploy: uploads, initialises on the server, starts, smoke-tests both ends" {
	if ((EUID != 0)) && ! sudo -n true 2>/dev/null; then skip "needs root or passwordless sudo"; fi
	run deploy --domain deploy.burrowrs.test --tls internal --bind 127.0.0.1 --port "$(port)" \
		--http-port "$(port)" --metrics-port "$(port)" --ipv4 127.0.0.1 --link-host 127.0.0.1 \
		--subnet "$(random_subnet)"
	assert_success
	assert_output --partial "initialising"
	assert_output --partial "all 8 checks passed"
	assert_output --partial "testing from this machine"
	refute_output --partial "passes locally but not from here"
	assert_line --regexp '^tg://proxy\?server=127\.0\.0\.1&port=[0-9]+&secret=ee[0-9a-f]+$'
	[[ -f $REMOTE_DIR/.env && -x $REMOTE_DIR/burrowrs && -f $REMOTE_DIR/tools/Dockerfile ]]
	[[ ! -e $REMOTE_DIR/tests/.deps && ! -e $REMOTE_DIR/.git ]]
	[[ $(as_remote stat -c %a "$REMOTE_DIR/.env") == 600 ]]
}

@test "re-deploy upgrades the code and keeps the server's secret" {
	[[ -f $REMOTE_DIR/.env ]] || skip "first deploy did not run"
	before=$(as_remote grep '^SECRET=' "$REMOTE_DIR/.env")
	run deploy --domain ignored.example.org
	assert_success
	assert_output --partial "keeping the existing configuration"
	[[ $(as_remote grep '^SECRET=' "$REMOTE_DIR/.env") == "$before" ]]
}

@test "deploy stops, and says so, when the server cannot start the proxy" {
	if ((EUID != 0)) && ! sudo -n true 2>/dev/null; then skip "needs root or passwordless sudo"; fi
	local dir=$BATS_TEST_TMPDIR/failing/opt/burrowrs busy holder
	busy=$(port)
	# Hold the proxy port, so the server's `burrowrs up` cannot publish it.
	python3 -c 'import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(); time.sleep(600)' "$busy" &
	holder=$!
	sleep 0.5
	BURROWRS_PROJECT=$BURROWRS_PROJECT-fail run deploy --dir "$dir" --no-local-smoke --domain fail.burrowrs.test \
		--tls internal --bind 127.0.0.1 --port "$busy" --http-port "$(port)" --metrics-port "$(port)" \
		--ipv4 127.0.0.1 --subnet "$(random_subnet)"
	kill "$holder" 2>/dev/null || true
	BURROWRS_PROJECT=$BURROWRS_PROJECT-fail as_remote "$dir/burrowrs" down --volumes >/dev/null 2>&1 || true
	if ((EUID != 0)); then sudo -n rm -rf -- "$BATS_TEST_TMPDIR/failing"; fi
	assert_failure
	assert_output --partial "did not start"
	refute_output --partial "Deployed."
}
