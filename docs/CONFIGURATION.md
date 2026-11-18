# Configuration

## Installer settings

The [one-command installer](../README.md#install) is configured with environment
variables:

```bash
curl -fsSL https://raw.githubusercontent.com/deadboyccc/BurrowRs/main/install.sh |
  sudo BURROWRS_DOMAIN=notes.example.com BURROWRS_ACCESS=users bash
```

| Variable | Meaning |
|---|---|
| `BURROWRS_DOMAIN` | Stealth mode: your domain (A record → this server). No domain? Use `203-0-113-7.sslip.io` (your IP with dashes). |
| `BURROWRS_COVER_DOMAIN` | Simple mode, the last resort: a popular HTTPS site reachable where your users are. |
| `BURROWRS_ACCESS` | `shared` (default: one secret for everyone) or `users` (a name and a secret per user). |
| `BURROWRS_EMAIL` | Let's Encrypt account email (optional). |
| `BURROWRS_PORT` | Public proxy port (default `443`). |
| `BURROWRS_LINK_HOST` | What links point at (default: the domain, or the IP in simple mode). |
| `BURROWRS_ENABLE_IPV6` | `true` to also listen on IPv6. |
| `BURROWRS_SSH_PORT` | Your SSH port, if it can't be detected (ports sshd listens on are always kept open). |
| `BURROWRS_DIR` / `BURROWRS_REF` | Install directory (`/opt/burrowrs`) / release to install. |
| `BURROWRS_INIT_ARGS` | Extra `burrowrs init` flags, e.g. `"--subnet 10.77.1.0/28"`. |
| `BURROWRS_SKIP_HOST_SETUP=1` | Leave Docker, the firewall and kernel settings to you. |
| `BURROWRS_SWAP=0` | Never add a swap file. By default, a server with 2 GiB of RAM or less and no swap gets a 2 GiB one. |
| `BURROWRS_DRY_RUN=1` | Show every step, change nothing. |

On a server that is already installed, re-running the installer keeps the existing
configuration and users. It tells you if a variable you passed differs from it, and how to
change it.

## Settings (`.env`)

Everything lives in `/opt/burrowrs/.env` (mode 0600; it holds your secret). Every key is
documented, with its default, in [`.env.example`](../.env.example). Change settings like
this:

```bash
./burrowrs config set KEY VALUE [KEY VALUE ...]
./burrowrs up
```

`config set` validates all the values together and changes nothing if any is invalid. `up`
then recreates only the containers whose configuration changed.

Secrets are plain keys, so changing the domain keeps them. Links, however, carry the
fronting domain and the server address: when `BURROWRS_MODE`, `DOMAIN`, `COVER_DOMAIN`,
`LINK_HOST` or `PROXY_PORT` changes, every link changes, and everyone needs the new one
(`link`, `user link NAME`).

The settings you're most likely to touch:

| Key | Default | Notes |
|---|---|---|
| `DOMAIN` | | Stealth mode: your domain. |
| `ACCESS_MODE` | `shared` | `users` for a secret per user (see [Usage](USAGE.md#two-access-modes)). |
| `USER_DEFAULT_DAYS` | `30` | Days until a new user expires, or `never`. |
| `USER_DEFAULT_QUOTA` | `none` | Data quota for new users, e.g. `50G` (binary units). |
| `USER_DEFAULT_PERIOD` | `none` | When that quota resets: `daily`, `weekly`, `monthly` (UTC) or `none`. Needs a quota. |
| `USER_DEFAULT_IPS` | `3` | IP addresses a new user may have connected at once, or `none`. |
| `AD_TAG` | | A sponsored channel: the 32-hex tag [@MTProxybot](https://t.me/MTProxybot) gives you for this proxy. Needs `PUBLIC_IPV4`. |
| `LINK_HOST` | the domain | Put the server's IP here if DNS for your domain is poisoned. |
| `PROXY_PORT` | `443` | Keep 443: real HTTPS lives there. |
| `ENABLE_IPV6` | `false` | Also accept IPv6 clients, with their real addresses. |
| `LOGGING` | `on` | `off` keeps no container logs at all (see [Threat model](THREAT-MODEL.md#privacy)). |
| `LOG_LEVEL` | `silent` | telemt's log level: `silent` (warnings and errors only: refused connections, with the user name and sometimes the client's IP), `normal`, `verbose` or `debug`. |
| `MAX_CONNECTIONS` | `10000` | Maximum simultaneous client connections. |

### Sponsored channel (`AD_TAG`)

Telegram lets a proxy owner show their users a sponsored channel. Register the proxy with
@MTProxybot, then:

```bash
./burrowrs config set AD_TAG 0123456789abcdef0123456789abcdef && ./burrowrs up
```

With a tag, telemt routes traffic through Telegram's middle proxies (that is how the
sponsored channel reaches the app) and tells them the server's public address
(`PUBLIC_IPV4`). Without one, it connects straight to Telegram's data centres.

## Your own decoy website

The decoy is what everyone who isn't a Telegram app sees. The bundled one is a template,
and the same template on many servers would be a fingerprint, so make it yours:

```bash
cp -r site site.local       # or upload your own pages into site.local/
$EDITOR site.local/index.html
./burrowrs up               # only the website container is recreated
```

`site.local/` is used automatically, never touched by upgrades, and `{{SITE_NAME}}`,
`{{DOMAIN}}`, `{{YEAR}}` and `{{ACCENT}}` are filled in for you.

Rules for your pages:

- **CSS goes in files** (`<link rel="stylesheet" href="/style.css">`). The site sends a
  strict Content-Security-Policy that blocks `<style>` blocks, inline `style=""` and all
  scripts.
- Images and fonts must come from the site itself.
- Keep a `404.html`: scanners probe paths like `/wp-admin`.
- Dotfiles (`.git`, `.DS_Store`) are never published.
