# shellcheck shell=bash
# shellcheck disable=SC2034 # settings are globals consumed by render.sh and the CLI
# The user's configuration (.env): strict parsing, defaults, validation, writing.
#
# .env is read as data and never `source`d, so a malformed or hostile file
# cannot execute code. Only the keys listed below are accepted.

CONFIG_KEYS=(
	BURROWRS_MODE DOMAIN COVER_DOMAIN ACCESS_MODE SECRET PUBLIC_IPV4 PUBLIC_IPV6 LINK_HOST
	BIND_ADDR PROXY_PORT HTTP_PORT METRICS_PORT ENABLE_IPV6 EDGE_SUBNET DECOY_IP EDGE_SUBNET6
	TLS_MODE ACME_EMAIL ACME_CA
	AD_TAG
	USER_DEFAULT_DAYS USER_DEFAULT_QUOTA USER_DEFAULT_PERIOD USER_DEFAULT_IPS
	MAX_CONNECTIONS TELEMT_MEMORY_LIMIT DECOY_MEMORY_LIMIT
	LOGGING LOG_LEVEL
)

config_reset() {
	local key
	for key in "${CONFIG_KEYS[@]}"; do
		unset "$key"
	done
}

config_set_defaults() {
	: "${BURROWRS_MODE:=stealth}"
	: "${DOMAIN:=}" "${COVER_DOMAIN:=}" "${SECRET:=}"
	: "${ACCESS_MODE:=shared}"
	: "${PUBLIC_IPV4:=}" "${PUBLIC_IPV6:=}" "${LINK_HOST:=}"
	: "${BIND_ADDR:=0.0.0.0}"
	: "${PROXY_PORT:=443}"
	: "${HTTP_PORT:=80}"
	: "${METRICS_PORT:=3129}"
	: "${ENABLE_IPV6:=false}"
	: "${EDGE_SUBNET:=10.204.47.0/28}"
	: "${DECOY_IP:=10.204.47.10}"
	: "${EDGE_SUBNET6:=fd42:7761:7272:656e::/64}"
	: "${TLS_MODE:=acme}"
	: "${ACME_EMAIL:=}" "${ACME_CA:=}"
	: "${AD_TAG:=}"
	: "${USER_DEFAULT_DAYS:=30}"
	: "${USER_DEFAULT_QUOTA:=none}"
	: "${USER_DEFAULT_PERIOD:=none}"
	: "${USER_DEFAULT_IPS:=3}"
	: "${MAX_CONNECTIONS:=5000}"
	: "${TELEMT_MEMORY_LIMIT:=512m}"
	: "${DECOY_MEMORY_LIMIT:=256m}"
	: "${LOGGING:=on}"
	: "${LOG_LEVEL:=silent}"
}

config_is_known_key() {
	local key
	for key in "${CONFIG_KEYS[@]}"; do
		[[ $key == "$1" ]] && return 0
	done
	return 1
}

# config_load FILE: reset, parse KEY=value lines, apply defaults.
config_load() {
	local file=$1 line key value n=0
	[[ -f $file ]] || die "no configuration at $file. Create one with: ./burrowrs init --domain notes.example.com"
	config_reset
	while IFS= read -r line || [[ -n $line ]]; do
		n=$((n + 1))
		line=${line%$'\r'}
		[[ $line =~ ^[[:space:]]*(#|$) ]] && continue
		[[ $line =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "$file:$n: expected KEY=value, got: $line"
		key=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
		if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then
			value=${BASH_REMATCH[1]}
		fi
		if ! config_is_known_key "$key"; then
			warn "$file:$n: unknown setting $key (ignored)"
			continue
		fi
		printf -v "$key" '%s' "$value"
	done <"$file"
	config_set_defaults
	# Simple mode has no decoy, so older configs may carry a DECOY_IP outside a
	# changed EDGE_SUBNET. Compose still needs a consistent value: derive one.
	if [[ $BURROWRS_MODE == simple ]] && is_cidr4 "$EDGE_SUBNET" &&
		! { is_ipv4 "$DECOY_IP" && ip_in_subnet "$DECOY_IP" "$EDGE_SUBNET"; }; then
		DECOY_IP=$(subnet_host "$EDGE_SUBNET" 10)
	fi
}

# The hostname clients put in SNI, which is also encoded in every link.
config_front_host() {
	if [[ $BURROWRS_MODE == stealth ]]; then printf '%s\n' "$DOMAIN"; else printf '%s\n' "$COVER_DOMAIN"; fi
}

# What goes into share links as "server".
config_link_host() {
	if [[ -n $LINK_HOST ]]; then
		printf '%s\n' "$LINK_HOST"
	elif [[ $BURROWRS_MODE == stealth ]]; then
		printf '%s\n' "$DOMAIN"
	else
		printf '%s\n' "$PUBLIC_IPV4"
	fi
}

ipv4_to_int() {
	local a b c d
	IFS=. read -r a b c d <<<"$1"
	printf '%d\n' $(((a << 24) | (b << 16) | (c << 8) | d))
}

int_to_ipv4() {
	printf '%d.%d.%d.%d\n' $((($1 >> 24) & 255)) $((($1 >> 16) & 255)) $((($1 >> 8) & 255)) $(($1 & 255))
}

# subnet_host CIDR N: the Nth address of the network (N=10 -> x.x.x.10 for a /24).
subnet_host() {
	local net bits mask
	net=$(ipv4_to_int "${1%/*}")
	bits=${1#*/}
	mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
	int_to_ipv4 $(((net & mask) + $2))
}

# ip_in_subnet IP CIDR: true if IP is a usable host address in CIDR and is
# not the first host (Docker hands that to the bridge gateway).
ip_in_subnet() {
	local ip net bits mask
	ip=$(ipv4_to_int "$1")
	net=$(ipv4_to_int "${2%/*}")
	bits=${2#*/}
	((bits >= 1 && bits <= 30)) || return 1
	mask=$(((0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF))
	(((ip & mask) == (net & mask))) || return 1
	local host=$((ip & ~mask & 0xFFFFFFFF)) top=$((~mask & 0xFFFFFFFF))
	((host > 1 && host < top))
}

# RAM one client connection can take inside the telemt container. Measured
# on 2026-11-18 at 70-75 KiB per active connection (client and Telegram
# sockets, buffers included; 3000 held at once used 219 MiB), plus headroom.
CONN_BUDGET_KIB=96

# mem_kib 512m -> 524288
mem_kib() {
	local n=${1%[kmgKMG]} unit=${1: -1}
	case ${unit,,} in
	k) printf '%d\n' "$n" ;;
	m) printf '%d\n' $((n * 1024)) ;;
	g) printf '%d\n' $((n * 1024 * 1024)) ;;
	esac
}

# config_capacity_warning: when MAX_CONNECTIONS can need more RAM than
# TELEMT_MEMORY_LIMIT allows, say so (and return 0). Past the memory limit
# the kernel kills telemt and every user drops at once; within it, telemt
# simply refuses connections over MAX_CONNECTIONS.
config_capacity_warning() {
	is_count "$MAX_CONNECTIONS" && is_mem "$TELEMT_MEMORY_LIMIT" || return 1
	local need_kib=$((MAX_CONNECTIONS * CONN_BUDGET_KIB)) have_kib fits
	have_kib=$(mem_kib "$TELEMT_MEMORY_LIMIT")
	((need_kib > have_kib)) || return 1
	fits=$((have_kib / CONN_BUDGET_KIB))
	printf 'MAX_CONNECTIONS=%s can need about %d MiB, but TELEMT_MEMORY_LIMIT=%s: at that load the kernel would kill the proxy and drop everyone. Lower MAX_CONNECTIONS to %d or less, or raise TELEMT_MEMORY_LIMIT (about %d KiB per connection).\n' \
		"$MAX_CONNECTIONS" $((need_kib / 1024)) "$TELEMT_MEMORY_LIMIT" "$fits" "$CONN_BUDGET_KIB"
}

_config_errors=()
_need() { # _need KEY VALIDATOR MESSAGE
	local value=${!1-}
	"$2" "$value" || _config_errors+=("$1=${value:-<empty>}: $3")
}

is_none_or_size() { [[ $1 == none ]] || is_size "$1"; }
is_none_or_period() { [[ $1 == none ]] || is_quota_period "$1"; }
is_none_or_count() { [[ $1 == none ]] || is_count "$1"; }
is_days() { [[ $1 == never ]] || { is_count "$1" && (($1 <= 36500)); }; }

config_validate() {
	_config_errors=()

	_need BURROWRS_MODE is_mode "must be 'stealth' or 'simple'"
	_need ACCESS_MODE is_access_mode "must be 'shared' (one secret for everyone) or 'users' (a secret per user)"
	# Every value reaches compose.env, so every key is checked in every mode.
	_need HTTP_PORT is_port "must be 1-65535 (port 80 is needed for Let's Encrypt HTTP-01)"
	_need DECOY_IP is_ipv4 "must be an IPv4 address inside EDGE_SUBNET"
	_need TLS_MODE is_tls_mode "must be 'acme' or 'internal'"
	[[ -z $ACME_EMAIL ]] || _need ACME_EMAIL is_email "is not an email address"
	[[ -z $ACME_CA ]] || _need ACME_CA is_https_url "must be an https:// ACME directory URL"
	if [[ $BURROWRS_MODE == stealth ]]; then
		_need DOMAIN is_hostname "stealth mode needs a domain you own, pointed at this server (lowercase FQDN)"
	elif [[ $BURROWRS_MODE == simple ]]; then
		_need COVER_DOMAIN is_hostname "simple mode needs a real HTTPS site to impersonate (lowercase FQDN)"
		[[ -n $LINK_HOST ]] || _need PUBLIC_IPV4 is_ipv4 "simple mode needs the server's public IPv4 (or set LINK_HOST)"
	fi
	is_key "$SECRET" || _config_errors+=("SECRET: missing or not 32 hex characters. Run: ./burrowrs rotate")

	[[ -z $PUBLIC_IPV4 ]] || _need PUBLIC_IPV4 is_ipv4 "is not an IPv4 address"
	[[ -z $PUBLIC_IPV6 ]] || _need PUBLIC_IPV6 is_ipv6 "is not an IPv6 address"
	[[ -z $LINK_HOST ]] || { is_hostname "$LINK_HOST" || is_ip "$LINK_HOST"; } ||
		_config_errors+=("LINK_HOST=$LINK_HOST: must be a hostname or IP")

	_need BIND_ADDR is_bind_addr "must be an IPv4 address such as 0.0.0.0 or 127.0.0.1"
	_need PROXY_PORT is_port "must be 1-65535"
	_need METRICS_PORT is_port "must be 1-65535 (it is only ever bound to 127.0.0.1)"
	if [[ $BURROWRS_MODE == stealth && $PROXY_PORT == "$HTTP_PORT" ]]; then
		_config_errors+=("HTTP_PORT: must differ from PROXY_PORT")
	fi
	_need ENABLE_IPV6 is_bool "must be true or false"
	_need EDGE_SUBNET is_cidr4 "must be an IPv4 CIDR such as 10.204.47.0/28"
	if is_ipv4 "$DECOY_IP" && is_cidr4 "$EDGE_SUBNET"; then
		ip_in_subnet "$DECOY_IP" "$EDGE_SUBNET" ||
			_config_errors+=("DECOY_IP=$DECOY_IP: must be a host address inside EDGE_SUBNET=$EDGE_SUBNET (not .0, .1 or broadcast)")
	fi
	_need EDGE_SUBNET6 is_cidr6 "must be an IPv6 CIDR such as fd42:7761:7272:656e::/64"
	if [[ $ENABLE_IPV6 == true && $BIND_ADDR != 0.0.0.0 && $BIND_ADDR != 127.0.0.1 ]]; then
		_config_errors+=("ENABLE_IPV6=true: IPv6 listens on all interfaces (with BIND_ADDR=0.0.0.0) or on loopback (with 127.0.0.1), not alongside BIND_ADDR=$BIND_ADDR")
	fi

	[[ -z $AD_TAG ]] || _need AD_TAG is_ad_tag "must be the 32 hex characters @MTProxybot gives you"
	if [[ -n $AD_TAG && -z $PUBLIC_IPV4 ]]; then
		_config_errors+=("AD_TAG: the sponsored-channel route goes through Telegram's middle proxies, which need PUBLIC_IPV4")
	fi

	_need USER_DEFAULT_DAYS is_days "must be a number of days (1-36500) or 'never'"
	_need USER_DEFAULT_QUOTA is_none_or_size "must be 'none' or a size such as 50G"
	_need USER_DEFAULT_PERIOD is_none_or_period "must be none, daily, weekly or monthly"
	_need USER_DEFAULT_IPS is_none_or_count "must be 'none' or a positive number"
	if [[ $USER_DEFAULT_PERIOD != none && $USER_DEFAULT_QUOTA == none ]]; then
		_config_errors+=("USER_DEFAULT_PERIOD=$USER_DEFAULT_PERIOD: a reset period needs a USER_DEFAULT_QUOTA")
	fi

	_need MAX_CONNECTIONS is_count "must be a positive integer without leading zeros"
	_need TELEMT_MEMORY_LIMIT is_mem "must look like 512m or 1g"
	_need DECOY_MEMORY_LIMIT is_mem "must look like 256m or 1g"
	[[ $LOGGING == on || $LOGGING == off ]] || _config_errors+=("LOGGING=$LOGGING: must be on or off")
	_need LOG_LEVEL is_log_level "must be silent, normal, verbose or debug"

	if ((${#_config_errors[@]})); then
		local e
		for e in "${_config_errors[@]}"; do cross "$e"; done
		return 1
	fi
}

# Replace (or append) one KEY=value line, preserving everything else.
config_set_value() {
	local file=$1 key=$2 value=$3 line found=0
	config_is_known_key "$key" || die "unknown setting $key"
	{
		while IFS= read -r line || [[ -n $line ]]; do
			if [[ $line =~ ^${key}= ]]; then
				printf '%s=%s\n' "$key" "$value"
				found=1
			else
				printf '%s\n' "$line"
			fi
		done <"$file"
		((found)) || printf '%s=%s\n' "$key" "$value"
	} | write_atomic "$file" 600
}

# Write a fresh, documented .env from the current values.
config_write() {
	local file=$1
	write_atomic "$file" 600 <<EOF
# burrowrs configuration. Generated by \`./burrowrs init\` on $(date -u +%Y-%m-%d).
# This file holds your SECRET: keep it private (mode 0600) and back it up.
# After editing, apply with: ./burrowrs up        Reference: docs/CONFIGURATION.md

# --- Identity --------------------------------------------------------------
# stealth: your own domain, a real decoy website and a real TLS certificate (recommended)
# simple:  no domain needed; impersonate COVER_DOMAIN (works, but easier to spot)
BURROWRS_MODE=$BURROWRS_MODE
DOMAIN=$DOMAIN
COVER_DOMAIN=$COVER_DOMAIN
PUBLIC_IPV4=$PUBLIC_IPV4
PUBLIC_IPV6=$PUBLIC_IPV6
# What share links point at. Default: DOMAIN (stealth) or PUBLIC_IPV4 (simple).
LINK_HOST=$LINK_HOST

# --- Access ----------------------------------------------------------------
# shared: one secret (SECRET) for everyone; \`./burrowrs rotate\` revokes it for all.
# users:  every user gets a name and a secret of their own (\`./burrowrs user add\`),
#         with an expiry date, a data quota and a device limit. SECRET stays
#         yours: the built-in "owner" user that health checks also use.
ACCESS_MODE=$ACCESS_MODE
SECRET=$SECRET
# Defaults for \`./burrowrs user add\` (each can be overridden per user).
# Days until expiry (or never), quota (none or e.g. 50G), when the quota
# resets (none, daily, weekly, monthly) and how many IPs may connect at once.
USER_DEFAULT_DAYS=$USER_DEFAULT_DAYS
USER_DEFAULT_QUOTA=$USER_DEFAULT_QUOTA
USER_DEFAULT_PERIOD=$USER_DEFAULT_PERIOD
USER_DEFAULT_IPS=$USER_DEFAULT_IPS
# Optional sponsored channel from @MTProxybot (32 hex characters).
AD_TAG=$AD_TAG

# --- Network ---------------------------------------------------------------
BIND_ADDR=$BIND_ADDR
PROXY_PORT=$PROXY_PORT
HTTP_PORT=$HTTP_PORT
METRICS_PORT=$METRICS_PORT
ENABLE_IPV6=$ENABLE_IPV6
EDGE_SUBNET=$EDGE_SUBNET
DECOY_IP=$DECOY_IP
EDGE_SUBNET6=$EDGE_SUBNET6

# --- TLS for the decoy site (stealth mode) ---------------------------------
TLS_MODE=$TLS_MODE
ACME_EMAIL=$ACME_EMAIL
ACME_CA=$ACME_CA

# --- Capacity --------------------------------------------------------------
# Each connection needs about 96 KiB inside TELEMT_MEMORY_LIMIT (measured 70-75):
# 512m holds about 5400. A Telegram app keeps 2-4 connections while active.
MAX_CONNECTIONS=$MAX_CONNECTIONS
TELEMT_MEMORY_LIMIT=$TELEMT_MEMORY_LIMIT
DECOY_MEMORY_LIMIT=$DECOY_MEMORY_LIMIT

# --- Observability ---------------------------------------------------------
# LOGGING=off keeps no container logs at all. LOG_LEVEL: silent (warnings and
# errors only), normal, verbose or debug. See docs/THREAT-MODEL.md for what
# each level can record.
LOGGING=$LOGGING
LOG_LEVEL=$LOG_LEVEL
EOF
}
