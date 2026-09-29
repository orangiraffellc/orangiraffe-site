#!/usr/bin/env bash
# Run on the VPS as root: bash /opt/orangiraffe/deploy/set-inbox-password.sh
#
# Sets the username and password for https://orangiraffe.com/inbox. Only a
# PBKDF2 hash is stored, in /opt/orangiraffe/.env. Re-run any time to change it.
set -euo pipefail
P=orangiraffe
HOME_DIR=/opt/$P
ENVF=$HOME_DIR/.env

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
( : </dev/tty ) 2>/dev/null || { echo "Needs a terminal (use ssh -t)." >&2; exit 1; }
docker ps --format '{{.Names}}' | grep -qx orangiraffe-form || { echo "orangiraffe-form is not running." >&2; exit 1; }

while :; do
  read -r -p "Inbox username [admin]: " U </dev/tty
  U=${U:-admin}
  [[ "$U" =~ ^[A-Za-z0-9._-]{1,40}$ ]] && break
  echo "Use letters, digits, dot, dash or underscore."
done
while :; do
  read -r -s -p "Inbox password (at least 12 characters, hidden): " P1 </dev/tty; echo >/dev/tty
  read -r -s -p "Repeat the password: " P2 </dev/tty; echo >/dev/tty
  [ "$P1" = "$P2" ] || { echo "They do not match. Try again."; continue; }
  [ "${#P1}" -ge 12 ] || { echo "Too short. Use at least 12 characters."; continue; }
  break
done

H=$(printf '%s' "$P1" | docker exec -i orangiraffe-form python3 /app/contact.py --hash-password)
unset P1 P2
[[ "$H" == pbkdf2_sha256:* ]] || { echo "Could not hash the password." >&2; exit 1; }

( umask 077
  { grep -vE '^(INBOX_USER|INBOX_PASSWORD_HASH)=' "$ENVF" 2>/dev/null || true
    printf 'INBOX_USER=%s\nINBOX_PASSWORD_HASH=%s\n' "$U" "$H"; } > "$ENVF.tmp" )
mv "$ENVF.tmp" "$ENVF"
chown "$P:$P" "$ENVF"; chmod 600 "$ENVF"

sudo -u "$P" -H bash -c "cd $HOME_DIR && docker compose -p $P -f docker-compose.prod.yml up -d --force-recreate form" 2>&1 | sed 's/^/    /'
echo "Inbox password set for user '$U'. Open https://orangiraffe.com/inbox"
