#!/usr/bin/env bash
# Runs every 2 minutes as the orangiraffe user (cron). Fetches main from GitHub
# over a read-only deploy key and, when it moved, pushes it into the local bare
# repo, whose post-receive hook checks it out and restarts this project only.
# GitHub is the source of truth: a force-push there is followed here.
set -euo pipefail
# Never wait for a password prompt (cron has no terminal).
export GIT_TERMINAL_PROMPT=0
BARE=/opt/orangiraffe.git
LOG=/opt/orangiraffe/deploy.log

# Keep the log small.
if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG")" -gt 1000000 ]; then
  tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi
exec >>"$LOG" 2>&1

exec 9>"$BARE/pull.lock"
flock -n 9 || exit 0

git --git-dir="$BARE" fetch -q github '+refs/heads/main:refs/remotes/github/main' \
  || { echo "$(date -u +%FT%TZ) fetch from GitHub failed"; exit 1; }
new=$(git --git-dir="$BARE" rev-parse -q --verify refs/remotes/github/main) || exit 0
cur=$(git --git-dir="$BARE" rev-parse -q --verify refs/heads/main || true)
[ "$new" = "$cur" ] && exit 0

echo "$(date -u +%FT%TZ) deploying ${new:0:7} (was ${cur:0:7})"
git --git-dir="$BARE" push -q -f "$BARE" refs/remotes/github/main:refs/heads/main
echo "$(date -u +%FT%TZ) deployed ${new:0:7}"
