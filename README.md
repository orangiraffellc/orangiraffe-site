# orangiraffe.com

Company website for Orangiraffe LLC. Plain static HTML and CSS: no build step,
no cookies, no analytics, no external resources. The only JavaScript is our own
small files for the contact form's spam check and the inbox.

## Layout

```
public/                  what the site serves
  index.html             home: company, apps, contact
  privacy.html           privacy policy for this website (apps link out)
  legal.html             company details and website terms
  pickwar-privacy.html   PickWar app privacy policy (URL is in the Play Console: never move it)
  404.html
  assets/site.css        all styles, light and dark mode
  assets/logo.png        horizontal logo (header), from the original Illustrator artwork
  assets/mark.png        round icon (hero), from the original icon PNG
  assets/dromotelo.png   Dromotelo app icon
  assets/pickwar.png     PickWar app icon (256 px, from the owner)
  assets/hodolog.png     Hodolog app icon (256 px, rendered from app/icon.svg in orangiraffellc/travel)
  thanks.html, contact-error.html   where the contact form redirects
  assets/inbox.js        inbox conveniences (select all, local times, confirm)
  assets/contact.js      contact form spam check (proof of work, link warning)
  assets/nav.js          phone menu button (links show as a row without JavaScript)
  favicon.png, apple-touch-icon.png, robots.txt, sitemap.xml
form/contact.py          contact form + private inbox (Python stdlib only, SQLite)
nginx.conf               clean URLs, 404 page, forwards /api/contact and /inbox to the form
docker-compose.prod.yml  orangiraffe-web (nginx) on the proxy network + orangiraffe-form
deploy/orangiraffe.com.caddy   site block for the shared Caddy
deploy/enable-site.sh    root: installs the site block once DNS is right, verifies, rolls back on harm
deploy/set-inbox-password.sh   root: sets the inbox username and password
deploy/bootstrap.sh      root, once: project user, deploy key, first deploy, cron, Caddy
deploy/pull-deploy.sh    cron: pulls main from GitHub and deploys when it changed
deploy/health-status.sh  cron (via pull-deploy): writes public/status.txt for the server check
.github/workflows/server-check.yml   hourly outside check of the whole VPS, emails on failure
```

The site deliberately shows no address, phone or email. People reach the
company through the contact form.

Caching: nginx tells browsers to keep `/assets/` for 7 days. Every page links
CSS and JS with a version (`site.css?v=4`, `nav.js?v=1`, `contact.js?v=1`);
bump it in every page (and in `form/contact.py` for site.css) whenever that
file changes, or visitors keep the old copy for up to a week.

Copy rules: no em dashes or en dashes (plain hyphens only), no emojis, and do not
claim Play Store availability or integrations that are not live.

Logos come from the owner's originals in Google Drive: `Orangiraffe.pdf`
(Illustrator vector; the horizontal lockup, rendered at 600 dpi with a transparent
background) and `Orangiraffe Icon.png` (512 px). The favicons are resized from
the icon. Brand colors, from `Orangiraffe_colors.pdf`: black #231F20, dark gray
#4D4D4F, light gray #DCDDDE, orange #F7941E. The stylesheet uses only these plus
white. Orange text on white fails contrast, so links are black with an orange
underline.

## Hosting

Runs on the shared IONOS VPS (67.217.240.31) behind the `dromotelo-caddy` proxy,
following the box's project layout:

| Thing | Value |
| --- | --- |
| Unix user | `orangiraffe` |
| Working tree | `/opt/orangiraffe` |
| Source | GitHub `orangiraffellc/orangiraffe-site`, pulled every 2 minutes |
| Bare repo | `/opt/orangiraffe.git` (deploy hook; fed by `pull-deploy.sh`) |
| Containers | `orangiraffe-web`, `orangiraffe-form`, compose project `orangiraffe`, no host ports |
| Secrets | `/opt/orangiraffe/.env` (inbox password hash, mode 600, not in git) |
| Data | `/opt/orangiraffe/data/messages.db` (not in git) |
| Caddy site | `/opt/caddy-sites/orangiraffe.com.caddy` |

Why a container instead of a Caddy `file_server`: the shared Caddy only has
`/opt/caddy-sites` mounted, so it cannot read files under `/opt/orangiraffe`.
A 64 MB nginx container serves `public/` (bind-mounted read-only), and Caddy
proxies to it by name. Since the content is bind-mounted, a deploy is live as
soon as the hook checks out the new commit.

## Contact form and inbox

`form/contact.py` (Python stdlib only, container `orangiraffe-form`):

- `POST /api/contact`: the home page form. Saves the message to
  SQLite at `/opt/orangiraffe/data/messages.db`, then redirects to `/thanks`
  or `/contact-error`. No email service is involved.
- `https://orangiraffe.com/inbox`: private list of messages behind HTTP Basic
  auth, with select all, delete selected and delete all. Each sender's email
  is a mailto link for replying.

Spam control, all on our own server (no CAPTCHA service, nothing third party):

- 5 submissions per IP per hour.
- A hidden honeypot field.
- Proof of work: while the visitor fills in the form, `assets/contact.js` has
  the browser find a nonce so that SHA-256 of `orangiraffe-contact:<salt>:<nonce>`
  starts with 16 zero bits (about a second). The server checks it and refuses
  a salt it has seen before (table `pow_used`, kept 30 days). Scripts that post
  the form without running the page fail here.
- At least 3 seconds between opening the page and sending.
- No links (`http`, `www.`, HTML/BBCode links, or a domain followed by a path).
  The page tells people to remove them; the server drops any that get past.
- 100 accepted messages per day overall (blocked ones do not count), and at
  most 5000 stored.

Anything that fails a spam check is dropped while the sender is shown the
normal "sent" page, so bots learn nothing. The exception is a post with no
proof-of-work fields at all, which gets the error page ("reload and try
again"), in case it is a person on a cached copy of the old page. The inbox shows how many were
blocked since the form service last started. The form needs JavaScript; a
`<noscript>` note says so. Bots that drive a full browser can still pass; if
that becomes a problem, the next step is Cloudflare Turnstile, which would
need a CSP change in the Caddy block and a privacy policy update.

IP addresses are never stored.
Ten failed inbox sign-ins from one IP lock it out for 15 minutes.

Set or change the inbox username and password, as root on the VPS:

```
bash /opt/orangiraffe/deploy/set-inbox-password.sh
```

It stores only a PBKDF2 hash in `/opt/orangiraffe/.env` (mode 600, not in git).

Backup is one file: `/opt/orangiraffe/data/messages.db`.

## Updating

Push to `main` on GitHub (`orangiraffellc/orangiraffe-site`). The VPS checks
every 2 minutes (cron, as the `orangiraffe` user, `deploy/pull-deploy.sh`),
fetches `main` (over HTTPS if the repo is public, else a read-only deploy
key), and pushes it into the local bare
repo `/opt/orangiraffe.git`, whose `post-receive` hook runs `git checkout -f
main` into `/opt/orangiraffe` and `docker compose -p orangiraffe -f
docker-compose.prod.yml up -d`. Deploy history: `/opt/orangiraffe/deploy.log`.

Nothing on GitHub can write to the server, and no server key is stored on
GitHub: the server only reads.

First-time setup is `deploy/bootstrap.sh`, run once as root with a terminal.
If the repo is public, the server reads it over HTTPS with no key, and one line
in any root console does everything:

```
git clone https://github.com/orangiraffellc/orangiraffe-site /root/og && bash /root/og/deploy/bootstrap.sh
```

If the repo is private, the script generates a read-only deploy key and asks
you to add it on GitHub (so run it from a terminal you can copy from):

```
scp deploy/bootstrap.sh root@67.217.240.31:/root/
ssh -t root@67.217.240.31 "bash /root/bootstrap.sh"
```

If you change `deploy/orangiraffe.com.caddy`, push, wait for the deploy, then as
root run `bash /opt/orangiraffe/deploy/enable-site.sh`. It copies the block to
`/opt/caddy-sites/orangiraffe.com.caddy`, validates, reloads (never restarts)
Caddy, checks both sites, and rolls back if dromotelo.com stops answering.

## Server check (alerts)

IONOS alarms can only see CPU from outside the VM, not disk space or memory.
So every 2 minutes `pull-deploy.sh` runs `deploy/health-status.sh`, which
writes `https://orangiraffe.com/status.txt` (disk %, memory %, load, time of
the last GitHub fetch). Every hour the GitHub workflow **Server check** reads
it and fails when:

- dromotelo.com, orangiraffe.com or orangiraffe.com/pickwar-privacy does not
  return 200,
- disk is 80% full or more, or memory 90% used or more,
- status.txt is over 20 minutes old (the server's cron, and auto-deploy, stopped),
- the server has not reached GitHub for an hour (pushes are not deploying).

A failed scheduled run is emailed by GitHub to whoever last changed the
workflow's `cron` line (Settings > Notifications > Actions must allow email).
Thresholds and the list of sites are the `env` values at the top of the
workflow. To test the email, run it from the Actions tab with "test_alert" on.

GitHub pauses scheduled workflows in a public repo after 60 days without a
commit; it emails a warning first, and one click in the Actions tab resumes it.
The check is free on a public repo.

## Preview locally

Any static server that maps `/privacy` to `privacy.html` works, for example:

```
caddy file-server --root public --listen :8080   # then open /privacy.html
```
