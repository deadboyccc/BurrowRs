# Development

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the house rules, and [AGENTS.md](../AGENTS.md)
for the traps already found.

## Running the tests

```bash
make test              # everything (needs Docker; e2e also needs internet)
make test-unit         # bash (bats) and Python (pytest), no network
make test-integration  # real telemt and Caddy parse every config; install dry runs in Debian
make test-e2e          # live stacks on 127.0.0.1 with real Telegram round trips
make lint              # shellcheck, shfmt, ruff, compose validation
```

Set `BURROWRS_E2E_OFFLINE=1` to skip only the checks that need Telegram.

## The test suites (389 tests)

| Suite | What it proves |
|---|---|
| **unit/** (bats, 169) | Validators reject injection; `.env` and `users.tsv` parsing never executes code and refuses malformed lines; secrets, links, user limits, rendering and file permissions are right; `--help` and bad arguments never run commands; privacy defaults hold. |
| **tools/tests/** (pytest, 146) | The FakeTLS/MTProto client against an independent server implementation of the same protocol; a full Telegram round trip through a fake relay; probe verdicts and time limits against hostile servers; QR output; parsing of telemt's API answers. |
| **integration/** (37) | The real telemt binary accepts every config variant (and rejects a broken one); Caddy validates every Caddyfile; the compose model is hardened; the host and install scripts plan the right steps in a Debian container. |
| **e2e/** (37) | Full stacks with real Telegram round trips; hardening as actually run; decoy pages, 404s and redirects; rotation without restarts; crash and hang recovery; per-user mode end to end (live add, disable, expiry, quota that survives a restart, rotate, remove, switching modes); simple mode; `try`; `deploy` end to end; the installer for real, including an upgrade that keeps the secret. |

CI runs every suite and a gitleaks secret scan on each push and pull request, and again
weekly to catch upstream changes (Telegram, images, certificate authorities).

## Releasing

1. Bump `BURROWRS_VERSION` (`lib/common.sh`), `tools/burrowrs_tools/__init__.py`,
   `tools/pyproject.toml` and `BURROWRS_INSTALLER_REF` (`install.sh`) together. A unit test
   checks that the installer pin matches.
2. Move the `[Unreleased]` notes in `CHANGELOG.md` under the new version.
3. Push a `vX.Y.Z` tag. The release workflow checks the version and the changelog, runs the
   unit tests, and publishes the source archive with checksums.

## Project layout

```
burrowrs                the CLI (Bash)
install.sh              one-command server installer (curl | sudo bash)
lib/                    CLI modules: config, validation, users, rendering, secrets, links, compose
compose.yaml            hardened stack: telemt-init, telemt, decoy-init, decoy (Caddy), tools, tools-api
compose.ipv6.yaml       overlay for ENABLE_IPV6=true
compose.nolog.yaml      overlay for LOGGING=off
site/                   decoy website template (copy to site.local/ to customise)
tools/                  burrowrs-tools image: FakeTLS/MTProto probe client, QR codes, API usage reader (Python)
scripts/                install-host.sh (server preparation), lint.sh, test.sh
deploy/                 systemd watchdog units, kernel tuning
tests/                  unit/, integration/, e2e/ (bats)
docs/                   the documentation
website/                GitHub Pages site
assets/digby.svg        the mascot
```

Generated at runtime and git-ignored: `.env`, `users.tsv`, `state/`, `.try/`, `site.local/`,
`.burrowrs-manifest`.
