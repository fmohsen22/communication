#!/usr/bin/env bash
# Day-to-day helper for the Snikket server. install.sh copies it to
# /usr/local/bin/chat, so you can run e.g. `sudo chat invite`.
set -euo pipefail

INSTALL_DIR=/etc/snikket
BACKUP_DIR=/var/backups/snikket

die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Please run as root: sudo $(basename "$0") ${1:-help}"
cd "$INSTALL_DIR" 2>/dev/null || die "$INSTALL_DIR not found. Run install.sh first."

data_volume() {
  docker volume ls -q | grep -E '(^|_)snikket_data$' | head -n1
}

case "${1:-help}" in
  invite)
    echo "Send this link to your friend (works once):"
    docker exec snikket create-invite --group default
    ;;
  admin-invite)
    echo "Admin invite link (works once):"
    docker exec snikket create-invite --admin --group default
    ;;
  status)
    docker compose ps
    ;;
  logs)
    docker compose logs -f --tail=100
    ;;
  restart)
    # Recreates the containers so changes in snikket.conf take effect.
    docker compose up -d --force-recreate
    ;;
  update)
    docker compose pull
    docker compose up -d
    docker image prune -f
    ;;
  backup)
    vol="$(data_volume)"
    [[ -n $vol ]] || die "Couldn't find the snikket_data volume."
    mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$vol")"
    mkdir -p "$BACKUP_DIR"
    file="$BACKUP_DIR/snikket-$(date +%Y%m%d-%H%M%S).tar.gz"
    echo "Stopping Snikket briefly for a consistent backup..."
    docker compose stop
    trap 'docker compose start >/dev/null' EXIT
    tar -czf "$file" -C "$mountpoint" .
    echo "Backup saved: $file"
    echo "It contains all accounts, messages and photos. Copy it somewhere safe (off this server)."
    ;;
  help|*)
    cat <<EOF
Usage: sudo chat <command>

  invite         Create an invite link for a friend
  admin-invite   Create an invite link for another admin
  status         Show whether the containers are running
  logs           Follow the server logs (Ctrl+C to stop)
  restart        Restart everything (also applies changes to snikket.conf)
  update         Download the latest Snikket version and restart
  backup         Save all accounts, messages and photos to $BACKUP_DIR
EOF
    ;;
esac
