#!/usr/bin/env bats
# install.sh: the one-command server installer. These cases all stop at input
# validation, before the installer does anything.

setup() {
	load ../helpers
	export BURROWRS_DRY_RUN=1
}

installer() { bash "$BURROWRS_ROOT/install.sh"; }

@test "installs the release it ships with" {
	version=$("$BURROWRS_ROOT/burrowrs" version | cut -d' ' -f2)
	grep -qx "BURROWRS_INSTALLER_REF=v$version # the release this installer belongs to" "$BURROWRS_ROOT/install.sh"
}

@test "needs a domain or a cover domain, not both" {
	run installer
	assert_failure
	assert_output --partial "BURROWRS_DOMAIN"
	BURROWRS_DOMAIN=notes.example.org BURROWRS_COVER_DOMAIN=www.example.com run installer
	assert_failure
	assert_output --partial "not both"
}

@test "rejects malformed settings before doing anything" {
	BURROWRS_DOMAIN='notes.example.org;id' run installer
	assert_failure
	BURROWRS_DOMAIN=notes.example.org BURROWRS_PORT=70000 run installer
	assert_failure
	BURROWRS_DOMAIN=notes.example.org BURROWRS_SSH_PORT=x run installer
	assert_failure
	BURROWRS_DOMAIN=notes.example.org BURROWRS_DIR=relative run installer
	assert_failure
	# shellcheck disable=SC2016 # a literal $(...) is the attack being tested
	BURROWRS_DOMAIN=notes.example.org BURROWRS_INIT_ARGS='--subnet $(id)' run installer
	assert_failure
	assert_output --partial "unsupported characters"
	BURROWRS_DOMAIN=notes.example.org BURROWRS_ENABLE_IPV6=yes run installer
	assert_failure
}

@test "refuses to run for real without root" {
	((EUID != 0)) || skip "running as root"
	BURROWRS_DRY_RUN=0 BURROWRS_DOMAIN=notes.example.org run installer
	assert_failure
	assert_output --partial "run as root"
}

@test "yes/no settings never fail open" {
	BURROWRS_DOMAIN=notes.example.org BURROWRS_DRY_RUN=maybe run installer
	assert_failure
	assert_output --partial "BURROWRS_DRY_RUN must be 1 or 0"
	BURROWRS_DOMAIN=notes.example.org BURROWRS_SKIP_HOST_SETUP=sure run installer
	assert_failure
	assert_output --partial "BURROWRS_SKIP_HOST_SETUP must be 1 or 0"
}
