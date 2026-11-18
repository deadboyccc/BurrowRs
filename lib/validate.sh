# shellcheck shell=bash
# Pure validators: each returns 0 (valid) or 1, prints nothing.
# Strict on purpose: every value ends up in TOML, a Caddyfile or a compose
# file, so anything outside a small, known alphabet is rejected up front
# instead of being escaped later.

is_bool() { [[ $1 == true || $1 == false ]]; }

is_uint() { [[ $1 =~ ^[0-9]+$ ]]; }

# A positive integer without leading zeros (valid in TOML).
is_count() { [[ $1 =~ ^[1-9][0-9]{0,8}$ ]]; }

is_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && (($1 >= 1 && $1 <= 65535)); }

# Lowercase LDH hostname with at least one dot (an FQDN). IDNs must be
# given in punycode (xn--...).
is_hostname() {
	local h=$1 label
	[[ ${#h} -le 253 && $h == *.* && $h =~ ^[a-z0-9.-]+$ ]] || return 1
	[[ $h != .* && $h != *. && $h != *..* ]] || return 1
	local IFS=.
	for label in $h; do
		[[ ${#label} -ge 1 && ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
	done
	# The last label (TLD) must not be all digits, or this is an IP.
	[[ ! ${h##*.} =~ ^[0-9]+$ ]]
}

is_ipv4() {
	local ip=$1 octet
	[[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
	local IFS=.
	for octet in $ip; do
		[[ $octet == 0 || $octet != 0* ]] || return 1 # no leading zeros
		((octet <= 255)) || return 1
	done
}

# Eight 1-4 digit hex groups, or fewer around a single "::". No zone ids and
# no embedded IPv4.
is_ipv6() {
	local ip=$1 head tail groups=() part group n=0
	[[ $ip =~ ^[0-9a-fA-F:]+$ && ${#ip} -le 39 ]] || return 1
	if [[ $ip == *::* ]]; then
		head=${ip%%::*} tail=${ip#*::}
		[[ $tail != *::* ]] || return 1
	else
		head=$ip tail=''
	fi
	for part in "$head" "$tail"; do
		[[ -z $part ]] && continue
		IFS=: read -ra groups <<<"$part"
		[[ $part != :* && $part != *: ]] || return 1
		for group in "${groups[@]}"; do
			[[ $group =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
			n=$((n + 1))
		done
	done
	if [[ $ip == *::* ]]; then ((n <= 7)); else ((n == 8)); fi
}

is_ip() { is_ipv4 "$1" || is_ipv6 "$1"; }

is_bind_addr() { is_ipv4 "$1"; }

is_cidr4() {
	[[ $1 == */* ]] || return 1
	local ip=${1%/*} bits=${1#*/}
	is_ipv4 "$ip" && [[ $bits =~ ^[0-9]{1,2}$ ]] && ((bits <= 32))
}

is_cidr6() {
	[[ $1 == */* ]] || return 1
	local ip=${1%/*} bits=${1#*/}
	is_ipv6 "$ip" && [[ $bits =~ ^[0-9]{1,3}$ ]] && ((bits <= 128))
}

# Docker memory limits: 256m, 1g.
is_mem() { [[ $1 =~ ^[0-9]+[kmg]$ ]]; }

is_email() { [[ $1 =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }

# https URL without characters that would need escaping in TOML/Caddyfile.
is_https_url() { [[ $1 =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+=-]*)?$ ]]; }

is_http_url() { [[ $1 =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~%/+=-]*)?$ ]]; }

# socks5://[user:pass@]host:port. Credentials limited to a safe alphabet.
is_socks5_url() { [[ $1 =~ ^socks5://([A-Za-z0-9._~%-]+(:[A-Za-z0-9._~%-]*)?@)?[A-Za-z0-9.-]+:[0-9]{1,5}$ ]]; }

is_mode() { [[ $1 == stealth || $1 == simple ]]; }

# shared: one secret for everyone. users: a name and a secret per customer.
is_access_mode() { [[ $1 == shared || $1 == users ]]; }

# A customer name: it becomes a TOML key and a column in users.tsv, so the
# alphabet is small. "owner" is the operator's own built-in user.
is_username() { [[ $1 =~ ^[a-z0-9][a-z0-9_.-]{0,31}$ ]]; }

# A data size for quotas: a whole number with K, M, G or T (binary units).
is_size() { [[ ${1^^} =~ ^[1-9][0-9]{0,5}[KMGT]$ ]]; }

# UTC timestamp exactly as burrowrs writes it: 2026-12-31T23:59:59Z.
is_utc_time() {
	[[ $1 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z$ ]] || return 1
	local mo=$((10#${BASH_REMATCH[2]})) d=$((10#${BASH_REMATCH[3]})) h=$((10#${BASH_REMATCH[4]}))
	local mi=$((10#${BASH_REMATCH[5]})) s=$((10#${BASH_REMATCH[6]}))
	((mo >= 1 && mo <= 12 && d >= 1 && d <= 31 && h <= 23 && mi <= 59 && s <= 59))
}

# A calendar date: 2026-12-31.
is_date() { [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] && is_utc_time "${1}T00:00:00Z"; }

is_quota_period() { [[ $1 == daily || $1 == weekly || $1 == monthly ]]; }

# @MTProxybot ad tag: 32 hex characters.
is_ad_tag() { [[ $1 =~ ^[0-9a-f]{32}$ ]]; }

is_log_level() { [[ $1 == silent || $1 == normal || $1 == verbose || $1 == debug ]]; }

is_tls_mode() { [[ $1 == acme || $1 == internal ]]; }

# Absolute host path made of safe characters (it is copied, never interpolated).
is_abs_path() { [[ $1 =~ ^/[A-Za-z0-9._/-]+$ && $1 != *..* ]]; }
