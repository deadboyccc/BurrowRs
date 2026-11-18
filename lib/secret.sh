# shellcheck shell=bash
# Secrets. telemt stores one 16-byte key per user (32 hex characters); share
# links carry the FakeTLS form: "ee" + key + hex(fronting hostname).

hex_encode() {
	printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

hex_decode() {
	local hex=$1
	[[ $hex =~ ^([0-9a-f]{2})*$ ]] || return 1
	# Turn "6162" into "\x61\x62" and let printf decode it. (sed, not
	# ${var//}: replacement back-references need bash 5.2.)
	# shellcheck disable=SC2001
	printf '%b' "$(sed 's/../\\x&/g' <<<"$hex")"
}

# A fresh user key: 16 random bytes as 32 lowercase hex characters.
key_new() { random_hex 16; }

is_key() { [[ $1 =~ ^[0-9a-f]{32}$ ]]; }

# key_link_secret KEY HOST: the ee… secret that goes into share links.
key_link_secret() {
	is_key "$1" && is_hostname "$2" || return 1
	printf 'ee%s%s\n' "$1" "$(hex_encode "$2")"
}

secret_is_valid() {
	[[ $1 =~ ^ee[0-9a-f]{32}([0-9a-f]{2})+$ ]] || return 1
	local host
	host=$(secret_host "$1") && is_hostname "$host"
}

# Print the fronting hostname embedded in a link secret.
secret_host() {
	[[ $1 =~ ^ee[0-9a-f]{32}([0-9a-f]{2})+$ ]] || return 1
	hex_decode "${1:34}"
}

# secret_normalize SECRET: accept the hex form (ee…, any case) or the
# base64/base64url form that Telegram links also use, and print the
# canonical lowercase hex form. Fails for anything else.
secret_normalize() {
	local s=$1 b64 hex
	if [[ ${s,,} =~ ^ee([0-9a-f]{2})+$ ]]; then
		hex=${s,,}
	elif [[ $s =~ ^[A-Za-z0-9+/_-]+=*$ ]]; then
		b64=${s%%=*}
		b64=${b64//-/+}
		b64=${b64//_//}
		while ((${#b64} % 4)); do b64+='='; done
		hex=$(printf '%s' "$b64" | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; } | od -An -tx1 -v | tr -d ' \n')
	else
		return 1
	fi
	secret_is_valid "$hex" || return 1
	printf '%s\n' "$hex"
}

# Never print a full key or secret in logs.
secret_redact() {
	printf '%s…%s\n' "${1:0:6}" "${1: -4}"
}
