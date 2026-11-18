#!/usr/bin/env bats
# install.sh for real: fetch the committed code from a local git repository,
# unpack, init, up, smoke and share. Then run it again, which must upgrade in
# place and keep the secret. Host preparation (firewall, sysctl) is skipped
# on purpose: tests never reconfigure the machine they run on.

setup_file() {
	load ../helpers
	have_docker || return 0
	export WORK=$BATS_FILE_TMPDIR
	export REMOTE_DIR=$WORK/opt/burrowrs
	export BURROWRS_PROJECT=burrowrs-e2e-install-$$
	# A throwaway repository holding the commit under test. Built from
	# `git archive`, so it also works from CI's shallow checkouts.
	mkdir -p "$WORK/repo"
	git -C "$BURROWRS_ROOT" archive HEAD | tar -x -C "$WORK/repo"
	git -C "$WORK/repo" init -q -b e2e
	# The first "release" ships an extra page that the second one drops.
	printf 'retired\n' >"$WORK/repo/site/retired.html"
	git -C "$WORK/repo" add -A
	git -C "$WORK/repo" -c user.name=burrowrs-tests -c user.email=tests@burrowrs.invalid commit -q -m "release one"
}

teardown_file() {
	load ../helpers
	have_docker || return 0
	if [[ -x $REMOTE_DIR/burrowrs ]]; then
		as_root "$REMOTE_DIR/burrowrs" down --volumes >/dev/null 2>&1 || true
	fi
	if ((EUID != 0)) && sudo -n true 2>/dev/null; then sudo rm -rf -- "$WORK/opt"; fi
}

setup() {
	load ../helpers
	require_docker
	if ((EUID != 0)) && ! sudo -n true 2>/dev/null; then skip "needs root or passwordless sudo"; fi
	# The installer always runs the full smoke test, Telegram round trip included.
	[[ ${BURROWRS_E2E_OFFLINE:-0} != 1 ]] || skip "needs the internet (Telegram)"
	unset BURROWRS_ENV_FILE BURROWRS_STATE_DIR
}

as_root() { if ((EUID == 0)); then "$@"; else sudo -n env BURROWRS_PROJECT="$BURROWRS_PROJECT" "$@"; fi; }

port() { (
	# shellcheck source=/dev/null
	source "$BURROWRS_ROOT/lib/common.sh"
	free_port
); }

install_burrowrs() {
	as_root env BURROWRS_PROJECT="$BURROWRS_PROJECT" BURROWRS_REPO="file://$WORK/repo" BURROWRS_REF=e2e \
		BURROWRS_DIR="$REMOTE_DIR" BURROWRS_SKIP_HOST_SETUP=1 "$@" bash "$BURROWRS_ROOT/install.sh"
}

@test "one command: fetch, configure, start, smoke-test and share" {
	run install_burrowrs BURROWRS_DOMAIN=install.burrowrs.test BURROWRS_PORT="$(port)" \
		BURROWRS_INIT_ARGS="--tls internal --bind 127.0.0.1 --http-port $(port) --metrics-port $(port) --ipv4 127.0.0.1 --link-host 127.0.0.1 --subnet $(random_subnet)"
	assert_success
	assert_output --partial "creating the configuration and a fresh secret"
	assert_output --partial "all 8 checks passed"
	assert_output --partial "tg://proxy?server=127.0.0.1"
	assert_output --partial "Back up $REMOTE_DIR/.env"
	[[ $(as_root stat -c %a "$REMOTE_DIR/.env") == 600 ]]
	[[ -f $REMOTE_DIR/install.sh && ! -e $REMOTE_DIR/.git ]]
}

@test "running it again upgrades in place and keeps the secret" {
	[[ -f $REMOTE_DIR/.env ]] || skip "the first install did not run"
	[[ -f $REMOTE_DIR/site/retired.html ]]
	# Release two drops the page.
	git -C "$WORK/repo" rm -q site/retired.html
	git -C "$WORK/repo" -c user.name=burrowrs-tests -c user.email=tests@burrowrs.invalid commit -q -m "release two"
	before=$(as_root grep '^SECRET=' "$REMOTE_DIR/.env")
	run install_burrowrs BURROWRS_DOMAIN=install.burrowrs.test
	assert_success
	assert_output --partial "keeping the existing configuration and secret"
	assert_output --partial "all 8 checks passed"
	[[ $(as_root grep '^SECRET=' "$REMOTE_DIR/.env") == "$before" ]]
	# The dropped page is gone, from the install and from the published site.
	[[ ! -e $REMOTE_DIR/site/retired.html ]]
	run as_root find "$REMOTE_DIR/state/site" -name retired.html
	assert_output ""
	# Root-run code is never group- or world-writable.
	run as_root find "$REMOTE_DIR/burrowrs" "$REMOTE_DIR/lib" "$REMOTE_DIR/scripts" -perm /022
	assert_output ""
}
