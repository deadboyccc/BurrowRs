# Deploying burrowrs, A to Z

From "I have nothing" to "my phone uses my own proxy" in about 20 minutes. Every step is
here, in order. Commands in `this style` are copy-paste ready. Replace the example values:

| Example value | Replace with |
|---|---|
| `203.0.113.7` | your server's public IPv4 address |
| `notes.example.com` | the domain (or subdomain) you will use |
| `you@example.com` | your email (for Let's Encrypt expiry notices) |

---

## A. What you need

- [ ] A **VPS** (virtual server): 1 vCPU, 1 GB RAM, Debian 12/13 or Ubuntu 22.04/24.04, a public IPv4.
- [ ] A **domain name**, or a subdomain of one you already have.
- [ ] A computer with a terminal (Linux, macOS, or Windows with WSL) and `ssh`.
- [ ] Optional but recommended: Docker on that computer too, for the final check from *your* side.

No domain? Use your server's IP as a free wildcard-DNS name such as
`203-0-113-7.sslip.io`. That still gives stealth mode with a real certificate (step F,
"No domain?"). Simple mode is the last resort.

## B. Choose a server

1. **Location.** Pick a country where Telegram is *not* blocked and that has good routes to
   your users (usually a nearby one). burrowrs connects to Telegram directly from the
   server, so Telegram must be reachable from there.
2. **Provider.** Any mainstream VPS provider works. Avoid providers whose IP ranges are
   widely blocked where your users are; ask people locally which ones work.
3. **Image.** Debian 13 or Ubuntu 24.04 LTS, x86-64 or ARM64.
4. **Firewall in the provider panel** (if it has one): allow inbound **TCP 22, 80, 443**.

## C. Create an SSH key and the server

On your computer:

```bash
ssh-keygen -t ed25519 -C "burrowrs"      # press Enter to accept the defaults; set a passphrase
cat ~/.ssh/id_ed25519.pub                 # copy this line
```

Create the server in your provider's panel and paste the public key where it asks for an
SSH key. When it boots, note its **IPv4 address** and check you can log in:

```bash
ssh root@203.0.113.7 'echo connected'
```

(Some images log in as `debian` or `ubuntu` instead of `root`. That's fine: burrowrs uses
`sudo` automatically, as long as it doesn't ask for a password. Cloud images set it up that
way. Otherwise deploy as `root`.)

## D. Point your domain at the server

> **No domain?** Skip this step. `203-0-113-7.sslip.io` (your IP with dashes) already
> resolves to your server; use it as the domain in step F.

In your DNS provider (registrar, Cloudflare, …) create:

| Type | Name | Value | TTL |
|---|---|---|---|
| `A` | `notes` (for `notes.example.com`) | `203.0.113.7` | 300 |
| `AAAA` (only with `--enable-ipv6`) | `notes` | the server's IPv6 | 300 |

> **Cloudflare users:** set the record to **DNS only** (grey cloud), not proxied.

Choose a name that sounds like a website (`notes`, `blog`, `photos`, `garden`), not `proxy`
or `tg`. Wait a minute, then check:

```bash
dig +short notes.example.com          # must print 203.0.113.7
```

## E. Get burrowrs on your computer

```bash
git clone https://github.com/deadboyccc/BurrowRs.git
cd burrowrs
./burrowrs version
```

Optional, but nice: try it locally first (needs Docker on your computer):

```bash
./burrowrs try && ./burrowrs try --down            # shared mode
./burrowrs try --users && ./burrowrs try --down    # per-user mode
```

## F. Deploy

First decide how people get access (you can switch later with
`./burrowrs config set ACCESS_MODE …`):

- **shared** (default): one link for you and everyone you trust;
- **users**: every user gets their own link with an expiry date, a data quota and a device
  limit. Pick this to run a proxy service.

### Variant 1: one command on the server (easiest)

Log in to the server (`ssh root@203.0.113.7`) and run:

```bash
curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
  sudo BURROWRS_DOMAIN=notes.example.com BURROWRS_EMAIL=you@example.com bash
```

For per-user mode, add `BURROWRS_ACCESS=users` after `sudo`.

That's everything. It installs git/curl, fetches the pinned burrowrs release into
`/opt/burrowrs`, prepares the host (Docker, firewall that keeps your SSH port open, BBR,
NTP, security updates, watchdog), creates the secret, starts the proxy, runs the full smoke
test and prints your link and QR code. Re-run the same command later to upgrade (your
secret and users are kept). Preview it first with `BURROWRS_DRY_RUN=1`. Every option is in
the [Configuration](CONFIGURATION.md#installer-settings); the common ones:

| Variable | Example |
|---|---|
| `BURROWRS_ACCESS` | `users`: a secret per user |
| `BURROWRS_COVER_DOMAIN` | `www.wikipedia.org`: simple mode, instead of `BURROWRS_DOMAIN` |
| `BURROWRS_SSH_PORT` | `2222`, if your SSH port can't be detected |
| `BURROWRS_PORT` | `443` (default) |
| `BURROWRS_LINK_HOST` | `203.0.113.7`: links use the IP instead of the domain |

### Variant 2: one command from your computer

```bash
./burrowrs deploy root@203.0.113.7 --domain notes.example.com --email you@example.com --access users
```

What happens, in order:

1. connects over SSH (and uses `sudo` if you're not root);
2. uploads burrowrs to `/opt/burrowrs` (never your `.env` or `users.tsv`; secrets are
   created on the server);
3. runs `scripts/install-host.sh`: Docker from Docker's signed repository, ufw firewall
   (SSH rate-limited on your SSH port and every port sshd listens on, plus 80 and 443),
   BBR tuning, a swap file on servers with 2 GiB of RAM or less, NTP, unattended security
   upgrades, watchdog timer;
4. `burrowrs init` on the server: generates the secret;
5. `burrowrs up`: starts telemt + the decoy site and waits for the certificate;
6. `burrowrs smoke` on the server, then **again from your computer across the internet**;
7. prints your link.

Useful flags: `--ssh-port 2222`, `-i ~/.ssh/other_key`, `--dir /srv/burrowrs`,
`--no-host-setup` (if you manage the server yourself), `--no-swap`, `--enable-ipv6`.
Re-running `deploy` later upgrades burrowrs and **keeps** the existing secret and users.

### Variant 3: by hand on the server

```bash
ssh root@203.0.113.7
apt-get update && apt-get install -y git
git clone https://github.com/deadboyccc/BurrowRs.git /opt/burrowrs && cd /opt/burrowrs
sudo scripts/install-host.sh --dir /opt/burrowrs --ssh-port 22   # your SSH port; --dry-run to preview
./burrowrs init --domain notes.example.com --email you@example.com --access users
./burrowrs up
./burrowrs smoke
```

### No domain?

**Recommended: a free wildcard-DNS name.** `203-0-113-7.sslip.io` resolves to `203.0.113.7`,
so Let's Encrypt can issue a real certificate and probes see a real website, exactly like
with your own domain. Links point at the IP, so phones never need that DNS service:

```bash
# on the server: finds its public IPv4 and installs (paste as is)
IP=$(curl -fsS4 https://api.ipify.org) &&
  curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
  sudo BURROWRS_DOMAIN="${IP//./-}.sslip.io" BURROWRS_LINK_HOST="$IP" bash
# or with the IP written out:
curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
  sudo BURROWRS_DOMAIN=203-0-113-7.sslip.io BURROWRS_LINK_HOST=203.0.113.7 bash
# or from your computer:
./burrowrs deploy root@203.0.113.7 --domain 203-0-113-7.sslip.io --link-host 203.0.113.7
```

(Certificate renewals every ~60 days rely on sslip.io resolving. If it ever stops, move to
a real domain with `./burrowrs config set DOMAIN …`.)

**Last resort: simple mode.** It impersonates a popular site that is reachable where your
users are:

```bash
curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh | sudo BURROWRS_COVER_DOMAIN=www.wikipedia.org bash
# or from your computer:
./burrowrs deploy root@203.0.113.7 --mode simple --cover-domain www.wikipedia.org
```

`--cover-domain` must be a popular HTTPS site that **is reachable where your users are**
(if it's blocked there, connections that name it will be too). Links will point at the
server's IP.

## G. Verify it works

> From here on, `./burrowrs …` means: on the server, in the install directory. Run
> `ssh root@203.0.113.7` and then `cd /opt/burrowrs` first, or call
> `/opt/burrowrs/burrowrs …` directly.

1. **On the server:** `./burrowrs smoke` should print `all 8 checks passed`.
2. **From your computer** (in your local clone of burrowrs, with Docker):
   `./burrowrs smoke --link 'tg://proxy?server=…'` (paste your link) should pass all checks.
3. **In a browser:** open `https://notes.example.com`. You should see an ordinary notes
   website with a valid padlock. That is what everyone except Telegram sees.
4. **Health overview:** `./burrowrs status`, and `./burrowrs doctor` for host checks.

If something fails, see [Troubleshooting](#troubleshooting) below.

## H. Make the decoy website yours

Thousands of identical template sites would be a fingerprint. On the server:

```bash
cd /opt/burrowrs
cp -r site site.local
nano site.local/index.html        # change titles, posts, wording; add pages or images
./burrowrs up                     # only the decoy container is recreated
```

Already have a page? Upload it into `site.local/` from your computer, then apply:

```bash
scp -r mysite/* root@203.0.113.7:/opt/burrowrs/site.local/
ssh root@203.0.113.7 /opt/burrowrs/burrowrs up
```

Rules for your pages:

- CSS goes in files (`<link rel="stylesheet" href="/style.css">`). The site sends a strict
  Content-Security-Policy that blocks `<style>` blocks, inline `style=""` and all scripts.
  Images and fonts must come from the site itself.
- Include a `404.html`; scanners love to probe `/wp-admin`.
- Dotfiles (`.git`, `.DS_Store`) are skipped automatically.

Keep it plausible: a personal blog, a portfolio, a recipe collection, a memorial page.
`./burrowrs doctor` stops warning once `site.local/` exists.

## I. Connect your phone

```bash
./burrowrs share          # prints a QR code + links (also saved in state/share/)
```

- **Phone:** scan the QR code with the camera, or open the `https://t.me/proxy?…` link,
  then tap **Connect proxy**.
- **Desktop:** click the `tg://proxy?…` link, or in Telegram go to *Settings → Advanced →
  Connection type → Use custom proxy → MTProto*, then enter server, port 443 and the secret
  (`./burrowrs link --format secret`).
- A shield icon or "Connected (proxy)" in Telegram's settings confirms it is in use.

In per-user mode this is your own **owner** link: no limits, and the health checks use it.
Keep it to yourself.

## J. Give other people access

**Shared mode.** Send the `https://t.me/proxy?…` link (it works even for people who can't
open `tg://` links) through a channel you trust. Anyone with the link can use your proxy.
Someone shouldn't have access any more? `./burrowrs rotate`, then send the new link to
everyone who should keep it.

**Per-user mode.** Create a user per person and send each their own link:

```bash
./burrowrs user add alice --days 30 --quota 50G --period monthly --ips 2
./burrowrs user share alice        # QR code; or: ./burrowrs user link alice --format tme
./burrowrs user list               # state, expiry, quota used, live connections
./burrowrs user renew alice --days 30
./burrowrs user disable alice      # cuts her off at once; enable lets her back in
```

Every change applies to the running proxy immediately and disconnects no one else. All the
commands and limits are in [Usage](USAGE.md#managing-users).

## K. Day-2 operations

| Task | Command |
|---|---|
| Health and traffic | `./burrowrs status` |
| Users and their usage | `./burrowrs user list` |
| Full self-test | `./burrowrs smoke` |
| Logs | `./burrowrs logs -f telemt` / `./burrowrs logs decoy` |
| Update burrowrs | re-run the step F command (Variant 1 or 2); the secret and users are kept |
| Update container images | `./burrowrs update` |
| Change settings | `./burrowrs config set KEY VALUE && ./burrowrs up` |
| Back up | copy `/opt/burrowrs/.env` and `/opt/burrowrs/users.tsv` somewhere safe (they hold the secrets) |

**Privacy:** successful connections are never logged. `./burrowrs status` and
`./burrowrs user list` show what is connected right now; past connections leave no trace
beyond per-user traffic counters and the warnings for refused connections (which name the
user, and sometimes the client's IP). `LOGGING=off` keeps no logs at all. Raise
`LOG_LEVEL` above `silent` only while troubleshooting. Details:
[Threat model](THREAT-MODEL.md#privacy).

The watchdog checks the proxy every 5 minutes and restarts it if it hangs
(`systemctl list-timers burrowrs-watchdog.timer`, logs: `journalctl -u burrowrs-watchdog`).
Certificates renew themselves. Security updates install themselves.

## L. Move to a new server (keep your links working)

1. Deploy burrowrs on the new server (step F, any domain; it is replaced next).
2. Copy the old `/opt/burrowrs/.env` and `users.tsv` over the new ones, then run
   `./burrowrs config set PUBLIC_IPV4 <new IP> && ./burrowrs up` there.
3. Point the DNS `A` record at the new IP. With `LINK_HOST` unset, links use the domain,
   so users don't need new links.

Quota usage lives in a Docker volume on the old server, so it starts again from zero on
the new one.

### Coming from Burrow (keep every link)

A Burrow secret is `ee` + a 32-hex key + the domain in hex; burrowrs keeps the key alone. Give
burrowrs the same key and domain and every link Burrow handed out keeps working. On the
Burrow server, as root:

1. Put burrowrs next to Burrow, without starting it:
   `git clone --depth 1 --branch v1.0.1 https://github.com/deadboyccc/BurrowRs.git /opt/burrowrs`
2. Create its `.env` from Burrow's settings, then give it Burrow's key:

   ```bash
   cd /opt/burrowrs
   b() { /opt/burrow/burrow config get "$1"; }
   ./burrowrs init --domain "$(b DOMAIN)" --link-host "$(b LINK_HOST)" --ipv4 "$(b PUBLIC_IPV4)" \
     --port "$(b PROXY_PORT)" --http-port "$(b HTTP_PORT)" --quiet
   secret=$(b SECRET); sed -i "s/^SECRET=.*/SECRET=${secret:2:32}/" .env
   [ "$(/opt/burrow/burrow link --format secret)" = "$(./burrowrs link --format secret)" ] && echo "same link"
   ```

3. Bring the decoy site along: `cp -a /opt/burrow/site.local /opt/burrowrs/` (if you have one).
4. Prepare the host while Burrow still serves (it doesn't restart Docker):
   `scripts/install-host.sh --dir /opt/burrowrs --ssh-port 22 --ports 80,443`
5. Optional, saves a certificate request: copy the certificate volume.

   ```bash
   docker volume create --label com.docker.compose.project=burrowrs \
     --label com.docker.compose.volume=decoy-data burrowrs_decoy-data
   docker run --rm -v burrow_decoy-data:/from:ro -v burrowrs_decoy-data:/to busybox cp -a /from/. /to/
   ```

6. Switch (measured: 6.7 s without service), then test:
   `/opt/burrow/burrow down && ./burrowrs up && ./burrowrs smoke`

Going back is `./burrowrs down && /opt/burrow/burrow up`; `burrow down` keeps its volumes.

## M. If the server gets blocked

| Situation | What to do |
|---|---|
| The **IP** is blocked for your users | New server (step L). Links keep working if they use the domain. |
| The **domain** is DNS-poisoned | `./burrowrs config set LINK_HOST 203.0.113.7 && ./burrowrs up`, then send everyone their new link. |
| Telegram is blocked **from the server** | burrowrs has no upstream proxy setting; move to a server in a country where Telegram is reachable (step L). |
| Probes still find it | Make the decoy richer (step H), use your own domain rather than simple mode, keep port 443. |

## N. Uninstall

```bash
cd /opt/burrowrs
./burrowrs uninstall --purge     # containers, volumes, state, watchdog, .env and users.tsv
```

The firewall, sysctl tuning and Docker stay installed; remove them with your package manager if you like.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `cannot SSH to …` | Check the IP, the user (`root` vs `debian`/`ubuntu`), `--ssh-port`, `-i keyfile`. |
| "the decoy website has no valid certificate yet" | DNS doesn't point at the server yet (`dig +short`), or ports 80/443 are closed in the provider's firewall. Fix it, then `./burrowrs up`. Let's Encrypt allows a few failures per hour, so don't loop. |
| Smoke passes on the server but not from your computer | Something between you and the server blocks it (provider firewall, your ISP). Try from another network. |
| `Pool overlaps with other one on this host` | `./burrowrs config set EDGE_SUBNET 10.77.1.0/28 DECOY_IP 10.77.1.10 && ./burrowrs up` |
| Clients connect, then drop | Clock drift: `./burrowrs doctor`. On the server: `timedatectl status`. |
| One user can't connect | `./burrowrs user show NAME`: expired, disabled, quota used up, or more devices than `--ips` allows. |
| `per-user secrets need ACCESS_MODE=users` | You're in shared mode: `./burrowrs config set ACCESS_MODE users && ./burrowrs up`. |
| Port 443 is already taken | Another web server is running. burrowrs must own 443: stop it, or serve that site as burrowrs's decoy via `site.local/`. |
| Anything else | `./burrowrs doctor`, `./burrowrs logs`, then open an issue with the output (remove secrets). |
