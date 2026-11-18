# Operations

Commands run on the server in `/opt/burrowrs`.

## Day-to-day tasks

| Task | How |
|---|---|
| Health, connections, traffic | `./burrowrs status` |
| Users: state, expiry, quota used, live usage | `./burrowrs user list` (per-user mode) |
| Full self-test | `./burrowrs smoke` |
| Logs | `./burrowrs logs -f telemt` / `./burrowrs logs decoy` (rotated: 3 × 10 MB per container) |
| Prometheus metrics | scrape `http://127.0.0.1:3129/metrics` on the server (`telemt_*`, including per-user `telemt_user_*`) |
| Change a setting | `./burrowrs config set KEY VALUE && ./burrowrs up` |
| Revoke access | shared mode: `./burrowrs rotate`; per-user mode: `./burrowrs user disable NAME` or `user rotate NAME` |
| Upgrade burrowrs | re-run the install command (or `burrowrs deploy`); in a git clone, `git pull && ./burrowrs up` |
| Update container images only | `./burrowrs update` |
| Back up | `.env` and `users.tsv` (the secrets); optionally the `burrowrs_decoy-data` volume (certificates) and `burrowrs_telemt-data` (quota usage) |
| Move to a new server | install there, copy `.env` and `users.tsv` over, `./burrowrs config set PUBLIC_IPV4 <new IP> && ./burrowrs up`, point DNS at it; domain-based links keep working |
| Remove | `./burrowrs uninstall --purge` |

## What `status` shows

| Line | Meaning |
|---|---|
| connected now | open client connections, and how many users have one |
| telegram traffic | bytes relayed for all users since the proxy started |
| connections accepted | every connection since start; *not valid clients* counts probes, scanners, browsers and wrong secrets |
| failed Telegram dials | connections to Telegram that didn't succeed (should stay near 0) |
| up for | proxy uptime |

## Reliability

- **Checked start:** `up` only reports success once a real handshake succeeds. In stealth
  mode it then checks the website too, and says why if the certificate isn't ready yet.
- **Crash recovery:** every container restarts automatically.
- **Hang recovery:** a watchdog probes the proxy every 5 minutes. After three failed
  handshakes it recreates the proxy. It never restarts the proxy because of a problem in
  the probe itself.
- **No restarts for user changes:** adding, changing, disabling or removing a user only
  rewrites `state/telemt/users.toml`, and telemt reloads it by itself (burrowrs waits for the
  confirmation). Other users stay connected.
- **Docker upgrades:** `live-restore` keeps the proxy serving while Docker restarts.
- **Precise changes:** `up` recreates only the containers whose configuration changed.
- **Certificates** renew automatically and survive `down` (only `down --volumes` deletes
  them), so restarts never hit Let's Encrypt's rate limits.
- **Quota usage** survives restarts and upgrades (the `telemt-data` volume).
- **Time:** NTP is set up at install, and `doctor` checks it. telemt refuses handshakes
  whose clock is more than 2 minutes off.

## Performance and capacity

The network is almost always the limit, not the CPU. On an idle local trial, telemt used
5.7 MiB of memory and the decoy website 12.9 MiB. Throughput under load has not been
measured for burrowrs yet; watch `./burrowrs status`, `docker stats` and your bandwidth as
users grow.

What makes it fast:
- **Kernel:** BBR congestion control with `fq`, larger queues and buffers, MTU probing,
  no slow restart after idle, and a cap on unsent data per socket. These matter most on the
  lossy, long-distance links censored users tend to have. The installer switches the network
  card to `fq` at once, not only after the next reboot.
- **Network path:** no userspace proxy. Ports are forwarded by the kernel, and client
  addresses are preserved (device limits depend on that).
- **Inside the proxy container:** every connection ends in the container's own network
  namespace, which doesn't inherit the host's TCP settings. So the container repeats the
  TCP tuning itself, and adds a larger accept queue, a wide port range for connections to
  Telegram, and 65,536 file descriptors.
- **Memory:** telemt is written in Rust, with no garbage collector. On servers with 2 GiB
  of RAM or less and no swap, the installer adds a 2 GiB swap file (swappiness 10: the
  proxy stays in RAM, and swap only absorbs real pressure).
- **Connection tracking:** Docker's NAT tracks every connection, so the installer sizes
  the hash table for it (65,536 buckets for 262,144 entries). The kernel default on a 1 GB
  server is 8,192 buckets.
- **Tuning knobs:** `MAX_CONNECTIONS`, `TELEMT_MEMORY_LIMIT`, `DECOY_MEMORY_LIMIT`.

### Capacity (measured)

Measured on 2026-11-18 on a 1 vCPU (Xeon E-2176G), 961 MiB RAM server running burrowrs
1.0.0, with load sent from another server over the internet. Every connection did a real
Telegram exchange (FakeTLS → obfuscated2 → `req_pq_multi` → `resPQ`).

| Test | Result | telemt RAM | telemt CPU (peak, of one core) |
|---|---|---|---|
| 1,000 round trips, 100 at a time | 1,000/1,000 ok, 313/s, median 204 ms | 15 MiB | 41% |
| 1,000 connections held 45 s, active every 15 s | 1,000/1,000 stayed up | 79 MiB | 13% |
| 2,000 held | 2,000/2,000 stayed up | 150 MiB | 18% |
| 3,000 held | 2,970/3,000 stayed up (the test client fell behind; telemt logged no failures) | 219 MiB | 17% |

- **Memory is the limit, not CPU,** for chat-type traffic: about 70-75 KiB per connection,
  buffers included. On this server that is roughly 6,000-7,000 connections before the
  host runs short of RAM.
- **Users, not connections:** a Telegram app keeps about 2-4 connections while active, and
  more while it moves media. So a 1 GB server serves on the order of 1,500-3,000 users
  online at once for chat. Media-heavy use is bounded by CPU and bandwidth instead; that
  was not measured (it needs real Telegram accounts).
- For the same 200-round-trip test, Burrow (mtg) used 58 MiB under load and 50 MiB idle;
  burrowrs used 7 MiB and 4.6 MiB.

Watch your provider's **monthly data allowance**, and size users' quotas to it.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `up` says the website has no valid certificate | DNS doesn't point at the server yet, or ports 80/443 are closed in the provider's firewall. Check `dig +short DOMAIN`, then `./burrowrs logs decoy`. |
| Telegram shows "connecting…" forever | From a computer on another network (with burrowrs cloned): `./burrowrs smoke --link "$(ssh root@203.0.113.7 /opt/burrowrs/burrowrs link --format tg)"`. If that passes, your local network is blocking the server's IP. |
| One user can't connect, others can | `./burrowrs user show NAME`: expired, disabled, quota used up, or more IP addresses than `--ips` allows. Test their link from anywhere: `./burrowrs smoke --link "$(./burrowrs user link NAME --format tg)"`. |
| Works on Wi-Fi but not mobile data, or the reverse | IP blocking on one network. Try `LINK_HOST` set to the IP, or a second server. |
| Many clients rejected | Check the clock with `./burrowrs doctor`. Clients whose clock is more than 2 minutes off are refused by design. |
| `doctor`: telemt is running but not ready | `./burrowrs logs telemt`. Usually Telegram is unreachable from the server. |
| `Pool overlaps with other one on this host` | Another Docker network uses `10.204.47.0/28`: `./burrowrs config set EDGE_SUBNET 10.77.1.0/28 DECOY_IP 10.77.1.10`. |
| Port 443 already in use | burrowrs must own 443. Move the other site into `site.local/` as the decoy, or use another server. |
| A custom page shows up unstyled | Inline `<style>` is blocked; move the CSS into `site.local/style.css` and link it. |
| No domain, but you want a real certificate | Use `<your-ip-with-dashes>.sslip.io` as the domain and set `LINK_HOST` to the IP. |

Still stuck? Run `./burrowrs doctor` and `./burrowrs logs`, then open an issue with the
output (remove secrets first).
