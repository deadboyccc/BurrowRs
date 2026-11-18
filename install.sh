#!/usr/bin/env bash
# burrowrs one-command installer. Run it ON the server (Debian/Ubuntu), as root.
#
#   Stealth mode (recommended: your own domain, A record pointing at the server):
#     curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
#       sudo BURROWRS_DOMAIN=notes.example.com BURROWRS_EMAIL=you@example.com bash
#
#   No domain? Your IP as a free wildcard-DNS name still gets a real certificate:
#     curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
#       sudo BURROWRS_DOMAIN=203-0-113-7.sslip.io BURROWRS_LINK_HOST=203.0.113.7 bash
#
#   Simple mode (last resort; impersonate a popular site reachable where your users are):
#     curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
#       sudo BURROWRS_COVER_DOMAIN=www.wikipedia.org bash
#
# It installs git/curl if needed, fetches this burrowrs release, prepares the host
# (Docker, firewall, kernel tuning, time sync, security updates, watchdog), creates
# the secret, starts the proxy, runs the smoke test, and prints the share links and
# a QR code. Re-running it upgrades burrowrs in place and keeps the existing secret.
#
# Settings (environment variables):
#   BURROWRS_DOMAIN           stealth mode: your domain (A record -> this server)
#   BURROWRS_COVER_DOMAIN     simple mode: a popular HTTPS site reachable by your users
#   BURROWRS_EMAIL            Let's Encrypt account email (optional, stealth mode)
#   BURROWRS_ACCESS           shared (default: one secret for everyone) or users
#                           (a name and a secret per user: ./burrowrs user add NAME)
#   BURROWRS_PORT             public proxy port (default 443)
#   BURROWRS_LINK_HOST        what share links point at (default: domain, or IP in simple mode)
#   BURROWRS_ENABLE_IPV6      true: also listen on IPv6
#   BURROWRS_SSH_PORT         your SSH port, if it can't be detected (ports sshd listens
#                           on are always kept open in the firewall)
#   BURROWRS_DIR              install directory (default /opt/burrowrs)
#   BURROWRS_REF              git tag or branch to install (default: this release)
#   BURROWRS_REPO             git URL (default: the official repository)
#   BURROWRS_INIT_ARGS        extra `burrowrs init` flags, e.g. "--subnet 10.77.1.0/28"
#   BURROWRS_SKIP_HOST_SETUP  1: leave Docker/firewall/sysctl alone (you manage the host)
#   BURROWRS_SWAP             0: never add a swap file (default: a 2 GiB one on servers
#                           with 2 GiB of RAM or less and no swap)
#   BURROWRS_DRY_RUN          1: print every step, change nothing
#
# The whole script is one function called on the last line, so a truncated
# download can never run half of it.

set -Eeuo pipefail

BURROWRS_INSTALLER_REF=v1.0.1 # the release this installer belongs to

say() { printf '%s\n' "$*" >&2; }
step() {
	if [[ -t 2 && -z ${NO_COLOR:-} ]]; then
		printf '\n\033[1m==> %s\033[0m\n' "$*" >&2
	else
		printf '\n==> %s\n' "$*" >&2
	fi
}
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}

valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (($1 <= 65535)); }

# Removed on exit, however the script ends.
BURROWRS_SRC=''
trap 'rm -rf -- "${BURROWRS_SRC:-}"' EXIT

# yes_no NAME VALUE: 1 for 1/true/yes/on, 0 for 0/false/no/off/empty.
# Anything else is fatal: a typo must never turn a dry run into a real one.
yes_no() {
	case ${2,,} in
	1 | true | yes | on) echo 1 ;;
	'' | 0 | false | no | off) echo 0 ;;
	*) die "$1 must be 1 or 0 (got '$2')" ;;
	esac
}

DRY=0

# run CMD...: execute, or only print it in a dry run.
run() {
	if ((DRY)); then
		printf '    [dry-run] %s\n' "$*" >&2
	else
		"$@"
	fi
}

main() {
	local domain=${BURROWRS_DOMAIN:-} cover=${BURROWRS_COVER_DOMAIN:-} email=${BURROWRS_EMAIL:-}
	local access=${BURROWRS_ACCESS:-shared}
	local port=${BURROWRS_PORT:-} link_host=${BURROWRS_LINK_HOST:-} ipv6=${BURROWRS_ENABLE_IPV6:-false}
	local ssh_port=${BURROWRS_SSH_PORT:-} dir=${BURROWRS_DIR:-/opt/burrowrs}
	local ref=${BURROWRS_REF:-$BURROWRS_INSTALLER_REF}
	local repo=${BURROWRS_REPO:-https://github.com/deadboyccc/BurrowRs.git}
	local skip_host swap
	DRY=$(yes_no BURROWRS_DRY_RUN "${BURROWRS_DRY_RUN:-}")
	skip_host=$(yes_no BURROWRS_SKIP_HOST_SETUP "${BURROWRS_SKIP_HOST_SETUP:-}")
	swap=$(yes_no BURROWRS_SWAP "${BURROWRS_SWAP:-1}")
	local extra_init=() arg
	read -ra extra_init <<<"${BURROWRS_INIT_ARGS:-}"
	for arg in "${extra_init[@]}"; do
		[[ $arg =~ ^[A-Za-z0-9._:/@,=-]+$ ]] || die "BURROWRS_INIT_ARGS: unsupported characters in '$arg'"
	done

	# --- check the settings before touching anything -------------------------
	domain=${domain,,} cover=${cover,,} link_host=${link_host,,}
	if [[ -n $domain && -n $cover ]]; then
		die "set BURROWRS_DOMAIN (stealth mode) or BURROWRS_COVER_DOMAIN (simple mode), not both"
	fi
	if [[ -z $domain && -z $cover ]]; then
		die "set BURROWRS_DOMAIN=your.domain (no domain? use your IP as 203-0-113-7.sslip.io) or BURROWRS_COVER_DOMAIN=popular.site.
       Example: curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh | sudo BURROWRS_DOMAIN=notes.example.com bash"
	fi
	local host_re='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
	[[ -z $domain || $domain =~ $host_re ]] || die "BURROWRS_DOMAIN is not a valid domain name: $domain"
	[[ -z $cover || $cover =~ $host_re ]] || die "BURROWRS_COVER_DOMAIN is not a valid domain name: $cover"
	[[ $access == shared || $access == users ]] || die "BURROWRS_ACCESS must be shared or users (got '$access')"
	[[ -z $port ]] || valid_port "$port" || die "BURROWRS_PORT must be 1-65535"
	[[ -z $ssh_port ]] || valid_port "$ssh_port" || die "BURROWRS_SSH_PORT must be 1-65535"
	[[ $ipv6 == true || $ipv6 == false ]] || die "BURROWRS_ENABLE_IPV6 must be true or false"
	[[ $dir =~ ^/[A-Za-z0-9._/-]+$ && $dir != *..* ]] || die "BURROWRS_DIR must be an absolute path"
	[[ $ref =~ ^[A-Za-z0-9._/-]+$ ]] || die "BURROWRS_REF is not a valid git ref"
	[[ $repo =~ ^(https://|file://|/)[A-Za-z0-9._/:@-]+$ ]] || die "BURROWRS_REPO must be an https:// git URL"
	((EUID == 0 || DRY)) || die "run as root, for example: curl -fsSL …/install.sh | sudo BURROWRS_DOMAIN=… bash"

	local mode=stealth
	[[ -n $cover ]] && mode=simple
	((DRY)) && say "DRY RUN: nothing will be changed."
	say "burrowrs installer ($ref): $mode mode, ${domain:-$cover}, port ${port:-443}, into $dir"

	# --- prerequisites -------------------------------------------------------
	step "prerequisites"
	if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
		command -v apt-get >/dev/null 2>&1 || die "git and curl are required (this installer automates Debian/Ubuntu)"
		# A fresh server may still be running its first automatic updates:
		# wait for the package lock instead of failing on it.
		run apt-get -o DPkg::Lock::Timeout=600 update -qq
		run env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 install -y -qq \
			--no-install-recommends git curl ca-certificates
	else
		say "    git and curl are present"
	fi

	# --- fetch burrowrs --------------------------------------------------------
	# Unpacked over the install directory: .env (the secret), state/ and
	# site.local/ are not part of the release, so they are never touched.
	step "fetching burrowrs $ref"
	BURROWRS_SRC=$(mktemp -d)
	local src=$BURROWRS_SRC/burrowrs fetched=0
	if ((DRY)); then
		# Fetching into a temp dir changes nothing, and lets the dry run show
		# the real host plan (including the SSH ports kept open).
		if command -v git >/dev/null 2>&1 &&
			git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$repo" "$src" 2>/dev/null; then
			fetched=1
			say "    fetched $ref into a temporary directory"
		else
			say "    [dry-run] git clone --depth 1 --branch $ref $repo"
		fi
		say "    [dry-run] unpack it over $dir (keeping .env, state/ and site.local/)"
	else
		git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$ref" "$repo" "$src"
		fetched=1
		install -d -m 0755 "$dir"
		local manifest=$dir/.burrowrs-manifest files
		files=$(git -C "$src" ls-tree -r --name-only HEAD)
		# tar.umask: 0755/0644 modes, never group-writable root-run code.
		git -c tar.umask=0022 -C "$src" archive --format=tar HEAD | tar -x -C "$dir" --no-same-owner
		# Files an earlier release installed but this one dropped would linger
		# (and a dropped decoy page would stay published): remove them.
		if [[ -f $manifest ]]; then
			local old
			while IFS= read -r old; do
				[[ -n $old && $old != /* && $old != *..* ]] && rm -f -- "${dir:?}/$old"
			done < <(comm -23 <(LC_ALL=C sort -u "$manifest") <(LC_ALL=C sort -u <<<"$files"))
		fi
		printf '%s\n' "$files" >"$manifest"
		chmod 0644 "$manifest"
	fi

	# --- an existing installation keeps its configuration ----------------------
	local burrowrs=("$dir/burrowrs") has_env=0 http_port=80
	if [[ -f $dir/.env && -x $dir/burrowrs ]]; then
		has_env=1
		local current_mode current_front current_port current_link
		current_mode=$("${burrowrs[@]}" config get BURROWRS_MODE)
		current_port=$("${burrowrs[@]}" config get PROXY_PORT)
		current_link=$("${burrowrs[@]}" config get LINK_HOST)
		http_port=$("${burrowrs[@]}" config get HTTP_PORT)
		if [[ $current_mode == stealth ]]; then
			current_front=$("${burrowrs[@]}" config get DOMAIN)
		else
			current_front=$("${burrowrs[@]}" config get COVER_DOMAIN)
		fi
		# Requested settings that differ are reported, never applied silently.
		local wanted=${domain:-$cover}
		if [[ $mode != "$current_mode" || $wanted != "$current_front" ]]; then
			say "    note: this server is configured for $current_mode mode with '$current_front'; keeping it."
			if [[ $mode == stealth ]]; then
				say "    To switch: ${burrowrs[*]} config set DOMAIN $domain && ${burrowrs[*]} up   (every link changes)"
			else
				say "    To switch: ${burrowrs[*]} config set BURROWRS_MODE simple COVER_DOMAIN $cover && ${burrowrs[*]} up   (every link changes)"
			fi
		fi
		if [[ -n $port && $port != "$current_port" ]]; then
			say "    note: keeping PROXY_PORT=$current_port. To change it: ${burrowrs[*]} config set PROXY_PORT $port && ${burrowrs[*]} up"
		fi
		if [[ -n $link_host && $link_host != "$current_link" ]]; then
			say "    note: keeping LINK_HOST=${current_link:-<default>}. To change it: ${burrowrs[*]} config set LINK_HOST $link_host"
		fi
		mode=$current_mode port=$current_port
	fi
	port=${port:-443}

	# --- host ----------------------------------------------------------------
	local ports=$port
	[[ $mode == stealth ]] && ports=$http_port,$port
	if ((skip_host)); then
		step "host preparation skipped (BURROWRS_SKIP_HOST_SETUP)"
	else
		step "preparing the host: Docker, firewall, kernel tuning, time sync, updates, watchdog"
		local host_args=(--dir "$dir" --ports "$ports")
		[[ -n $ssh_port ]] && host_args+=(--ssh-port "$ssh_port")
		((swap)) || host_args+=(--no-swap)
		if ((DRY && fetched)); then
			"$src/scripts/install-host.sh" "${host_args[@]}" --dry-run
		else
			run "$dir/scripts/install-host.sh" "${host_args[@]}"
		fi
	fi

	# --- configure (first run only) ------------------------------------------
	if ((has_env)); then
		step "keeping the existing configuration and secret ($dir/.env)"
		say "    (change settings later with: $dir/burrowrs config set KEY VALUE)"
	else
		step "creating the configuration and a fresh secret"
		local init_args=(init --port "$port" --quiet)
		if [[ $mode == stealth ]]; then
			init_args+=(--domain "$domain")
		else
			init_args+=(--mode simple --cover-domain "$cover")
		fi
		[[ -n $email ]] && init_args+=(--email "$email")
		init_args+=(--access "$access")
		[[ -n $link_host ]] && init_args+=(--link-host "$link_host")
		[[ $ipv6 == true ]] && init_args+=(--enable-ipv6)
		run "${burrowrs[@]}" "${init_args[@]}" "${extra_init[@]}"
	fi

	# --- start, verify, share ------------------------------------------------
	step "starting burrowrs"
	run "${burrowrs[@]}" up
	step "smoke test (real handshakes, a real Telegram round trip, probe resistance)"
	run "${burrowrs[@]}" smoke || die "burrowrs is running but failed its smoke test (details above). Diagnose with: $dir/burrowrs doctor"
	step "share"
	run "${burrowrs[@]}" share

	say ""
	if ((DRY)); then
		say "Dry run complete: nothing was changed. Run again without BURROWRS_DRY_RUN to install."
		return 0
	fi
	say "Done. burrowrs is running and will restart itself (and be watched) after reboots."
	say "  Back up $dir/.env somewhere safe: it holds your secret."
	say "  Manage it with: $dir/burrowrs status | share | rotate | logs | doctor"
}

main "$@"
