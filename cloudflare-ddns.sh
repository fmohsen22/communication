#!/usr/bin/env bash
# Points your domain's Cloudflare DNS records at this machine's public IP and
# keeps them updated, for a server on a home connection whose IP changes.
#
#   sudo bash cloudflare-ddns.sh setup chat.example.com   # once (install.sh can do this for you)
#   sudo snikket-ddns update                              # what the 5-minute timer runs
#
# Creates/updates:  chat.example.com A -> your IP
#                   groups.chat.example.com and share.chat.example.com CNAME -> chat.example.com
set -euo pipefail

CONF=/etc/snikket/cloudflare.conf
API=https://api.cloudflare.com/client/v4

die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# cf METHOD PATH [JSON-BODY]: call the Cloudflare API and print the response.
cf() {
  local args=(-sS --max-time 20 -X "$1" "$API$2"
              -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json")
  [[ $# -ge 3 ]] && args+=(--data "$3")
  local out
  out="$(curl "${args[@]}")" || die "Couldn't reach Cloudflare."
  [[ $(jq -r '.success' <<<"$out" 2>/dev/null) == true ]] \
    || die "Cloudflare refused the request: $(jq -c '.errors' <<<"$out" 2>/dev/null || echo "$out")"
  printf '%s' "$out"
}

public_ip() {
  local ip
  ip="$(curl -4 -fsS --max-time 10 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' || true)"
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ip="$(curl -4 -fsS --max-time 10 https://api.ipify.org || true)"
  [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Couldn't find this machine's public IP. Is the internet up?"
  printf '%s' "$ip"
}

# upsert TYPE NAME CONTENT: make sure exactly this record exists, "DNS only" (not proxied).
upsert() {
  local type=$1 name=$2 content=$3 found id current proxied body
  found="$(cf GET "/zones/$CF_ZONE_ID/dns_records?type=$type&name=$name")"
  id="$(jq -r '.result[0].id // empty' <<<"$found")"
  current="$(jq -r '.result[0].content // empty' <<<"$found")"
  proxied="$(jq -r '.result[0].proxied // false' <<<"$found")"
  body="$(jq -nc --arg t "$type" --arg n "$name" --arg c "$content" \
    '{type: $t, name: $n, content: $c, ttl: 1, proxied: false}')"
  if [[ -z $id ]]; then
    cf POST "/zones/$CF_ZONE_ID/dns_records" "$body" >/dev/null
    echo "  created  $name -> $content"
  elif [[ $current != "$content" || $proxied != false ]]; then
    cf PUT "/zones/$CF_ZONE_ID/dns_records/$id" "$body" >/dev/null
    echo "  updated  $name -> $content"
  fi
}

update() {
  if [[ -z ${CF_API_TOKEN:-} ]]; then
    [[ -r $CONF ]] || die "$CONF not found. Run: sudo bash cloudflare-ddns.sh setup <domain>"
    # shellcheck disable=SC1090
    source "$CONF"
  fi
  local ip
  ip="$(public_ip)"
  upsert A     "$CF_DOMAIN"        "$ip"
  upsert CNAME "groups.$CF_DOMAIN" "$CF_DOMAIN"
  upsert CNAME "share.$CF_DOMAIN"  "$CF_DOMAIN"
}

setup() {
  [[ $EUID -eq 0 ]] || die "Please run as root: sudo bash $0 setup"
  command -v jq >/dev/null && command -v curl >/dev/null \
    || apt-get install -y -qq jq curl ca-certificates >/dev/null

  CF_DOMAIN="${1:-}"
  [[ -n $CF_DOMAIN ]] || read -rp "Chat domain (e.g. chat.example.com): " CF_DOMAIN
  CF_DOMAIN="$(tr '[:upper:]' '[:lower:]' <<<"$CF_DOMAIN")"

  CF_ZONE_ID="${CF_ZONE_ID:-}"
  CF_API_TOKEN="${CF_API_TOKEN:-}"
  if [[ -z $CF_ZONE_ID || -z $CF_API_TOKEN ]]; then
    cat <<EOF

Cloudflare setup: copy two things from https://dash.cloudflare.com

  1. Zone ID: click your domain. On its Overview page, scroll down. It's on
     the right, under "API".
  2. API token: profile icon (top right) -> My Profile -> API Tokens ->
     Create Token -> "Edit zone DNS" template -> Zone Resources: your domain
     -> Continue to summary -> Create Token. Copy it (it's shown only once).

EOF
    [[ -n $CF_ZONE_ID ]]   || read -rp "Zone ID: " CF_ZONE_ID
    [[ -n $CF_API_TOKEN ]] || { read -rsp "API token (hidden while you type/paste): " CF_API_TOKEN; echo; }
  fi
  [[ $CF_ZONE_ID =~ ^[0-9a-f]{32}$ ]] || die "That doesn't look like a Zone ID (32 letters/numbers)."

  echo "Checking the token..."
  cf GET "/zones/$CF_ZONE_ID/dns_records?per_page=1" >/dev/null

  mkdir -p "$(dirname "$CONF")"
  (umask 077; printf 'CF_DOMAIN=%q\nCF_ZONE_ID=%q\nCF_API_TOKEN=%q\n' \
    "$CF_DOMAIN" "$CF_ZONE_ID" "$CF_API_TOKEN" > "$CONF")

  echo "Setting DNS records..."
  update

  # Copy this script to where the timer runs it (skip if we *are* that copy).
  [[ $(readlink -f "${BASH_SOURCE[0]}") == /usr/local/bin/snikket-ddns ]] \
    || install -m 755 "${BASH_SOURCE[0]}" /usr/local/bin/snikket-ddns
  cat > /etc/systemd/system/snikket-ddns.service <<EOF
[Unit]
Description=Point $CF_DOMAIN at this machine's public IP (Cloudflare)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snikket-ddns update
EOF
  cat > /etc/systemd/system/snikket-ddns.timer <<EOF
[Unit]
Description=Check the public IP for $CF_DOMAIN every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now snikket-ddns.timer >/dev/null 2>&1
  echo "DNS is set. It will follow your home IP automatically (checked every 5 minutes)."
}

case "${1:-}" in
  setup)  shift; setup "$@" ;;
  update) update ;;
  *)      echo "Usage: sudo bash $0 setup <chat-domain>   |   snikket-ddns update" >&2; exit 1 ;;
esac
