# Stack Nginx — host `10.61.21.143` (edge)

Reverse-proxy unique exposé sur Internet, devant :

- **Odoo** (`10.61.21.133:8069 / 8072`) via HTTP keep-alive LAN.
- **Keycloak** (même hôte, réseau Docker `edge`) → 0 hop LAN.
- **Grafana** (`10.61.21.147:3000`) via HTTP keep-alive LAN.

Inclut aussi les exporters `node`, `cadvisor`, `nginx-exporter` pour Prometheus.

## 1. Pré-requis hôte

```bash
sudo mkdir -p /home/eadminsc/nginx/{etc/conf.d,etc/sites-enabled,etc/snippets,letsencrypt,webroot,logs}
docker network create edge 2>/dev/null || true   # partagé avec stack keycloak
```

### Désactiver Nginx natif (`apt`) sur cet hôte

```bash
sudo systemctl disable --now nginx
sudo systemctl mask nginx
sudo apt-mark hold nginx
```

## 2. Migration depuis `apt`

| Source (apt) | Destination |
|---|---|
| `/etc/nginx/nginx.conf` | `/home/eadminsc/nginx/etc/nginx.conf` |
| `/etc/nginx/conf.d/` | `/home/eadminsc/nginx/etc/conf.d/` |
| `/etc/nginx/sites-enabled/` | `/home/eadminsc/nginx/etc/sites-enabled/` |
| `/etc/nginx/snippets/` | `/home/eadminsc/nginx/etc/snippets/` |
| `/etc/letsencrypt/` | `/home/eadminsc/nginx/letsencrypt/` |
| `/var/www/letsencrypt/` | `/home/eadminsc/nginx/webroot/` |
| `/var/log/nginx/` | `/home/eadminsc/nginx/logs/` |

```bash
sudo cp -a /etc/nginx/nginx.conf       /home/eadminsc/nginx/etc/nginx.conf
sudo cp -a /etc/nginx/conf.d/.         /home/eadminsc/nginx/etc/conf.d/
sudo cp -a /etc/nginx/sites-enabled/.  /home/eadminsc/nginx/etc/sites-enabled/
sudo cp -a /etc/nginx/snippets/.       /home/eadminsc/nginx/etc/snippets/ 2>/dev/null || true
sudo cp -a /etc/letsencrypt/.          /home/eadminsc/nginx/letsencrypt/
```

Les vhosts fournis dans ce repo (`odoo.conf`, `keycloak.conf`, `grafana.conf`)
remplacent ceux d'`apt` ; à ajuster (FQDN réels) avant déploiement.

## 3. `.env`

```env
LAN_IP=10.61.21.143
TZ=Europe/Paris
```

## 4. Déploiement Portainer (environnement = edge-host)

> Déployer la stack `keycloak/` **avant** la stack `nginx/` (pour que le réseau
> `edge` contienne déjà le container `keycloak`).

1. *Stacks → Add stack → Repository*, path = `stacks/nginx/docker-compose.yml`.
2. *Load variables from .env file*.
3. *Deploy*.
4. Test : `curl -I http://10.61.21.143/healthz` → `200`.

## 5. Émission Let's Encrypt

```bash
docker exec -it certbot certbot certonly --webroot -w /var/www/certbot \
  -d odoo.example.com -d sso.example.com -d grafana.example.com \
  --email ops@example.com --agree-tos --no-eff-email
docker exec nginx nginx -s reload
```

Le service `certbot` boucle ensuite toutes les 12 h sur `certbot renew`.

## 6. Optimisations « limiter les allers-retours »

| Mécanisme | Où | Effet |
|---|---|---|
| `keepalive N` + `proxy_http_version 1.1` + `Connection ""` | tous vhosts | une seule connexion TCP par worker → backend, réutilisée 1000× |
| Upstreams en IP LAN | `*.conf` | pas de DNS, pas de SRV lookup |
| `map $http_upgrade $connection_upgrade` | `nginx.conf` | bascule WebSocket / HTTP keep-alive en un header |
| TLS terminé à l'edge | `nginx.conf` | LAN en clair, pas de TLS handshake interne |
| `proxy_cache` `/web/static/` | `odoo.conf` | assets Odoo servis depuis Nginx |
| Keycloak via réseau Docker `edge` | `keycloak.conf` | 0 hop LAN (même host) |
| Compression `gzip` à l'edge | `nginx.conf` | unique passe de compression |

## 7. Ports

| Port | Service | Visibilité |
|---|---|---|
| 80, 443 | Nginx | **Internet** |
| 9100 | node-exporter | LAN (`10.61.21.0/24`) |
| 9101 | cadvisor | LAN |
| 9113 | nginx-exporter | LAN |

## 8. Reload / test config

```bash
docker exec nginx nginx -t
docker exec nginx nginx -s reload
```

## 9. Dépannage

| Symptôme | Piste |
|---|---|
| 502 sur `/` (Odoo) | port 8069 fermé côté `10.61.21.133`, UFW LAN ? |
| 502 sur `/` (Keycloak) | container `keycloak` pas sur le réseau `edge` |
| 502 sur Grafana | port 3000 non bindé sur LAN dans stack monitoring |
| ACME 404 | bind-mount `/var/www/certbot` mal résolu côté server default |
| Boucle de redirect Keycloak | manque `X-Forwarded-Proto https` ou `KC_HOSTNAME` mal réglé |
