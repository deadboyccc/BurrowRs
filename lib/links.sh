# shellcheck shell=bash
# Telegram proxy share links.

urlencode() {
	local s=$1 out='' c i
	for ((i = 0; i < ${#s}; i++)); do
		c=${s:i:1}
		case $c in
		[A-Za-z0-9._~-]) out+=$c ;;
		*) out+=$(printf '%%%02X' "'$c") ;;
		esac
	done
	printf '%s' "$out"
}

_link_query() {
	printf 'server=%s&port=%s&secret=%s' "$(urlencode "$1")" "$(urlencode "$2")" "$(urlencode "$3")"
}

# Opens the Telegram app directly.
link_tg() { printf 'tg://proxy?%s\n' "$(_link_query "$@")"; }

# Web link that works anywhere and redirects into the app.
link_tme() { printf 'https://t.me/proxy?%s\n' "$(_link_query "$@")"; }
