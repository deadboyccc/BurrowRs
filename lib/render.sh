# shellcheck shell=bash
# shellcheck disable=SC2153 # settings are globals loaded by config.sh
# Render validated config into the files the containers read (STATE_DIR):
#   telemt/config.toml  proxy configuration
#   telemt/users.toml   secrets and per-user limits (reloaded live)
#   Caddyfile           decoy web server (stealth mode)
#   site/               decoy website, personalised for DOMAIN
#   compose.env         the only variables docker compose interpolates
# Values were validated by config_validate and users_load, so they are safe
# to interpolate.

# telemt's main configuration. Users live in users.toml (included at the
# end), so adding or removing a user never changes this file, never changes
# the container's config hash, and never restarts the proxy.
render_telemt_toml() {
	local front middle=false
	front=$(config_front_host)
	[[ -n $AD_TAG ]] && middle=true

	cat <<EOF
# Rendered by burrowrs from .env. Do not edit: change .env, then ./burrowrs up
[general]
# Fail on unknown keys instead of ignoring a typo.
config_strict = true
# Straight to Telegram's data centres, unless a sponsored channel (AD_TAG)
# needs Telegram's middle proxies.
use_middle_proxy = $middle
log_level = "$LOG_LEVEL"
disable_colors = true
# No per-IP observation file or endpoint: burrowrs does not record who connects.
beobachten = false
# Quota usage survives restarts (a volume; no IP addresses in it).
quota_state_path = "/var/lib/telemt/quota.json"
EOF
	if [[ -n $AD_TAG ]]; then
		printf 'ad_tag = "%s"\nmiddle_proxy_nat_ip = "%s"\n' "$AD_TAG" "$PUBLIC_IPV4"
	fi

	cat <<EOF

[general.modes]
classic = false
secure = false
tls = true

[general.links]
# Never print links (they contain secrets) to the logs.
show = []

[network]
ipv4 = true
ipv6 = false
prefer = 4
# The public address is known (PUBLIC_IPV4) or not needed: no STUN lookups.
stun_use = false

[server]
port = 3128
max_connections = $MAX_CONNECTIONS
metrics_listen = "0.0.0.0:3129"
# Published on the host's 127.0.0.1 only; Docker forwards from the bridge.
metrics_whitelist = ["127.0.0.0/8", "$EDGE_SUBNET"]

[server.api]
# Read-only, and reachable only from inside telemt's own network namespace
# (./burrowrs user list joins it to read live usage).
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]
read_only = true

[[server.listeners]]
ip = "0.0.0.0"
EOF
	if [[ $ENABLE_IPV6 == true ]]; then printf '\n[[server.listeners]]\nip = "::"\n'; fi

	cat <<EOF

[censorship]
tls_domain = "$front"
# Anything that is not a valid client for one of our secrets (other SNIs,
# plain HTTP, scanners, probes) is relayed to the website below.
unknown_sni_action = "mask"
mask = true
EOF
	if [[ $BURROWRS_MODE == stealth ]]; then
		# Our own decoy, by literal IP on the internal network.
		printf 'mask_host = "%s"\nmask_port = 8443\n' "$DECOY_IP"
	fi
	cat <<EOF
# Mirror the real site's certificate and record sizes in our handshakes.
tls_emulation = true
tls_front_dir = "/run/telemt/tlsfront"

[access]
user_max_unique_ips_mode = "active_window"

include = "/etc/telemt/users.toml"
EOF
}

# users.toml: the owner (SECRET) plus, in users mode, every user in
# users.tsv. telemt reloads it without dropping other users' connections.
render_users_toml() {
	local name
	printf '# Rendered by burrowrs. Do not edit: use ./burrowrs user\n\n[access.users]\n'
	printf '"%s" = "%s"\n' "$OWNER_USER" "$SECRET"
	[[ $ACCESS_MODE == users ]] || return 0
	for name in "${USER_NAMES[@]}"; do printf '"%s" = "%s"\n' "$name" "${USER_KEY[$name]}"; done

	printf '\n[access.user_enabled]\n'
	for name in "${USER_NAMES[@]}"; do
		if [[ ${USER_STATUS[$name]} == off ]]; then printf '"%s" = false\n' "$name"; fi
	done
	printf '\n[access.user_expirations]\n'
	for name in "${USER_NAMES[@]}"; do
		if [[ ${USER_EXPIRES[$name]} != never ]]; then printf '"%s" = "%s"\n' "$name" "${USER_EXPIRES[$name]}"; fi
	done
	printf '\n[access.user_data_quota]\n'
	for name in "${USER_NAMES[@]}"; do
		if [[ ${USER_QUOTA[$name]} != none ]]; then printf '"%s" = %s\n' "$name" "$(size_bytes "${USER_QUOTA[$name]}")"; fi
	done
	printf '\n[access.user_quota_periods]\n'
	for name in "${USER_NAMES[@]}"; do
		if [[ ${USER_PERIOD[$name]} != none ]]; then printf '"%s" = "%s"\n' "$name" "${USER_PERIOD[$name]}"; fi
	done
	printf '\n[access.user_max_unique_ips]\n'
	for name in "${USER_NAMES[@]}"; do
		if [[ ${USER_IPS[$name]} != none ]]; then printf '"%s" = %s\n' "$name" "${USER_IPS[$name]}"; fi
	done
}

render_caddyfile() {
	local globals=''
	[[ -n $ACME_EMAIL ]] && globals+=$'\temail '"$ACME_EMAIL"$'\n'
	[[ -n $ACME_CA ]] && globals+=$'\tacme_ca '"$ACME_CA"$'\n'
	[[ $TLS_MODE == internal ]] && globals+=$'\tskip_install_trust\n'
	local tls_line=''
	[[ $TLS_MODE == internal ]] && tls_line=$'\ttls internal\n'
	local redirect_port=''
	[[ $PROXY_PORT == 443 ]] || redirect_port=":$PROXY_PORT"

	cat <<EOF
# Rendered by burrowrs from .env. Do not edit: change .env, then ./burrowrs up
#
# This is the website the world sees at https://$DOMAIN. telemt owns the public
# TLS port and splices every connection that is not a valid FakeTLS hello for
# one of our secrets to this server, so browsers, scanners and censors' probes all
# get a genuine site with a genuine certificate.
{
	admin off
	persist_config off
	http_port 8080
	https_port 8443
	# Redirects are explicit below: automatic ones would leak port 8443.
	auto_https disable_redirects
${globals}	servers {
		# No HTTP/3: the UDP port is not published, and advertising h3
		# without a listener would be an odd fingerprint.
		protocols h1 h2
	}
}

$DOMAIN {
${tls_line}	root * /srv
	encode zstd gzip
	header {
		Strict-Transport-Security "max-age=31536000"
		X-Content-Type-Options "nosniff"
		Referrer-Policy "strict-origin-when-cross-origin"
		Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
	}
	# Never serve dotfiles, even if one slips into site.local/.
	file_server {
		hide .*
	}
	handle_errors 404 {
		rewrite * /404.html
		file_server {
			status 404
		}
	}
}

http://$DOMAIN {
	redir https://{host}$redirect_port{uri} permanent
}

# Container-local health endpoint for the Docker healthcheck. Not published.
http://127.0.0.1:2020 {
	bind 127.0.0.1
	respond /healthz "ok" 200
}
EOF
}

# A human-ish site name from the domain: notes.alice.dev -> Alice
site_name() {
	local domain=$1 labels name
	IFS=. read -ra labels <<<"$domain"
	if ((${#labels[@]} >= 2)); then name=${labels[-2]}; else name=${labels[0]}; fi
	name=${name//-/ }
	printf '%s\n' "${name^}"
}

site_accent() {
	local palette=("#2f6f4f" "#7a4b2a" "#3b5b8c" "#8c3b5b" "#5b3b8c" "#2a6d7a" "#7a6a2a" "#6b4f2f")
	local h
	h=$(printf '%s' "$1" | sha256_stdin)
	printf '%s\n' "${palette[$((16#${h:0:2} % ${#palette[@]}))]}"
}

site_source_dir() {
	if [[ -d $BURROWRS_ROOT/site.local ]]; then
		printf '%s\n' "$BURROWRS_ROOT/site.local"
	else
		printf '%s\n' "$BURROWRS_ROOT/site"
	fi
}

render_site() {
	local dest=$1 src name accent year file content new
	# A symlinked site directory would be merged into, not replaced.
	[[ ! -L $dest ]] || die "$dest must be a real directory, not a symlink"
	src=$(site_source_dir)
	name=$(site_name "$DOMAIN")
	accent=$(site_accent "$DOMAIN")
	year=$(date -u +%Y)

	new=$(mktemp -d "$dest.new.XXXXXX")
	cp -R "$src/." "$new/"
	# Dotfiles (.git, .DS_Store, editor swap files) would leak data and give
	# probes a fingerprint.
	find "$new" -mindepth 1 -name '.*' -prune -exec rm -rf -- {} +
	while IFS= read -r -d '' file; do
		content=$(<"$file")
		content=${content//"{{SITE_NAME}}"/"$name"}
		content=${content//"{{DOMAIN}}"/"$DOMAIN"}
		content=${content//"{{YEAR}}"/"$year"}
		content=${content//"{{ACCENT}}"/"$accent"}
		printf '%s\n' "$content" >"$file"
	done < <(find "$new" -type f \( -name '*.html' -o -name '*.css' -o -name '*.txt' -o -name '*.xml' -o -name '*.svg' -o -name '*.webmanifest' \) -print0)
	find "$new" -type d -exec chmod 0755 {} +
	find "$new" -type f -exec chmod 0644 {} +

	if [[ ! -d $dest ]]; then
		mv "$new" "$dest"
	elif [[ $(cd "$dest" && hash_paths .) == $(cd "$new" && hash_paths .) ]]; then
		rm -rf -- "$new"
	else
		# Update the contents, not the directory: a running decoy has the
		# directory itself bind-mounted. Copy first (with the modes set above,
		# so the unprivileged decoy can read everything), then prune what is
		# gone, so the site never goes empty in between.
		cp -pR "$new/." "$dest/"
		local path
		while IFS= read -r -d '' path; do
			[[ -e $new/${path#"$dest"/} ]] || rm -rf -- "$path"
		done < <(find "$dest" -mindepth 1 -depth -print0)
		rm -rf -- "$new"
	fi
	# Belt and braces: whatever happened above, leave it readable by the decoy.
	find "$dest" -type d -exec chmod 0755 {} +
	find "$dest" -type f -exec chmod 0644 {} +
}

# telemt_rust_log: the log filter for LOG_LEVEL. It must be explicit:
# telemt's own "silent" filter keeps its telemt::links target at info, and
# that target prints every new user's full link (secret included) whenever
# users.toml is reloaded. RUST_LOG overrides it and switches the target off.
telemt_rust_log() {
	local level
	case $LOG_LEVEL in
	silent) level=warn ;;
	normal) level=info ;;
	verbose) level=debug ;;
	debug) level=trace ;;
	esac
	printf '%s,telemt::links=off\n' "$level"
}

render_compose_env() {
	# IPv6 listeners follow BIND_ADDR: all interfaces only if IPv4 is on all
	# interfaces too, otherwise loopback.
	local bind6='::1'
	[[ $BIND_ADDR == 0.0.0.0 ]] && bind6='::'
	# Single quotes: compose reads these literally (no $ interpolation, no #
	# comments), so unusual characters in the install path stay intact.
	cat <<EOF
# Rendered by burrowrs. Variables for docker compose interpolation only.
BURROWRS_VERSION='$BURROWRS_VERSION'
BURROWRS_STATE_DIR='$STATE_DIR'
BIND_ADDR='$BIND_ADDR'
BIND_ADDR6='$bind6'
PROXY_PORT='$PROXY_PORT'
HTTP_PORT='$HTTP_PORT'
METRICS_PORT='$METRICS_PORT'
EDGE_SUBNET='$EDGE_SUBNET'
EDGE_SUBNET6='$EDGE_SUBNET6'
DECOY_IP='$DECOY_IP'
TELEMT_MEMORY_LIMIT='$TELEMT_MEMORY_LIMIT'
TELEMT_RUST_LOG='$(telemt_rust_log)'
DECOY_MEMORY_LIMIT='$DECOY_MEMORY_LIMIT'
TELEMT_CONFIG_HASH='$1'
DECOY_CONFIG_HASH='$2'
EOF
}

# Hash of every file under the given paths, so a config change changes a
# container label and `docker compose up` recreates exactly what changed.
hash_paths() {
	local sum=(sha256sum)
	command -v sha256sum >/dev/null 2>&1 || sum=(shasum -a 256)
	find "$@" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 -r "${sum[@]}" | sha256_stdin
}

# render_users: rewrite users.toml only. Safe while the proxy runs: the
# directory is bind-mounted, so the container sees the new file.
render_users() {
	if [[ $ACCESS_MODE == users ]]; then users_load "$USERS_FILE"; else users_reset; fi
	render_users_toml | write_if_changed "$STATE_DIR/telemt/users.toml" 644
}

render_all() {
	umask 077
	mkdir -p "$STATE_DIR" "$STATE_DIR/share" "$STATE_DIR/telemt"
	chmod 0700 "$STATE_DIR" "$STATE_DIR/share"
	# The container user (65534) reads these through a bind mount; the 0700
	# state directory keeps other host users out.
	chmod 0755 "$STATE_DIR/telemt"

	render_telemt_toml | write_if_changed "$STATE_DIR/telemt/config.toml" 644
	render_users
	if [[ $BURROWRS_MODE == stealth ]]; then
		render_caddyfile | write_if_changed "$STATE_DIR/Caddyfile" 644
		render_site "$STATE_DIR/site"
	else
		# Compose validates bind sources of inactive services too.
		printf '# unused in simple mode\n' | write_if_changed "$STATE_DIR/Caddyfile" 644
		mkdir -p "$STATE_DIR/site"
		chmod 0755 "$STATE_DIR/site"
	fi

	local telemt_hash decoy_hash
	telemt_hash=$(hash_paths "$STATE_DIR/telemt/config.toml")
	decoy_hash=$(hash_paths "$STATE_DIR/Caddyfile" "$STATE_DIR/site")
	render_compose_env "${telemt_hash:0:16}" "${decoy_hash:0:16}" | write_if_changed "$STATE_DIR/compose.env" 600
}
