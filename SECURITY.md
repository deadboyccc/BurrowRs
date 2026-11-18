# Security policy

## Reporting a vulnerability

Please **do not open a public issue**. Report privately through
[GitHub security advisories](https://github.com/deadboyccc/BurrowRs/security/advisories/new)
with steps to reproduce and the burrowrs version (`./burrowrs version`). You will get an
acknowledgement within a few days and a fix or mitigation plan as soon as possible.

Vulnerabilities in the proxy itself belong upstream at
[telemt/telemt](https://github.com/telemt/telemt), and in the web server at
[caddyserver/caddy](https://github.com/caddyserver/caddy/security). If a burrowrs release
needs to pick up their fix, tell us too.

## Scope

In scope: the `burrowrs` CLI and `lib/`, `install.sh`, the compose files,
`scripts/install-host.sh`, the systemd units, the burrowrs-tools image, and the defaults they
ship with. For example: secret leakage (including through logs), command injection through
configuration or `users.tsv`, a weaker-than-documented container sandbox, a way around a
user's limits that burrowrs's configuration opens, or a fingerprint that singles out
burrowrs deployments.

## Supported versions

Only the latest release receives fixes. Upgrade by re-running the one-command installer
(or `burrowrs deploy` from your computer); in a git clone, `git pull && ./burrowrs up`.

## Handling secrets

- Your own secret lives in `.env` (mode 0600), users' secrets in `users.tsv` (mode 0600),
  and both in links. Anyone holding a link can use it.
- If a link leaks: shared mode, run `./burrowrs rotate`; per-user mode, run
  `./burrowrs user rotate NAME`. The old link stops working immediately.
- Never paste `.env`, `users.tsv`, `burrowrs link` or `user link` output, or `state/share/`
  files into issues or chats. `burrowrs config show` redacts the secret for that reason.

See [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) for the full threat model.
