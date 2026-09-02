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
| [`pro-plugin-manager.sh`](#-pro-plugin-managersh) | WooCommerce or Elementor is broken, or you need to search-replace the whole DB |
| [`plugin-hunter.sh`](#-plugin-huntersh) | The site is white/500 and you don't know *which* plugin did it |
| [`perm-patrol.sh`](#-perm-patrolsh) | File ownership or permissions on a hosting account are a mess |
| [`magic-move.sh`](#-magic-movesh) | Verifying a whole-server migration and auto-healing sites that broke in transit |
| [`fix-roundcube.sh`](#-fix-roundcubesh) | Roundcube webmail won't load on a DirectAdmin server |
| [`thing-to-link.sh`](#-thing-to-linksh) | You need to hand someone a download link for a file, right now |

Every script prints its version in its terminal header. Full per-script release history lives in the bilingual changelog: **[material.bobclub.ir/changelog](https://material.bobclub.ir/changelog)**.

**Logging.** Every run is logged under `/var/log/<script-name>/`, in a per-target sub-directory (the domain, or the user, depending on the script) with one timestamped file per run — e.g. `/var/log/plugin-hunter/site.ir/2026-08-22_14-30-05.log`. When `/var/log` isn't writable (you're not root), it falls back to the same layout under `/tmp`. Each script prints the exact log path when it finishes.

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

**A repair toolkit for the two plugins that break sites most often — WooCommerce and Elementor — plus a whole-database search & replace.**

> ⚠️ This is *not* a general "install any plugin" tool. The main menu is exactly these four items:

| # | Option | What it does |
| --- | --- | --- |
| **1** | WooCommerce Manager | Opens the plugin submenu below, targeting `woocommerce`. |
| **2** | Elementor Manager | Same submenu, targeting `elementor`. |
| **3** | Search And Replace | Find/replace text across **every table** in the WP database. |
| **4** | Install latest Blue Guard | Downloads and installs the latest Blue Guard security plugin (old copy kept in `old-blue-guard/`). |

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

> ⚠️ **Serialized data is not length-fixed.** WordPress stores some options (widgets, theme settings, page builder data) as serialized PHP strings that embed their own character counts. A raw SQL replace of a *different-length* string breaks them. If your two values have different lengths and the site uses page builders, use `wp search-replace` from wp-cli instead — the script warns you about this too.

```bash
sudo ./pro-plugin-manager.sh
# or answer every prompt up-front with flags:
sudo ./pro-plugin-manager.sh -d site.ir --woocommerce --update -y
sudo ./pro-plugin-manager.sh -p /home/u/public_html -e --install --version 3.21.0
sudo ./pro-plugin-manager.sh -d site.ir -s --old http://old.ir --new https://new.ir --dry-run
```

Any flag you leave out is simply asked for interactively. Run `./pro-plugin-manager.sh --help` for the full list.

---

## 🎯 plugin-hunter.sh

**Finds the one plugin that's killing the site.** The classic scenario: white screen or HTTP 500, no error in the logs, 40 plugins installed, and you have no idea which one.

It disables plugins by renaming their folders (`plugin-name` → `plugin-name.off`). WordPress simply stops seeing them. **Nothing is deleted**, and everything is renamed back at the end — or immediately, if you cancel.

### Two choices when it starts:

**First — how do you want to test?**

| # | Mode | Meaning |
| --- | --- | --- |
| **1** | manual | The script pauses after each change and asks *you* whether the site is working. **Use this** when the bug is something only a human can see — broken checkout, wrong layout, a page that half-loads. |
| **2** | automate | The script loads the homepage itself and checks for a healthy, fully-rendered response. Faster, hands-off. Use this when the site is fully down (500 / white screen), because that's a failure a script can actually detect. |

**Second — how should it hunt?**

Both strategies start the same way: **every plugin is disabled first**, and the site is checked to confirm it's now healthy. If it's still broken with nothing enabled, the fault isn't a plugin and the scan stops — *unless* WooCommerce is installed, in which case it's switched back on and the check repeated first (many themes fatal without it); WooCommerce then stays on and is excluded from the hunt. They then re-enable plugins to find what breaks the site — so problems that only show up when several plugins are active together are caught too. Either strategy reports **every** guilty plugin, not just the first. In **manual** mode you confirm each culprit as it's found. In **automate** mode the hunt runs unattended, then does a re-verification pass — each identified culprit is switched back on and the site re-tested, and anything that no longer breaks it is treated as a false positive and left enabled — before confirming all the survivors with a single question. Pass `--auto-accept` to keep every find without prompting.

| # | Strategy | Meaning |
| --- | --- | --- |
| **1** | linear | Re-enables plugins one at a time. When the site breaks, that plugin is flagged and left disabled, and the hunt continues. Simple and predictable. |
| **2** | binary | Isolates a culprit by bisection (~log₂n checks), then re-enables everything and re-tests: healthy → done; still broken → hunt the next one. Same complete result as linear, far fewer checks. **Recommended.** |

**Fast path (tried first).** Before any of that, it asks WordPress directly *which* plugin fatally errored — reading the shown error, an existing `wp-content/debug.log`, or briefly turning on `WP_DEBUG_LOG` and re-triggering the site — then disables just that plugin and re-checks, looping for any further culprit. If that fixes the site the whole search is skipped; if the log names no plugin (e.g. the fault is in the theme), everything it touched is undone and the normal hunt runs exactly as before. Only the culprit line of a fatal is trusted, so an ordinary asset URL can't be mistaken for a culprit. Turn it off with `--no-fast`.

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

```bash
sudo ./magic-move.sh --source
sudo ./magic-move.sh --source --list-only --ns                          # just the account list + nameservers
sudo ./magic-move.sh --destination -f migration.csv
sudo ./magic-move.sh --destination -f migration.csv --protect "wp-rocket, litespeed-cache"
sudo ./magic-move.sh --destination -f migration.csv --no-plugin-heal   # PHP-only healing
sudo ./magic-move.sh --destination -f migration.csv --dry-run          # check & report, change nothing
```

> ⚠️ On the destination, healing **modifies live sites** — it disables plugins and (on CloudLinux) switches PHP versions. Use `--dry-run` first to see what it *would* do. The migration CSV/report/snapshots are the result and stay in the output folder; the run log goes to `/var/log/magic-move/`.

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

Run it, and it asks for **one** thing: a file path, a directory, or a URL.

| You give it… | It does… |
| --- | --- |
| A **file path** | Copies it into `/var/www/html` and prints the public URL. |
| A **directory** | Asks whether you want `tar.gz` or `zip`, compresses it, publishes the archive, prints the URL. |
| A **URL** | Downloads it with `wget` straight into the web root and re-publishes it from your server. Handy for pulling a file across servers when one can't reach the other. |

```bash
sudo ./thing-to-link.sh
# or answer every prompt up-front with flags:
sudo ./thing-to-link.sh -i https://example.com/file.zip
sudo ./thing-to-link.sh -i /home/user/backups -c zip -w /var/www/html
```

Any flag you leave out is simply asked for interactively. Run `./thing-to-link.sh --help` for the full list.

> ⚠️ Whatever you publish is **public to anyone with the link**. Delete it from `/var/www/html` when you're done — especially backups and database dumps.

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
