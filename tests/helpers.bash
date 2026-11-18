# shellcheck shell=bash
# shellcheck disable=SC2034 # sets config globals for the code under test
# Shared bats helpers.

BURROWRS_ROOT=$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)
export BURROWRS_ROOT NO_COLOR=1

load "$BURROWRS_ROOT/tests/.deps/bats-support/load"
load "$BURROWRS_ROOT/tests/.deps/bats-assert/load"

# Unit tests source the libraries directly.
load_libs() {
	local lib
	for lib in common validate secret links config users render compose; do
		# shellcheck source=/dev/null
		source "$BURROWRS_ROOT/lib/$lib.sh"
	done
}

# Give each test its own .env/state/project so nothing touches a real install.
isolate() {
	export BURROWRS_ENV_FILE=$BATS_TEST_TMPDIR/.env
	export BURROWRS_USERS_FILE=$BATS_TEST_TMPDIR/users.tsv
	export BURROWRS_STATE_DIR=$BATS_TEST_TMPDIR/state
	export BURROWRS_PROJECT=burrowrs-test-$$-$RANDOM
}

burrowrs() { "$BURROWRS_ROOT/burrowrs" "$@"; }

# A minimal valid stealth configuration in the current shell (unit tests).
stealth_config() {
	config_reset
	BURROWRS_MODE=stealth DOMAIN=notes.example.org TLS_MODE=internal
	config_set_defaults
	SECRET=$(key_new)
}

have_docker() { command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; }

require_docker() {
	if ! have_docker; then skip "docker is not available"; fi
}

# A /28 that no other test run is likely to use at the same time.
random_subnet() {
	printf '10.%d.%d.%d/28\n' $((210 + RANDOM % 40)) $((RANDOM % 256)) $((16 * (RANDOM % 16)))
}

pinned_image() { # pinned_image SERVICE: the image reference from compose.yaml
	awk -v svc="  $1:" '$0 == svc {found=1} found && /image:/ {print $2; exit}' "$BURROWRS_ROOT/compose.yaml"
}
