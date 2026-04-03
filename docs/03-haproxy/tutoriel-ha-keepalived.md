# Tutoriel Pratique : HAProxy HA + Keepalived sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel HAProxy (`docs/03-haproxy/tutoriel-docker.md`)

## Objectifs
1. Monter 2 HAProxy en haute disponibilité avec Keepalived
2. Comprendre le mécanisme de VIP (Virtual IP) avec VRRP
3. Tester le failover HAProxy : kill le MASTER, le BACKUP prend la VIP
4. Observer la preemption : quand le MASTER revient, il reprend la VIP

## Architecture

```
            Client / PgBouncer
                    │
              VIP 172.20.0.100
              :5000 (write) / :5001 (read)
                    │
         ┌──────────┴──────────┐
         │                     │
┌────────▼────────┐  ┌────────▼────────┐
│   HAProxy-1     │  │   HAProxy-2     │
│   172.20.0.10   │  │   172.20.0.11   │
│ + Keepalived    │  │ + Keepalived    │
│   MASTER        │  │   BACKUP        │
│   priority=150  │  │   priority=100  │
└────────┬────────┘  └────────┬────────┘
         │                     │
         └──────────┬──────────┘
                    │
         ┌──────────▼──────────┐
         │   Patroni / PG x3   │
         │ patroni-1 (Leader)  │
         │ patroni-2 (Replica) │
         │ patroni-3 (Replica) │
         └──────────┬──────────┘
                    │
         ┌──────────▼──────────┐
         │     etcd x3         │
         └─────────────────────┘
```

### Comment ça marche

1. Keepalived utilise le protocole **VRRP** (Virtual Router Redundancy Protocol)
2. Le MASTER envoie des annonces VRRP toutes les secondes
3. Si le BACKUP ne reçoit plus d'annonces → il prend la VIP
4. Quand le MASTER revient → il reprend la VIP (preemption, car priority plus haute)

---

## Étape 1 : Fichiers de configuration

### keepalived/keepalived-master.conf

```
global_defs {
    router_id HAPROXY_MASTER
}

vrrp_script check_haproxy {
    script "/bin/sh -c 'kill -0 $(cat /var/run/haproxy.pid 2>/dev/null) 2>/dev/null || exit 1'"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 150
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass transactis
    }

    virtual_ipaddress {
        172.20.0.100/24
    }

    track_script {
        check_haproxy
    }
}
```

### keepalived/keepalived-backup.conf

```
global_defs {
    router_id HAPROXY_BACKUP
}

vrrp_script check_haproxy {
    script "/bin/sh -c 'kill -0 $(cat /var/run/haproxy.pid 2>/dev/null) 2>/dev/null || exit 1'"
    interval 2
    weight -20
    fall 3
    rise 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass transactis
    }

    virtual_ipaddress {
        172.20.0.100/24
    }

    track_script {
        check_haproxy
    }
}
```

### Paramètres clés de Keepalived

| Paramètre | Valeur | Rôle |
|---|---|---|
| `state` | MASTER / BACKUP | Rôle initial au démarrage |
| `interface` | eth0 | Interface réseau où la VIP est assignée |
| `virtual_router_id` | 51 | Identifiant VRRP (doit être identique sur les 2 nœuds) |
| `priority` | 150 / 100 | Le plus haut gagne la VIP. MASTER=150, BACKUP=100 |
| `advert_int` | 1 | Intervalle d'annonce VRRP en secondes |
| `auth_pass` | transactis | Mot de passe VRRP (partagé entre les 2) |
| `virtual_ipaddress` | 172.20.0.100/24 | La VIP partagée |
| `track_script` | check_haproxy | Si HAProxy est down → priority baisse de 20 → le BACKUP prend le relais |

### haproxy.cfg

Le même que dans le tutoriel HAProxy précédent (avec le frontend prometheus sur :8405).

## Étape 2 : Docker Compose

Crée `docker-compose-ha.yml` :

```yaml
services:
  # ===== ETCD =====
  etcd-1:
    image: quay.io/coreos/etcd:v3.5.12
    container_name: etcd-1
    hostname: etcd-1
    command:
      - etcd
      - --name=etcd-1
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://etcd-1:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://etcd-1:2380
      - --initial-cluster=etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,etcd-3=http://etcd-3:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=ha-lab
      - --metrics=extensive
    networks:
      hanet:
        ipv4_address: 172.20.0.2

  etcd-2:
    image: quay.io/coreos/etcd:v3.5.12
    container_name: etcd-2
    hostname: etcd-2
    command:
      - etcd
      - --name=etcd-2
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://etcd-2:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://etcd-2:2380
      - --initial-cluster=etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,etcd-3=http://etcd-3:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=ha-lab
      - --metrics=extensive
    networks:
      hanet:
        ipv4_address: 172.20.0.3

  etcd-3:
    image: quay.io/coreos/etcd:v3.5.12
    container_name: etcd-3
    hostname: etcd-3
    command:
      - etcd
      - --name=etcd-3
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://etcd-3:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://etcd-3:2380
      - --initial-cluster=etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,etcd-3=http://etcd-3:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=ha-lab
      - --metrics=extensive
    networks:
      hanet:
        ipv4_address: 172.20.0.4

  # ===== PATRONI =====
  patroni-1:
    image: ghcr.io/zalando/spilo-16:3.2-p2
    container_name: patroni-1
    hostname: patroni-1
    environment:
      SCOPE: pg-cluster
      PGVERSION: "16"
      ETCD3_HOSTS: "'etcd-1:2379','etcd-2:2379','etcd-3:2379'"
      PATRONI_NAME: patroni-1
      PATRONI_RESTAPI_LISTEN: 0.0.0.0:8008
      PATRONI_RESTAPI_CONNECT_ADDRESS: patroni-1:8008
      PATRONI_POSTGRESQL_LISTEN: 0.0.0.0:5432
      PATRONI_POSTGRESQL_CONNECT_ADDRESS: patroni-1:5432
      PGPASSWORD_SUPERUSER: postgres
      PGPASSWORD_STANDBY: rep_pass
      PATRONI_POSTGRESQL_DATA_DIR: /home/postgres/pgdata/pgroot/data
      ALLOW_NOSSL: "true"
    networks:
      hanet:
        ipv4_address: 172.20.0.5

  patroni-2:
    image: ghcr.io/zalando/spilo-16:3.2-p2
    container_name: patroni-2
    hostname: patroni-2
    environment:
      SCOPE: pg-cluster
      PGVERSION: "16"
      ETCD3_HOSTS: "'etcd-1:2379','etcd-2:2379','etcd-3:2379'"
      PATRONI_NAME: patroni-2
      PATRONI_RESTAPI_LISTEN: 0.0.0.0:8008
      PATRONI_RESTAPI_CONNECT_ADDRESS: patroni-2:8008
      PATRONI_POSTGRESQL_LISTEN: 0.0.0.0:5432
      PATRONI_POSTGRESQL_CONNECT_ADDRESS: patroni-2:5432
      PGPASSWORD_SUPERUSER: postgres
      PGPASSWORD_STANDBY: rep_pass
      PATRONI_POSTGRESQL_DATA_DIR: /home/postgres/pgdata/pgroot/data
      ALLOW_NOSSL: "true"
    networks:
      hanet:
        ipv4_address: 172.20.0.6

  patroni-3:
    image: ghcr.io/zalando/spilo-16:3.2-p2
    container_name: patroni-3
    hostname: patroni-3
    environment:
      SCOPE: pg-cluster
      PGVERSION: "16"
      ETCD3_HOSTS: "'etcd-1:2379','etcd-2:2379','etcd-3:2379'"
      PATRONI_NAME: patroni-3
      PATRONI_RESTAPI_LISTEN: 0.0.0.0:8008
      PATRONI_RESTAPI_CONNECT_ADDRESS: patroni-3:8008
      PATRONI_POSTGRESQL_LISTEN: 0.0.0.0:5432
      PATRONI_POSTGRESQL_CONNECT_ADDRESS: patroni-3:5432
      PGPASSWORD_SUPERUSER: postgres
      PGPASSWORD_STANDBY: rep_pass
      PATRONI_POSTGRESQL_DATA_DIR: /home/postgres/pgdata/pgroot/data
      ALLOW_NOSSL: "true"
    networks:
      hanet:
        ipv4_address: 172.20.0.7

  # ===== HAPROXY HA (2 nodes + Keepalived) =====
  haproxy-1:
    image: haproxy:2.9
    container_name: haproxy-1
    hostname: haproxy-1
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      hanet:
        ipv4_address: 172.20.0.10
    depends_on:
      - patroni-1
      - patroni-2
      - patroni-3

  keepalived-1:
    image: osixia/keepalived:2.0.20
    container_name: keepalived-1
    network_mode: "service:haproxy-1"
    cap_add:
      - NET_ADMIN
      - NET_BROADCAST
      - NET_RAW
    volumes:
      - ./keepalived/keepalived-master.conf:/usr/local/etc/keepalived/keepalived.conf:ro
    depends_on:
      - haproxy-1

  haproxy-2:
    image: haproxy:2.9
    container_name: haproxy-2
    hostname: haproxy-2
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      hanet:
        ipv4_address: 172.20.0.11
    depends_on:
      - patroni-1
      - patroni-2
      - patroni-3

  keepalived-2:
    image: osixia/keepalived:2.0.20
    container_name: keepalived-2
    network_mode: "service:haproxy-2"
    cap_add:
      - NET_ADMIN
      - NET_BROADCAST
      - NET_RAW
    volumes:
      - ./keepalived/keepalived-backup.conf:/usr/local/etc/keepalived/keepalived.conf:ro
    depends_on:
      - haproxy-2

  # ===== PGBOUNCER (via VIP) =====
  pgbouncer:
    image: edoburu/pgbouncer:latest
    container_name: pgbouncer
    hostname: pgbouncer
    environment:
      DB_HOST: "172.20.0.100"
      DB_PORT: "5000"
      DB_USER: postgres
      DB_PASSWORD: postgres
      AUTH_TYPE: plain
      POOL_MODE: transaction
      DEFAULT_POOL_SIZE: "10"
      ADMIN_USERS: postgres
      LISTEN_PORT: "6432"
    ports:
      - "6432:6432"
    networks:
      hanet:
        ipv4_address: 172.20.0.20
    depends_on:
      - haproxy-1
      - haproxy-2

networks:
  hanet:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
          gateway: 172.20.0.1
```

> **Note** : PgBouncer se connecte à la **VIP** `172.20.0.100:5000`, pas à un HAProxy
> spécifique. Si le MASTER tombe, Keepalived bascule la VIP → PgBouncer se reconnecte
> automatiquement.

## Étape 3 : Démarrer et vérifier

```bash
mkdir -p keepalived
# Copier keepalived/keepalived-master.conf et keepalived/keepalived-backup.conf
# Copier haproxy.cfg (avec frontend prometheus :8405)

docker compose -f docker-compose-ha.yml up -d
sleep 45

# Vérifier les containers
docker compose -f docker-compose-ha.yml ps

# Vérifier Patroni
docker exec patroni-1 patronictl list
```

## Étape 4 : Vérifier la VIP

```bash
# Qui a la VIP ?
docker logs keepalived-1 2>&1 | grep -E "MASTER|VIP|172.20.0.100" | tail -5
docker logs keepalived-2 2>&1 | grep -E "BACKUP|VIP|172.20.0.100" | tail -5

# keepalived-1 doit être MASTER avec la VIP 172.20.0.100
```

### Tester la connexion via la VIP

On utilise un client PostgreSQL temporaire dans le réseau Docker :

```bash
# Write (via VIP → HAProxy MASTER → leader PG)
docker run --rm --network training_hanet -e PGPASSWORD=postgres \
  postgres:16-alpine psql -h 172.20.0.100 -p 5000 -U postgres \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
# → inet_server_addr = leader, pg_is_in_recovery = f

# Read (via VIP → HAProxy MASTER → replica PG)
docker run --rm --network training_hanet -e PGPASSWORD=postgres \
  postgres:16-alpine psql -h 172.20.0.100 -p 5001 -U postgres \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
# → pg_is_in_recovery = t (replica)

# Via PgBouncer (→ VIP → HAProxy → leader)
PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
```

## Étape 5 : Tester le failover HAProxy

### 5.1 Kill le MASTER

```bash
# AVANT : vérifier qui sert
docker logs keepalived-1 2>&1 | tail -3
# → "Entering MASTER STATE"

# Kill HAProxy-1 (le MASTER)
docker stop haproxy-1
```

### 5.2 Observer la bascule

```bash
# Keepalived-2 prend la VIP (~2 secondes)
docker logs keepalived-2 2>&1 | tail -5
# → "Entering MASTER STATE"
# → "setting VIPs"
# → "Sending gratuitous ARP on eth0 for 172.20.0.100"

# La connexion via VIP fonctionne toujours !
docker run --rm --network training_hanet -e PGPASSWORD=postgres \
  postgres:16-alpine psql -h 172.20.0.100 -p 5000 -U postgres \
  -c "SELECT 'HAProxy failover OK';"
```

### 5.3 Restaurer et observer la preemption

```bash
# Redémarrer HAProxy-1
docker start haproxy-1
sleep 5

# Keepalived-1 reprend la VIP (priority 150 > 100)
docker logs keepalived-1 2>&1 | tail -5
# → "Entering MASTER STATE"

# Keepalived-2 repasse en BACKUP
docker logs keepalived-2 2>&1 | tail -5
# → "Entering BACKUP STATE"
```

> **Preemption** : quand le MASTER revient, il reprend la VIP car sa priority (150)
> est plus haute que le BACKUP (100). En production, on peut désactiver la preemption
> avec `nopreempt` dans la config du BACKUP si on veut éviter les bascules inutiles.

## Étape 6 : Tester le double failover (HAProxy + Patroni)

```bash
# 1. Kill HAProxy-1 (VIP bascule sur HAProxy-2)
docker stop haproxy-1

# 2. Kill le leader PostgreSQL
docker exec patroni-1 patronictl list
docker kill patroni-1

# 3. Attendre le failover Patroni (~30s)
sleep 30

# 4. Vérifier : PG a un nouveau leader, HAProxy-2 sert via la VIP
docker exec patroni-2 patronictl list
docker run --rm --network training_hanet -e PGPASSWORD=postgres \
  postgres:16-alpine psql -h 172.20.0.100 -p 5000 -U postgres \
  -c "SELECT inet_server_addr(), pg_is_in_recovery();"
# → nouveau leader

# 5. PgBouncer fonctionne toujours
PGPASSWORD=postgres psql -h localhost -p 6432 -U postgres \
  -c "SELECT 'double failover OK';"

# 6. Restaurer
docker start haproxy-1 patroni-1
```

## Étape 7 : HAProxy Stats sur les 2 nœuds

Les 2 HAProxy ont leur propre page stats :

```bash
# HAProxy-1 stats (accessible depuis le réseau Docker)
# http://172.20.0.10:8404/stats

# HAProxy-2 stats
# http://172.20.0.11:8404/stats

# Les 2 montrent les mêmes backends (pg-write, pg-read) avec les mêmes états
```

## Étape 8 : Nettoyage

```bash
docker compose -f docker-compose-ha.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Mesurer le temps de failover
1. Lance une boucle de connexions toutes les secondes
2. Kill haproxy-1
3. Compte combien de connexions échouent avant que haproxy-2 prenne la VIP
4. Le failover devrait prendre ~2-3 secondes

```bash
# Dans un terminal : boucle de test
while true; do
  docker run --rm --network training_hanet -e PGPASSWORD=postgres \
    postgres:16-alpine psql -h 172.20.0.100 -p 5000 -U postgres \
    -tAc "SELECT now();" 2>&1 | head -1
  sleep 1
done

# Dans un autre terminal : kill
docker stop haproxy-1
```

### Exercice 2 : Désactiver la preemption
1. Ajoute `nopreempt` dans keepalived-backup.conf
2. Kill haproxy-1 → haproxy-2 prend la VIP
3. Restart haproxy-1 → la VIP **reste** sur haproxy-2
4. Ca évite les bascules inutiles quand le MASTER revient

### Exercice 3 : Simuler un split-brain
1. Que se passe-t-il si les 2 Keepalived ne se voient plus (réseau partitionné) ?
2. Les 2 deviennent MASTER → 2 VIP → **split-brain**
3. C'est pour ça que `authentication` est important + unicast en prod
