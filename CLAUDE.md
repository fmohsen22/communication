# CLAUDE.md

This repo installs a private, WhatsApp-style chat server (text, photos, voice
calls) based on [Snikket](https://snikket.org), running in Docker on the
user's own Linux machine. Usually that's an **Ubuntu PC at home behind a
router**. Read `README.md` for the full picture. This file is the runbook for
setting it up with the user.

## This installation

The settings are already decided. They're in README.md → **"Our setup"**:
home Ubuntu PC, domain `chat.mosi-app.com`, DNS for mosi-app.com managed at
**Cloudflare**, home IP followed by DuckDNS (`mosi-home.duckdns.org`). Use them
without asking again. The only thing to ask for is the admin email, and the
installer asks for that itself.

When the user asks you to set things up, follow the runbook below with these
values. Skip the decisions in steps 1 and 2 that are already made, but **do run
the checks**, especially:
- Ports 80/443 are free. Another app runs on this PC; if it uses them, stop and
  discuss, and don't touch that app.
- The CGNAT check.
- The 3 DNS records exist:
  ```bash
  for n in chat groups.chat share.chat; do curl -s -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$n.mosi-app.com&type=CNAME"; echo; done
  ```
  Each should answer `mosi-home.duckdns.org.`. If they're missing, tell the
  user to add them in **Cloudflare** (not Squarespace) as **DNS only**
  (grey cloud), exactly as in README → "Our setup". Wait until they resolve
  before the user runs the installer.

Then have the user run the install command from README → "Our setup" in their
own terminal.

## Rules

- **The user runs `sudo` and anything involving secrets themselves**, in their
  own terminal window. You can't type the sudo password, and the DuckDNS token
  or Cloudflare API token must **never** be pasted into the chat. `install.sh`
  asks for tokens with hidden input; let it.
- **The machine may already run other apps.** Never stop, remove or reconfigure
  other services or containers. If ports 80/443 are taken, stop and discuss with
  the user (Snikket supports running behind an existing reverse proxy:
  https://snikket.org/service/help/advanced/reverse_proxy/).
- **DNS:** only create or change the chat domain's 3 records
  (`<domain>`, `groups.<domain>`, `share.<domain>`). Never touch the user's
  other records. Chat records must be **DNS only** (Cloudflare grey cloud),
  because Cloudflare's proxy doesn't carry chat or call traffic.
- **This repo is public.** The domain and DuckDNS name in "Our setup" are there
  on purpose. Never commit anything else personal: IP addresses, emails, tokens,
  or the contents of `/etc/snikket`.
- Test reachability from **outside** (a phone on mobile data). Many home
  routers can't reach their own public IP from inside ("NAT loopback").

## Runbook

### 1. Ask the user for
- The chat domain, e.g. `chat.example.com`. It can't be changed later
  (accounts are named `user@<domain>`), so prefer a subdomain of a domain they
  own over a `*.duckdns.org` name.
- The admin email (used for Let's Encrypt).
- How DNS should follow a changing home IP. Decide with step 2.

### 2. Checks you can run yourself (no sudo)
```bash
lsb_release -ds                                   # want Ubuntu 22.04/24.04 or Debian 12
ss -ltn '( sport = :80 or sport = :443 )'         # want: no listeners (else see Rules)
hostname -I                                       # the PC's LAN IP, for port forwarding
curl -4 -s ifconfig.me                            # public IP the internet sees
# Where is the domain's DNS actually managed? (works without dig)
curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=<apex-domain>&type=NS'
```
- **CGNAT check:** ask the user for the router's WAN/Internet IP (router admin
  page). It must equal the public IP above. If it doesn't, or it starts with
  `100.64`–`100.127`, `10.`, `172.16`–`172.31` or `192.168.`, home hosting
  won't work. Stop and explain (options: ask the provider for a public IPv4, or
  use a rented server).
- **DNS mode**, based on the NS lookup:
  - Nameservers are `*.ns.cloudflare.com` → **`cloudflare`**. The installer
    creates the 3 records itself and keeps the A record updated. The user needs
    the **Zone ID** (domain's Overview page, under "API") and an API token from
    the **"Edit zone DNS"** template, limited to that zone. Records added at the
    registrar (e.g. Squarespace) are ignored in this case.
  - Other DNS provider → **`duckdns`**. The user needs a free name and token from
    duckdns.org and adds 3 CNAME records (`<domain>`, `groups.<domain>`,
    `share.<domain>` → `<name>.duckdns.org`) at their DNS provider.
  - Fixed IP, or a rented server → **`none`** (3 records added by hand, see README).

### 3. Router (the user does this; guide them)
- DHCP reservation, so the PC keeps its LAN IP.
- Port forwarding to that LAN IP:
  - TCP 80, 443, 5000, 5222, 5269, 3478-3479, 5349-5350
  - UDP 3478-3479, 5349-5350, 60000-60100

### 4. The user runs in their own terminal
```bash
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo SNIKKET_DOMAIN=<domain> SNIKKET_ADMIN_EMAIL=<email> SNIKKET_DNS_MODE=<cloudflare|duckdns|none> bash install.sh
```
The installer asks for the token(s), installs Docker if needed, starts
Snikket and prints an **admin invite link**. It's safe to run again. If its DNS
check fails right after records were added, answer N, wait 5–10 minutes and
re-run.

### 5. Verify
```bash
curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=<domain>&type=A'   # resolves to the public IP
curl -sI --resolve <domain>:443:127.0.0.1 https://<domain>/ | head -1                                  # local HTTPS answers with a valid cert
```
The user can check containers with `sudo chat status` (`snikket`,
`snikket-proxy`, `snikket-certs` and `snikket-portal` should be "running") and
logs with `sudo chat logs`. Then ask them to open `https://<domain>` **on a phone
using mobile data**, and to open the admin link there to create their account.
If the link was lost: `sudo chat admin-invite`.

### 6. After setup
- Invite people: `sudo chat invite`, or the web portal → Invitations.
- Keep a backup: `sudo chat backup`, then copy it off the machine.
- Common problems and fixes: README → Troubleshooting.
