# Nginx Domain Manager

Interactive terminal-based Nginx reverse proxy and SSL management tool for Linux servers.

## Overview

`nginx.sh` provides a menu-driven TUI for managing active Nginx virtual hosts without manually editing configuration files for common operations. It discovers the configuration currently loaded by Nginx, groups aliases that belong to the same site, validates configuration changes before reload, and keeps rollback snapshots for safer administration.

## Features

- Discover active Nginx domains from `nginx -T`
- Display existing sites and aliases in an interactive menu
- Navigate with the arrow keys and select actions with Enter
- Create new reverse-proxy domains
- Configure the public HTTPS port
- Configure backend IP/hostname and backend port
- Support HTTP and HTTPS upstreams
- Add WebSocket-compatible proxy headers
- Detect TCP port conflicts before creating a site
- Allow shared HTTPS ports when the listener is already owned by Nginx
- Request Let's Encrypt certificates using Certbot
- Check SSL certificate details and expiration
- Force-renew Certbot-managed certificates
- Test the complete Nginx configuration with `nginx -t`
- Reload Nginx only after successful validation
- Delete Nginx sites with safety checks
- Create automatic configuration snapshots before destructive changes
- Restore previous configurations using the Rollback menu

## Requirements

The script is intended for Debian/Ubuntu-style Nginx installations and expects:

- Bash
- Nginx
- systemd
- `dialog`
- OpenSSL
- `ss` from `iproute2`
- Certbot and `python3-certbot-nginx` for Let's Encrypt operations

Missing basic dependencies are installed automatically where supported.

## Installation

```bash
chmod +x nginx.sh
sudo ./nginx.sh
```

Optionally install it system-wide:

```bash
sudo cp nginx.sh /usr/local/sbin/nginx-domain-manager
sudo chmod +x /usr/local/sbin/nginx-domain-manager
sudo nginx-domain-manager
```

## Main Menu

The interactive menu provides:

- Create Domain
- Delete Domain / Site
- Check SSL
- Renew SSL
- Test Nginx Configuration
- Reload Nginx
- Rollback
- Refresh Domain List

Existing active Nginx sites are also displayed directly in the main menu. Selecting a site shows its primary hostname, aliases, HTTPS port, configuration path, and SSL certificate path.

## Port Conflict Detection

Before a domain is created, the manager checks the requested public TCP port.

If the port is already owned by Nginx, the manager allows the operation because multiple HTTPS virtual hosts can safely share the same listener through `server_name` and TLS SNI.

If another process owns the port, creation is stopped and the conflicting listener is displayed.

## Backups and Rollback

Configuration snapshots are stored under:

```text
/var/backups/orama-nginx-manager/snapshots/
```

Snapshots are created before supported destructive or replacement operations. The Rollback menu can restore an earlier configuration and validates it with `nginx -t` before completing the reload.

## SSL Management

The manager can request, inspect, and renew Let's Encrypt certificates through Certbot. Certificate information includes issuer, validity dates, SHA-256 fingerprint, and remaining validity days.

## Safety

The manager performs configuration validation before Nginx reloads. If a generated configuration fails validation, the previous snapshot is restored where applicable.

Always keep an independent backup of production Nginx configuration and review generated configuration before using the tool on critical infrastructure.

## Author

Designed and Development : antonios.mortos@outlook.com