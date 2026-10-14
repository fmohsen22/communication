#!/usr/bin/env bash
# Installs a private Snikket chat server (text, photos, voice/video calls)
# on a Debian/Ubuntu server.
#
#   sudo ./install.sh
#
# You can skip the questions by setting these in the environment:
#   SNIKKET_DOMAIN, SNIKKET_ADMIN_EMAIL
#   SNIKKET_DNS_MODE=duckdns|cloudflare|none   (how DNS follows a changing home IP)
#   DUCKDNS_NAME, DUCKDNS_TOKEN                (for duckdns)
#   CF_ZONE_ID, CF_API_TOKEN                   (for cloudflare)
# Safe to run again: it keeps existing chats and accounts.
set -euo pipefail

INSTALL_DIR=/etc/snikket
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

say()  { printf '\n\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

confirm() {
  local answer
  read -rp "$1 [y/N] " answer
  [[ $answer =~ ^[Yy] ]]
}

[[ $EUID -eq 0 ]] || die "Please run as root: sudo $0"
[[ -f $SCRIPT_DIR/docker-compose.yml ]] || die "docker-compose.yml not found next to this script."

# --- 1. Settings --------------------------------------------------------------

DOMAIN="${SNIKKET_DOMAIN:-}"
EMAIL="${SNIKKET_ADMIN_EMAIL:-}"

# Reuse the values from a previous run if there is one.
if [[ -f $INSTALL_DIR/snikket.conf ]]; then
  # shellcheck disable=SC1091
  source "$INSTALL_DIR/snikket.conf"
  DOMAIN="${DOMAIN:-${SNIKKET_DOMAIN:-}}"
  EMAIL="${EMAIL:-${SNIKKET_ADMIN_EMAIL:-}}"
fi

# UDP ports for relayed call audio. Snikket's default is 49152-65535; 100 ports
# is enough for ~20 people calling at once and is much easier to forward on a
# home router.
TURN_MIN="${SNIKKET_TWEAK_TURNSERVER_MIN_PORT:-60000}"
TURN_MAX="${SNIKKET_TWEAK_TURNSERVER_MAX_PORT:-60100}"

[[ -n $DOMAIN ]] || read -rp "Chat domain (e.g. chat.example.com): " DOMAIN
[[ -n $EMAIL ]]  || read -rp "Your email (used for the free HTTPS certificate): " EMAIL

DOMAIN="${DOMAIN,,}"
[[ $DOMAIN =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
  || die "'$DOMAIN' doesn't look like a domain name."
[[ $EMAIL =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
  || die "'$EMAIL' doesn't look like an email address."

# --- 2. Basic tools -----------------------------------------------------------

say "Installing basic tools..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl ca-certificates iproute2 jq >/dev/null

# --- 3. Keeping DNS pointed at a changing home IP (optional) -----------------

DUCK="$SCRIPT_DIR/duckdns.sh"
CF="$SCRIPT_DIR/cloudflare-ddns.sh"
if [[ -f $INSTALL_DIR/duckdns.conf ]]; then
  say "Updating DuckDNS..."
  bash "$DUCK" update
elif [[ -f $INSTALL_DIR/cloudflare.conf ]]; then
  say "Updating Cloudflare DNS records..."
  bash "$CF" update
elif [[ $DOMAIN == *.duckdns.org ]]; then
  bash "$DUCK" setup "$DOMAIN"
  sleep 5  # give the new address a moment
else
  cat <<EOF

Home internet addresses usually change now and then. How should $DOMAIN
keep pointing at this machine?
  1) DuckDNS (free): works with any domain provider, e.g. Squarespace.
     You add 3 records at your provider once; DuckDNS follows your IP.
  2) Cloudflare: your domain's DNS is managed by Cloudflare.
  3) Neither: my IP never changes, or this is a rented server.
EOF
  case "${SNIKKET_DNS_MODE:-}" in
    duckdns)    choice=1 ;;
    cloudflare) choice=2 ;;
    none)       choice=3 ;;
    *)          read -rp "Choose 1, 2 or 3 [3]: " choice || choice=3 ;;
  esac
  case "${choice:-3}" in
    1) bash "$DUCK" setup "${DUCKDNS_NAME:-}" "$DOMAIN" ;;
    2) bash "$CF" setup "$DOMAIN"; sleep 5 ;;
    *) ;;
  esac
fi

# --- 4. DNS check -------------------------------------------------------------

say "Checking DNS records point to this server..."
PUBLIC_IP="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
dns_ok=true
for name in "$DOMAIN" "groups.$DOMAIN" "share.$DOMAIN"; do
  resolved="$(getent ahostsv4 "$name" | awk 'NR==1 {print $1}' || true)"
  if [[ -z $resolved ]]; then
    warn "$name does not resolve yet."
    dns_ok=false
  elif [[ -n $PUBLIC_IP && $resolved != "$PUBLIC_IP" ]]; then
    warn "$name points to $resolved, but this server's public IP is $PUBLIC_IP."
    dns_ok=false
  else
    echo "  ok  $name -> $resolved"
  fi
done
if ! $dns_ok; then
  if [[ -f $INSTALL_DIR/duckdns.conf && $DOMAIN != *.duckdns.org ]]; then
    duck="$(sed -n 's/^DUCKDNS_NAME=//p' "$INSTALL_DIR/duckdns.conf").duckdns.org"
    records="    $DOMAIN          CNAME  $duck
    groups.$DOMAIN   CNAME  $duck
    share.$DOMAIN    CNAME  $duck"
  else
    records="    $DOMAIN          A      ${PUBLIC_IP:-<your server IP>}
    groups.$DOMAIN   CNAME  $DOMAIN
    share.$DOMAIN    CNAME  $DOMAIN"
  fi
  cat >&2 <<EOF

  These DNS records are needed at your domain provider:
$records

  Without them the HTTPS certificate can't be issued and the apps won't connect.
  New records can take a few minutes to start working. If you just added them,
  answer N, wait 5-10 minutes, and run this installer again (that's safe).
EOF
  confirm "Continue anyway?" || exit 1
fi

# --- 5. Ports 80/443 must be free ---------------------------------------------

snikket_running() { command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx snikket-proxy; }

if ! snikket_running && ss -ltnH '( sport = :80 or sport = :443 )' | grep -q .; then
  ss -ltnp '( sport = :80 or sport = :443 )' >&2 || true
  die "Something is already using port 80/443 (see above). Snikket needs these ports.
       Stop that web server, or follow https://snikket.org/service/help/advanced/reverse_proxy/"
fi

# --- 6. Docker ----------------------------------------------------------------

if ! command -v docker >/dev/null; then
  say "Installing Docker (official installer from get.docker.com)..."
  curl -fsSL https://get.docker.com | sh
fi
if ! docker compose version >/dev/null 2>&1; then
  say "Installing the Docker Compose plugin..."
  apt-get install -y -qq docker-compose-plugin >/dev/null \
    || die "Couldn't install 'docker compose'. Install it manually: https://docs.docker.com/compose/install/linux/"
fi
systemctl enable --now docker >/dev/null 2>&1 || true

# --- 7. Firewall --------------------------------------------------------------

if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  say "Opening chat and call ports in ufw..."
  ufw allow 80,443,5000,5222,5269/tcp   >/dev/null  # web, file transfer, apps, federation
  ufw allow 3478:3479/tcp               >/dev/null  # STUN/TURN (call setup)
  ufw allow 3478:3479/udp               >/dev/null
  ufw allow 5349:5350/tcp               >/dev/null  # STUN/TURN over TLS
  ufw allow 5349:5350/udp               >/dev/null
  ufw allow "$TURN_MIN:$TURN_MAX/udp"   >/dev/null  # call audio relay
else
  echo "  ufw is not active, skipping. (If your host has a cloud firewall, open the ports listed in README.md there.)"
fi

# --- 8. Config and start ------------------------------------------------------

say "Writing configuration to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"
cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
[[ -f $SCRIPT_DIR/chat.sh ]] && install -m 755 "$SCRIPT_DIR/chat.sh" /usr/local/bin/chat
if [[ -f $INSTALL_DIR/snikket.conf ]]; then
  # Keep any settings you added; only update domain and email.
  sed -i -e "s|^SNIKKET_DOMAIN=.*|SNIKKET_DOMAIN=$DOMAIN|" \
         -e "s|^SNIKKET_ADMIN_EMAIL=.*|SNIKKET_ADMIN_EMAIL=$EMAIL|" "$INSTALL_DIR/snikket.conf"
  if ! grep -q '^SNIKKET_TWEAK_TURNSERVER_MIN_PORT=' "$INSTALL_DIR/snikket.conf"; then
    printf '\n# UDP ports for relayed call audio\nSNIKKET_TWEAK_TURNSERVER_MIN_PORT=%s\nSNIKKET_TWEAK_TURNSERVER_MAX_PORT=%s\n' \
      "$TURN_MIN" "$TURN_MAX" >> "$INSTALL_DIR/snikket.conf"
  fi
else
  cat > "$INSTALL_DIR/snikket.conf" <<EOF
# Snikket settings. After editing, run: sudo chat restart
SNIKKET_DOMAIN=$DOMAIN
SNIKKET_ADMIN_EMAIL=$EMAIL

# UDP ports for relayed call audio (open/forward the same range).
SNIKKET_TWEAK_TURNSERVER_MIN_PORT=$TURN_MIN
SNIKKET_TWEAK_TURNSERVER_MAX_PORT=$TURN_MAX

# How many days the server keeps messages and shared photos (default 7).
# Phones keep their own full history either way; this is what a new or
# reinstalled phone can download. Remove the # and change the number to keep more.
#SNIKKET_RETENTION_DAYS=365

# Maximum disk space for shared photos/files, in GB (default: no limit).
#SNIKKET_UPLOAD_STORAGE_GB=20
EOF
fi

say "Downloading and starting Snikket (first time takes a minute or two)..."
cd "$INSTALL_DIR"
docker compose pull -q
docker compose up -d

# --- 9. First admin account ---------------------------------------------------

say "Waiting for the server to be ready..."
invite=""
for _ in $(seq 1 60); do
  # create-invite prints "Your invite link: <url>"; keep just the URL.
  out="$(docker exec snikket create-invite --admin --group default 2>/dev/null || true)"
  invite="$(grep -oE 'https://[^[:space:]]+' <<<"$out" | head -n1 || true)"
  [[ -n $invite ]] && break
  sleep 5
done
[[ -n $invite ]] || die "Server didn't come up in time. Check the logs: cd $INSTALL_DIR && docker compose logs"

cat <<EOF

$(printf '\033[1;32m')Your chat server is running!$(printf '\033[0m')

  1. Open this link on your phone to create YOUR (admin) account:

       $invite

     It will tell you to install the Snikket app and set everything up.
     (The link works once; it can take a few minutes for the HTTPS certificate.)

  2. Invite friends:   sudo chat invite
     or from the web:  https://$DOMAIN  ->  log in  ->  Invitations

  Other commands:      sudo chat help
EOF

# A home PC sits behind a router: the internet sees the router's address, not
# this machine's, so the router must pass the ports through.
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") {print $(i + 1); exit}}' || true)"
if [[ -n $PUBLIC_IP && -n $LAN_IP ]] && ! ip -4 -o addr show | grep -qF "inet $PUBLIC_IP/"; then
  cat <<EOF

$(printf '\033[1;33m')This machine is behind a router$(printf '\033[0m') (the internet sees $PUBLIC_IP, this PC is $LAN_IP).
  In your router's "Port forwarding" page, forward these ports to $LAN_IP:

     TCP   80, 443, 5000, 5222, 5269, 3478-3479, 5349-5350
     UDP   3478-3479, 5349-5350, $TURN_MIN-$TURN_MAX

  Then run:  sudo chat restart
  (Skip this if it's a cloud server that just doesn't show its public IP locally,
   like AWS or Oracle; open the ports in the provider's firewall instead.)
EOF
fi
