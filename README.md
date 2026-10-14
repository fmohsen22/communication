# Private chat server for you and your friends

A WhatsApp-style messenger that runs on **your own server**, built on
[Snikket](https://snikket.org), an open-source project.

- 💬 Text messages, 1-to-1 and in groups
- 📷 Photos and files
- 📞 Voice calls (video too, if you want it)
- 🔒 End-to-end encrypted. Your server stores messages but can't read them.
- 🔔 Push notifications, so the app doesn't have to stay open
- ✉️ Invite-only. Nobody can sign up unless you send them a link.

Your friends install the free **Snikket** app (Android / iOS), tap your invite
link, and they're in. No phone numbers, and none of your messages pass through
a big company's server.

## Quick start

On an Ubuntu/Debian machine that will be the server:

```bash
git clone https://github.com/fmohsen22/communication.git
cd communication
sudo bash install.sh
```

The installer asks a few questions and prints an admin invite link at the end.
Read [What you need](#what-you-need) first. If the server is a PC at home, also
read [Running on a home PC](#running-on-a-home-pc).

**Using Claude Code?** Open `claude` in this folder and ask it to set up the
server. [CLAUDE.md](CLAUDE.md) tells it the steps, checks and rules.

## Our setup

This repo is used for one specific server. These are its settings; use them
as they are.

| | |
|---|---|
| **Server** | Ubuntu PC at home, behind a router. **Another app already runs on this PC; don't touch it.** |
| **Chat domain** | `chat.mosi-app.com` (accounts will be `name@chat.mosi-app.com`) |
| **Where mosi-app.com's DNS is managed** | **Cloudflare.** The domain was bought at Squarespace, but its nameservers are Cloudflare's, so records at Squarespace have no effect. |
| **Following the changing home IP** | DuckDNS name `mosi-home.duckdns.org`, so `SNIKKET_DNS_MODE=duckdns` and `DUCKDNS_NAME=mosi-home` |

**DNS records** (in Cloudflare → mosi-app.com → DNS → Records). All three
must be **DNS only** (grey cloud), not proxied:

| Type | Name | Target |
|---|---|---|
| CNAME | `chat` | `mosi-home.duckdns.org` |
| CNAME | `groups.chat` | `mosi-home.duckdns.org` |
| CNAME | `share.chat` | `mosi-home.duckdns.org` |

**Install command.** Run it in your own terminal. It asks for the admin email
and the DuckDNS token (paste the token there, never into a chat):

```bash
sudo SNIKKET_DOMAIN=chat.mosi-app.com SNIKKET_DNS_MODE=duckdns DUCKDNS_NAME=mosi-home bash install.sh
```

When it shows the 3 records and says "Press Enter", they're already in
Cloudflare, so just press Enter.

## What's in this repo

| File | What it does |
|---|---|
| `install.sh` | Installs everything: checks DNS and ports, installs Docker, writes the config, starts Snikket, prints the admin link |
| `chat.sh` | Day-to-day helper, installed as `sudo chat` (invite, status, logs, update, backup) |
| `docker-compose.yml` | Snikket's official container setup |
| `duckdns.sh` | Keeps a free DuckDNS name pointed at a home connection whose IP changes |
| `cloudflare-ddns.sh` | Same, for domains whose DNS is on Cloudflare (creates the records too) |

---

## How it works

```
   Your phone (Snikket app)                         Friend's phone (Snikket app)
          │                                                     ▲
          │  1. message / photo / "ring!"                       │ 3. delivered
          ▼                                                     │
   ┌──────────────────────────── YOUR SERVER ───────────────────────────────┐
   │  Snikket server (XMPP)  ── stores & forwards messages, keeps accounts  │
   │  File storage (HTTPS)   ── holds encrypted photos                      │
   │  TURN/STUN (coturn)     ── helps calls connect, relays audio if needed │
   │  Web portal + HTTPS     ── admin page, invites, free Let's Encrypt cert│
   └────────────────────────────────────────────────────────────────────────┘
                     │ 2. "you have a new message" (no content)
                     ▼
            Apple / Google push service  ──►  wakes up friend's phone
```

**Text messages.** The app keeps a secure connection open to your server
(port 5222). When you send a message, your phone encrypts it first (OMEMO
encryption, similar to WhatsApp's Signal protocol), so the server only sees
scrambled data. The server passes it on to your friend. If your friend is
offline, the server holds the message until their phone reconnects, and
message history syncs across devices.

**Notifications.** If your friend's app is asleep, your server sends an empty
"wake up" signal through Apple or Google's push service. The phone wakes up,
connects to *your* server, and downloads the message. Apple and Google never
see the message itself.

**Photos.** Your phone encrypts the photo and uploads it to your server
(`share.yourdomain`). Then it sends your friend a message with the link and the
key. Your friend's phone downloads the photo and decrypts it.

**Voice calls.** Calls use WebRTC, the same technology video-call websites use.
1. *Ringing.* The call request ("Sara is calling…") goes through your server
   like a message.
2. *Connecting.* Each phone asks the server's STUN service "what's my public
   address?", and the phones swap addresses.
3. *Talking.* If possible, the audio goes **directly phone-to-phone**. If a
   router or mobile network blocks that (common on 4G/5G), the audio is
   **relayed through your server's TURN service** instead. The audio is
   encrypted in both cases.

This is why some UDP ports need to be open (see below). Without the TURN relay,
calls would often fail on mobile data.

---

## What you need

| | |
|---|---|
| **A Linux server** | Ubuntu 22.04/24.04 or Debian 12. A small VPS (1 vCPU, 1 GB RAM) is plenty for a group of friends. It needs a public IP. A PC at home works too; see [Running on a home PC](#running-on-a-home-pc). |
| **A domain name** | e.g. `chat.yourname.com`. You must be able to add DNS records. Or use a free `yourname.duckdns.org` name (see [Running on a home PC](#running-on-a-home-pc)). |
| **Free ports 80 and 443** | Snikket runs its own web server. If the server already hosts a website, see [reverse proxy docs](https://snikket.org/service/help/advanced/reverse_proxy/). |

---

## Setup (about 10 minutes)

### Step 1: DNS records

First check **where your domain's DNS is managed**. That's not always the
company you bought the domain from:

```bash
dig +short NS yourdomain.com
```

If it shows `*.ns.cloudflare.com`, the records go in Cloudflare, even if you
bought the domain at Squarespace, GoDaddy etc. Records added anywhere else are
ignored.

There, add these records, using your own domain and server IP:

| Name                      | Type  | Value              |
|---------------------------|-------|--------------------|
| `chat.example.com`        | A     | `your.server.ip`   |
| `groups.chat.example.com` | CNAME | `chat.example.com` |
| `share.chat.example.com`  | CNAME | `chat.example.com` |

> **Cloudflare users:** you can skip this step. The installer can create the
> records for you (see [Running on a home PC](#running-on-a-home-pc)). If you
> create them by hand, set them to **"DNS only"** (grey cloud), not proxied.
> Cloudflare's proxy doesn't pass chat and call traffic.

### Step 2: Get this repo onto the server and run the installer

On the server (log in with `ssh` first if it's a rented one):

```bash
git clone https://github.com/fmohsen22/communication.git
cd communication
sudo bash install.sh
```

It will ask for your domain and email, then:
- check your DNS records,
- install Docker if it isn't installed,
- open the firewall ports (if `ufw` is enabled),
- start Snikket, which gets an HTTPS certificate automatically,
- print an **admin invite link**.

### Step 3: Create your own account

Open the admin invite link **on your phone**. It will walk you through
installing the Snikket app and creating your account.

### Step 4: Invite your friends

```bash
sudo chat invite
```

Send each friend their own link (WhatsApp, SMS, email…). You can also create
invites in the web portal at `https://chat.example.com`.

Nobody can sign up without an invite. By default, though, any **normal** member
can also create invites from inside the app. If you want to be the only one who
lets people in, create invites in the web portal with the role set to
**Limited**, or change people's role later on the **Users** page. Limited
members can't invite anyone and can only talk to people on your server.

Everyone in the default group sees each other in their contacts automatically.
Tap a name to chat. Tap the 📞 icon to call.

---

## Apps

| Platform | App |
|---|---|
| Android | **Snikket** on [Google Play](https://play.google.com/store/apps/details?id=org.snikket.android) or [F-Droid](https://f-droid.org/packages/org.snikket.android/) |
| iPhone  | **Snikket** on the [App Store](https://apps.apple.com/app/snikket/id1545164189) |
| Desktop | Snikket uses the open XMPP standard, so desktop XMPP apps work too, e.g. [Dino](https://dino.im) (Linux), [Gajim](https://gajim.org) (Windows/Linux), [Monal](https://monal-im.org) (Mac). Call support varies. |

The invite link takes each friend to the right app for their phone.

---

## Firewall ports

`install.sh` opens these in `ufw`. **If your provider has its own firewall**
(AWS Security Groups, Hetzner/Oracle/DigitalOcean cloud firewall, home router),
you have to open them there too:

| Protocol  | Port(s)       | Used for |
|-----------|---------------|----------|
| TCP       | 80, 443       | Web portal, HTTPS certificate, photo upload/download |
| TCP       | 5222          | Apps connecting to the server |
| TCP       | 5269          | Talking to other Snikket/XMPP servers (optional) |
| TCP       | 5000          | File transfer proxy |
| TCP + UDP | 3478, 3479    | STUN/TURN: setting up calls |
| TCP + UDP | 5349, 5350    | STUN/TURN over TLS |
| UDP       | 60000–60100   | Call audio relay |

The call audio range is set in `/etc/snikket/snikket.conf`. 100 ports is
enough for about 20 people calling at the same time. (Snikket's own default is
49152–65535; this kit uses a smaller range so it's easy to forward on a home
router.) If you change it, open or forward the new range and run
`sudo chat restart`:

```
SNIKKET_TWEAK_TURNSERVER_MIN_PORT=60000
SNIKKET_TWEAK_TURNSERVER_MAX_PORT=60100
```

---

## Running on a home PC

An always-on Ubuntu PC at home works fine as the server. Compared with a rented
server, you need to sort out a few extra things:

1. **A real public IP address.** Look up the "WAN" or "Internet" IP on your
   router's admin page and compare it with what the PC sees:
   ```bash
   curl -4 ifconfig.me
   ```
   If they're different (or the router's starts with `100.64`–`100.127`, `10.`,
   `172.16`–`172.31` or `192.168.`), your internet provider shares one address
   between many customers (called CGNAT). In that case nobody on the internet can
   reach your PC. Ask your provider for a public IPv4 address, or use a rented
   server instead.
2. **A fixed local address for the PC.** In the router, add a "DHCP reservation"
   (sometimes called a "static lease") so the PC always gets the same local
   address, e.g. `192.168.1.42`.
3. **Port forwarding.** Forward the ports from the table above to that local
   address. At the end, the installer prints the exact list with your PC's
   address.
4. **Your home IP changing.** Most home connections get a new public IP from
   time to time. When that happens, the DNS record has to be updated
   ("dynamic DNS"). **If your domain's DNS is on Cloudflare (free), the kit
   does this for you.** When `install.sh` asks "Is your domain's DNS on
   Cloudflare?", answer `y` and paste your Zone ID and an API token (the script
   explains where to find them). It creates the 3 DNS records itself and checks
   your IP every 5 minutes (`cloudflare-ddns.sh`). To see what it's been doing:
   `journalctl -u snikket-ddns`

   **Domain at Squarespace, GoDaddy etc. (no automatic updates there)?** Choose
   option 1 (DuckDNS) when the installer asks. Your own name, e.g.
   `chat.yourdomain.com`, then points to a free `yourname.duckdns.org` name
   through 3 CNAME records you add once. DuckDNS follows your home IP, so you
   never have to touch your provider's records again. Your existing website
   records aren't affected.

   **Free alternative, no domain to buy:** sign in at
   [duckdns.org](https://www.duckdns.org), add a name, and use
   `yourname.duckdns.org` as your domain in `install.sh`. The installer notices
   it's a DuckDNS name, asks for your DuckDNS token, and keeps it updated
   (`duckdns.sh`). `groups.` and `share.` work automatically, so you don't need
   to create any DNS records.
5. **Keeping the PC awake.** Turn off sleep:
   ```bash
   sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
   ```
   Also look for "Restore on AC power loss" in the BIOS, so the PC switches back
   on after a power cut.

Good to know:
- **Your home IP becomes public.** Anyone who looks up your domain sees your
  home internet address (roughly your city and provider). With a rented server
  they'd only see the server's address.
- **Security:** the PC is reachable from the internet. Keep Ubuntu updated
  (`sudo apt update && sudo apt upgrade`), use a strong password, and ideally
  don't keep sensitive personal files on it.
- **Speed:** a voice call needs well under 1 Mbit/s, so a normal home connection
  is plenty.
- **Getting the kit onto the PC:**
  `git clone https://github.com/fmohsen22/communication.git && cd communication && sudo bash install.sh`

---

## Your data

Everything lives on your server, in the Docker volume `snikket_snikket_data`
(`/var/lib/docker/volumes/snikket_snikket_data`): accounts, contacts, messages
and shared photos. Messages and photos are stored end-to-end encrypted.

**How long the server keeps messages and photos:** 7 days by default. That's
enough for every phone to pick them up. Each phone keeps its own full chat
history after that, but a **new or reinstalled phone only gets what's still on
the server**. To keep more, edit `/etc/snikket/snikket.conf`:

```
# keep messages and photos for a year
SNIKKET_RETENTION_DAYS=365
# optional: cap the disk space used by photos
SNIKKET_UPLOAD_STORAGE_GB=20
```

Then run `sudo chat restart`.

---

## Running the installer without questions

Every question can be answered in advance (handy for scripts or Claude Code).
Pass the values after `sudo`, because `sudo` drops normal environment variables:

```bash
sudo SNIKKET_DOMAIN=chat.example.com SNIKKET_ADMIN_EMAIL=you@example.com \
     SNIKKET_DNS_MODE=cloudflare bash install.sh
```

`SNIKKET_DNS_MODE` is `duckdns`, `cloudflare` or `none`. Tokens (`DUCKDNS_TOKEN`,
`CF_API_TOKEN`) can be passed the same way, but it's safer to type them when the
installer asks, so they don't end up in your shell history.

---

## Day-to-day

```
sudo chat invite         # invite link for a friend
sudo chat status         # is everything running?
sudo chat logs           # watch the logs
sudo chat update         # update to the latest Snikket version
sudo chat backup         # back up accounts, messages and photos
```

The server restarts automatically after a reboot or crash.

**Backups:** `sudo chat backup` creates a `.tar.gz` in `/var/backups/snikket/`.
Copy it off the server, e.g. `scp root@server:/var/backups/snikket/*.tar.gz .`
To restore onto a fresh server, run `install.sh`, then `docker compose down`,
extract the backup into the `snikket_snikket_data` volume folder
(`docker volume inspect snikket_snikket_data`), and `docker compose up -d`.

**Admin tasks** (remove a user, reset a password, see who's registered) are in
the web portal at `https://chat.example.com` → log in with your admin account.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| DNS records added but nothing resolves | They were added at the wrong company. Check `dig +short NS yourdomain.com` and add them where the nameservers point (e.g. Cloudflare). |
| Invite link / website doesn't load | DNS not pointing to the server yet, or port 80/443 blocked. Check `sudo chat logs` for certificate errors. |
| Messages work but **calls don't connect** (especially on mobile data) | UDP ports 3478/3479 and 60000–60100 aren't open. Check your **cloud provider's firewall** or **router port forwarding**, not just `ufw`. |
| Home server: works on mobile data but **not on your home Wi-Fi** | Your router doesn't support "NAT loopback" (also called "hairpinning"). Turn it on in the router if it has the option; otherwise use mobile data at home. |
| Photos fail to send | `share.yourdomain` DNS record missing, or port 443 blocked. |
| Group chats fail | `groups.yourdomain` DNS record missing. |
| Notifications are late on Android | In Android settings, turn off battery optimisation for the Snikket app. |

More help: https://snikket.org/service/help/

---

## Why Snikket?

Alternatives:
- **Matrix (Synapse + Element)**: very capable, but heavier to run and more
  complex to set up, and calls in the newer apps need extra servers (LiveKit).
- **Rocket.Chat / Mattermost**: built for workplaces (Slack-style), not
  personal messaging.
- **Writing a custom app**: possible, but WhatsApp-like features such as
  push notifications that ring your phone when the app is closed,
  encryption, and reliable calls on mobile networks take months to get right.
  Snikket already does all of that.

Snikket is designed for exactly this use case: a family or group of friends
with one person running the server. It needs one config file, and it updates
with one command.
