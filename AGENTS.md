# AGENTS.md

Guidance for AI coding agents (and humans) working on **burrowrs**: a self-hosted Telegram
proxy service (telemt in FakeTLS mode behind a real decoy website) in hardened Docker,
driven by a Bash CLI, with a Python probe tool. Two access modes: one shared secret, or a
name and secret per user with expiry, quotas and device limits. It is Burrow rewritten on
the telemt engine. Mascot: Digby the mole (`assets/digby.svg`), with a rust-orange scarf.

Read [CONTRIBUTING.md](CONTRIBUTING.md) for the contribution rules, and
[docs/DESIGN.md](docs/DESIGN.md) and [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) for the
architecture, test suites and project layout. This file adds how to work here, and the traps
that have already bitten.

## Priorities

Security first, then reliability, then performance. A change that makes the proxy easier to
detect, or less private, is a regression, however fast it is. Simple beats clever: no new
dependencies, services or settings without a clear need.

## How to work

- **Decide, don't ask.** Make the judgement call, keep it reasonable, and say what you
  chose and why in the commit message and the changelog.
- **Verify before you claim.** Every statement in docs, changelogs and commit messages must
  be checked against the code, a test, upstream source, or a live run. Measure performance
  claims; don't estimate them. If you can't verify it, don't write it.
- **Finish the job.** Code, tests, docs, changelog, and a green CI. A feature that isn't in
  the docs doesn't exist; a doc that's no longer true is a bug.
- **Small, reviewable commits.** Imperative mood; the body explains *why*.

## Commands

```bash
make lint            # shellcheck, shfmt, ruff, compose validation (scripts/lint.sh)
make fmt             # auto-format shell (tabs, shfmt) and Python (ruff)
make test-unit       # bats + pytest, no network, about a minute
make test            # everything: needs Docker and internet (scripts/test.sh all)
scripts/test.sh unit|integration|e2e
./burrowrs try       # throwaway local instance on 127.0.0.1 (--users: per-user mode); ./burrowrs try --down
```

GitHub Actions runs lint, gitleaks, unit, integration and e2e on every push to `main` and
every pull request (and weekly). End-to-end tests need real Docker and reach Telegram, so CI
is the authoritative run. Never call a release done while CI is red.

## Rules that keep it safe

- **Secrets never leave their place.** Never commit a real proxy secret, token or password,
  and never put one in argv, logs, test fixtures or memory files. Probe secrets reach
  containers through the environment (`BURROWRS_SECRET`), never the command line; user
  secrets reach telemt only through `state/telemt/users.toml`. Test fixtures use fake
  secrets marked `# gitleaks:allow`.
- **`.env` and `users.tsv` are data, not code.** They are parsed strictly and never
  `source`d. Every value that reaches a config file is validated in `lib/validate.sh` or
  `users_check_row`.
- **Pin everything:** images by digest, Python packages by hash, actions by commit SHA.
- **Containers stay hardened:** uid 65534, read-only root, `cap_drop: ALL`,
  `no-new-privileges`, memory and pid limits. Tests assert this; keep them passing.
- **Tests bind 127.0.0.1 only**, on random ports and random `/28` subnets, and clean up
  after themselves. Never start a public proxy from a test or a dev machine.
- **Privacy claims are exact.** Successful connections are never logged; at the default
  level telemt logs refused connections with the user name and sometimes the client IP.
  Logs aside, no state file holds an IP address. If you change logging or what telemt
  stores, change `docs/THREAT-MODEL.md` in the same commit.

## Traps already found (don't reintroduce them)

- **telemt logs links, with secrets, on every reload.** When `users.toml` changes it logs
  each new user's full `tg://` link under the `telemt::links` target, whatever
  `general.links.show` says (that only covers start-up). `RUST_LOG` (rendered as
  `TELEMT_RUST_LOG`, and it overrides `log_level`) must always end in
  `,telemt::links=off`. Keep `general.links.show = []` too.
- **telemt's "silent" is not silent.** It means `warn`, and warnings name refused users and
  some client IPs. Say so in the docs; don't promise more.
- **`beobachten` must stay `false`.** Its default is on: per-IP observation buckets written
  to a file every 15 seconds and served on the metrics port.
- **Users live in `users.toml`, never in `config.toml`.** `config.toml` ends with
  `include = "/etc/telemt/users.toml"` (expanded as text before parsing, so it must stay the
  last line, after `[access]`). A user change rewrites only `users.toml`; telemt's own file
  watcher (inotify plus a 3-second poll) loads it, and burrowrs waits until the control API
  reports the `access` section as `published_match`. Anything in `config.toml` changes the
  container's config hash and restarts the proxy, dropping everyone.
- **Never signal telemt with `docker kill`** (not even `-s HUP`). Docker then treats the
  container as manually stopped, and its restart policy no longer brings it back after a
  crash. The e2e crash test caught this.
- **Bind-mount the directory, not the file.** `users.toml` is replaced atomically (a new
  inode); a single-file bind mount would keep showing the old one. `state/telemt/` is
  mounted read-only as a whole.
- **The control API stays private and read-only.** It listens on 127.0.0.1 inside telemt's
  network namespace, `read_only = true`; only the on-demand `tools-api` service
  (`network_mode: service:telemt`) reaches it. Never publish it or bind it to the edge
  network.
- **`config_strict = true`:** telemt refuses unknown keys. Check every new key against
  telemt's `docs/Config_params/CONFIG_PARAMS.en.md` for the pinned version, and let the
  integration test parse it with the real binary.
- **The decoy has a static IP.** `mask_host` is rendered as the literal `DECOY_IP`, and
  TLS emulation fetches the decoy's certificate from the same address, so neither ever
  depends on name resolution inside the proxy container. Keep it a literal IP.
- **`owner` is reserved.** It is `SECRET` in both access modes, and every health check
  (`up`, `status`, `smoke`, the watchdog) uses its link.
- **State paths are made absolute.** `compose.env` holds bind sources, so the same state
  directory given once relative and once absolute made `up` recreate every container.
- **Network namespaces don't inherit TCP settings.** Every proxied connection ends inside
  the telemt container, so host sysctls (`deploy/sysctl/99-burrowrs.conf`) don't reach it.
  The per-namespace keys are repeated in `compose.yaml`; a unit test keeps the two in step.
- **`default_qdisc` only applies to interfaces brought up later.** The installer switches
  the live uplink to `fq` itself.
- **Never define `fail` (or other bats-support/bats-assert names) in `lib/`.** Unit tests
  source the libraries; a `fail` there silently turned ~80 tests' assertions into no-ops.
  The status printers are `ok`, `warn`, `cross`.
- **Probe containers must not read stdin** (except `qr`): `status` once swallowed the
  rest of an `ssh host 'bash -s' <script`. `tools_in_stack`, `tools_in_proxy` and
  `tools_on_host` handle it.
- **`--help` never runs a command,** and bad flags fail before anything changes.
- **bats:** prefer one final assertion over `cmd || fail` inside loops, and check that a new
  test can fail (break the code once, watch it go red).

## Releasing

1. Bump the version in all four places together: `BURROWRS_VERSION` (`lib/common.sh`),
   `tools/burrowrs_tools/__init__.py`, `tools/pyproject.toml`, and `BURROWRS_INSTALLER_REF`
   (`install.sh`). A unit test checks the installer pin.
2. Move `[Unreleased]` in `CHANGELOG.md` (Keep a Changelog) under `## [X.Y.Z] - date`, and
   add the compare link at the bottom.
3. Update the counts and claims that changed: the test totals in `README.md`,
   `website/index.html` and `docs/DEVELOPMENT.md`; behaviour in `docs/`.
4. Push to `main`, wait for green CI, then push tag `vX.Y.Z`. The release workflow checks
   the version and the changelog and publishes the archive with `SHA256SUMS`.

## Docs style

- **Split by reader.** `README.md` is a compact front page; details live in `docs/`
  (DEPLOY, USAGE, CONFIGURATION, OPERATIONS, THREAT-MODEL, DESIGN, DEVELOPMENT). The website
  (`website/index.html`) mirrors the README's claims.
- **Plain, short and scannable:** tables for options and commands, numbered steps for
  procedures, and **bold** for the one thing a reader must not miss. Give exact commands,
  the reason behind each recommendation, and measured numbers rather than adjectives.
- Commit messages: the maintainer's identity (deadboyccc), with a `Co-Authored-By` line for
  the AI agent as the only trailer.
