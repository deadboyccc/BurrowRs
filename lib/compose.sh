# shellcheck shell=bash
# shellcheck disable=SC2153 # settings are globals loaded by config.sh
# docker compose plumbing. Always go through these helpers: they pass the
# rendered env file, the project name, profiles and overlays consistently.

MIN_COMPOSE_VERSION=2.24.4 # first release with the !override YAML tag
MIN_DOCKER_VERSION=25.0.0  # healthcheck start_interval

version_ge() { # version_ge A B: true if A >= B (dotted numeric)
	local IFS=. i a b
	read -ra a <<<"${1#v}"
	read -ra b <<<"${2#v}"
	for ((i = 0; i < 3; i++)); do
		((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
		((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
	done
	return 0
}

require_docker() {
	need docker "https://docs.docker.com/engine/install/ or ./scripts/install-host.sh"
	docker info >/dev/null 2>&1 ||
		die "cannot talk to the Docker daemon. Is it running, and are you root or in the 'docker' group?"
	local engine
	engine=$(docker version --format '{{.Server.Version}}' 2>/dev/null) || engine=0
	version_ge "${engine%%[-+]*}" "$MIN_DOCKER_VERSION" ||
		die "Docker Engine $engine is too old; burrowrs needs >= $MIN_DOCKER_VERSION"
	local v
	v=$(docker compose version --short 2>/dev/null) || die "the Docker Compose v2 plugin is missing (apt install docker-compose-plugin)"
	v=${v%%[-+]*}
	version_ge "$v" "$MIN_COMPOSE_VERSION" || die "Docker Compose $v is too old; burrowrs needs >= $MIN_COMPOSE_VERSION"
}

compose_args() {
	COMPOSE_ARGS=(
		--project-name "$BURROWRS_PROJECT"
		--project-directory "$BURROWRS_ROOT"
		--env-file "$STATE_DIR/compose.env"
		-f "$BURROWRS_ROOT/compose.yaml"
	)
	[[ $ENABLE_IPV6 == true ]] && COMPOSE_ARGS+=(-f "$BURROWRS_ROOT/compose.ipv6.yaml")
	[[ $LOGGING == off ]] && COMPOSE_ARGS+=(-f "$BURROWRS_ROOT/compose.nolog.yaml")
	[[ $BURROWRS_MODE == stealth ]] && COMPOSE_ARGS+=(--profile stealth)
	return 0
}

# The owner's ee… link secret, which probes use unless PROBE_SECRET is set.
owner_link_secret() {
	key_link_secret "$SECRET" "$(config_front_host)"
}

# compose [--progress MODE] ARGS...
compose() {
	local global=()
	if [[ ${1-} == --progress ]]; then
		global=(--progress "$2")
		shift 2
	fi
	compose_args
	docker compose "${global[@]}" "${COMPOSE_ARGS[@]}" "$@"
}

tools_image() { printf 'burrowrs-tools:%s\n' "$BURROWRS_VERSION"; }

ensure_tools_image() {
	docker image inspect "$(tools_image)" >/dev/null 2>&1 && return 0
	info "building the burrowrs-tools image (probes and QR codes)"
	docker build --quiet --target runtime -t "$(tools_image)" "$BURROWRS_ROOT/tools" >/dev/null
}

# tools_in_stack ARGS...: run burrowrs-tools inside the stack's network.
# PROBE_SECRET (default: the owner's link secret) reaches the container
# through the environment, never through argv, so it does not show up in `ps`.
# stdin is /dev/null: `compose run` attaches stdin by default, which would
# swallow the rest of a script that runs burrowrs (`ssh host 'bash -s' <script`).
tools_in_stack() {
	compose_args
	BURROWRS_SECRET=${PROBE_SECRET:-$(owner_link_secret)} docker compose --progress quiet "${COMPOSE_ARGS[@]}" \
		run --rm --no-deps -T tools "$@" </dev/null
}

# tools_in_proxy ARGS...: run burrowrs-tools inside telemt's network namespace,
# the only place its read-only API (127.0.0.1:9091) can be reached from.
tools_in_proxy() {
	compose_args
	docker compose --progress quiet "${COMPOSE_ARGS[@]}" run --rm --no-deps -T tools-api "$@" </dev/null
}

# wait_users_applied: telemt picks up users.toml by itself (it watches its
# config files); wait until its API says the access settings it runs match the
# file. Never signal it with `docker kill`: Docker then treats the container
# as manually stopped and stops restarting it after a crash.
wait_users_applied() {
	ensure_tools_image >/dev/null 2>&1 || return 1
	tools_in_proxy wait-applied --timeout "${BURROWRS_APPLY_TIMEOUT:-20}" >/dev/null
}

# tools_on_host ARGS...: run burrowrs-tools on the host network (remote checks).
# Only `qr` reads stdin; nothing else may consume the caller's.
tools_on_host() {
	local run=(docker run --rm --network host
		--read-only --cap-drop ALL --security-opt no-new-privileges:true
		--user 65534:65534 --memory 128m --pids-limit 64
		-e BURROWRS_SECRET)
	if [[ ${1:-} == qr ]]; then
		BURROWRS_SECRET=${PROBE_SECRET:-} "${run[@]}" -i "$(tools_image)" "$@"
	else
		BURROWRS_SECRET=${PROBE_SECRET:-} "${run[@]}" "$(tools_image)" "$@" </dev/null
	fi
}

stack_running() {
	[[ -f $STATE_DIR/compose.env ]] || return 1
	[[ -n $(compose ps --status running --quiet telemt 2>/dev/null) ]]
}
