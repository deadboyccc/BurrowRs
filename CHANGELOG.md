# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-11-18

First release. burrowrs is [Burrow](https://github.com/deadboyccc/Burrow) 1.2.0 rewritten on
a Rust proxy engine, [telemt](https://github.com/telemt/telemt) 3.5.17, with per-user
secrets. The disguise, the hardened containers, the installer, the CLI and the test suites
come from Burrow; the proxy, the access model and everything they touch are new. Digby the
mole came along, in a rust-orange scarf with a cog on it.

### Added

- **telemt as the proxy:** FakeTLS only (classic and `dd` modes off), unrecognised
  connections masked to the decoy website (`unknown_sni_action = "mask"`), the decoy's real
  certificate sizes mirrored in handshakes (`tls_emulation`), strict config parsing. The
  official image is pinned by digest and runs unmodified, as uid 65534 on a read-only root.
- **Two access modes** (`ACCESS_MODE`):
  - `shared` (default): one secret and one link for everyone, as in Burrow.
  - `users`: a name and a secret per user, kept in `users.tsv` (0600). `SECRET` becomes the
    operator's own `owner` user, which the health checks use.
- **`burrowrs user`:** `add`, `list`, `show`, `link`, `share`, `renew`, `set`, `disable`,
  `enable`, `rotate`, `remove`. Per-user limits: expiry (`--days`, `--until`, `--forever`),
  data quota (`--quota`, binary units), quota resets (`--period daily|weekly|monthly`, UTC)
  and simultaneous IP addresses (`--ips`). Defaults come from `USER_DEFAULT_DAYS`
  (30), `USER_DEFAULT_QUOTA`, `USER_DEFAULT_PERIOD` and `USER_DEFAULT_IPS` (3).
- **Changes without restarts:** users live in `users.toml`, included by telemt's main
  config and picked up by telemt's own file watcher, so adding, changing, disabling or removing a user (and
  `rotate`) disconnects no one else. Disabling a user closes their open connections. Each change waits until telemt's
  API confirms it runs the new user list.
- **Live usage:** `user list` and `user show` read connections, connected IPs, traffic and
  quota use from telemt's control API, which is read-only and reachable only from inside
  the proxy's network namespace (the on-demand `tools-api` container).
- **Quota usage survives restarts** in the `telemt-data` volume.
- **Sponsored channel:** `AD_TAG` (from @MTProxybot) switches telemt to Telegram's middle
  proxies with the server's public address.
- `init --access`, `deploy --access`, `try --users`, and the installer's `BURROWRS_ACCESS`.
- New settings: `ACCESS_MODE`, `AD_TAG`, `USER_DEFAULT_*`, `MAX_CONNECTIONS`,
  `TELEMT_MEMORY_LIMIT`, `LOG_LEVEL`.
- `doctor` asks the running proxy whether it is ready and whether Telegram answers through
  it.

### Changed (compared with Burrow)

- **The secret is a plain 16-byte key.** Links still carry the FakeTLS form (`ee` + key +
  hex of the domain), so changing the domain keeps every secret; `config set` warns that
  links change instead.
- **`rotate` reloads instead of restarting.** The old link stops working at once.
- **Logging:** `LOG_LEVEL` (default `silent`, telemt's warnings and errors) replaces
  `DEBUG`. Successful connections are never logged; refused ones are, with the user name
  and sometimes the client's IP. Links never reach the logs: the `telemt::links` log target
  is switched off, and telemt's per-IP observation feature (`beobachten`) is disabled.
- **Default network** `10.204.47.0/28` (decoy `10.204.47.10`), so burrowrs can run next to
  Burrow.
- `status` reads telemt's metrics: connections and users connected now, traffic, accepted
  and invalid connections, failed Telegram dials, uptime.

### Removed (compared with Burrow)

- mtg-only features: IP block and allow lists (`BLOCKLIST_*`, `ALLOWLIST_URLS`,
  `LOCAL_BLOCKLIST`, `LOCAL_ALLOWLIST`), traffic-shape mimicry (`DOPPELGANGER_URLS`),
  SOCKS5 upstreams (`UPSTREAM_PROXIES`), `DNS_RESOLVER`, `PREFER_IP`, `TIME_SKEW` (telemt
  allows ±2 minutes), `ANTI_REPLAY_SIZE`, `IDLE_TIMEOUT`, the Go memory limit, and
  `mtg doctor`.
- `CONCURRENCY` and `MTG_MEMORY_LIMIT` are now `MAX_CONNECTIONS` and `TELEMT_MEMORY_LIMIT`.

### Verified

- On 2026-11-18 a local `./burrowrs try` passed all 8 smoke checks: FakeTLS handshake, a
  Telegram `req_pq_multi` → `resPQ` round trip, replay refused, a 10-minute clock skew
  refused, a wrong secret gets the decoy, the real website over TLS, plain HTTP answered,
  metrics on loopback only.
- In per-user mode, added users worked at once, and a disabled user, an expired user and a
  1 KiB quota were enforced live, without restarting the proxy container.

[Unreleased]: https://github.com/deadboyccc/BurrowRs/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/deadboyccc/BurrowRs/releases/tag/v1.0.0
