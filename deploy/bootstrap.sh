#!/usr/bin/env bash
# One-time setup of orangiraffe.com on the shared VPS. Run as root, with a terminal.
# Public repo, from any root console (including the IONOS browser console):
#   git clone https://github.com/orangiraffellc/orangiraffe-site /root/og && bash /root/og/deploy/bootstrap.sh
# Private repo, over SSH:
#   ssh -t root@67.217.240.31 "bash /root/bootstrap.sh"
#
# Creates the isolated 'orangiraffe' project (user, /opt/orangiraffe, bare repo
# with deploy hook), reads the repo over HTTPS if public or through a read-only
# deploy key if private, deploys main from
# github.com/orangiraffellc/orangiraffe-site, keeps pulling it every 2 minutes,
# asks for the inbox password, then enables orangiraffe.com in the shared Caddy
# only if DNS already points here. Touches no other project. Safe to re-run.
set -euo pipefail
# Commands run as the project user must not inherit an unreadable cwd (/root).
cd /
P=orangiraffe
HOME_DIR=/opt/$P
BARE=/opt/$P.git
ENVF=$HOME_DIR/.env
REPO=orangiraffellc/orangiraffe-site
REMOTE=git@github.com:$REPO.git
HTTPS_URL=https://github.com/$REPO.git
KEY=$HOME_DIR/.ssh/github_deploy
# GitHub's published ed25519 host key fingerprint.
GITHUB_FP=SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU

[ "$(id -u)" = 0 ] || { echo "Run this as root on the VPS." >&2; exit 1; }
# ORANGIRAFFE_NONINTERACTIVE=1 runs without a terminal (for example from a CI
# job): it needs the repo to be public, and leaves the inbox password for later.
NONINTERACTIVE=${ORANGIRAFFE_NONINTERACTIVE:-0}
if [ "$NONINTERACTIVE" != 1 ]; then
  ( : </dev/tty ) 2>/dev/null || { echo "Needs a terminal: run it with ssh -t." >&2; exit 1; }
fi
as_p() { sudo -u "$P" -H "$@"; }

echo "==> preflight"
docker ps --format '{{.Names}}' | grep -qx dromotelo-caddy || { echo "dromotelo-caddy is not running here. Is this the VPS (67.217.240.31)? Stopping." >&2; exit 1; }
docker network inspect proxy >/dev/null 2>&1 || { echo "Shared 'proxy' network missing. Stopping." >&2; exit 1; }
if grep -lE '^[[:space:]]*(https?://)?(www\.)?orangiraffe\.com([[:space:]]|,|\{|$)' /opt/caddy-sites/*.caddy 2>/dev/null | grep -vx /opt/caddy-sites/orangiraffe.com.caddy; then
  echo "Another Caddy file already serves orangiraffe.com (listed above). Stopping." >&2; exit 1
fi

echo "==> user $P"
if id "$P" >/dev/null 2>&1; then echo "    exists"; else
  adduser --system --group --home "$HOME_DIR" --shell /bin/bash "$P" >/dev/null
fi
usermod -aG docker "$P"
install -d -o "$P" -g "$P" -m 755 "$HOME_DIR"
install -d -o "$P" -g "$P" -m 700 "$HOME_DIR/.ssh"
# Inbox password hash lives here (written by deploy/set-inbox-password.sh).
[ -f "$ENVF" ] || install -o "$P" -g "$P" -m 600 /dev/null "$ENVF"
# Messages database. The form container runs as uid 65534 (nobody).
install -d -o 65534 -g 65534 -m 700 "$HOME_DIR/data"

echo "==> bare repo $BARE"
[ -d "$BARE" ] || git init -q --bare --initial-branch=main "$BARE"
cat > "$BARE/hooks/post-receive" <<HOOK
#!/usr/bin/env bash
# Deploy hook: check out the pushed commit and (re)start this project only.
set -euo pipefail
export GIT_DIR=$BARE
WORK_TREE=$HOME_DIR
while read -r _old _new ref; do
  [ "\$ref" = "refs/heads/main" ] || continue
  echo "[deploy] checking out main into \$WORK_TREE"
  git --git-dir="\$GIT_DIR" --work-tree="\$WORK_TREE" checkout -f main
  cd "\$WORK_TREE"
  echo "[deploy] starting"
  docker compose -p $P -f docker-compose.prod.yml up -d --build
  echo "[deploy] done"
done
HOOK
chmod +x "$BARE/hooks/post-receive"
chown -R "$P:$P" "$BARE"

echo "==> GitHub access"
# A public repo is read over HTTPS with no key. A private one needs a
# read-only deploy key, which the server generates and you add on GitHub.
if as_p env GIT_TERMINAL_PROMPT=0 git ls-remote -q "$HTTPS_URL" main >/dev/null 2>&1; then
  REMOTE=$HTTPS_URL
  echo "    public repo, reading over HTTPS (no key needed)"
elif [ "$NONINTERACTIVE" = 1 ]; then
  echo "The repo is not public, and a deploy key needs a terminal. Stopping." >&2; exit 1
else
  [ -f "$KEY" ] || as_p ssh-keygen -q -t ed25519 -N "" -C "orangiraffe VPS deploy (read-only)" -f "$KEY"
  SCAN=$(ssh-keyscan -t ed25519 github.com 2>/dev/null)
  FP=$(printf '%s\n' "$SCAN" | ssh-keygen -lf - | awk '{print $2}')
  [ "$FP" = "$GITHUB_FP" ] || { echo "GitHub host key fingerprint mismatch ($FP). Stopping." >&2; exit 1; }
  printf '%s\n' "$SCAN" > "$HOME_DIR/.ssh/known_hosts"
  cat > "$HOME_DIR/.ssh/config" <<CFG
Host github.com
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking yes
CFG
  chown "$P:$P" "$HOME_DIR/.ssh/known_hosts" "$HOME_DIR/.ssh/config"
  chmod 600 "$HOME_DIR/.ssh/config"

  TRIES=0
  until ERR=$(as_p git ls-remote -q "$REMOTE" main 2>&1 >/dev/null); do
    TRIES=$((TRIES + 1))
    [ "$TRIES" -gt 1 ] && echo "    Still no access. GitHub said: $(printf '%s' "$ERR" | tail -n 1)"
    cat <<MSG

    The server needs read access to github.com/$REPO.
    1. Open https://github.com/$REPO/settings/keys/new
    2. Title: VPS   Key: paste the line below   Leave "Allow write access" UNTICKED
    3. Click "Add key", then come back here and press Enter.

$(cat "$KEY.pub")

MSG
    read -r -p "    Press Enter once the key is added (Ctrl+C to stop): " _ </dev/tty
  done
fi
if as_p git --git-dir="$BARE" remote get-url github >/dev/null 2>&1; then
  as_p git --git-dir="$BARE" remote set-url github "$REMOTE"
else
  as_p git --git-dir="$BARE" remote add github "$REMOTE"
fi
echo "    GitHub access OK ($REMOTE)"

echo "==> deploy from GitHub"
as_p git --git-dir="$BARE" fetch -q github '+refs/heads/main:refs/remotes/github/main'
NEW=$(as_p git --git-dir="$BARE" rev-parse refs/remotes/github/main)
CUR=$(as_p git --git-dir="$BARE" rev-parse -q --verify refs/heads/main || true)
if [ "$NEW" != "$CUR" ]; then
  as_p git --git-dir="$BARE" push -f "$BARE" refs/remotes/github/main:refs/heads/main 2>&1 | sed 's/^/    /'
else
  echo "    already at ${NEW:0:7}"
fi

echo "==> auto-deploy every 2 minutes"
CRON="*/2 * * * * $HOME_DIR/deploy/pull-deploy.sh"
( crontab -u "$P" -l 2>/dev/null | grep -vF "$HOME_DIR/deploy/pull-deploy.sh" || true; echo "$CRON" ) | crontab -u "$P" -
echo "    installed: $CRON"

echo "==> containers"
as_p bash -c "cd $HOME_DIR && docker compose -p $P -f docker-compose.prod.yml up -d" 2>&1 | sed 's/^/    /'
OUTP=""
for _ in $(seq 1 30); do
  OUTP=$(docker exec orangiraffe-web wget -qO- http://127.0.0.1/ 2>/dev/null || true)
  echo "$OUTP" | grep -q 'Orangiraffe LLC' && break
  sleep 1
done
echo "$OUTP" | grep -q 'Orangiraffe LLC' || { echo "orangiraffe-web is not serving the page." >&2; docker logs --tail 20 orangiraffe-web; exit 1; }
HZ=""
for _ in $(seq 1 30); do
  HZ=$(docker exec orangiraffe-web wget -qO- http://form:8000/healthz 2>/dev/null || true)
  [ -n "$HZ" ] && break
  sleep 1
done
[ -n "$HZ" ] || { echo "orangiraffe-form is not answering." >&2; docker logs --tail 20 orangiraffe-form; exit 1; }
echo "    orangiraffe-web:  $(docker ps --filter name=^orangiraffe-web$ --format '{{.Status}}')"
echo "    orangiraffe-form: $(docker ps --filter name=^orangiraffe-form$ --format '{{.Status}}')"

echo "==> inbox password"
if grep -q '^INBOX_PASSWORD_HASH=.' "$ENVF"; then
  echo "    already set (change it any time: bash $HOME_DIR/deploy/set-inbox-password.sh)"
elif [ "$NONINTERACTIVE" = 1 ]; then
  echo "    not set yet. The form still saves messages; the inbox says 'not set up'."
  echo "    Set it later from a terminal: bash $HOME_DIR/deploy/set-inbox-password.sh"
else
  echo "    Choose the username and password for https://orangiraffe.com/inbox"
  bash "$HOME_DIR/deploy/set-inbox-password.sh"
fi

echo "==> Caddy site (DNS-gated)"
bash "$HOME_DIR/deploy/enable-site.sh"
