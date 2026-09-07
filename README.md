
# 📘 ee.sh – Advanced LEMP + Mail Server Manager

`ee.sh` is a powerful, all‑in‑one Bash script that automates the setup and management of a **LEMP stack** (Nginx, MariaDB, PHP) and a **Stalwart Mail Server** on Ubuntu 24.04 or Debian 12. Think of it as a lightweight, easy‑to‑use alternative to EasyEngine – with built‑in mail server support.

> **GitHub Repository:** [sugan0927/ee.sh](https://github.com/sugan0927/ee.sh)  
> **Direct Script URL:** [raw.githubusercontent.com/sugan0927/ee.sh/main/ee.sh](https://raw.githubusercontent.com/sugan0927/ee.sh/main/ee.sh)

---

## ✨ Features

| Feature | Description |
|---------|-------------|
| 🚀 **One‑command LEMP install** | Installs Nginx, MariaDB, PHP (8.1–8.4), Redis, and security tools (UFW, Fail2ban, unattended‑upgrades). |
| 📁 **Site creation** | Create static HTML or WordPress sites with a single command. |
| 🔒 **SSL certificates** | Automatically obtain Let’s Encrypt SSL certificates (standard or wildcard via Cloudflare DNS). |
| 📧 **Mail server integration** | Install and manage Stalwart Mail Server – a modern, lightweight mail server. |
| 🐘 **Multiple PHP versions** | Install and switch between PHP 8.1, 8.2, 8.3, and 8.4. |
| ⚡ **Redis caching** | WordPress sites get Redis object cache enabled automatically. |
| 🛡️ **Security hardening** | MariaDB secured, UFW firewall configured, Fail2ban jails for SSH, Nginx, and WordPress login. |

---

## 📋 Prerequisites

- **Operating System:** Ubuntu 24.04 or Debian 12 (fresh installation recommended).
- **Root access:** The script must be run as `root` (or with `sudo`).
- **Open ports:** `22` (SSH), `80` (HTTP), `443` (HTTPS), and for mail: `25, 587, 465, 143, 993, 110, 995`.

---

## 🚀 Quick Installation

```bash
# Download the script
curl -O https://raw.githubusercontent.com/sugan0927/ee.sh/main/ee.sh

# Make it executable
chmod +x ee.sh

# Install the full LEMP stack (this will also install the script as /usr/local/bin/ee)
sudo ./ee.sh install
```

After the first run, the script installs itself as **`/usr/local/bin/ee`**, so you can run it from anywhere:

```bash
ee help
```

---

## 📖 Command Reference

### 🌐 Site Management

| Command | Description |
|---------|-------------|
| `ee create <domain> [options]` | Create a new website (static HTML, WordPress, or mail server). |
| `ee delete <domain>` | Delete a site and its database. |

#### Options for `ee create`

| Option | Description |
|--------|-------------|
| `-html` | (Default) Create a static HTML site. |
| `-wp` | Install WordPress with Redis caching. |
| `-ssl` | Obtain a Let’s Encrypt SSL certificate (with HTTP→HTTPS redirect). |
| `-wildcard` | Obtain a wildcard SSL certificate (requires Cloudflare DNS API token). |
| `-phpX.Y` | Specify PHP version (e.g., `-php8.4`). Default is `8.3`. |
| `-email <addr>` | Email address for SSL certificate notifications. Default: `admin@domain`. |
| `-mail` | Install Stalwart Mail Server on this domain. |

#### Examples

```bash
# Static HTML site with SSL
ee create example.com -html -ssl

# WordPress site with PHP 8.4 and SSL
ee create myblog.com -wp -ssl -php8.4

# Mail server on a subdomain with SSL
ee create mail.easyinstall.site -mail -ssl

# Delete a site
ee delete example.com
```

---

### 📧 Mail Server Management

| Command | Description |
|---------|-------------|
| `ee mail status` | Show Stalwart service status. |
| `ee mail start` | Start the mail server. |
| `ee mail stop` | Stop the mail server. |
| `ee mail restart` | Restart the mail server. |

---

### 🧰 Advanced Subcommands (Power Users)

| Command | Description |
|---------|-------------|
| `ee install` | Install the full LEMP stack (Nginx, MariaDB, PHP, Redis, security tools). |
| `ee site create <domain> [--flags]` | Same as `ee create` but with `--ssl`, `--wp`, `--wildcard`, `--email`. |
| `ee site delete <domain>` | Delete a site. |
| `ee php install <version>` | Install an additional PHP version (e.g., `ee php install 8.4`). |
| `ee php set-default <version>` | Set the default PHP version. |
| `ee ssl <domain> [email]` | Obtain a standard SSL certificate for a domain. |
| `ee wildcard <domain> [email]` | Obtain a wildcard SSL certificate (requires Cloudflare). |
| `ee update` | Update system and PHP packages. |
| `ee help` | Show this help message (works without root). |

---

## 📂 Important Paths

| Resource | Location |
|----------|----------|
| Website root | `/var/www/<domain>/htdocs` |
| Nginx vhost config | `/etc/nginx/sites-available/<domain>` |
| MariaDB root password | `/root/.mysql_root_password` |
| Mail server binary | `/usr/local/bin/stalwart` |
| Mail config directory | `/etc/stalwart` (config.json appears after setup wizard) |
| Mail data directory | `/var/lib/stalwart/data` |
| Mail environment file | `/etc/stalwart/stalwart.env` (contains bootstrap credentials) |
| Mail admin panel | `https://<mail-domain>/admin` |

---

## 🔐 Mail Server – First‑Time Setup

When you run `ee create <domain> -mail -ssl`, the script:

1. Installs Stalwart Mail Server.
2. Generates a **one‑time bootstrap password**.
3. Configures Nginx as a reverse proxy (and SSL if `-ssl` is used).
4. Opens the required mail ports in the firewall.

After installation, visit the admin panel:

```
https://<your-mail-domain>/admin
```

**Login with:**
- Username: `admin`
- Password: *(the bootstrap password shown in the script output)*

> ⚠️ This is a **one‑time** login. Once you complete the setup wizard, Stalwart creates a permanent admin account and the temporary password stops working.

---

## 🌐 Wildcard SSL (Cloudflare)

To obtain a wildcard certificate (`*.example.com`):

1. Create a Cloudflare API token with **DNS:Edit** permission.
2. Save it in `/root/.cloudflare.ini`:
   ```
   dns_cloudflare_api_token = your_token_here
   ```
3. Run:
   ```bash
   ee create example.com -wildcard
   ```

---

## 🛠️ Troubleshooting

### MariaDB root password
If the script cannot connect to MariaDB, it will prompt you for the current root password. The password is stored in `/root/.mysql_root_password` for future use.

### Nginx configuration test fails
The script runs `nginx -t` before reloading. If it fails, check the error log:
```bash
cat /tmp/nginx-test.log
```

### Fail2ban not starting
The script attempts to enable Fail2ban with common jails. If it fails, check the logs:
```bash
sudo journalctl -u fail2ban -n 50
```

### Mail server not starting
Check the Stalwart logs:
```bash
sudo journalctl -u stalwart -n 50
```

---

## 📝 Notes

- The script is **idempotent** – you can run it multiple times without breaking your setup.
- Supported PHP versions: `8.1`, `8.2`, `8.3`, `8.4`.
- The script automatically handles `grub-pc` issues on VPS/container environments.
- After installation, the script installs itself as `/usr/local/bin/ee` – so you can just type `ee` from anywhere.

---

## 📄 License

This script is open‑source and available under the MIT License. Feel free to use, modify, and distribute it.

---

## 🙌 Contributing

Found a bug or have a feature request? Open an issue or submit a pull request on the [GitHub repository](https://github.com/sugan0927/ee.sh).

---

**Happy hosting! 🚀**
```

---

## ⚡ Quick Command Cheat Sheet (copy‑paste friendly)

```bash
# Install full LEMP stack
ee install

# Create a static site with SSL
ee create example.com -html -ssl

# Create a WordPress site with PHP 8.4
ee create myblog.com -wp -ssl -php8.4

# Install mail server on a subdomain
ee create mail.yourdomain.com -mail -ssl

# Delete a site
ee delete example.com

# Mail server control
ee mail status
ee mail restart
ee mail stop
ee mail start

# Install additional PHP version
ee php install 8.4

# Set default PHP
ee php set-default 8.3

# Get a standard SSL certificate
ee ssl example.com admin@example.com

# Get a wildcard SSL (Cloudflare required)
ee wildcard example.com admin@example.com

# Update system packages
ee update

# Show help
ee help
```

---

Everything above is **free to use and copy** – the script is MIT licensed. Just download and run! Let me know if you need any clarification. 😊
