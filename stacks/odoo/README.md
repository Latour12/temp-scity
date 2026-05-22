# Stack Odoo 19 Enterprise — host `10.61.21.133`

Odoo 19 Enterprise + PostgreSQL 16 + exporters (pg, node, cadvisor).
**Aucun port n'est exposé sur Internet** : tout est borné à l'IP LAN.

## 1. Pré-requis hôte

```bash
sudo mkdir -p /home/eadminsc/odoo/{config,data,logs,addons/enterprise,addons/extra,postgres/data,postgres/init,postgres/backups}
sudo chown -R 101:101 /home/eadminsc/odoo/{data,logs,config,addons}
sudo chown -R 70:70   /home/eadminsc/odoo/postgres
sudo chmod 700 /home/eadminsc/odoo/postgres/data
```

Copier les configs vers l'hôte (depuis ce repo) :

```bash
cp config/odoo.conf                         /home/eadminsc/odoo/config/
cp postgres/postgresql.conf                 /home/eadminsc/odoo/postgres/
cp postgres/init/01-monitoring-user.sh      /home/eadminsc/odoo/postgres/init/
chmod +x /home/eadminsc/odoo/postgres/init/01-monitoring-user.sh
chown 101:101 /home/eadminsc/odoo/config/odoo.conf
chown 70:70   /home/eadminsc/odoo/postgres/postgresql.conf
chown 70:70   /home/eadminsc/odoo/postgres/init/01-monitoring-user.sh
```

Éditer **`/home/eadminsc/odoo/config/odoo.conf`** : changer `admin_passwd` et
`db_password` (= `POSTGRES_PASSWORD` du `.env`).

## 2. Addons Enterprise

```bash
sudo -u eadminsc git clone --depth 1 -b 19.0 \
  https://<token>@github.com/odoo/enterprise.git \
  /home/eadminsc/odoo/addons/enterprise
sudo chown -R 101:101 /home/eadminsc/odoo/addons/enterprise
```

## 3. `.env`

```env
LAN_IP=10.61.21.133
POSTGRES_USER=odoo
POSTGRES_PASSWORD=<strong>
PG_EXPORTER_USER=monitoring
PG_EXPORTER_PASSWORD=<strong-readonly>
```

> Le user `monitoring` (rôle `pg_monitor`) est créé automatiquement par
> `postgres/init/01-monitoring-user.sh` au tout premier démarrage de la DB.
> Si la base existe déjà : `docker exec -it odoo-db psql -U odoo -c
> "CREATE ROLE monitoring LOGIN PASSWORD '...'; GRANT pg_monitor TO monitoring;"`

## 4. Déploiement Portainer (environnement = odoo-host)

1. *Stacks → Add stack → Repository*, path = `stacks/odoo/docker-compose.yml`.
2. *Load variables from .env file*.
3. *Deploy the stack*.

## 5. Ports exposés sur le LAN (`10.61.21.133`)

| Port | Service | Consommé par |
|---|---|---|
| 8069 | Odoo HTTP | Nginx (10.61.21.143) |
| 8072 | Odoo websocket | Nginx |
| 9100 | node-exporter | Prometheus (10.61.21.147) |
| 9101 | cadvisor | Prometheus |
| 9187 | postgres-exporter | Prometheus |

Aucun port DB (5432) n'est exposé.

## 6. Tuning rappelé

| Paramètre | Valeur | Justification |
|---|---|---|
| workers | 9 | (2 × CPU) + 1 sur 4 vCPU |
| max_cron_threads | 2 | cron en // |
| limit_memory_soft / hard | 2 / 2.5 GB | recyclage avant OOM kernel |
| db_maxconn | 30 | < `max_connections` PG |
| PG max_connections | 350 | `(workers + cron) × db_maxconn` + marge |
| PG shared_buffers | 4 GB | ~25 % RAM (cible 16 GB) |
| PG effective_cache_size | 12 GB | ~75 % RAM |

Adapter `postgres/postgresql.conf` si l'hôte n'a pas 16 GB.

## 7. Sauvegarde

```bash
docker exec odoo-db pg_dump -U odoo -Fc -d <db> > \
  /home/eadminsc/odoo/postgres/backups/<db>-$(date +%F).dump
tar czf /home/eadminsc/odoo/postgres/backups/filestore-$(date +%F).tgz \
  -C /home/eadminsc/odoo/data filestore
```

Cron suggéré (`/etc/cron.d/odoo-backup`) :

```cron
15 2 * * * eadminsc /home/eadminsc/scripts/odoo-backup.sh >> /var/log/odoo-backup.log 2>&1
```

## 8. Migration depuis un Odoo existant

```bash
# source
pg_dump -Fc <db> > old.dump
tar czf filestore.tgz -C ~/.local/share/Odoo/filestore <db>

# cible (10.61.21.133)
docker exec -i odoo-db createdb -U odoo <db>
docker exec -i odoo-db pg_restore -U odoo -d <db> < old.dump
tar xzf filestore.tgz -C /home/eadminsc/odoo/data/filestore/
chown -R 101:101 /home/eadminsc/odoo/data/filestore/
docker exec -it odoo-app odoo -c /etc/odoo/odoo.conf -d <db> -u all --stop-after-init
docker restart odoo-app
```

## 9. Communication avec Nginx (`10.61.21.143`)

Le vhost Nginx `etc/sites-enabled/odoo.conf` proxy vers :

- `http://10.61.21.133:8069` pour `/` et `/web/static`
- `http://10.61.21.133:8072` pour `/websocket` et `/longpolling`

Connexions **keep-alive HTTP 1.1** (`keepalive 32`, `Connection ""`) → un seul TCP
handshake par worker Nginx, réutilisé pour les requêtes suivantes. TLS terminé à
l'edge, trafic LAN en clair.

## 10. Dépannage

| Symptôme | Piste |
|---|---|
| `FATAL: too many clients` | bumper `max_connections` PG ou baisser `db_maxconn` |
| OOM worker | augmenter `limit_memory_hard` ou ajouter RAM |
| 502 depuis Nginx | port `8069` non joignable depuis `.143` → vérifier UFW |
| Prometheus target `DOWN` | vérifier `9100/9101/9187` ouverts pour `10.61.21.147` |
| Métriques PG vides | rôle `monitoring` absent ; lancer l'INIT du §3 manuellement |
