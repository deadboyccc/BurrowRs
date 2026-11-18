#!/usr/bin/env bats

setup() {
	load ../helpers
	load_libs
	isolate
	ENV_FILE=$BURROWRS_ENV_FILE
}

write_env() { printf '%s\n' "$@" >"$ENV_FILE"; }

@test "load: parses values, quotes, comments, blank lines and CRLF" {
	local key=00112233445566778899aabbccddeeff # gitleaks:allow (fake fixture)
	write_env "# comment" "" "BURROWRS_MODE=stealth" "DOMAIN=notes.example.org" \
		"SECRET=$key" "USER_DEFAULT_QUOTA=\"50G\"" \
		"ACME_EMAIL='me@example.org'" $'PROXY_PORT=8443\r'
	config_load "$ENV_FILE"
	[[ $DOMAIN == notes.example.org ]]
	[[ $SECRET == 00112233445566778899aabbccddeeff ]] # gitleaks:allow (fake fixture)
	[[ $USER_DEFAULT_QUOTA == 50G ]]
	[[ $ACME_EMAIL == me@example.org ]]
	[[ $PROXY_PORT == 8443 ]]
	[[ $HTTP_PORT == 80 ]] # default applied
}

@test "load: does not execute anything" {
	# shellcheck disable=SC2016 # literal $() and backticks are the point
	write_env 'DOMAIN=$(touch '"$BATS_TEST_TMPDIR"'/pwned)' 'BURROWRS_MODE=`id`'
	config_load "$ENV_FILE"
	[[ ! -e $BATS_TEST_TMPDIR/pwned ]]
	# shellcheck disable=SC2016
	[[ $BURROWRS_MODE == '`id`' ]]
}

@test "load: ignores (and warns about) unknown keys" {
	write_env "DOMAIN=a.example.org" "PATH=/tmp/evil" "LD_PRELOAD=/tmp/x.so"
	run config_load "$ENV_FILE"
	assert_success
	assert_output --partial "unknown setting PATH"
	config_load "$ENV_FILE" 2>/dev/null
	[[ $PATH != /tmp/evil ]]
}

@test "load: malformed lines are fatal" {
	write_env "DOMAIN a.example.org"
	run config_load "$ENV_FILE"
	assert_failure
	assert_output --partial "expected KEY=value"
}

@test "load: the process environment cannot leak into the config" {
	write_env "DOMAIN=a.example.org"
	export PROXY_PORT=1 METRICS_PORT=2 ACCESS_MODE=users
	config_load "$ENV_FILE"
	[[ $PROXY_PORT == 443 && $METRICS_PORT == 3129 && $ACCESS_MODE == shared ]]
}

@test "load: missing file explains what to do" {
	run config_load "$BATS_TEST_TMPDIR/nope"
	assert_failure
	assert_output --partial "burrowrs init"
}

@test "defaults: shared access, quiet logs, sensible user defaults" {
	config_reset
	config_set_defaults
	[[ $ACCESS_MODE == shared ]]
	[[ $LOG_LEVEL == silent && $LOGGING == on ]]
	[[ $USER_DEFAULT_DAYS == 30 && $USER_DEFAULT_QUOTA == none ]]
	[[ $USER_DEFAULT_PERIOD == none && $USER_DEFAULT_IPS == 3 ]]
	[[ -z $AD_TAG ]]
}

@test "validate: a fresh stealth config is valid" {
	stealth_config
	run config_validate
	assert_success
}

@test "validate: users mode is valid too" {
	stealth_config
	ACCESS_MODE=users
	run config_validate
	assert_success
	ACCESS_MODE=everyone
	run config_validate
	assert_failure
	assert_output --partial "ACCESS_MODE=everyone"
}

@test "validate: stealth mode requires a domain" {
	stealth_config
	DOMAIN=''
	run config_validate
	assert_failure
	assert_output --partial "stealth mode needs a domain"
}

@test "validate: simple mode requires a cover domain and an address" {
	config_reset
	BURROWRS_MODE=simple
	config_set_defaults
	SECRET=$(key_new)
	run config_validate
	assert_failure
	assert_output --partial "COVER_DOMAIN"
	assert_output --partial "PUBLIC_IPV4"
}

@test "validate: the secret must be a 32-hex key" {
	stealth_config
	for bad in '' ee00112233445566778899aabbccddeeff 00112233445566778899AABBCCDDEEFF 0011; do
		SECRET=$bad
		run config_validate
		assert_failure
		assert_output --partial "SECRET: missing or not 32 hex characters"
	done
}

@test "validate: reports every problem at once" {
	stealth_config
	PROXY_PORT=99999 LOG_LEVEL=chatty TELEMT_MEMORY_LIMIT=lots
	run config_validate
	assert_failure
	assert_output --partial PROXY_PORT
	assert_output --partial LOG_LEVEL
	assert_output --partial TELEMT_MEMORY_LIMIT
}

@test "validate: proxy and http ports must differ" {
	stealth_config
	HTTP_PORT=443
	run config_validate
	assert_output --partial "HTTP_PORT: must differ"
}

@test "validate: decoy IP must be a host inside the subnet" {
	stealth_config
	local bad=0 ip
	for ip in 10.204.47.0 10.204.47.1 10.204.47.15 10.204.48.10; do
		DECOY_IP=$ip
		config_validate 2>/dev/null && bad=1
	done
	DECOY_IP=10.204.47.14
	run config_validate
	assert_success
	((bad == 0))
}

@test "validate: USER_DEFAULT_* settings" {
	stealth_config
	USER_DEFAULT_DAYS=0 USER_DEFAULT_QUOTA=50 USER_DEFAULT_PERIOD=hourly USER_DEFAULT_IPS=-1
	run config_validate
	assert_failure
	assert_output --partial USER_DEFAULT_DAYS
	assert_output --partial USER_DEFAULT_QUOTA
	assert_output --partial USER_DEFAULT_PERIOD
	assert_output --partial USER_DEFAULT_IPS
	USER_DEFAULT_DAYS=never USER_DEFAULT_QUOTA=50G USER_DEFAULT_PERIOD=monthly USER_DEFAULT_IPS=none
	run config_validate
	assert_success
	USER_DEFAULT_DAYS=36501
	run config_validate
	assert_failure
}

@test "validate: a default reset period needs a default quota" {
	stealth_config
	USER_DEFAULT_PERIOD=weekly USER_DEFAULT_QUOTA=none
	run config_validate
	assert_failure
	assert_output --partial "needs a USER_DEFAULT_QUOTA"
}

@test "validate: AD_TAG is 32 hex and needs PUBLIC_IPV4" {
	stealth_config
	AD_TAG=00112233445566778899aabbccddeeff # gitleaks:allow (fake fixture)
	run config_validate
	assert_failure
	assert_output --partial "need PUBLIC_IPV4"
	PUBLIC_IPV4=203.0.113.7
	run config_validate
	assert_success
	AD_TAG=not-a-tag
	run config_validate
	assert_failure
	assert_output --partial "AD_TAG=not-a-tag"
}

@test "subnet helpers" {
	run subnet_host 10.204.47.0/28 10
	assert_output 10.204.47.10
	run subnet_host 192.168.7.130/25 10
	assert_output 192.168.7.138
	run ip_in_subnet 10.0.0.5 10.0.0.0/29
	assert_success
	run ip_in_subnet 10.0.0.9 10.0.0.0/29
	assert_failure
}

@test "front host and link host follow the mode" {
	stealth_config
	[[ $(config_front_host) == notes.example.org && $(config_link_host) == notes.example.org ]]
	LINK_HOST=203.0.113.7
	[[ $(config_link_host) == 203.0.113.7 ]]
	BURROWRS_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2 LINK_HOST=''
	[[ $(config_front_host) == www.example.com && $(config_link_host) == 198.51.100.2 ]]
}

@test "write + load round-trips every key, mode 0600" {
	stealth_config
	ACME_EMAIL=me@example.org ACCESS_MODE=users USER_DEFAULT_QUOTA=20G USER_DEFAULT_PERIOD=monthly
	AD_TAG=00112233445566778899aabbccddeeff PUBLIC_IPV4=203.0.113.7 # gitleaks:allow (fake fixture)
	declare -A before
	for key in "${CONFIG_KEYS[@]}"; do before[$key]=${!key}; done
	config_write "$ENV_FILE"
	[[ $(stat -c %a "$ENV_FILE") == 600 ]]
	config_load "$ENV_FILE"
	local mismatched=()
	for key in "${CONFIG_KEYS[@]}"; do
		[[ ${!key} == "${before[$key]}" ]] || mismatched+=("$key")
	done
	assert_equal "${mismatched[*]}" ""
}

@test "set_value replaces one line and keeps the rest" {
	write_env "# keep me" "DOMAIN=a.example.org" "PROXY_PORT=443"
	config_set_value "$ENV_FILE" PROXY_PORT 8443
	run cat "$ENV_FILE"
	assert_output $'# keep me\nDOMAIN=a.example.org\nPROXY_PORT=8443'
	config_set_value "$ENV_FILE" ACME_EMAIL me@example.org
	assert_equal "$(tail -n1 "$ENV_FILE")" "ACME_EMAIL=me@example.org"
	[[ $(stat -c %a "$ENV_FILE") == 600 ]]
}

@test ".env.example documents every setting" {
	local missing=()
	for key in "${CONFIG_KEYS[@]}"; do
		grep -q "^#\? \?$key=" "$BURROWRS_ROOT/.env.example" || missing+=("$key")
	done
	assert_equal "${missing[*]}" ""
}

@test "validate: every key is checked in simple mode too" {
	config_reset
	BURROWRS_MODE=simple COVER_DOMAIN=www.example.com PUBLIC_IPV4=198.51.100.2
	config_set_defaults
	SECRET=$(key_new)
	HTTP_PORT=0 DECOY_IP=nope EDGE_SUBNET6=bad MAX_CONNECTIONS=0123
	run config_validate
	assert_failure
	assert_output --partial HTTP_PORT
	assert_output --partial DECOY_IP
	assert_output --partial EDGE_SUBNET6
	assert_output --partial MAX_CONNECTIONS
}

@test "validate: IPv6 cannot be combined with a specific BIND_ADDR" {
	stealth_config
	ENABLE_IPV6=true BIND_ADDR=203.0.113.7
	run config_validate
	assert_failure
	assert_output --partial "ENABLE_IPV6=true"
	BIND_ADDR=0.0.0.0
	run config_validate
	assert_success
}

@test "load: simple mode re-derives a DECOY_IP left outside a changed subnet" {
	write_env "BURROWRS_MODE=simple" "COVER_DOMAIN=www.example.com" "PUBLIC_IPV4=198.51.100.2" \
		"SECRET=$(key_new)" "EDGE_SUBNET=10.77.1.0/28" "DECOY_IP=10.204.47.10"
	config_load "$ENV_FILE"
	[[ $DECOY_IP == 10.77.1.10 ]]
	run config_validate
	assert_success
}

@test "validate: LOGGING and LOG_LEVEL" {
	stealth_config
	local level bad=0
	for level in silent normal verbose debug; do
		LOG_LEVEL=$level
		config_validate 2>/dev/null || bad=1
	done
	((bad == 0))
	LOGGING=maybe
	run config_validate
	assert_failure
	assert_output --partial "LOGGING=maybe"
}

@test "capacity: the default MAX_CONNECTIONS fits in the default memory limit" {
	stealth_config
	[[ $MAX_CONNECTIONS == 5000 && $TELEMT_MEMORY_LIMIT == 512m ]]
	run config_capacity_warning
	assert_failure
	assert_output ""
}

@test "capacity: a connection limit the memory limit cannot hold is called out, with the fix" {
	stealth_config
	MAX_CONNECTIONS=8192 TELEMT_MEMORY_LIMIT=512m
	run config_capacity_warning
	assert_success
	assert_output --partial "MAX_CONNECTIONS=8192 can need about 768 MiB"
	assert_output --partial "Lower MAX_CONNECTIONS to 5461 or less"
	MAX_CONNECTIONS=8192 TELEMT_MEMORY_LIMIT=1g
	run config_capacity_warning
	assert_failure
}

@test "capacity: mem_kib understands k, m and g" {
	[[ $(mem_kib 512k) == 512 && $(mem_kib 512m) == 524288 && $(mem_kib 2g) == 2097152 && $(mem_kib 1G) == 1048576 ]]
}
