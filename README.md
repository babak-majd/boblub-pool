# boblub-pool

A pool of Bash utility scripts for managing WordPress and mail servers, maintained by [bobclub.ir](https://bobclub.ir).

Each script is standalone, dependency-light, and ships with a styled terminal UI. They are meant to be run **on the server** they operate on (they touch paths like `/var/www/html` and `/var/log`, and most need `root`).

- **Website:** https://bobclub.ir
- **Pool:** https://bobclub.ir/pool
- **Telegram:** https://t.me/bob_club

## Scripts

| Script | What it does |
| --- | --- |
| [`pro-plugin-manager.sh`](pro-plugin-manager.sh) | Menu-driven WordPress plugin operations — install, update, repair, and rollback. |
| [`plugin-hunter.sh`](plugin-hunter.sh) | Scan a WordPress install for plugins and log the results to `/var/log/plugin-hunter.log`. |
| [`wp-core.sh`](wp-core.sh) | Repair, update, or replace WordPress core; provision a fresh site when none is found (moves existing files to `old-files/`, creates the database via the panel, and configures WordPress); and manage administrator accounts (list admins, reset a password, or add a new admin). |
| [`fix-roundcube.sh`](fix-roundcube.sh) | Repair and reconfigure a Roundcube webmail installation. |
| [`perm-patrol.sh`](perm-patrol.sh) | Patrol a DirectAdmin or cPanel user's home directory: reset ownership, fix web file modes (755/644), and harden sensitive files (`wp-config.php`, `.env`, `.my.cnf`). Supports `--dry-run`. |
| [`thing-to-link.sh`](thing-to-link.sh) | Fetch a local file or a remote URL into the web root and make it accessible. |

Each script is versioned independently (the `VERSION` at the top of the file, also shown in its terminal header). Per-script release history lives in the bilingual changelog: [bobclub.ir/changelog](https://bobclub.ir/changelog) (source: [changelog.html](changelog.html)).

## Usage

Clone the repo (or download a single script), then run it:

```bash
git clone git@github.com:babak-majd/boblub-pool.git
cd boblub-pool

chmod +x pro-plugin-manager.sh
sudo ./pro-plugin-manager.sh
```

Or run a single script directly, without cloning — straight from GitHub:

```bash
bash <(curl -kLs https://raw.githubusercontent.com/babak-majd/boblub-pool/refs/heads/main/plugin-hunter.sh)
```

or from the pool mirror:

```bash
bash <(curl -kLs https://material.bobclub.ir/thing-to-link.sh)
```

> **Note:** These scripts modify live server configuration, files, and databases.
> Read a script before running it, run it on the correct host, and take a backup first.

## Requirements

- A Linux server (Debian/Ubuntu-oriented).
- `bash`, plus common tooling used per script (e.g. `wp-cli`, `wget`/`curl`, `mysql`).
- `root` / `sudo` for scripts that write to the web root or system config.

## License

Released into the public domain under [The Unlicense](LICENSE).
Do whatever you want with these scripts — anywhere, for any purpose, no attribution required.
