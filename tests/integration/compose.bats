#!/usr/bin/env bats
# The effective Docker Compose model, for every mode and overlay.

setup() {
	load ../helpers
	require_docker
	command -v jq >/dev/null 2>&1 || skip "jq is not installed"
	isolate
	burrowrs init --domain notes.example.org --ipv4 203.0.113.7 --quiet
}

# model [config set args...]: render and print the compose model as JSON.
model() {
	(($#)) && burrowrs config set "$@" >/dev/null
	burrowrs render >/dev/null
	(
		# shellcheck source=/dev/null
		for lib in common validate secret links config users render compose; do source "$BURROWRS_ROOT/lib/$lib.sh"; done
		ENV_FILE=$BURROWRS_ENV_FILE STATE_DIR=$BURROWRS_STATE_DIR
		config_load "$ENV_FILE"
		compose config --format json
	)
}

@test "every container is locked down" {
	json=$(model)
	for svc in telemt decoy; do
		jq -e --arg s "$svc" '.services[$s] |
			.read_only == true and .cap_drop == ["ALL"] and
			(.security_opt | index("no-new-privileges:true")) != null and
			.user == "65534:65534" and .mem_limit != null and .pids_limit > 0 and
			.restart == "unless-stopped"' <<<"$json"
	done
	for svc in decoy-init telemt-init; do
		jq -e --arg s "$svc" '.services[$s] | .cap_add == ["CHOWN"] and .cap_drop == ["ALL"] and .network_mode == "none"' <<<"$json"
	done
	# The on-demand tools containers are locked down too, and the API reader
	# shares telemt's network namespace instead of joining any network.
	json=$(
		# shellcheck source=/dev/null
		for lib in common validate secret links config users render compose; do source "$BURROWRS_ROOT/lib/$lib.sh"; done
		ENV_FILE=$BURROWRS_ENV_FILE STATE_DIR=$BURROWRS_STATE_DIR
		config_load "$ENV_FILE"
		compose_args
		docker compose "${COMPOSE_ARGS[@]}" --profile tools config --format json
	)
	for svc in tools tools-api; do
		jq -e --arg s "$svc" '.services[$s] | .read_only == true and .cap_drop == ["ALL"] and .user == "65534:65534"' <<<"$json"
	done
	jq -e '.services["tools-api"].network_mode == "service:telemt"' <<<"$json"
}

@test "users.toml is a live, read-only bind mount; quota state is a volume" {
	json=$(model)
	jq -e '[.services.telemt.volumes[] | select(.target == "/etc/telemt" and .type == "bind" and .read_only == true)] | length == 1' <<<"$json"
	jq -e '[.services.telemt.volumes[] | select(.target == "/var/lib/telemt" and .type == "volume" and .source == "telemt-data")] | length == 1' <<<"$json"
	grep -qx 'include = "/etc/telemt/users.toml"' "$BURROWRS_STATE_DIR/telemt/config.toml"
}

@test "only the proxy, HTTP and loopback metrics are published" {
	json=$(model)
	run jq -c '[.services[] | select(.ports) | .ports[] | {target, published, host_ip}] | sort_by(.target)' <<<"$json"
	assert_output '[{"target":3128,"published":"443","host_ip":"0.0.0.0"},{"target":3129,"published":"3129","host_ip":"127.0.0.1"},{"target":8080,"published":"80","host_ip":"0.0.0.0"}]'
}

@test "the decoy gets the fixed address telemt masks to" {
	json=$(model)
	jq -e '.services.decoy.networks.edge.ipv4_address == "10.204.47.10"' <<<"$json"
	grep -qx 'mask_host = "10.204.47.10"' "$BURROWRS_STATE_DIR/telemt/config.toml"
}

@test "simple mode runs telemt alone" {
	burrowrs init --cover-domain www.example.com --ipv4 203.0.113.7 --quiet --force
	run jq -r '.services | keys | join(",")' <<<"$(model)"
	assert_output telemt,telemt-init
}

@test "IPv6 overlay: dual-stack network and an IPv6 listener" {
	json=$(model ENABLE_IPV6 true)
	jq -e '.networks.edge.enable_ipv6 == true and (.networks.edge.ipam.config | length) == 2' <<<"$json"
	jq -e '[.services.telemt.ports[] | select(.host_ip == "::")] | length == 1' <<<"$json"
	grep -qx 'ip = "::"' "$BURROWRS_STATE_DIR/telemt/config.toml"
}

@test "IPv6 overlay never exposes more than BIND_ADDR does" {
	json=$(model ENABLE_IPV6 true BIND_ADDR 127.0.0.1)
	run jq -r '[.services[].ports[]? | select(.name == "proxy6" or .name == "http6") | .host_ip] | unique | join(",")' <<<"$json"
	assert_output "::1"
}

@test "LOGGING=off drops all container logs" {
	run jq -r '.services.telemt.logging.driver + "," + .services.decoy.logging.driver' <<<"$(model LOGGING off)"
	assert_output none,none
}

@test "config changes move the right container label; user changes move none" {
	burrowrs config set ACCESS_MODE users >/dev/null
	a=$(model)
	burrowrs user add alice >/dev/null
	b=$(model)
	c=$(model MAX_CONNECTIONS 1024)
	label() { jq -r --arg s "$1" '.services[$s].labels["io.burrowrs.config-hash"]' <<<"$2"; }
	[[ $(label telemt "$a") == "$(label telemt "$b")" ]]
	[[ $(label telemt "$b") != "$(label telemt "$c")" ]]
	[[ $(label decoy "$a") == "$(label decoy "$c")" ]]
}

@test "third-party images are pinned by digest" {
	run grep -E '^\s+image:' "$BURROWRS_ROOT/compose.yaml"
	for line in "${lines[@]}"; do
		[[ $line == *burrowrs-tools* || $line == *@sha256:* ]] || {
			echo "not pinned: $line"
			return 1
		}
	done
	grep -q '^ARG PYTHON_IMAGE=python:.*@sha256:' "$BURROWRS_ROOT/tools/Dockerfile"
}
