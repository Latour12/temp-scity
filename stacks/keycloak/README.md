# Stack Keycloak 26 — host `10.61.21.143` (co-localisé avec Nginx)

Keycloak Quarkus + PostgreSQL 16 + `pg-exporter`.

Par défaut la stack est en **mode bootstrap** (DNS pas prêt) : `:8080` est bindé
sur le LAN et `KC_HOSTNAME_STRICT=false` pour accéder via
`http://10.61.21.143:8080/admin`. **Retirer ces réglages avant la mise en prod**
(cf. §9).

## 1. Pré-requis hôte

```bash
sudo mkdir -p /home/eadminsc/keycloak/{postgres/data,postgres/init,postgres/backups,import,export,themes,providers}
sudo chown -R 70:70   /home/eadminsc/keycloak/postgres
sudo chmod 700        /home/eadminsc/keycloak/postgres/data
sudo chown -R 1000:0  /home/eadminsc/keycloak/{import,export,themes,providers}

docker network create edge 2>/dev/null || true
```

Copier l'init SQL :

```bash
cp postgres/init/01-monitoring-user.sh /home/eadminsc/keycloak/postgres/init/
chmod +x /home/eadminsc/keycloak/postgres/init/01-monitoring-user.sh
sudo chown 70:70 /home/eadminsc/keycloak/postgres/init/01-monitoring-user.sh
```

## 2. `.env`

```env
LAN_IP=10.61.21.143
KC_DB_NAME=keycloak
KC_DB_USER=keycloak
KC_DB_PASSWORD=<strong>
KC_HOSTNAME=sso.example.com
KC_HOSTNAME_STRICT=false
KC_HOSTNAME_STRICT_HTTPS=false
KC_BOOTSTRAP_ADMIN=admin
KC_BOOTSTRAP_ADMIN_PASSWORD=<strong>
PG_EXPORTER_USER=monitoring
PG_EXPORTER_PASSWORD=<strong-readonly>
```

## 3. Déploiement Portainer (environnement = edge-host)

Déployer **avant** la stack `nginx/` (pour que `keycloak` soit déjà sur le réseau `edge`).

1. *Stacks → Add stack → Repository*, path = `stacks/keycloak/docker-compose.yml`.
2. *Load variables from .env file*.
3. *Deploy*.

## 4. Migration depuis l'existant — 2 méthodes

### Méthode A : export / import par realm (versions différentes OK)

```bash
# === source ===
./kc.sh export --dir /tmp/kc-export --users different_files --realm <realm>
scp -r old-host:/tmp/kc-export/* /home/eadminsc/keycloak/import/
sudo chown -R 1000:0 /home/eadminsc/keycloak/import/

# === cible (après premier boot) ===
docker exec -it keycloak /opt/keycloak/bin/kc.sh import \
  --dir /opt/keycloak/data/import --override true
docker restart keycloak
```

### Méthode B : dump / restore PostgreSQL (même version majeure)

```bash
# source
pg_dump -h <old-pg> -U keycloak -Fc keycloak > /tmp/keycloak.dump
scp /tmp/keycloak.dump 10.61.21.143:/home/eadminsc/keycloak/postgres/backups/

# cible
docker compose -f /home/eadminsc/keycloak/docker-compose.yml stop keycloak
docker exec -i keycloak-db dropdb -U keycloak --if-exists keycloak
docker exec -i keycloak-db createdb -U keycloak keycloak
docker exec -i keycloak-db pg_restore -U keycloak -d keycloak --no-owner --clean --if-exists \
  < /home/eadminsc/keycloak/postgres/backups/keycloak.dump
docker compose -f /home/eadminsc/keycloak/docker-compose.yml start keycloak
```

Si la version Keycloak diffère, Liquibase applique les migrations au démarrage.

### Thèmes & providers

```bash
cp -a /old/path/themes/*        /home/eadminsc/keycloak/themes/
cp -a /old/path/providers/*.jar /home/eadminsc/keycloak/providers/
docker restart keycloak
```

## 5. Vérifier l'installation (bootstrap)

```bash
# containers
docker ps --filter name=keycloak --format "table {{.Names}}\t{{.Status}}"

# health (LAN)
curl -s http://10.61.21.143:9000/health/ready | jq -r .status   # UP

# console admin directe (bootstrap, sans DNS)
curl -s -o /dev/null -w "%{http_code}\n" http://10.61.21.143:8080/admin/
# attendu : 200 ou 302 → navigateur : http://10.61.21.143:8080/admin
```

Login : `KC_BOOTSTRAP_ADMIN` / `KC_BOOTSTRAP_ADMIN_PASSWORD`.

## 6. Ports

| Port | Service | Visibilité (bootstrap) | Visibilité (prod §9) |
|---|---|---|---|
| 8080 | Keycloak HTTP | LAN (`10.61.21.143`) | **retiré** — Nginx via réseau `edge` |
| 9000 | `/metrics`, `/health/*` | LAN | LAN |
| 9187 | pg-exporter | LAN | LAN |

> La DB Postgres (5432) **n'est jamais exposée**.

## 7. Reverse-proxy

`stacks/nginx/etc/sites-enabled/keycloak.conf` proxy `https://sso.example.com`
→ `http://keycloak:8080` (résolution Docker DNS interne, 0 hop LAN).
Headers `X-Forwarded-*` + `KC_PROXY_HEADERS=xforwarded` côté Keycloak.

## 8. Sauvegarde

```bash
docker exec keycloak-db pg_dump -U keycloak -Fc keycloak > \
  /home/eadminsc/keycloak/postgres/backups/keycloak-$(date +%F).dump
docker exec keycloak /opt/keycloak/bin/kc.sh export \
  --dir /opt/keycloak/data/export --users different_files
```

## 9. Passage en prod — retirer impérativement

Quand le DNS public pointe vers `10.61.21.143` et Nginx sert `https://sso.example.com` :

### 1. `docker-compose.yml` — retirer le bind `:8080`

```yaml
    ports:
      # - "${LAN_IP}:8080:8080"   # ← supprimer cette ligne
      - "${LAN_IP}:9000:9000"
```

Keycloak reste joignable par Nginx via le réseau Docker `edge` (`http://keycloak:8080`).

### 2. `.env` — activer le strict hostname

```env
KC_HOSTNAME=sso.example.com
KC_HOSTNAME_STRICT=true
KC_HOSTNAME_STRICT_HTTPS=true
```

### 3. Redéployer la stack dans Portainer

Puis vérifier :

```bash
# ne doit plus répondre depuis le LAN
curl -s -o /dev/null -w "%{http_code}\n" --connect-timeout 2 http://10.61.21.143:8080/admin/
# attendu : 000 (connexion refusée)

# doit répondre via Nginx
curl -k -s -o /dev/null -w "%{http_code}\n" https://sso.example.com/admin/
# attendu : 200 ou 302
```

### 4. UFW (recommandé)

```bash
# s'assurer que 8080 n'est plus autorisé depuis le LAN en prod
sudo ufw delete allow from 10.61.21.0/24 to any port 8080 proto tcp 2>/dev/null || true
```

Checklist prod :

- [ ] Ligne `:8080:8080` supprimée du compose
- [ ] `KC_HOSTNAME_STRICT=true`
- [ ] `KC_HOSTNAME_STRICT_HTTPS=true`
- [ ] Certificat Let's Encrypt actif sur Nginx pour `sso.example.com`
- [ ] `http://10.61.21.143:8080` inaccessible depuis le LAN

## 10. Dépannage

| Symptôme | Piste |
|---|---|
| Boucle login / cookie domain | `KC_HOSTNAME` = FQDN exact derrière Nginx ; `X-Forwarded-Proto https` ok ? |
| 502 depuis Nginx | container `keycloak` pas sur réseau `edge` (`docker network inspect edge`) |
| Liquibase échoue | upgrade minor par minor (24 → 25 → 26) |
| Prometheus target DOWN | port `9000` non joignable depuis `.147`, vérifier UFW |
| Metrics 404 | `KC_METRICS_ENABLED=true` + image `--optimized` rebuildée si feature flags changés |
