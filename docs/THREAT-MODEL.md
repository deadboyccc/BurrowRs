# Threat model

## What burrowrs protects against

| Threat | Defence |
|---|---|
| Deep packet inspection recognising Telegram | FakeTLS: the bytes on the wire look like TLS 1.3 to your own domain. telemt also mirrors the decoy site's real certificate and record sizes in its handshakes (`tls_emulation`). |
| Active probing ("are you a proxy?") | Anything without a valid secret (other domain names in SNI, plain HTTP, garbage, wrong secrets) is passed to a real website with a real certificate. |
| Replay of a captured handshake | telemt's anti-replay cache (65,536 entries, 120-second window), plus a ±2-minute timestamp window. |
| DNS/IP/SNI mismatch checks | Stealth mode: your domain resolves to your server, which serves its own certificate. |
| A leaked link | Per-user mode: `user rotate NAME` or `user disable NAME` affects only that user. Shared mode: `rotate` replaces the one secret. |
| Link sharing beyond what you sold | Per-user device limits (`--ips`): only N source addresses may be connected at once. |
| A compromised container | Non-root (uid 65534), read-only filesystems, zero Linux capabilities, `no-new-privileges`, memory and process limits. |
| Secret leakage | `.env`, `users.tsv` and share files are private (0600); secrets reach containers through the environment or a 0700 state directory, never command lines; telemt never prints links (`general.links.show = []` at start-up, and the `telemt::links` log target switched off for reloads); `config show` redacts; QR codes are made offline. |
| Abuse of the control API | telemt's API is read-only and listens on 127.0.0.1 inside the proxy's own network namespace; only the on-demand `tools-api` container joins it. |
| Supply-chain tampering | Images pinned by digest, Python packages by hash, test tools by commit, CI actions by SHA. Dependabot updates images, Python packages and actions; the test and lint tools are bumped by hand. |
| Configuration injection | `.env` and `users.tsv` are read as data (never executed); unknown `.env` keys are ignored, malformed user lines are refused; every value is validated before it reaches a config file; telemt itself rejects unknown keys (`config_strict`). |

## What it does not do

- **It is not an anonymity tool.** Your hosting provider can see the server talking to
  Telegram, and Telegram sees the server's IP instead of your users'. Messages are
  protected by Telegram's own encryption either way.
- **It can't hide that the server exists.** A determined censor can still block its IP.
  Have a plan B: another server, `LINK_HOST`.
- **Anyone with a link can use it.** Share links carefully. In shared mode one leak
  means `rotate` for everyone; in per-user mode, only the leaked user's link changes.
- **A refused user is not a stranger.** Users who are disabled, expired or over quota hold
  a valid secret, so the proxy completes the disguised handshake with them before it
  disconnects them (measured with the probe for a disabled user). That reveals nothing to
  anyone without a secret; those still only ever see the website.

## Privacy

**Successful connections are never logged.** What the logs can contain:

- With the default `LOG_LEVEL=silent`, telemt logs warnings and errors only. Valid users'
  successful connections are not logged at that level. **Refused connections are:** each
  warning names the user and, for some, the client's IP address and port, for example
  `Disabled user rejected user=bob`, `Connection closed with error peer=IP:port
  error=User bob disabled`, `User carol expired`, `User dave exceeded data quota`, and,
  for anyone, `TLS replay attack detected peer=IP:port`.
- Higher levels (`normal`, `verbose`, `debug`) log more; use them only while
  troubleshooting.
- Links never reach the logs, at any level. telemt would otherwise log each new user's full
  `tg://` link, secret included, whenever the user list is reloaded; burrowrs switches that
  log target off (`telemt::links=off` in `RUST_LOG`).
- `LOGGING=off` keeps no container logs at all, including the warnings above.
- telemt's per-IP observation feature (`beobachten`), which would write recent client
  addresses to a file and a metrics endpoint, is switched off.
- The decoy website keeps no access logs.
- The host firewall logs only packets it blocks; proxy traffic is never logged.

**What burrowrs does keep:**

| What | Where | Contains |
|---|---|---|
| Your settings and secret | `.env` (0600) | the owner `SECRET` |
| Users | `users.tsv` (0600) | name, secret, expiry, quota, reset period, device limit, enabled, creation date |
| Quota usage | `quota.json` in the `telemt-data` volume | per user: bytes used, last reset time, reset period and calendar cursor. **No IP addresses.** |
| Generated config | `state/` (0700) | the above, rendered for telemt and Caddy |
| Share files | `state/share/` (0600) | links and QR codes |

**Held in memory only, while the proxy runs:** telemt tracks each user's currently
connected source IPs to enforce device limits, and counts connections and traffic per user.
Its read-only API can list those IPs; `user list` and `user show` print only the counts.
Prometheus metrics (127.0.0.1 only) carry per-user counts, never addresses. All of it is
gone when the proxy restarts, except the quota counters above.

Still worth knowing: anyone with root on the server can see live connections.

## Host hardening

`scripts/install-host.sh`, run by the installer, sets up:

- **Firewall (ufw):** inbound traffic is denied except rate-limited SSH, 80 and 443. SSH
  stays reachable on your SSH port and on every port sshd listens on. If no SSH port can be
  determined, the firewall is left off rather than risk locking you out.
- **Automatic security updates**, including Docker's own packages.
- **NTP time synchronisation.**
- **Docker** from Docker's signed repository, with `live-restore`.
- **The watchdog**, as a hardened systemd unit.

Docker publishes only the proxy and HTTP ports. Metrics stay on 127.0.0.1, and the control
API is not published at all.

Found a vulnerability? See the [security policy](../SECURITY.md).
