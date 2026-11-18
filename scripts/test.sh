#!/usr/bin/env bash
# Run burrowrs's automated tests.
#
#   scripts/test.sh unit          bash + Python unit tests (no network)
#   scripts/test.sh integration   Docker: compose, telemt/Caddy config parsing, install-host dry run
#   scripts/test.sh e2e           Docker + internet: real stacks, real Telegram round trips
#   scripts/test.sh all           everything above (default)
#
# Environment: BURROWRS_E2E_OFFLINE=1 skips the checks that need Telegram/internet.
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$ROOT"
suite=${1:-all}

"$ROOT/tests/deps.sh"
BATS=("$ROOT/tests/.deps/bats-core/bin/bats" --print-output-on-failure --timing)

python_tests() {
	echo "==> Python unit tests (burrowrs-tools)"
	docker build --quiet --target test -t burrowrs-tools:test tools >/dev/null
	docker run --rm --network none --memory 256m burrowrs-tools:test -q
}

case $suite in
unit)
	"${BATS[@]}" tests/unit
	python_tests
	;;
integration) "${BATS[@]}" tests/integration ;;
e2e) "${BATS[@]}" tests/e2e ;;
all)
	"${BATS[@]}" tests/unit
	python_tests
	"${BATS[@]}" tests/integration
	"${BATS[@]}" tests/e2e
	;;
*)
	echo "usage: $0 [unit|integration|e2e|all]" >&2
	exit 2
	;;
esac
