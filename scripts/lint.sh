#!/usr/bin/env bash
# Static checks: shellcheck, shfmt, ruff and compose validation.
# Tools run from pinned container images, so results match CI exactly.
#   scripts/lint.sh          check
#   scripts/lint.sh --fix    rewrite formatting in place
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d
SHFMT_IMAGE=mvdan/shfmt:v3.14.1@sha256:8c06884a35683d8763fba6c0d9484d11a61a96da65f8d497d6f625825a6043f2

fix=0
[[ ${1-} == --fix ]] && fix=1
cd "$ROOT"

run() { docker run --rm --network none --user "$(id -u):$(id -g)" -v "$ROOT:/src:ro" -w /src "$@"; }
run_rw() { docker run --rm --network none --user "$(id -u):$(id -g)" -v "$ROOT:/src" -w /src "$@"; }

mapfile -t shell_files < <(
	printf '%s\n' burrowrs install.sh
	find lib scripts tests -type f \( -name '*.sh' -o -name '*.bash' \) -not -path 'tests/.deps/*' | sort
)
mapfile -t bats_files < <(find tests -type f -name '*.bats' -not -path 'tests/.deps/*' | sort)

echo "==> shellcheck"
run "$SHELLCHECK_IMAGE" --external-sources "${shell_files[@]}"
run "$SHELLCHECK_IMAGE" --external-sources --shell=bats "${bats_files[@]}"

echo "==> shfmt"
if ((fix)); then
	run_rw "$SHFMT_IMAGE" -w "${shell_files[@]}"
	run_rw "$SHFMT_IMAGE" -w -ln bats "${bats_files[@]}"
else
	run "$SHFMT_IMAGE" -d "${shell_files[@]}"
	run "$SHFMT_IMAGE" -d -ln bats "${bats_files[@]}"
fi

echo "==> ruff"
docker build --quiet --target test -t burrowrs-tools:test tools >/dev/null
ruff=(docker run --rm --network none --user "$(id -u):$(id -g)" -e RUFF_CACHE_DIR=/tmp/ruff)
ruff+=(-v "$ROOT/tools:/src" -w /src --entrypoint ruff burrowrs-tools:test)
if ((fix)); then
	"${ruff[@]}" check --fix .
	"${ruff[@]}" format .
else
	"${ruff[@]}" check .
	"${ruff[@]}" format --check .
fi

echo "==> compose files"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat >"$tmp/compose.env" <<EOF
BURROWRS_VERSION=lint
BURROWRS_STATE_DIR=$tmp
BIND_ADDR=0.0.0.0
BIND_ADDR6=::
PROXY_PORT=443
HTTP_PORT=80
METRICS_PORT=3129
EDGE_SUBNET=10.204.47.0/28
EDGE_SUBNET6=fd42:7761:7272:656e::/64
DECOY_IP=10.204.47.10
TELEMT_MEMORY_LIMIT=512m
TELEMT_RUST_LOG=warn,telemt::links=off
DECOY_MEMORY_LIMIT=256m
TELEMT_CONFIG_HASH=lint
DECOY_CONFIG_HASH=lint
EOF
for overlays in "" "-f compose.ipv6.yaml" "-f compose.nolog.yaml"; do
	# shellcheck disable=SC2086 # word splitting of $overlays is intended
	docker compose --env-file "$tmp/compose.env" -f compose.yaml $overlays --profile stealth config --quiet
done

echo "lint: all clean"
