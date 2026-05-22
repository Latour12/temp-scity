# Stack Monitoring — host `10.61.21.147`

Prometheus + Alertmanager + Grafana + node-exporter + cadvisor (locaux à cet hôte).
Les exporters `pg-exporter` et `nginx-exporter` vivent **sur leurs hôtes
respectifs** (déployés avec les stacks `odoo/`, `keycloak/`, `nginx/`) → un
seul aller-retour LAN par scrape, pas de relais.

## 1. Pré-requis hôte

```bash
sudo mkdir -p /home/eadminsc/monitoring/{prometheus/data,prometheus/rules,alertmanager/data,grafana/data,grafana/provisioning/{datasources,dashboards/json}}

sudo chown -R 65534:65534 /home/eadminsc/monitoring/prometheus
sudo chown -R 65534:65534 /home/eadminsc/monitoring/alertmanager
sudo chown -R 472:472     /home/eadminsc/monitoring/grafana
```

Copier les configs :

```bash
cp prometheus/prometheus.yml          /home/eadminsc/monitoring/prometheus/
cp prometheus/rules/alerts.yml        /home/eadminsc/monitoring/prometheus/rules/
cp alertmanager/alertmanager.yml      /home/eadminsc/monitoring/alertmanager/
cp -r grafana/provisioning/*          /home/eadminsc/monitoring/grafana/provisioning/
sudo chown -R 65534:65534 /home/eadminsc/monitoring/prometheus /home/eadminsc/monitoring/alertmanager
sudo chown -R 472:472     /home/eadminsc/monitoring/grafana
```

## 2. `.env`

```env
LAN_IP=10.61.21.147
GF_ADMIN_USER=admin
GF_ADMIN_PASSWORD=<strong>
GF_ROOT_URL=https://grafana.example.com
GF_DOMAIN=grafana.example.com
```

> Les credentials `PG_EXPORTER_*` vivent dans les `.env` des stacks `odoo/` et
> `keycloak/` (pas ici, puisque les exporters tournent là-bas).

## 3. Déploiement Portainer (environnement = mon-host)

1. *Stacks → Add stack → Repository*, path = `stacks/monitoring/docker-compose.yml`.
2. *Load variables from .env file*.
3. *Deploy*.

Accès :

- Grafana : `http://10.61.21.147:3000` (LAN) ou `https://grafana.example.com` (via Nginx).
- Prometheus : `http://10.61.21.147:9090` (LAN, accès admin direct).
- Alertmanager : `http://10.61.21.147:9093` (LAN).

## 4. Targets scrappés (résumé)

| Job | Cible | Hôte source |
|---|---|---|
| `node` | `:9100` sur les 3 hôtes | 133 / 143 / 147 |
| `cadvisor` | `:9101` sur les 3 hôtes | 133 / 143 / 147 |
| `nginx` | `10.61.21.143:9113` | edge |
| `keycloak` | `10.61.21.143:9000/metrics` | edge |
| `postgres-odoo` | `10.61.21.133:9187` | odoo |
| `postgres-keycloak` | `10.61.21.143:9187` | edge |

Tout est scrappé en HTTP direct sur le LAN (pas de DNS, pas de TLS).

## 5. Pré-requis sur les autres hôtes

| Hôte | Doit exposer (sur `LAN_IP`) |
|---|---|
| `10.61.21.133` | `9100`, `9101`, `9187` |
| `10.61.21.143` | `9000`, `9100`, `9101`, `9113`, `9187` |

UFW : `sudo ufw allow from 10.61.21.147 to any port 9000,9100,9101,9113,9187 proto tcp`.

## 6. Alertes par défaut

Voir `prometheus/rules/alerts.yml` :

- Host down / CPU > 90 % / RAM > 90 % / disque < 10 %
- Container OOM / restart loop
- Nginx / Keycloak / Postgres `up == 0`
- Postgres connexions > 80 %

Adapter les seuils + destinataires Alertmanager (SMTP / Slack) dans
`alertmanager/alertmanager.yml`.

## 7. Dashboards Grafana

À importer depuis l'UI ou à déposer en JSON sous
`grafana/provisioning/dashboards/json/` (provisioning auto au démarrage) :

| Dashboard | ID Grafana.com |
|---|---|
| Node Exporter Full | 1860 |
| Docker / cAdvisor | 19792 |
| Nginx exporter | 12708 |
| PostgreSQL | 9628 |
| Keycloak | 17878 |

## 8. Reverse-proxy (Grafana public)

Le vhost `stacks/nginx/etc/sites-enabled/grafana.conf` proxy
`https://grafana.example.com` → `http://10.61.21.147:3000` en keep-alive HTTP/1.1.

## 9. Sauvegarde

- Prometheus : `/home/eadminsc/monitoring/prometheus/data` (snapshot via API
  `curl -X POST http://10.61.21.147:9090/api/v1/admin/tsdb/snapshot`).
- Grafana : `/home/eadminsc/monitoring/grafana/data/grafana.db` (sqlite).
- Alertmanager : `/home/eadminsc/monitoring/alertmanager/data` (silences).

## 10. Dépannage

| Symptôme | Piste |
|---|---|
| Target `DOWN` | UFW de l'hôte cible — autoriser `10.61.21.147` |
| `pg_up == 0` | rôle SQL `monitoring` absent → script init dans stack odoo/keycloak |
| Pas de métriques Keycloak | `KC_METRICS_ENABLED=true` + port `9000` bindé sur LAN |
| Alertmanager n'envoie rien | `smtp_*` vide ou `receiver` mal routé |
| Grafana 502 derrière Nginx | port `3000` pas bindé sur `LAN_IP` (cf. `.env`) |
