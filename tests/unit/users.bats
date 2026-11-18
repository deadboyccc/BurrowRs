#!/usr/bin/env bats
# lib/users.sh and the `burrowrs user` commands, without Docker (or without a
# running stack): every change lands in users.tsv and applies on the next up.

setup() {
	load ../helpers
	load_libs
	isolate
	USERS_FILE=$BURROWRS_USERS_FILE
}

KEY1=00000000000000000000000000000001 # gitleaks:allow (fake fixture)
KEY2=00000000000000000000000000000002 # gitleaks:allow (fake fixture)

row() { # row FIELD... -> one tab-separated line
	local IFS=$'\t'
	printf '%s\n' "$*"
}

init_users() {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --access users --quiet "$@"
}

# --- lib/users.sh ----------------------------------------------------------

@test "users_load: a missing file is an empty list" {
	users_load "$USERS_FILE"
	[[ ${#USER_NAMES[@]} == 0 ]]
}

@test "users_load + users_save round-trip every field, mode 0600, order kept" {
	{
		printf '%s\n' "$USERS_HEADER"
		row zed "$KEY1" 2026-12-31T23:59:59Z 50G monthly 2 on 2026-11-18
		row alice "$KEY2" never none none none off 2026-11-01
	} >"$USERS_FILE"
	users_load "$USERS_FILE"
	[[ ${USER_NAMES[*]} == "zed alice" ]]
	[[ ${USER_KEY[zed]} == "$KEY1" && ${USER_EXPIRES[zed]} == 2026-12-31T23:59:59Z ]]
	[[ ${USER_QUOTA[zed]} == 50G && ${USER_PERIOD[zed]} == monthly && ${USER_IPS[zed]} == 2 ]]
	[[ ${USER_STATUS[alice]} == off && ${USER_QUOTA[alice]} == none && ${USER_CREATED[alice]} == 2026-11-01 ]]
	before=$(<"$USERS_FILE")
	users_save "$USERS_FILE"
	[[ $(<"$USERS_FILE") == "$before" ]]
	[[ $(stat -c %a "$USERS_FILE") == 600 ]]
}

@test "users_load: quota sizes are normalised to upper case, none stays none" {
	row alice "$KEY1" never 50g none none on 2026-11-18 >"$USERS_FILE"
	row bob "$KEY2" never none none none on 2026-11-18 >>"$USERS_FILE"
	users_load "$USERS_FILE"
	[[ ${USER_QUOTA[alice]} == 50G && ${USER_QUOTA[bob]} == none ]]
}

@test "users_load: skips comments, blank lines and CRLF" {
	{
		printf '# a comment\n\n'
		printf '%s\r\n' "$(row alice "$KEY1" never none none none on 2026-11-18)"
	} >"$USERS_FILE"
	users_load "$USERS_FILE"
	[[ ${USER_NAMES[*]} == alice && ${USER_CREATED[alice]} == 2026-11-18 ]]
}

@test "users_load: malformed rows are fatal and name the line" {
	local -a bad=(
		"$(row alice "$KEY1" never none none none on)"
		"$(row Alice "$KEY1" never none none none on 2026-11-18)"
		"$(row owner "$KEY1" never none none none on 2026-11-18)"
		"$(row alice ee00 never none none none on 2026-11-18)"
		"$(row alice "$KEY1" 2026-12-31 none none none on 2026-11-18)"
		"$(row alice "$KEY1" never 50 none none on 2026-11-18)"
		"$(row alice "$KEY1" never none yearly none on 2026-11-18)"
		"$(row alice "$KEY1" never none monthly none on 2026-11-18)"
		"$(row alice "$KEY1" never none none 0 on 2026-11-18)"
		"$(row alice "$KEY1" never none none none yes 2026-11-18)"
		"$(row alice "$KEY1" never none none none on yesterday)"
		"alice $KEY1 never none none none on 2026-11-18"
	)
	local -a expect=("expected 8" "bad name" reserved "key must be" "expires must be" "quota must be"
		"period must be" "needs a quota" "ips must be" "status must be" "created must be" "expected 8")
	local i problems=()
	for i in "${!bad[@]}"; do
		printf '# header\n%s\n' "${bad[i]}" >"$USERS_FILE"
		run users_load "$USERS_FILE"
		[[ $status != 0 && $output == *"users.tsv:2: "*"${expect[i]}"* ]] || problems+=("$i: $output")
	done
	assert_equal "${problems[*]}" ""
}

@test "users_load: duplicate names are fatal" {
	row alice "$KEY1" never none none none on 2026-11-18 >"$USERS_FILE"
	row alice "$KEY2" never none none none on 2026-11-18 >>"$USERS_FILE"
	run users_load "$USERS_FILE"
	assert_failure
	assert_output --partial "users.tsv:2: duplicate user alice"
}

@test "users_remove_name drops every field of one user" {
	row alice "$KEY1" never none none none on 2026-11-18 >"$USERS_FILE"
	row bob "$KEY2" never none none none on 2026-11-18 >>"$USERS_FILE"
	users_load "$USERS_FILE"
	users_remove_name alice
	[[ ${USER_NAMES[*]} == bob ]]
	run users_exists alice
	assert_failure
	[[ -z ${USER_KEY[alice]+set}${USER_EXPIRES[alice]+set}${USER_STATUS[alice]+set} ]]
	users_exists bob
}

@test "size_bytes: binary units" {
	assert_equal "$(size_bytes 1K)" 1024
	assert_equal "$(size_bytes 512M)" 536870912
	assert_equal "$(size_bytes 50G)" 53687091200
	assert_equal "$(size_bytes 2T)" 2199023255552
	assert_equal "$(size_bytes 3g)" 3221225472
}

@test "human_bytes" {
	assert_equal "$(human_bytes 0)" 0B
	assert_equal "$(human_bytes 1023)" 1023B
	assert_equal "$(human_bytes 1536)" 1.5K
	assert_equal "$(human_bytes 53687091200)" 50.0G
	assert_equal "$(human_bytes 2199023255552)" 2.0T
}

@test "epoch and UTC conversions round-trip" {
	assert_equal "$(epoch_to_utc 1798761599)" 2026-12-31T23:59:59Z
	assert_equal "$(utc_to_epoch 2026-12-31T23:59:59Z)" 1798761599
	assert_equal "$(utc_to_epoch "$(epoch_to_utc 1700000000)")" 1700000000
}

@test "expiry_after_days: the end of the Nth day after FROM, UTC" {
	# 2026-11-18T10:00:00Z
	assert_equal "$(expiry_after_days 30 1794996000)" 2026-12-18T23:59:59Z
	assert_equal "$(expiry_after_days 1 1794996000)" 2026-11-19T23:59:59Z
	# From the last second of a day, too.
	assert_equal "$(expiry_after_days 1 1795046399)" 2026-11-19T23:59:59Z
	run expiry_after_days 7
	assert_output --regexp '^[0-9]{4}-[0-9]{2}-[0-9]{2}T23:59:59Z$'
}

@test "user_state: active, disabled, expired" {
	{
		row live "$KEY1" never none none none on 2026-11-18
		row gone "$KEY2" 2020-01-01T23:59:59Z none none none on 2019-12-01
		row off 00000000000000000000000000000003 2099-01-01T23:59:59Z none none none off 2026-11-18  # gitleaks:allow (fake fixture)
		row later 00000000000000000000000000000004 2099-01-01T23:59:59Z none none none on 2026-11-18 # gitleaks:allow (fake fixture)
	} >"$USERS_FILE"
	users_load "$USERS_FILE"
	assert_equal "$(user_state live) $(user_state gone) $(user_state off) $(user_state later)" \
		"active expired disabled active"
}

# --- burrowrs user (no running stack) ----------------------------------------

@test "user: refuses in shared mode and says how to switch" {
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --quiet
	run burrowrs user add alice
	assert_failure
	assert_output --partial "ACCESS_MODE=users"
	assert_output --partial "config set ACCESS_MODE users"
	[[ ! -e $USERS_FILE ]]
}

@test "user: no subcommand prints usage; unknown subcommands fail" {
	init_users
	run burrowrs user
	assert_failure
	assert_output --partial "Usage: burrowrs user"
	run burrowrs user frobnicate
	assert_failure
	assert_output --partial "unknown user command"
}

@test "user add: defaults from .env, a fresh key, a private file, and the user's links" {
	init_users
	run burrowrs user add alice
	assert_success
	assert_output --partial "not running"
	assert_output --partial "added alice"
	assert_output --regexp 'tg://proxy\?server=notes\.example\.org&port=443&secret=ee[0-9a-f]{32}6e6f7465732e6578616d706c652e6f7267'
	[[ $(stat -c %a "$USERS_FILE") == 600 ]]
	users_load "$USERS_FILE"
	[[ ${USER_NAMES[*]} == alice && ${USER_KEY[alice]} =~ ^[0-9a-f]{32}$ ]]
	[[ ${USER_KEY[alice]} != "$(burrowrs config get SECRET)" ]]
	[[ ${USER_EXPIRES[alice]} == "$(expiry_after_days 30)" ]]
	[[ ${USER_QUOTA[alice]} == none && ${USER_PERIOD[alice]} == none && ${USER_IPS[alice]} == 3 ]]
	[[ ${USER_STATUS[alice]} == on && ${USER_CREATED[alice]} == "$(date -u +%Y-%m-%d)" ]]
}

@test "user add: every limit flag" {
	init_users
	burrowrs user add a1 --days 7 --quota 50g --period monthly --ips 2 >/dev/null 2>&1
	burrowrs user add a2 --until 2027-03-01 --quota 1T >/dev/null 2>&1
	burrowrs user add a3 --forever --ips none >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "${USER_EXPIRES[a1]} ${USER_QUOTA[a1]} ${USER_PERIOD[a1]} ${USER_IPS[a1]}" \
		"$(expiry_after_days 7) 50G monthly 2"
	assert_equal "${USER_EXPIRES[a2]} ${USER_QUOTA[a2]} ${USER_PERIOD[a2]}" "2027-03-01T23:59:59Z 1T none"
	assert_equal "${USER_EXPIRES[a3]} ${USER_IPS[a3]}" "never none"
}

@test "user add: the .env default period applies with the default quota only" {
	init_users
	burrowrs config set USER_DEFAULT_QUOTA 20G USER_DEFAULT_PERIOD weekly USER_DEFAULT_DAYS never >/dev/null 2>&1
	burrowrs user add dflt >/dev/null 2>&1
	burrowrs user add own --quota 5G >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "${USER_QUOTA[dflt]} ${USER_PERIOD[dflt]} ${USER_EXPIRES[dflt]}" "20G weekly never"
	assert_equal "${USER_QUOTA[own]} ${USER_PERIOD[own]}" "5G none"
}

@test "user add: bad input fails before anything is written" {
	init_users
	local -a cases=(
		"add" "add Alice" "add owner" "add bad/name" "add x --days 0" "add x --days lots"
		"add x --until 2026-13-01" "add x --quota 5" "add x --period yearly" "add x --ips 0"
		"add x --period monthly" "add x --days 3 --until 2027-01-01" "add x --bogus" "add x --quota"
	)
	local args problems=()
	for args in "${cases[@]}"; do
		# shellcheck disable=SC2086 # word splitting intended
		run burrowrs user $args
		[[ $status != 0 && $output == *error:* ]] || problems+=("$args")
	done
	assert_equal "${problems[*]}" ""
	[[ ! -e $USERS_FILE ]]
}

@test "user add: names are unique" {
	init_users
	burrowrs user add alice >/dev/null 2>&1
	run burrowrs user add alice
	assert_failure
	assert_output --partial "already exists"
}

@test "user list and show: settings, states and no live column without a stack" {
	init_users
	burrowrs user add alice --until 2027-01-31 --quota 50G --period monthly --ips 2 >/dev/null 2>&1
	burrowrs user add bob --forever >/dev/null 2>&1
	burrowrs user disable bob >/dev/null 2>&1
	run burrowrs user list
	assert_success
	assert_output --regexp 'alice +active +2027-01-31 +50G m +2'
	assert_output --regexp 'bob +disabled +never +- +3'
	assert_output --partial "2 user(s)."
	assert_output --partial "Live usage appears while burrowrs runs"
	run burrowrs user show alice
	assert_success
	assert_output --partial "alice  (active, created"
	assert_output --partial "expires 2027-01-31, quota 50G/month, devices 2"
	assert_output --regexp 'https://t\.me/proxy\?server=notes\.example\.org&port=443&secret=ee'
	run burrowrs user show nobody
	assert_failure
	assert_output --partial "no user named nobody"
}

@test "user link: formats, and each user's link is their own" {
	init_users --link-host 203.0.113.7
	burrowrs user add alice >/dev/null 2>&1
	burrowrs user add bob >/dev/null 2>&1
	users_load "$USERS_FILE"
	run burrowrs user link alice --format secret
	assert_output "ee${USER_KEY[alice]}6e6f7465732e6578616d706c652e6f7267"
	run burrowrs user link bob --format tg
	assert_output "tg://proxy?server=203.0.113.7&port=443&secret=ee${USER_KEY[bob]}6e6f7465732e6578616d706c652e6f7267"
	run burrowrs user link bob
	assert_line --index 1 "https://t.me/proxy?server=203.0.113.7&port=443&secret=ee${USER_KEY[bob]}6e6f7465732e6578616d706c652e6f7267"
	run burrowrs user link bob --format
	assert_failure
	run burrowrs user link bob --format png
	assert_failure
}

@test "user renew: from the later of today and the current expiry" {
	init_users
	burrowrs user add future --until 2099-01-10 >/dev/null 2>&1
	burrowrs user add past --days 1 >/dev/null 2>&1
	sed -i "s/$(date -u +%Y)-[0-9-]*T23:59:59Z/2020-01-01T23:59:59Z/" "$USERS_FILE"
	burrowrs user renew future --days 5 >/dev/null 2>&1
	burrowrs user renew past --days 5 >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "${USER_EXPIRES[future]}" 2099-01-15T23:59:59Z
	assert_equal "${USER_EXPIRES[past]}" "$(expiry_after_days 5)"
	run burrowrs user renew past
	assert_failure
	run burrowrs user renew past --days 5 --quota 1G
	assert_failure
	burrowrs user renew past --days never >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "${USER_EXPIRES[past]}" never
}

@test "user set: changes only what is given; removing a quota removes its period" {
	init_users
	burrowrs user add alice --days 10 --quota 50G --period monthly --ips 2 >/dev/null 2>&1
	users_load "$USERS_FILE"
	key=${USER_KEY[alice]} expires=${USER_EXPIRES[alice]}
	burrowrs user set alice --ips 5 >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "${USER_KEY[alice]} ${USER_EXPIRES[alice]} ${USER_QUOTA[alice]} ${USER_PERIOD[alice]} ${USER_IPS[alice]}" \
		"$key $expires 50G monthly 5"
	burrowrs user set alice --quota none >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "${USER_QUOTA[alice]} ${USER_PERIOD[alice]}" "none none"
	run burrowrs user set alice --period weekly
	assert_failure
	assert_output --partial "needs a quota"
	run burrowrs user set alice
	assert_failure
	assert_output --partial "nothing to change"
	burrowrs user set alice --until 2020-01-01 >/dev/null 2>&1
	users_load "$USERS_FILE"
	assert_equal "$(user_state alice)" expired
}

@test "user disable and enable" {
	init_users
	burrowrs user add alice >/dev/null 2>&1
	run burrowrs user disable alice
	assert_success
	assert_output --partial "disabled alice"
	users_load "$USERS_FILE"
	[[ ${USER_STATUS[alice]} == off ]]
	run burrowrs user disable alice
	assert_output --partial "already disabled"
	burrowrs user enable alice >/dev/null 2>&1
	users_load "$USERS_FILE"
	[[ ${USER_STATUS[alice]} == on ]]
}

@test "user rotate: a new key for one user only, with confirmation" {
	init_users
	burrowrs user add alice >/dev/null 2>&1
	burrowrs user add bob >/dev/null 2>&1
	users_load "$USERS_FILE"
	alice=${USER_KEY[alice]} bob=${USER_KEY[bob]}
	run burrowrs user rotate alice </dev/null
	assert_failure
	assert_output --partial "--yes"
	run burrowrs user rotate alice --yes
	assert_success
	users_load "$USERS_FILE"
	[[ ${USER_KEY[alice]} != "$alice" && ${USER_KEY[alice]} =~ ^[0-9a-f]{32}$ && ${USER_KEY[bob]} == "$bob" ]]
	assert_output --partial "ee${USER_KEY[alice]}"
}

@test "user remove: with confirmation; the rest stay" {
	init_users
	burrowrs user add alice >/dev/null 2>&1
	burrowrs user add bob >/dev/null 2>&1
	run burrowrs user remove alice </dev/null
	assert_failure
	users_load "$USERS_FILE"
	users_exists alice
	run burrowrs user rm alice -y
	assert_success
	assert_output --partial "removed alice"
	users_load "$USERS_FILE"
	run users_exists alice
	assert_failure
	users_exists bob
	run burrowrs user remove alice --yes
	assert_failure
	assert_output --partial "no user named alice"
}

@test "users mode: users.toml is rendered from users.tsv" {
	init_users
	burrowrs user add alice --quota 1G --ips 1 >/dev/null 2>&1
	burrowrs render >/dev/null 2>&1
	users_load "$USERS_FILE"
	toml=$(<"$BURROWRS_STATE_DIR/telemt/users.toml")
	[[ $toml == *"\"alice\" = \"${USER_KEY[alice]}\""* ]]
	[[ $toml == *$'[access.user_data_quota]\n"alice" = 1073741824'* ]]
	[[ $toml == *$'[access.user_max_unique_ips]\n"alice" = 1'* ]]
}

@test "users mode: a broken users.tsv stops render with the line number" {
	init_users
	printf 'alice\tnot-a-key\n' >"$USERS_FILE"
	run burrowrs render
	assert_failure
	assert_output --partial "users.tsv:1:"
}
