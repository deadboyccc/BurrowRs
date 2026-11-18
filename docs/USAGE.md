# Usage

Commands run on the server in the install directory (`cd /opt/burrowrs`), or anywhere as
`/opt/burrowrs/burrowrs …`. Add `--help` to any command for its options; `--help` never
runs the command.

burrowrs needs Linux (or macOS) with Docker Engine 25+, Docker Compose 2.24.4+ and Bash
4.4+. On Debian/Ubuntu servers the installer sets all of that up for you.

## Commands

**Set up**

| Command | What it does |
|---|---|
| `init --domain D [--access shared\|users]` | Create `.env` with a fresh secret (`init --help` lists every flag). |
| `up [--no-wait]` | Apply the configuration, (re)start what changed, wait until the proxy answers, print your link. |
| `try [--users \| --down]` | Throwaway local instance on 127.0.0.1, fully self-tested. `--users` starts it in per-user mode; `--down` removes it. |
| `deploy user@host …` | Install or upgrade on a server over SSH (`deploy --help`). |

**Share** (in per-user mode these act on your own *owner* link)

| Command | What it does |
|---|---|
| `link [--format all\|tg\|tme\|secret]` | Print links on stdout. |
| `share` | Links, a QR code in the terminal, and private PNG/SVG copies in `state/share/`. |
| `rotate [--yes]` | New `SECRET`. Asks first; `--yes` skips the question. |

**Users** (`ACCESS_MODE=users`): see [Managing users](#managing-users) below.

**Operate**

| Command | What it does |
|---|---|
| `status` | Containers, a live handshake check, connections, traffic. |
| `smoke [--link L] [--insecure] [--no-telegram]` | End-to-end self-test (below). |
| `doctor` | Checks the host, clock, BBR, DNS, `.env` and decoy, then asks the running proxy whether it is ready and whether Telegram answers through it. |
| `logs [-f] [--tail N] [telemt\|decoy]` | Container logs. |
| `restart` · `down [--volumes]` · `update` | Restart; stop (`--volumes` also deletes the certificates and everyone's quota usage); pull the pinned images and recreate. |
| `config show` · `get KEY` · `set KEY VALUE …` | Inspect or change settings (see [Configuration](CONFIGURATION.md)). |
| `watchdog` | One health check, restarting what's stuck (a systemd timer runs it every 5 minutes). |
| `render` | Write the generated configs to `state/` without starting anything. |
| `uninstall [--purge]` | Remove containers, volumes, state and the watchdog (`--purge` also deletes `.env` and `users.tsv`). |

## Two access modes

`ACCESS_MODE` decides who holds which secret:

- **`shared`** (default): one secret, in `.env` as `SECRET`, and one link for everyone.
  `rotate` replaces it, and every old link stops working.
- **`users`**: every user gets a name and a secret of their own, kept in `users.tsv` next
  to `.env`. `SECRET` stays yours: it is the built-in **owner** user, with no limits, and
  the health checks (`up`, `status`, `smoke`, the watchdog) use it.

Pick the mode at install time (`BURROWRS_ACCESS=users`, or `./burrowrs init --access users`),
or switch at any time:

```bash
./burrowrs config set ACCESS_MODE users && ./burrowrs up
```

Switching from shared to users keeps `SECRET`, so the old shared link keeps working: it is
now your owner link. To cut everyone off from it, run `./burrowrs rotate` once you have
given your users their own links. Switching back to shared turns every user's link off
(only `SECRET` works again); `users.tsv` is kept, so switching to users again restores
them.

## Managing users

```text
Usage: burrowrs user COMMAND [NAME] [options]      (needs ACCESS_MODE=users)

  add NAME [limits]     create a user with their own secret; prints their link
  list                  every user: state, expiry, quota, devices, live usage
  show NAME             one user's settings and links
  link NAME [--format all|tg|tme|secret]
  share NAME            QR code for NAME (terminal, PNG, SVG)
  renew NAME --days N   extend from today or from the current expiry, whichever is later
  set NAME [limits]     change limits; anything not given stays as it is
  disable NAME | enable NAME
                        cut a user off (live connections drop) or let them back in
  rotate NAME [--yes]   new secret for NAME: their old link stops working
  remove NAME [--yes]   delete NAME and their secret

Limits (defaults come from USER_DEFAULT_* in .env):
  --days N | --until YYYY-MM-DD | --forever     when access ends (end of that day, UTC)
  --quota SIZE | --quota none                   traffic allowance, e.g. 50G (binary units)
  --period daily|weekly|monthly|none            when the quota resets (UTC); none = never
  --ips N | --ips none                          IP addresses connected at once (devices)
```

`users` works as an alias for `user`, `ls` for `list`, and `rm` or `delete` for `remove`.

### What each limit does

| Limit | Exactly |
|---|---|
| `--days N` | Access ends at 23:59:59 UTC, N days from today. `--days never` (or `--forever`) never expires. |
| `--until YYYY-MM-DD` | Access ends at 23:59:59 UTC on that date. A past date expires the user at once. |
| `--quota SIZE` | How much traffic the user may move through the proxy, as telemt counts it: a whole number with `K`, `M`, `G` or `T`, in binary units (`1G` = 1024³ bytes). Once it is used up, a connection in progress is closed and new ones are refused, until the quota resets or you raise it. |
| `--period P` | When a quota starts over, in UTC: `daily` at midnight, `weekly` on Monday at midnight, `monthly` on the 1st at midnight. `none`: the quota never resets (a prepaid allowance). Needs a quota. |
| `--ips N` | How many different IP addresses may have connections open at the same time (roughly, devices). A connection from one more address is refused while the others are connected. |

- **Defaults** come from `.env`: `USER_DEFAULT_DAYS=30`, `USER_DEFAULT_QUOTA=none`,
  `USER_DEFAULT_PERIOD=none`, `USER_DEFAULT_IPS=3`. A `--quota` given without `--period`
  never resets; the default period only applies together with the default quota.
- **Names** are lowercase letters, digits, `.`, `_` and `-`, up to 32 characters, starting
  with a letter or digit. `owner` is reserved. telemt supports up to 65,536 users.
- **Expired, disabled and over-quota users are refused.** Disabling a user also closes the
  connections they have open. Expiry is checked when a connection starts.
- **Changes apply at once and disconnect no one else.** burrowrs rewrites
  `state/telemt/users.toml`, which telemt reloads by itself; burrowrs waits until telemt confirms
  it, and the proxy keeps running.
- **Quota usage survives restarts and upgrades.** It lives in the `telemt-data` Docker
  volume; only `down --volumes` or `uninstall` deletes it.

### Running a small proxy service

```bash
# a 30-day plan with 50 GiB a month on up to 2 devices
./burrowrs user add alice --days 30 --quota 50G --period monthly --ips 2

# send alice her link (or a QR code)
./burrowrs user link alice --format tme
./burrowrs user share alice

# who is active, who expires when, who used how much
./burrowrs user list

# alice paid for another month: 30 days added to whatever she has left
./burrowrs user renew alice --days 30

# bob didn't pay: cut him off now, let him back in later
./burrowrs user disable bob
./burrowrs user enable bob

# carol upgraded to 200 GiB and 4 devices
./burrowrs user set carol --quota 200G --ips 4

# dave's link leaked: new secret, old link dead, send him the new one
./burrowrs user rotate dave

# erin left
./burrowrs user remove erin
```

`user list` shows, for each user:

| Column | Meaning |
|---|---|
| `STATE` | `active`, `disabled` or `expired`. |
| `EXPIRES` | The last day of access (UTC), or `never`. |
| `QUOTA` | `used/allowed` while the proxy runs (`-` for no quota). `d`, `w` or `m` after it: resets daily, weekly or monthly. |
| `DEVICES` | The `--ips` limit (`-` for none). |
| `LIVE` | While burrowrs runs: open connections, connected IP addresses and traffic since the proxy started. |

Live numbers come from telemt's read-only control API, which burrowrs reads from inside the
proxy's own network namespace; nothing else can reach it.

## Sharing a link

```bash
./burrowrs share                 # shared mode: the link; users mode: your owner link
./burrowrs user share alice      # users mode: alice's link
```

- **Anyone with a link can use it.** Send it privately, the way you'd send a key.
- **Two link forms.** `https://t.me/proxy?…` works everywhere; `tg://proxy?…` opens the
  app directly. Telegram accepts the secret in hex (`ee…`) or base64.
- **QR codes are made offline,** in the burrowrs-tools container. Your secret is never sent
  to a QR web service. Copies go to `state/share/` (mode 0600): `burrowrs-proxy.png`, `.svg`
  and `.txt` for your own link, `user-NAME.*` for a user.
- **Revoking.** Shared mode: `./burrowrs rotate`, then send the new link to the people who
  should keep access. Users mode: `user disable NAME` or `user rotate NAME`. A revoked
  link now just reaches the decoy website.
- **DNS trouble?** Links point at your domain by default. If DNS for it gets poisoned, set
  `LINK_HOST` to the server's IP: links keep working and the disguise stays the same.

## Self-tests

`./burrowrs smoke` checks the live proxy the way a Telegram app (and a censor) would:

1. a valid client completes the disguised handshake;
2. **Telegram answers through the proxy** (a real request to a Telegram data centre);
3. a replayed handshake is refused;
4. a client whose clock is 10 minutes off is refused;
5. a wrong secret gets the website, not the proxy;
6. browsers and probes see a real website over real TLS;
7. plain-HTTP scanners get a normal web-server answer;
8. metrics are served on 127.0.0.1 only.

`--no-telegram` skips check 2. `./burrowrs smoke --link 'tg://proxy?…'` runs the same
checks (minus the last one) against **any** FakeTLS proxy link, from any machine with
Docker. No `.env` is needed, so it's ideal for testing your server from another network,
or a user's link from their side.
