# temp-scity — Portainer Stacks (multi-host)

Stacks Docker Compose à déployer depuis Portainer sur **trois hôtes Linux** du même
LAN `10.61.21.0/24`. Home utilisateur partout : `/home/eadminsc`.

## Topologie

```
                Internet
                   │ 443/80
                   ▼
   ┌─────────────────────────────────┐
   │  10.61.21.143  (gateway)        │
   │   stacks: nginx + keycloak      │
   │   ports public : 443, 80        │
   └───────┬───────────────┬─────────┘
           │ LAN (HTTP)    │ LAN (HTTP)
           ▼               ▼
   10.61.21.133       10.61.21.147
   stack: odoo        stack: monitoring
   (Odoo + PG16)      (Prom + AM + Grafana)
```

- **Internet → seul `10.61.21.143:443`** est exposé (TLS termine ici).
- **LAN privé `10.61.21.0/24`** pour tout le reste (HTTP en clair, pas de TLS interne).
- Les exporters Prometheus sont **déployés sur l'hôte de la donnée** (pg-exporter à côté de la DB), pas sur le serveur de monitoring → un seul aller-retour LAN par scrape.

## Répartition des stacks

| Hôte | IP | Stack(s) | Ports publiés sur le LAN |
|---|---|---|---|
| **odoo-host** | `10.61.21.133` | `stacks/odoo/` | `8069`, `8072` (Odoo), `9100` (node), `9101` (cadvisor), `9187` (pg) |
| **edge-host** | `10.61.21.143` | `stacks/nginx/` + `stacks/keycloak/` | `80`/`443` (public), `9000` (KC metrics), `9100`, `9101`, `9113` (nginx), `9187` |
| **mon-host** | `10.61.21.147` | `stacks/monitoring/` | `9090`/`9093`/`3000` (LAN), `9100`, `9101` |

> Aucun port DB (`5432`) n'est exposé sur le LAN ; seuls les exporters le sont.

## Préparation par hôte (à faire une fois)

Sur **chaque** serveur, en root :

```bash
sudo mkdir -p /home/eadminsc
sudo chown -R eadminsc:eadminsc /home/eadminsc
```

Puis selon l'hôte, créer l'arborescence du stack (voir README de chaque stack).

### Réseaux Docker

- Sur `10.61.21.143` uniquement : `docker network create edge` (partagé entre `nginx`
  et `keycloak` pour que Nginx résolve `keycloak:8080` via DNS Docker local).
- Aucun réseau partagé inter-hôtes — la communication passe par les IPs LAN.

## Optimisations « limiter les allers-retours »

1. **TLS terminé uniquement à l'edge** (Nginx). Backends LAN en HTTP 1.1 clair.
2. **Keep-alive amont** (`keepalive 32`, `proxy_http_version 1.1`, `Connection ""`)
   dans tous les vhosts → connexions Nginx↔backend réutilisées.
3. **Upstreams en IP LAN** (pas de DNS) → 0 résolution.
4. **HTTP/2 client-side** + compression gzip côté edge uniquement.
5. **Cache statique Odoo** (`/web/static`) sur Nginx (10 jours).
6. **Prometheus scrape direct** des exporters via LAN, sans relais.
7. **Keycloak + Nginx co-localisés** sur `10.61.21.143` → Nginx parle à Keycloak
   via le réseau Docker `edge` (pas de hop LAN).

## Firewall (UFW exemple, à appliquer sur chaque hôte)

```bash
# edge-host 10.61.21.143 — public
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw allow from 10.61.21.0/24

# odoo-host 10.61.21.133 — LAN only
sudo ufw default deny incoming
sudo ufw allow from 10.61.21.0/24
sudo ufw allow 22/tcp

# mon-host 10.61.21.147 — LAN only
sudo ufw default deny incoming
sudo ufw allow from 10.61.21.0/24
sudo ufw allow 22/tcp
```

## Déploiement dans Portainer

Une **environnement Portainer par hôte** (agent Portainer ou edge agent) :

1. *Environments → Add environment → Docker Standalone* puis pointer chaque host.
2. *Stacks → Add stack → Repository*, sélectionner l'environnement cible.
3. *Path* = `stacks/<service>/docker-compose.yml`, charger le `.env`.
4. *Deploy*.

## Ordre de démarrage recommandé

1. **mon-host** (`monitoring`) — pour capter les métriques dès le boot des autres.
2. **edge-host** (`keycloak`) puis (`nginx`) — keycloak avant que nginx ne le proxy.
3. **odoo-host** (`odoo`) — peut être démarré en parallèle de keycloak.
