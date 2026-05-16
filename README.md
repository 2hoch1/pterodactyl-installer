# Pterodactyl Installer

Automated installer for [Pterodactyl Panel](https://pterodactyl.io) and Wings on Debian 13 (Trixie).

## Requirements

- **OS:** Debian 13
- **Access:** Root
- **DNS:** Panel domain (and Wings FQDN if used) must point to the server's IP before running
- **Ports:** 80 and 443 open

## What gets installed

| Component | Details |
|---|---|
| PHP 8.3 | Via Sury repo |
| MariaDB | Panel database |
| Redis | Cache, session, queue |
| NGINX | Webserver with TLS |
| Certbot | Let's Encrypt SSL |
| Composer | PHP dependency manager |
| Docker | Required for Wings |
| Wings | Pterodactyl node daemon (optional) |

## Usage

```bash
rm -f /tmp/ptero-setup.sh && curl -sSL https://raw.githubusercontent.com/2hoch1/pterodactyl-installer/main/setup.sh -o /tmp/ptero-setup.sh && sudo bash /tmp/ptero-setup.sh
```

The setup script asks for:

| Prompt | Default | Notes |
|---|---|---|
| Panel domain | `panel.example.com` | Must have DNS pointed here |
| Wings FQDN | server hostname | Enter = this node, custom = different name, `n` = skip |
| MariaDB password | auto-generated | Shown before prompt |
| Let's Encrypt email | none | Required for SSL cert |
| Timezone | `Europe/Berlin` | PHP timezone identifier |

## After install

Wings is installed but not started. To activate a Wings node:

1. Log into the panel and go to **Admin > Nodes > Create New**
2. On the node's **Configuration** tab, generate a token and run it in the console
3. Start Wings: `sudo systemctl enable --now wings`