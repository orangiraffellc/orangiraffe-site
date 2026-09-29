#!/usr/bin/env bash
# Run on the VPS as root: bash /opt/orangiraffe/deploy/enable-site.sh
#
# Installs the orangiraffe.com Caddy site block, but only once DNS for both
# names points at this box (A only, no AAAA). A site block for a name that does
# not resolve here makes Caddy retry certificate issuance and burns Let's
# Encrypt rate limits, so this refuses until DNS is right. Safe to re-run.
#
# Touches exactly one shared file, /opt/caddy-sites/orangiraffe.com.caddy, and
# applies it with a zero-downtime reload. If anything fails, or dromotelo.com
# stops answering, it removes that file and reloads again.
set -euo pipefail

IP=67.217.240.31
SRC=/opt/orangiraffe/deploy/orangiraffe.com.caddy
SITES=/opt/caddy-sites
DST=$SITES/orangiraffe.com.caddy
CADDY=dromotelo-caddy

[ "$(id -u)" = 0 ] || { echo "Run as root." >&2; exit 1; }
[ -f "$SRC" ] || { echo "Missing $SRC (deploy the site first)." >&2; exit 1; }

a_records() {
  if command -v dig >/dev/null 2>&1; then
    dig +short A "$1" @1.1.1.1 | grep -E '^[0-9.]+$' | sort -u | tr '\n' ' ' || true
  else
    python3 -c 'import socket,sys; print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1],None,socket.AF_INET)})))' "$1" 2>/dev/null || true
  fi
}
aaaa_records() {
  if command -v dig >/dev/null 2>&1; then
    dig +short AAAA "$1" @1.1.1.1 | grep ':' | sort -u | tr '\n' ' ' || true
  else
    python3 -c 'import socket,sys; print(" ".join(sorted({a[4][0] for a in socket.getaddrinfo(sys.argv[1],None,socket.AF_INET6)})))' "$1" 2>/dev/null || true
  fi
}
code() { curl -s -o /dev/null -m 10 -w '%{http_code}' --resolve "$1:443:127.0.0.1" "https://$1${2:-/}" || true; }
reload() { docker exec "$CADDY" caddy reload --config /etc/caddy/Caddyfile; }
rollback() {
  echo "!! Rolling back: removing $DST and reloading Caddy."
  rm -f "$DST"
  reload || true
}

echo "==> DNS"
ok=1
for h in orangiraffe.com www.orangiraffe.com; do
  a=$(a_records "$h" | xargs); six=$(aaaa_records "$h" | xargs)
  echo "    $h  A: ${a:-none}  AAAA: ${six:-none}"
  [ "$a" = "$IP" ] || ok=0
  [ -z "$six" ] || ok=0
done
if [ "$ok" != 1 ]; then
  cat <<MSG

DNS is not ready, so the site block was NOT installed (this protects the
certificate rate limits). Both names need exactly one A record, $IP,
and no AAAA record. Fix the records at Porkbun, wait a few minutes, then run:

    bash /opt/orangiraffe/deploy/enable-site.sh
MSG
  exit 2
fi

echo "==> upstream reachable from Caddy"
UP=$(docker exec "$CADDY" wget -qO- http://orangiraffe-web/ 2>&1 || true)
echo "$UP" | grep -q 'Orangiraffe LLC' \
  || { echo "Caddy cannot reach orangiraffe-web on the proxy network. Not installing." >&2; exit 1; }

DROMO_BEFORE=$(code dromotelo.com)
echo "    dromotelo.com before: $DROMO_BEFORE"

echo "==> installing $DST"
cp "$SRC" "$SITES/.orangiraffe.tmp"
chown orangiraffe:orangiraffe "$SITES/.orangiraffe.tmp"
chmod 644 "$SITES/.orangiraffe.tmp"
mv "$SITES/.orangiraffe.tmp" "$DST"

if ! docker exec "$CADDY" caddy validate --config /etc/caddy/Caddyfile >/tmp/orangiraffe-validate.log 2>&1; then
  tail -5 /tmp/orangiraffe-validate.log
  echo "Config did not validate." >&2
  rm -f "$DST"; exit 1
fi
reload || { echo "Reload rejected; running config unchanged." >&2; rm -f "$DST"; exit 1; }

echo "==> waiting for the certificate"
c=000
for _ in $(seq 1 40); do
  c=$(code orangiraffe.com)
  [ "$c" = 200 ] && break
  sleep 3
done

W=$(curl -s -o /dev/null -m 10 -w '%{http_code} %{redirect_url}' --resolve www.orangiraffe.com:443:127.0.0.1 https://www.orangiraffe.com/privacy || true)
P=$(code orangiraffe.com /privacy)
L=$(code orangiraffe.com /legal)
# Honeypot-filled submission: exercises Caddy -> nginx -> form without sending email.
F=$(curl -s -o /dev/null -m 15 -w '%{http_code} %{redirect_url}' --resolve orangiraffe.com:443:127.0.0.1 \
  -d 'website=selftest&name=selftest&email=selftest%40example.com&message=selftest' https://orangiraffe.com/api/contact || true)
DROMO_AFTER=$(code dromotelo.com)

echo
echo "    https://orangiraffe.com/          $c"
echo "    https://orangiraffe.com/privacy   $P"
echo "    https://orangiraffe.com/legal     $L"
echo "    https://www.orangiraffe.com/...   $W"
echo "    contact form (no email sent)      $F"
echo "    https://dromotelo.com/            $DROMO_AFTER (before: $DROMO_BEFORE)"

if [ "$DROMO_BEFORE" = 200 ] && [ "$DROMO_AFTER" != 200 ]; then
  echo "!! dromotelo.com stopped answering after this change." >&2
  rollback
  echo "   After rollback dromotelo.com: $(code dromotelo.com)" >&2
  exit 1
fi

if [ "$c" = 200 ] && [ "$P" = 200 ] && [ "$L" = 200 ] && [ "$W" = "301 https://orangiraffe.com/privacy" ] \
   && [ "$F" = "303 https://orangiraffe.com/thanks" ]; then
  echo
  echo "ORANGIRAFFE.COM IS LIVE with a valid certificate. dromotelo.com: $DROMO_AFTER"
else
  echo
  echo "Not fully up yet. Certificate issuance can take a minute; re-run this script."
  echo "Caddy log lines for this domain:"
  docker logs --since 5m "$CADDY" 2>&1 | grep -i 'orangiraffe.com' | grep -v 'brief\.' | tail -8 || true
  exit 3
fi
