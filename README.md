<div align="center">

# 🧰 boblub-pool

**A pool of Bash tools for fixing WordPress and mail servers — fast.**

Seven standalone scripts. No dependencies to install, no framework, no config files.
You SSH into a broken server, run one command, pick a number from a menu, done.

[![Website](https://img.shields.io/badge/web-bobclub.ir-2ea44f?style=flat-square)](https://bobclub.ir)
[![Pool](https://img.shields.io/badge/pool-bobclub.ir%2Fpool-2ea44f?style=flat-square)](https://bobclub.ir/pool)
[![Telegram](https://img.shields.io/badge/telegram-@bob__club-2ea44f?style=flat-square)](https://t.me/bob_club)
[![License](https://img.shields.io/badge/license-Unlicense-2ea44f?style=flat-square)](LICENSE)

[فارسی 🇮🇷](README-fa.md)

</div>

---

## ⚡ Quick start

Run any script straight from the pool — no clone, no download:

```bash
bash <(curl -kLs https://material.bobclub.ir/wp-core.sh)
```

Or clone the whole repo:

```bash
git clone git@github.com:babak-majd/boblub-pool.git
cd boblub-pool
chmod +x wp-core.sh
sudo ./wp-core.sh
```

> ### 💾 About backups
> **These scripts have been tested many times on real servers, and they keep their own safety nets** — old plugins go to `old-<slug>/`, the old WordPress core goes to `old-core/`, existing site files go to `old-files/`, and the Roundcube database is dumped to `/root/` before anything is dropped. So a rollback is almost always one menu item away.
>
> That said: they write to live files, databases and permissions. **If taking a backup makes you sleep better, take one.** It costs you two minutes and it has never once been a bad idea.

---

## 📦 The scripts

| Script | Use it when… |
| --- | --- |
| [`wp-core.sh`](#-wp-coresh) | WordPress core is broken, out of date, or the site doesn't exist yet |
| [`pro-plugin-manager.sh`](#-pro-plugin-managersh) | WooCommerce or Elementor is broken, you need to search-replace the whole DB, or install / toggle / remove any plugin via wp-cli |
| [`plugin-hunter.sh`](#-plugin-huntersh) | The site is white/500 and you don't know *which* plugin did it |
| [`perm-patrol.sh`](#-perm-patrolsh) | File ownership or permissions on a hosting account are a mess |
| [`magic-move.sh`](#-magic-movesh) | Verifying a whole-server migration and auto-healing sites that broke in transit |
| [`fix-roundcube.sh`](#-fix-roundcubesh) | Roundcube webmail won't load on a DirectAdmin server |
| [`thing-to-link.sh`](#-thing-to-linksh) | You need to hand someone a download link for a file, right now |

Every script prints its version in its terminal header. Full per-script release history lives in the bilingual changelog: **[material.bobclub.ir/changelog](https://material.bobclub.ir/changelog)**.

**Logging.** Every run is logged under `/var/log/<script-name>/`, in a per-target sub-directory (the domain, or the user, depending on the script) with one timestamped file per run — e.g. `/var/log/plugin-hunter/site.ir/2026-08-22_14-30-05.log`. When `/var/log` isn't writable (you're not root), it falls back to the same layout under `/tmp`. Each script prints the exact log path when it finishes — even when you stop it with Ctrl+C, the log keeps everything up to the exit.

---

## 🧩 wp-core.sh

**Manages the WordPress core files** — the `wp-admin/`, `wp-includes/` and root PHP files. Your themes, plugins, uploads and database are never touched by the core operations.

**Run it inside a site's `public_html`, or run it anywhere and type the domain when asked** — it finds the web root through cPanel/DirectAdmin.

### If WordPress *is* installed, you get this menu:

| # | Option | What it actually does |
| --- | --- | --- |
| **1** | Repair existing version | Detects your installed version (e.g. 6.9.4), downloads that *same* version fresh from wordpress.org, and overwrites the core files. **Fixes hacked/corrupted/deleted core files without changing your version.** |
| **2** | Update to latest version | Same thing, but with the newest WordPress release. |
| **3** | Install WordPress 6.9.4 | Forces this specific version — useful for downgrading after a bad update. |
| **4** | Install custom version | You type the version (e.g. `6.8.3`) and it installs exactly that. |
| **5** | Rollback to previous core | Restores the core that was replaced last time, from `old-core/`. Your undo button. |
| **6** | Manage administrator users | Opens the admin submenu below. |

Options 1–4 all copy the current core into **`old-core/`** first, so option 5 can always bring it back.

### The administrator submenu (option 6):

| # | Option | What it does |
| --- | --- | --- |
| **1** | List administrator accounts | Shows every admin: login, email, ID. Useful when you inherit a site and don't know who's in it. |
| **2** | Change an administrator's password | You give a login, it sets a new password and signs every other session out. **Gets you back in when you're locked out.** |
| **3** | Create a new administrator | Makes a brand-new admin. Press Enter at the login prompt and it takes the first free name in the `admin`, `admin1`, `admin2`… series — the suggestion is shown in parentheses. Leave the password blank and one is generated. |

This talks to **MySQL directly**, using the credentials already in `wp-config.php` — no PHP, no WordPress bootstrap, no plugin code executed. That matters because the `php` binary on a server is often not the version the site runs on, and loading WordPress with the wrong one fatals. It also means the submenu works **even when wp-admin is completely dead**, and even when the site's PHP is broken outright.

The submenu header also reports the **real login URL**, read out of `wp_options`: if a login-hiding plugin has moved `wp-login.php`, the moved address is shown along with the plugin that did it (WPS Hide Login, Rename wp-login.php, Hide My WP Ghost, All In One WP Security, Defender, WP Cerber, Perfmatters, Solid Security). The same line appears next to the WordPress version on the main menu.

A newly created password is stored in WordPress's legacy MD5 format, which WordPress accepts and silently upgrades to its modern hash the first time the account signs in.

### If WordPress is *not* installed:

It offers to build the site from scratch: existing files are moved out of the way into `old-files/`, a database is created through the panel (cPanel/DirectAdmin) — or you enter DB details yourself — WordPress is downloaded, `wp-config.php` is written with fresh security salts, and ownership/permissions are set correctly.

After an update, repair, install or fresh install, it reads the version back from `wp-includes/version.php` and prints exactly what landed on disk, so you can confirm the operation.

```bash
sudo ./wp-core.sh
# or answer every prompt up-front with flags:
sudo ./wp-core.sh -d site.ir --update
sudo ./wp-core.sh -p /home/u/public_html --install --version 6.8.3 -y
sudo ./wp-core.sh -d site.ir --fresh --version latest -y
sudo ./wp-core.sh -d site.ir --install --custom-url https://example.com/core.zip -y
sudo ./wp-core.sh -p /home/u/public_html --install --custom-zip /root/core.zip -y

# administrators, without any prompting:
sudo ./wp-core.sh -d site.ir --admin-user bob --admin-email bob@site.ir
sudo ./wp-core.sh -d site.ir -A -y     # auto login + auto password
```

`--admin-user`, `--admin-email` and `--admin-pass` create an administrator non-interactively; any one of them implies `-A`. Leave `--admin-user` out (or use `-A -y`) and the same `admin`/`admin1`/`admin2` suggestion is used. Generated passwords are 20 characters drawn entirely from `/dev/urandom`, guaranteed to carry a lowercase, uppercase, digit and symbol.

`--custom-url`/`--custom-zip` swap the core package for one you supply, instead of resolving a version — handy for a private mirror or a hand-patched core. Either zip layout works: wrapped in a `wordpress/` folder (the wordpress.org default) or flat at the zip root.

Any flag you leave out is simply asked for interactively — pasting a URL or local path at the version prompt is auto-detected too. Run `./wp-core.sh --help` for the full list.

---

## 🔌 pro-plugin-manager.sh

**A repair toolkit for the two plugins that break sites most often — WooCommerce and Elementor — plus a whole-database search & replace and a wp-cli manager for any plugin.**

The main menu:

| # | Option | What it does |
| --- | --- | --- |
| **1** | WooCommerce Manager | Opens the plugin submenu below, targeting `woocommerce`. |
| **2** | Elementor Manager | Same submenu, targeting `elementor`. |
| **3** | Search And Replace | Find/replace text across **every table** in the WP database. |
| **4** | Install latest Blue Guard | Downloads and installs the latest Blue Guard security plugin (old copy kept in `old-blue-guard/`). |
| **5** | Plugin Manager (wp-cli) | Any plugin: install from a link or path, list, activate, deactivate, delete. |

### The plugin submenu (options 1 and 2):

It shows you the currently installed version, then:

| # | Option | What it does |
| --- | --- | --- |
| **1** | Repair current version | Re-downloads the exact version you already have and overwrites the plugin folder. **Fixes a corrupted plugin without changing its version** — important when a newer version isn't compatible with your theme. |
| **2** | Update to latest version | Installs the newest release from wordpress.org. |
| **3** | Install specific version | You type a version (e.g. `10.9.0`) — for rolling back to a version you know worked. |
| **4** | Rollback to previous | Restores the copy saved in `old-<slug>/` from the last operation. |

After installing, it offers to activate the plugin via wp-cli. Downloads come from wordpress.org, with a mirror as fallback if that's unreachable.

### Search & Replace (option 3)

You give an old value and a new value, then choose:

- **1) Dry run** — counts how many rows would change. Changes nothing. **Always run this first.**
- **2) Replace now** — actually performs the replacement.

Classic use: moving a site from `http://old-domain.ir` to `https://new-domain.ir`.

### Plugin Manager (option 5)

| # | Option | What it does |
| --- | --- | --- |
| **1** | Install from a link or path | Installs a plugin `.zip` from a URL or a file on the server; asks whether to activate it, and offers to overwrite if it is already installed. |
| **2** | List plugins | `wp plugin list` — name, status, version. |
| **3** | Activate | Activates a plugin by slug. |
| **4** | Deactivate | Deactivates a plugin by slug. |
| **5** | Delete | Deactivates, keeps a copy in `old-<slug>/`, deletes — and asks whether to also run the plugin's uninstall routine (removes its settings/tables). |

**Why everything goes through wp-cli:** WordPress is loaded normally, so the plugin's own activation / deactivation / uninstall hooks run exactly as they do from WP-Admin. Renaming or deleting folders by hand skips those hooks and leaves the site in a state WordPress didn't create — which is what later clashes with the site owner's own WordPress.

> ⚠️ **Serialized data is not length-fixed.** WordPress stores some options (widgets, theme settings, page builder data) as serialized PHP strings that embed their own character counts. A raw SQL replace of a *different-length* string breaks them. If your two values have different lengths and the site uses page builders, use `wp search-replace` from wp-cli instead — the script warns you about this too.

```bash
sudo ./pro-plugin-manager.sh
# or answer every prompt up-front with flags:
sudo ./pro-plugin-manager.sh -d site.ir --woocommerce --update -y
sudo ./pro-plugin-manager.sh -p /home/u/public_html -e --install --version 3.21.0
sudo ./pro-plugin-manager.sh -d site.ir -s --old http://old.ir --new https://new.ir --dry-run
sudo ./pro-plugin-manager.sh -d site.ir --from https://example.com/plugin.zip -y
sudo ./pro-plugin-manager.sh -d site.ir --deactivate hello-dolly
```

Any flag you leave out is simply asked for interactively. Run `./pro-plugin-manager.sh --help` for the full list.

---

## 🎯 plugin-hunter.sh

**Finds the one plugin that's killing the site.** The classic scenario: white screen or HTTP 500, no error in the logs, 40 plugins installed, and you have no idea which one.

It disables plugins by renaming their folders (`plugin-name` → `plugin-name.off`). WordPress simply stops seeing them. **Nothing is deleted**, and everything is renamed back at the end — or immediately, if you cancel. To cancel, answer `c` at any prompt (manual mode) or press **Ctrl+C** at any time (either mode); only the plugins the scan itself turned off are put back, so ones that were already `.off` stay disabled.

### Two choices when it starts:

**First — how do you want to test?**

| # | Mode | Meaning |
| --- | --- | --- |
| **1** | manual | The script pauses after each change and asks *you* whether the site is working. **Use this** when the bug is something only a human can see — broken checkout, wrong layout, a page that half-loads. |
| **2** | automate | The script loads the pages itself — the homepage, `wp-login.php` and any extra pages you name — and checks each for a healthy, fully-rendered, fast response. Faster, hands-off. Use this when the failure is something a script can detect: 500 / white screen, a PHP error on the page, or a site that has become very slow or hangs. |

**Second — how should it hunt?**

Both strategies start the same way: **every plugin is disabled first**, and the site is checked to confirm it's now healthy. If it's still broken with nothing enabled, the fault isn't a plugin and the scan stops — *unless* WooCommerce is installed, in which case it's switched back on and the check repeated first (many themes fatal without it); WooCommerce then stays on and is excluded from the hunt. They then re-enable plugins to find what breaks the site — so problems that only show up when several plugins are active together are caught too. Either strategy reports **every** guilty plugin, not just the first. In **manual** mode you confirm each culprit as it's found. In **automate** mode the hunt runs unattended, then does a re-verification pass — each identified culprit is switched back on and the site re-tested, and anything that no longer breaks it is treated as a false positive and left enabled — before confirming all the survivors with a single question. Pass `--auto-accept` to keep every find without prompting.

**What automate mode counts as broken.** Every checked page must pass. A page fails on a **timeout** (`--timeout`, default 30s) or a **slow load** (`--slow`, default 10s), each re-tested once first so a cold cache isn't blamed. It also fails on a connection failure or redirect loop, a non-200 status, an empty (white) or cut-off page, or an error in the body: critical error, PHP fatal/parse error, memory exhausted, max execution time exceeded, database error, or stuck maintenance mode. The reason is printed with every fail. `wp-login.php` only fails on a 5xx or one of those errors — a 403/404 there is usually a hide-login plugin or a firewall, not a fault. Extra pages come from `--page /shop --page /cart` or are asked for once (`--no-extra` skips the question, `--no-login` skips wp-login).

| # | Strategy | Meaning |
| --- | --- | --- |
| **1** | linear | Re-enables plugins one at a time. When the site breaks, that plugin is flagged and left disabled, and the hunt continues. Simple and predictable. |
| **2** | binary | Isolates a culprit by bisection (~log₂n checks), then re-enables everything and re-tests: healthy → done; still broken → hunt the next one. Same complete result as linear, far fewer checks. **Recommended.** |

**Fast path (tried first).** Before any of that, it asks WordPress directly *which* plugin fatally errored — reading the shown error, an existing `wp-content/debug.log`, or briefly turning on `WP_DEBUG_LOG` and re-triggering the site — then disables just that plugin and re-checks, looping for any further culprit. If that fixes the site the whole search is skipped; if the log names no plugin (e.g. the fault is in the theme), everything it touched is undone and the normal hunt runs exactly as before. Only the culprit line of a fatal is trusted, so an ordinary asset URL can't be mistaken for a culprit. Turn it off with `--no-fast`.

**When it can't fix the site.** If the hunt ends without a fix — no plugin culprit, a combination it can't pin down, or a fault that isn't a plugin — it asks whether to **turn WordPress debugging on**. On yes it checks `WP_DEBUG`, `WP_DEBUG_LOG` and `WP_DEBUG_DISPLAY` in `wp-config.php` and switches each one on (already-on ones are left alone, a timestamped backup is kept), then shows the newest lines of `wp-content/debug.log`. `--debug` does it without asking, `--no-debug` never offers. Errors become visible to visitors, so switch it off when you're done.

Everything it does is logged to `/var/log/plugin-hunter/<domain>/<timestamp>.log` (with a `/tmp` fallback), and the path is printed when it finishes.

```bash
sudo ./plugin-hunter.sh
# point it straight at a path:
sudo ./plugin-hunter.sh /home/user/domains/site.ir/public_html
# or answer every prompt up-front with flags:
sudo ./plugin-hunter.sh -d site.ir --automate --binary
```

Any flag you leave out is simply asked for interactively. Run `./plugin-hunter.sh --help` for the full list.

---

## 🛡️ perm-patrol.sh

**Repairs ownership and permissions across one hosting account** — after a bad `chown -R`, a migration from another server, or an upload done as `root`. Symptoms: "cannot write to directory", uploads failing, updates failing, or a `wp-config.php` that's readable by other users on the server.

It detects the panel (DirectAdmin or cPanel), asks for a username, finds that user's web roots, and works **only inside that home directory** — it hard-refuses to touch `/`, `/etc`, `/usr`, `/var` and friends.

### It asks you three yes/no questions, in order:

| # | Step | What it fixes |
| --- | --- | --- |
| **1** | Reset ownership | Every file becomes owned by the account's user and group. **Fixes "permission denied" and failed uploads/updates.** |
| **2** | Fix web file modes | Directories → `755`, files → `644`. The standard, safe web permissions. Fixes both broken sites *and* dangerously open `777` files. |
| **3** | Harden sensitive files | `wp-config.php`, `.env`, `.my.cnf`, `.htpasswd` → `600`, so **only the account owner can read them.** These files hold your database and API passwords. |

You answer each one separately, so you can do just the part you need. At the end it reports how many files it changed in each category.

### Preview mode — nothing is written:

```bash
sudo ./perm-patrol.sh --dry-run
```

It prints every change it *would* make and exits. Run this first if you're nervous; run it plain when you're ready:

```bash
sudo ./perm-patrol.sh
# or answer every prompt up-front with flags:
sudo ./perm-patrol.sh -u exampleuser -y
sudo ./perm-patrol.sh --user exampleuser --modes --harden --dry-run
```

Any flag you leave out is simply asked for interactively. Run `./perm-patrol.sh --help` for the full list.

---

## 🪄 magic-move.sh

**Verifies a whole-server migration in two passes, and heals what broke in transit.** Run it on the **source** first, then on the **destination** — the output folder travels between them.

Every domain is probed with **all hostnames pinned to the server being tested**, so a redirect to `www`/a subdomain follows onto that box, not wherever public DNS still points.

1. **SOURCE** — detects every account (cPanel/DirectAdmin), health-checks each domain, records `status_before` in `migration.csv`, and snapshots each page to `snapshots/before/`. Changes nothing.
   - **How much to do**: `--list-only` stops right after the account list — no requests, no snapshots, and no server-IP prompt, since nothing is fetched. `--snapshot` runs the full pass. Given neither, it asks which one; either flag on its own already means `--source`, so a flagged run asks nothing.
   - **Nameservers**: `--ns` looks up each domain's delegated nameservers into four extra columns, `ns1`–`ns4` (`--no-ns` skips it; given neither, it asks). An addon domain or subdomain falls back to the zone one label up, and the destination pass carries the columns through untouched — so one CSV holds both the migration status and where DNS still points.
2. **DESTINATION** — takes that CSV, re-checks every domain against *this* server, and **heals** anything broken:
   - **Plugin fatal** (the WordPress "critical error" white screen): turns on `WP_DEBUG` + `WP_DEBUG_DISPLAY` just long enough to read the culprit plugin from the error, disables it by renaming its folder to `<slug>.dis`, and repeats for any further culprit — then restores `wp-config.php`. **Elementor and WooCommerce are never disabled** (extend the list with `--protect`).
   - **Otherwise** it steps the PHP version down the cascade until the site comes back.

   It records `status_after` (including which plugins it disabled), snapshots to `snapshots/after/`, and writes a `report.txt`.
3. **SYNC** — copies the selected accounts' home directories to the destination with **one rsync**. A filter lets only those users through, `.cagefs` included, so there is no `/home`-wide exclude list. It is offered at the end of the source pass (`--with-sync` / `--no-sync` answer it up front), or runs on its own as `--sync`. It asks for the destination IP and SSH port (`--dest-ip`, `--dest-port`). SSH connects once in your terminal, so any password is typed there, and the copy then runs in a detached `screen`; attach with the `screen -r …` command it prints. Users missing on the destination, or homed under a different path there, are **not copied**; they are listed in `magic-move/sync-skipped.csv`.

> 🔧 **PREP — readying both servers (before the first byte moves).** A migration usually dies on things the transfer can't see: SecCheck re-enabling itself, a scanner locking files, the firewall dropping the rsync. So `magic-move.sh` can prepare a server first — it stops & disables **SecCheck** (quarantining the cron entries that resurrect it, moving `/etc/SecCheck` aside), stops & disables the **scanner services** (`clamd@scan`, `clamav-freshclam`, `cxswatch`, `rspamd`, `spamd`), comments an active `ALL: ALL` out of `hosts.deny`, and whitelists the peer's IP in **CSF**. The **destination** additionally gets **SSH root login** opened — validated with `sshd -t` before any restart, with the backup restored if the test fails. Every step is idempotent and keeps a backup. Inside a sync flow the source runs its prep, then prints a complete, **ready-to-paste block for the destination** (the source IP already in it) and waits for Enter before the rsync; `--skip-prep` skips it on already-prepared servers. Run it standalone with `--prep` (`--source`/`--destination` + `--peer-ip`), or pick menu option 4.

```bash
sudo ./magic-move.sh --source
sudo ./magic-move.sh --source --list-only --ns                          # just the account list + nameservers
sudo ./magic-move.sh --source --list-only --with-sync                   # list the accounts, then rsync their homes
sudo ./magic-move.sh --sync -f magic-move/migration.csv --dest-ip 203.0.113.7 --dest-port 3131   # sync only
sudo ./magic-move.sh --sync --skip-prep -f magic-move/migration.csv     # sync; both servers already prepared
sudo ./magic-move.sh --prep --source --peer-ip 203.0.113.7              # prep this source + print the destination block
sudo ./magic-move.sh --prep --destination --peer-ip 198.51.100.3        # prep this destination (opens root SSH)
sudo ./magic-move.sh --destination -f migration.csv
sudo ./magic-move.sh --destination -f migration.csv --protect "wp-rocket, litespeed-cache"
sudo ./magic-move.sh --destination -f migration.csv --no-plugin-heal   # PHP-only healing
sudo ./magic-move.sh --destination -f migration.csv --dry-run          # check & report, change nothing
```

> ⚠️ On the destination, healing **modifies live sites** — it disables plugins and (on CloudLinux) switches PHP versions. Use `--dry-run` first to see what it *would* do. The migration CSV/report/snapshots are the result and stay in the output folder; the run log goes to `/var/log/magic-move/`.
>
> ⚠️ PREP deliberately **relaxes the server's security for the migration** — it turns off SecCheck and the scanners and opens root SSH on the destination. Run it only between servers you control, and re-enable those protections once the move is done (backups of every edited file are kept next to the originals).

---

## 📬 fix-roundcube.sh

**Rebuilds a broken Roundcube webmail on a DirectAdmin server.** For when webmail shows a database error, a blank page, or won't log anyone in after an update.

It's not menu-driven — it does one job, top to bottom:

1. Reads the MySQL credentials from `/usr/local/directadmin/conf/mysql.conf` (no passwords to type).
2. **Dumps the Roundcube database to `/root/` first**, timestamped. If the dump fails it warns and continues — because a missing database is often exactly the problem you're fixing.
3. Drops the broken database, auto-detecting the correct MySQL socket so the connection actually goes through.
4. If leftover files remain in the MySQL data directory, it clears them **only after confirming the server is genuinely stopped** — it never deletes DB files under a live server (that's what caused `[1050] table already exists` rebuild failures), then restarts MySQL/MariaDB.
5. Runs `da build roundcube` — DirectAdmin rebuilds Roundcube clean, and reports an honest pass/fail at the end.

Everything is logged to `/var/log/fix-roundcube/<timestamp>.log` (with a `/tmp` fallback), and the path is printed at the end.

> 📮 Roundcube's database holds **contacts, settings and folder preferences** — not mail. Your actual emails live on disk in the mail store and are **not** affected.

```bash
sudo ./fix-roundcube.sh
```

---

## 🔗 thing-to-link.sh

**Turns anything into a download link.** You have a file on the server and someone needs it — a client, a colleague, another server. Instead of SFTP credentials, you give them a URL.

Give it one thing (a file path, a directory, or a URL), then pick **how** to publish. Only the backends the box actually has are offered, in this order — and the **first available one is the default** (Enter picks it; `--default` takes it without the menu). If it has none, it says so and stops:

| Method | What it does |
| --- | --- |
| **web root** | Classic copy into `/var/www/html`, served by the running web server. **Stays until you remove it.** Offered when a web server (or `/var/www/html`) is present. |
| **python link** | A throwaway python server on a **random free port**, serving **just that one file** behind a **random token path** — not the folder, not anything else. Offered when `python3` exists. |
| **php link** | The same, with `php -S`. Offered when php-cli exists. |

Pick one directly with `--web`, `--python` or `--php` (or `--serve php|python`, `--webroot <dir>`).

A directory is compressed first (`tar.gz` / `zip`); a URL is downloaded, then served from your server.

**The temporary link (php/python) is ephemeral and self-contained:**

- **One file only.** The link is `http://<ip>:<port>/<token>/<file>`; every other path — including `/` — returns `404`. No directory listing, nothing else on disk to reach. `Range` is supported, so an interrupted download can resume.
- **The firewall port is opened for the run and closed again afterwards** — `firewalld` / `ufw` / `iptables` is auto-detected, the rule is uniquely tagged, and on teardown **exactly that rule is removed and then verified**, so no hole is ever left open.
- **It lives only while the run does.** Press `Ctrl+C`, drop the SSH session (`SIGHUP`), or hit the `--timeout` you set (asked for; **max 12h**) and it tears everything down: server stopped, firewall closed, temp files removed. On timeout it blocks new connections first and lets an in-progress download finish. A background backstop closes the port even if the script is `kill -9`'d.

```bash
sudo ./thing-to-link.sh
# or answer every prompt up-front with flags:
sudo ./thing-to-link.sh -i /root/backup.tar.gz --default        # first available backend
sudo ./thing-to-link.sh -i /root/backup.tar.gz --php -t 2h
sudo ./thing-to-link.sh -i https://example.com/file.zip --python
sudo ./thing-to-link.sh -i /home/user/backups -c zip --webroot /var/www/html   # classic web-root copy
```

Any flag you leave out is simply asked for interactively. Run `./thing-to-link.sh --help` for the full list.

> ⚠️ Whatever you publish is **reachable by anyone with the link** while it is up. A temporary link limits the exposure — random port, unguessable token, and it dies with your session or the timeout. The **web-root** copy, by contrast, stays public until you delete it from `/var/www/html`, so clean up backups and database dumps when you're done.
>
> ℹ️ Run a temporary link **inside `tmux`/`screen`** and it survives an SSH disconnect (it is no longer your session that ends) — the `--timeout` still closes it.

---

## ✅ Requirements

- A Linux server (Debian/Ubuntu-oriented; the panel scripts expect DirectAdmin or cPanel).
- `bash`, plus the usual tooling: `wget` / `curl`, `unzip`, `mysql`, and PHP CLI.
- `wp-cli` is optional — used when present, worked around when not.
- `root` / `sudo`, since these scripts change ownership, permissions and system services.

---

## 📄 License

Released into the public domain under [The Unlicense](LICENSE).
Do whatever you want with these scripts — anywhere, for any purpose, no attribution required.

<div align="center">

**[bobclub.ir](https://bobclub.ir)** · **[Pool](https://bobclub.ir/pool)** · **[Changelog](https://material.bobclub.ir/changelog)** · **[Telegram](https://t.me/bob_club)**

</div>
