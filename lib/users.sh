# shellcheck shell=bash
# shellcheck disable=SC2034 # USER_* arrays are read by render.sh and the CLI
# The user list (users.tsv) for ACCESS_MODE=users.
#
# One user per line, tab-separated, parsed as data (never executed):
#   name  key  expires  quota  period  ips  status  created
#   name     is_username; "owner" is reserved for the operator (SECRET in .env)
#   key      32 hex characters (telemt's per-user secret)
#   expires  2026-12-31T23:59:59Z, or "never"
#   quota    "none", or a size such as 50G (binary units)
#   period   none, daily, weekly or monthly (when the quota resets; UTC)
#   ips      "none", or how many source IPs may be connected at once
#   status   on or off
#   created  2026-11-18

OWNER_USER=owner
USERS_HEADER='# burrowrs users. Manage with ./burrowrs user (see ./burrowrs user --help). Keep private: it holds secrets.
# name	key	expires	quota	period	ips	status	created'

users_reset() {
	USER_NAMES=()
	declare -gA USER_KEY=() USER_EXPIRES=() USER_QUOTA=() USER_PERIOD=() USER_IPS=() USER_STATUS=() USER_CREATED=()
}

# users_check_row NAME KEY EXPIRES QUOTA PERIOD IPS STATUS CREATED: print why
# a row is invalid, or nothing.
users_check_row() {
	local name=$1 key=$2 expires=$3 quota=$4 period=$5 ips=$6 status=$7 created=$8
	is_username "$name" || {
		echo "bad name (lowercase letters, digits, . _ -, up to 32)"
		return
	}
	[[ $name != "$OWNER_USER" ]] || {
		echo "'$OWNER_USER' is reserved for the operator"
		return
	}
	is_key "$key" || {
		echo "key must be 32 hex characters"
		return
	}
	[[ $expires == never ]] || is_utc_time "$expires" || {
		echo "expires must be never or YYYY-MM-DDTHH:MM:SSZ"
		return
	}
	[[ $quota == none ]] || is_size "$quota" || {
		echo "quota must be none or a size such as 50G"
		return
	}
	[[ $period == none ]] || is_quota_period "$period" || {
		echo "period must be none, daily, weekly or monthly"
		return
	}
	[[ $period == none || $quota != none ]] || {
		echo "a reset period needs a quota"
		return
	}
	[[ $ips == none ]] || is_count "$ips" || {
		echo "ips must be none or a positive number"
		return
	}
	[[ $status == on || $status == off ]] || {
		echo "status must be on or off"
		return
	}
	is_date "$created" || echo "created must be YYYY-MM-DD"
}

# users_load FILE: parse into USER_NAMES and the USER_* maps. A missing file
# is an empty list. Dies on the first malformed line, naming it.
users_load() {
	local file=$1 line n=0 fields problem
	users_reset
	[[ -f $file ]] || return 0
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		IFS=$'\t' read -r -a fields <<<"$line"
		((${#fields[@]} == 8)) || die "$file:$n: expected 8 tab-separated fields, found ${#fields[@]}"
		problem=$(users_check_row "${fields[@]}")
		[[ -z $problem ]] || die "$file:$n: $problem"
		[[ -z ${USER_KEY[${fields[0]}]+set} ]] || die "$file:$n: duplicate user ${fields[0]}"
		USER_NAMES+=("${fields[0]}")
		USER_KEY[${fields[0]}]=${fields[1]}
		USER_EXPIRES[${fields[0]}]=${fields[2]}
		USER_QUOTA[${fields[0]}]=${fields[3]}
		[[ ${fields[3]} == none ]] || USER_QUOTA[${fields[0]}]=${fields[3]^^}
		USER_PERIOD[${fields[0]}]=${fields[4]}
		USER_IPS[${fields[0]}]=${fields[5]}
		USER_STATUS[${fields[0]}]=${fields[6]}
		USER_CREATED[${fields[0]}]=${fields[7]}
	done <"$file"
}

users_exists() { [[ -n ${USER_KEY[$1]+set} ]]; }

# users_save FILE: write every loaded user back, atomically, mode 0600.
users_save() {
	local file=$1 name
	{
		printf '%s\n' "$USERS_HEADER"
		for name in "${USER_NAMES[@]}"; do
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "${USER_KEY[$name]}" "${USER_EXPIRES[$name]}" \
				"${USER_QUOTA[$name]}" "${USER_PERIOD[$name]}" "${USER_IPS[$name]}" "${USER_STATUS[$name]}" \
				"${USER_CREATED[$name]}"
		done
	} | write_atomic "$file" 600
}

users_remove_name() {
	local gone=$1 name kept=()
	for name in "${USER_NAMES[@]}"; do
		[[ $name == "$gone" ]] || kept+=("$name")
	done
	USER_NAMES=("${kept[@]}")
	unset "USER_KEY[$gone]" "USER_EXPIRES[$gone]" "USER_QUOTA[$gone]" "USER_PERIOD[$gone]" \
		"USER_IPS[$gone]" "USER_STATUS[$gone]" "USER_CREATED[$gone]"
}

# --- sizes and times -------------------------------------------------------

# size_bytes 50G -> 53687091200 (binary units).
size_bytes() {
	local n=${1%?} unit=${1: -1}
	case ${unit^^} in
	K) printf '%d\n' $((n * 1024)) ;;
	M) printf '%d\n' $((n * 1024 ** 2)) ;;
	G) printf '%d\n' $((n * 1024 ** 3)) ;;
	T) printf '%d\n' $((n * 1024 ** 4)) ;;
	esac
}

# human_bytes 1536 -> 1.5K
human_bytes() {
	awk -v b="$1" 'BEGIN {
		split("B K M G T", u, " ")
		i = 1
		while (b >= 1024 && i < 5) { b /= 1024; i++ }
		if (i == 1) printf "%d%s\n", b, u[i]; else printf "%.1f%s\n", b, u[i]
	}'
}

now_epoch() { date -u +%s; }

# epoch_to_utc 1798761599 -> 2026-12-31T23:59:59Z (GNU or BSD date).
epoch_to_utc() {
	date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# utc_to_epoch 2026-12-31T23:59:59Z -> 1798761599
utc_to_epoch() {
	date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}

# expiry_after_days DAYS [FROM_EPOCH]: the end of the last day, UTC.
expiry_after_days() {
	local from=${2:-$(now_epoch)}
	epoch_to_utc $(((from / 86400 + $1) * 86400 + 86399))
}

# user_state NAME: active, disabled or expired.
user_state() {
	if [[ ${USER_STATUS[$1]} == off ]]; then
		echo disabled
	elif [[ ${USER_EXPIRES[$1]} != never ]] && (($(utc_to_epoch "${USER_EXPIRES[$1]}") < $(now_epoch))); then
		echo expired
	else
		echo active
	fi
}
