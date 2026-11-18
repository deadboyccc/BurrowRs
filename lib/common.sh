# shellcheck shell=bash
# shellcheck disable=SC2034 # BURROWRS_VERSION and colours are used by the CLI
# Shared helpers: output, errors, small portable utilities.
# Sourced by ./burrowrs and the tests. Never executed directly.

BURROWRS_VERSION="1.0.0"

if [[ -t 2 && -z ${NO_COLOR:-} && ${TERM:-} != dumb ]]; then
	C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
	C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
	C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE=''
fi

# All human-facing output goes to stderr so stdout stays clean for data
# (links, secrets, JSON) that callers may pipe somewhere.
say() { printf '%s\n' "$*" >&2; }
info() { printf '%s==>%s %s\n' "${C_BLUE}${C_BOLD}" "$C_RESET" "$*" >&2; }
ok() { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
cross() { printf '  %s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die() {
	printf '%serror:%s %s\n' "${C_RED}${C_BOLD}" "$C_RESET" "$1" >&2
	exit "${2:-1}"
}

need() {
	command -v "$1" >/dev/null 2>&1 || die "'$1' is required but was not found${2:+ ($2)}"
}

# Bash 4.4+ is needed for associative arrays, ${var@Q} and sane `set -u`
# behaviour with empty arrays.
require_bash() {
	if ((BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4))); then
		die "bash >= 4.4 is required (found $BASH_VERSION). On macOS: brew install bash"
	fi
}

# sha256 of stdin, hex only (Linux coreutils or macOS shasum).
sha256_stdin() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum | cut -d' ' -f1
	else
		shasum -a 256 | cut -d' ' -f1
	fi
}

# Print N random bytes as lowercase hex. /dev/urandom is the kernel CSPRNG.
random_hex() {
	od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'
}

# Pick a free TCP port on 127.0.0.1 in [20000, 60000).
free_port() {
	local port _
	for _ in {1..50}; do
		port=$((20000 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 40000))
		if ! (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			printf '%s\n' "$port"
			return 0
		fi
	done
	return 1
}

# Write stdin to a file atomically (temp file + rename) with the given mode.
write_atomic() {
	local dest=$1 mode=$2 tmp
	tmp=$(mktemp "${dest}.XXXXXX")
	cat >"$tmp"
	chmod "$mode" "$tmp"
	mv -f "$tmp" "$dest"
}

# Like write_atomic, but leaves DEST (and its inode) alone when the content
# is unchanged. Running containers bind-mount these files: replacing an
# unchanged file would strand them on the deleted inode.
write_if_changed() {
	local dest=$1 mode=$2 tmp
	tmp=$(mktemp "${dest}.XXXXXX")
	cat >"$tmp"
	if [[ -f $dest ]] && cmp -s "$tmp" "$dest"; then
		rm -f -- "$tmp"
		chmod "$mode" "$dest"
	else
		chmod "$mode" "$tmp"
		mv -f "$tmp" "$dest"
	fi
}

join_by() {
	local sep=$1
	shift
	local first=${1-}
	shift || true
	printf '%s' "$first" "${@/#/$sep}"
}
