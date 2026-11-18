# Convenience targets. Everything here is a thin wrapper around scripts/ and ./burrowrs.
.DEFAULT_GOAL := help
.PHONY: help deps lint fmt test test-unit test-integration test-e2e try try-down clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

deps: ## Fetch pinned test dependencies (bats)
	@tests/deps.sh

lint: ## shellcheck, shfmt, ruff, compose validation
	@scripts/lint.sh

fmt: ## Auto-format shell and Python code
	@scripts/lint.sh --fix

test: ## Run every test suite (Docker; e2e needs internet)
	@scripts/test.sh all

test-unit: ## Fast tests, no network
	@scripts/test.sh unit

test-integration: ## Real telemt/Caddy config parsing, install script dry run
	@scripts/test.sh integration

test-e2e: ## Live stacks and real Telegram round trips
	@scripts/test.sh e2e

try: ## Throwaway local instance on 127.0.0.1
	@./burrowrs try

try-down: ## Remove the throwaway instance
	@./burrowrs try --down

clean: ## Remove test dependencies and caches
	rm -rf tests/.deps tools/.pytest_cache tools/.ruff_cache
	find . -name __pycache__ -type d -prune -exec rm -rf {} +
