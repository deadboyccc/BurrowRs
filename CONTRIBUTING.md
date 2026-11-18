# Contributing

Thanks for helping Digby dig. 🐾

1. `make lint test-unit` must pass. Run `make test` (Docker + internet) for anything that
   touches the stack, the CLI or the probe client.
2. Shell code: Bash ≥ 4.4, `set -Eeuo pipefail`, shellcheck-clean, formatted with `make fmt`.
   Validate every value that reaches a config file in `lib/validate.sh` (or, for users,
   `users_check_row` in `lib/users.sh`).
3. New settings: add them to `CONFIG_KEYS`, `config_set_defaults`, `config_validate`,
   `config_write`, `.env.example` and `docs/CONFIGURATION.md`, with tests. New telemt keys
   must exist in the pinned telemt version: its config is strict and refuses unknown keys.
4. Pin everything: images by digest, Python packages by hash (`tools/requirements*.txt`
   come from `pip-compile --generate-hashes`), actions by commit SHA.
5. Add an entry under `[Unreleased]` in `CHANGELOG.md`.
6. Commit messages: imperative mood, explain *why*.
