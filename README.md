# orangiraffe.com

Company website for Orangiraffe LLC. Plain static HTML and CSS: no build step,
no JavaScript, no cookies, no analytics, no external resources.

## Layout

```
public/                  what the site serves
  index.html             home: company, apps, contact
  privacy.html           privacy policy for this website (apps link out)
  legal.html             company details and website terms
  404.html
  assets/site.css        all styles, light and dark mode
  assets/mark.svg        logo mark (also the SVG favicon)
  assets/dromotelo.png   Dromotelo app icon
  thanks.html, contact-error.html   where the contact form redirects
  assets/inbox.js        inbox conveniences (select all, local times, confirm)
  favicon.png, apple-touch-icon.png, robots.txt, sitemap.xml
form/contact.py          contact form + private inbox (Python stdlib only, SQLite)
nginx.conf               clean URLs, 404 page, forwards /api/contact and /inbox to the form
docker-compose.prod.yml  orangiraffe-web (nginx) on the proxy network + orangiraffe-form
deploy/orangiraffe.com.caddy   site block for the shared Caddy
deploy/enable-site.sh    root: installs the site block once DNS is right, verifies, rolls back on harm
deploy/set-inbox-password.sh   root: sets the inbox username and password
```

The site deliberately shows no address, phone or email. People reach the
company through the contact form.

Copy rules: no em dashes or en dashes (plain hyphens only), no emojis, and do not
claim Play Store availability or integrations that are not live.

`assets/mark.svg` is a vector redraw of the Orangiraffe roundel. Replace it with
the original artwork when available (keep the file name).

## Hosting

Runs on the shared IONOS VPS (67.217.240.31) behind the `dromotelo-caddy` proxy,
following the box's project layout:

| Thing | Value |
| --- | --- |
| Unix user | `orangiraffe` |
| Working tree | `/opt/orangiraffe` |
| Bare repo | `/opt/orangiraffe.git` (push `main` to deploy) |
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

- `POST /api/contact`: plain HTML form, no JavaScript. Saves the message to
  SQLite at `/opt/orangiraffe/data/messages.db`, then redirects to `/thanks`
  or `/contact-error`. No email service is involved.
- `https://orangiraffe.com/inbox`: private list of messages behind HTTP Basic
  auth, with select all, delete selected and delete all. Each sender's email
  is a mailto link for replying.

Spam control: a hidden honeypot field, 5 submissions per IP per hour, 100 per
day overall, and at most 5000 stored messages. IP addresses are never stored.
Ten failed inbox sign-ins from one IP lock it out for 15 minutes.

Set or change the inbox username and password, as root on the VPS:

```
bash /opt/orangiraffe/deploy/set-inbox-password.sh
```

It stores only a PBKDF2 hash in `/opt/orangiraffe/.env` (mode 600, not in git).

Backup is one file: `/opt/orangiraffe/data/messages.db`.

## Updating

```
git remote add vps ssh://orangiraffe@67.217.240.31/opt/orangiraffe.git
git push vps main
```

The `post-receive` hook runs `git checkout -f main` into `/opt/orangiraffe` and
`docker compose -p orangiraffe -f docker-compose.prod.yml up -d`. The
`orangiraffe` user needs an SSH key in `/opt/orangiraffe/.ssh/authorized_keys`
first (installed by root).

If you change `deploy/orangiraffe.com.caddy`, deploy, then as root run
`bash /opt/orangiraffe/deploy/enable-site.sh`. It copies the block to
`/opt/caddy-sites/orangiraffe.com.caddy`, validates, reloads (never restarts)
Caddy, checks both sites, and rolls back if dromotelo.com stops answering.

## Preview locally

Any static server that maps `/privacy` to `privacy.html` works, for example:

```
caddy file-server --root public --listen :8080   # then open /privacy.html
```
