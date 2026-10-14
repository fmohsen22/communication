#!/usr/bin/env bash
# Keeps a free DuckDNS name (yourname.duckdns.org) pointing at this machine's
# public IP, for a server on a home connection whose IP changes.
# groups.yourname.duckdns.org and share.yourname.duckdns.org follow automatically.
#
#   sudo bash duckdns.sh setup yourname.duckdns.org   # once (install.sh does this for you)
#   sudo snikket-duckdns update                       # what the 5-minute timer runs
set -euo pipefail

CONF=/etc/snikket/duckdns.conf

die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

update() {
  if [[ -z ${DUCKDNS_TOKEN:-} ]]; then
    [[ -r $CONF ]] || die "$CONF not found. Run: sudo bash duckdns.sh setup <name>.duckdns.org"
    # shellcheck disable=SC1090
    source "$CONF"
  fi
  local reply
  # Leaving ip= empty makes DuckDNS use the address this request comes from.
  reply="$(curl -4 -fsS --max-time 20 \
    "https://www.duckdns.org/update?domains=$DUCKDNS_NAME&token=$DUCKDNS_TOKEN&ip=")" \
    || die "Couldn't reach DuckDNS."
  [[ $reply == OK* ]] || die "DuckDNS refused the update (check the name and token)."
}

setup() {
  [[ $EUID -eq 0 ]] || die "Please run as root: sudo bash $0 setup"

  # $2 (optional): your own chat domain, e.g. chat.example.com, which will
  # point at the DuckDNS name through CNAME records.
  local name="${1:-}" site="${2:-}"
  [[ -n $name ]] || read -rp "DuckDNS name (e.g. yourname.duckdns.org): " name
  name="$(tr '[:upper:]' '[:lower:]' <<<"$name")"
  DUCKDNS_NAME="${name%.duckdns.org}"
  [[ $DUCKDNS_NAME =~ ^[a-z0-9-]+$ ]] || die "'$name' should look like yourname.duckdns.org"

  DUCKDNS_TOKEN="${DUCKDNS_TOKEN:-}"
  if [[ -z $DUCKDNS_TOKEN ]]; then
    cat <<EOF

DuckDNS setup: on https://www.duckdns.org (sign in), copy the "token"
shown at the top of the page. Your name "$DUCKDNS_NAME" must already be
added in the "domains" list there.

EOF
    read -rsp "DuckDNS token (hidden while you type/paste): " DUCKDNS_TOKEN; echo
  fi
  [[ $DUCKDNS_TOKEN =~ ^[0-9a-f-]{36}$ ]] || die "That doesn't look like a DuckDNS token."

  echo "Pointing $DUCKDNS_NAME.duckdns.org at this machine..."
  update

  mkdir -p "$(dirname "$CONF")"
  (umask 077; printf 'DUCKDNS_NAME=%q\nDUCKDNS_TOKEN=%q\n' "$DUCKDNS_NAME" "$DUCKDNS_TOKEN" > "$CONF")

  # Copy this script to where the timer runs it (skip if we *are* that copy).
  [[ $(readlink -f "${BASH_SOURCE[0]}") == /usr/local/bin/snikket-duckdns ]] \
    || install -m 755 "${BASH_SOURCE[0]}" /usr/local/bin/snikket-duckdns
  cat > /etc/systemd/system/snikket-duckdns.service <<EOF
[Unit]
Description=Point $DUCKDNS_NAME.duckdns.org at this machine's public IP
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/snikket-duckdns update
EOF
  cat > /etc/systemd/system/snikket-duckdns.timer <<EOF
[Unit]
Description=Check the public IP for $DUCKDNS_NAME.duckdns.org every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now snikket-duckdns.timer >/dev/null 2>&1
  echo "Done. $DUCKDNS_NAME.duckdns.org will follow your home IP automatically (checked every 5 minutes)."

  if [[ -n $site && $site != *.duckdns.org ]]; then
    cat <<EOF

Now point $site at it. At your domain provider (Squarespace: Domains ->
your domain -> DNS -> Custom records -> Add record), add these 3 records.
Don't change or delete your existing records.

    Name / Host                      Type    Data / Value
    $(printf '%-32s' "$site") CNAME   $DUCKDNS_NAME.duckdns.org
    $(printf '%-32s' "groups.$site") CNAME   $DUCKDNS_NAME.duckdns.org
    $(printf '%-32s' "share.$site") CNAME   $DUCKDNS_NAME.duckdns.org

  Most providers only want the part before your main domain in "Host",
  e.g. for chat.example.com: "chat", "groups.chat" and "share.chat".

EOF
    read -rp "Press Enter once you've added them... " _ || true
  fi
}

case "${1:-}" in
  setup)  shift; setup "$@" ;;
  update) update ;;
  *)      echo "Usage: sudo bash $0 setup <name>.duckdns.org   |   snikket-duckdns update" >&2; exit 1 ;;
esac
