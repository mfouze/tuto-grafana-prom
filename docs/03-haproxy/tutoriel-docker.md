# Tutoriel Pratique : HAProxy devant PostgreSQL/Patroni sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel Patroni (`docs/02-postgresql-patroni/tutoriel-docker.md`)

## Objectifs
1. Ajouter HAProxy devant le cluster Patroni
2. Comprendre le routage write/read
3. Observer le failover des backends
4. Explorer la page de stats

---

## Étape 1 : Préparer la configuration HAProxy

Crée un fichier `haproxy.cfg` :

```cfg
global
    log stdout format raw local0
    maxconn 500

defaults
    log     global
    mode    tcp
    retries 3
    timeout connect 5s
    timeout client  30m
    timeout server  30m
    timeout check   5s

listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 5s
    stats show-legends

frontend prometheus
    bind *:8405
    mode http
    http-request use-service prometheus-exporter if { path /metrics }

listen pg-write
    bind *:5000
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server patroni-1 patroni-1:5432 check port 8008
    server patroni-2 patroni-2:5432 check port 8008
    server patroni-3 patroni-3:5432 check port 8008

listen pg-read
    bind *:5001
    mode tcp
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions
    server patroni-1 patroni-1:5432 check port 8008
    server patroni-2 patroni-2:5432 check port 8008
    server patroni-3 patroni-3:5432 check port 8008
```

## Étape 2 : docker-compose avec HAProxy

Crée `docker-compose-haproxy.yml` :

```yaml
version: '3.8'

services:
  # ===== CLUSTER ETCD =====
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
      - --initial-cluster-token=haproxy-lab
    networks:
      - lab-net

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
      - --initial-cluster-token=haproxy-lab
    networks:
      - lab-net

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
      - --initial-cluster-token=haproxy-lab
    networks:
      - lab-net

  # ===== CLUSTER PATRONI (Spilo) =====
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
      - lab-net

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
      - lab-net

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
      - lab-net

  # ===== HAPROXY =====
  haproxy:
    image: haproxy:2.9
    container_name: haproxy
    hostname: haproxy
    ports:
      - "5000:5000"   # Écriture (leader)
      - "5001:5001"   # Lecture (replicas)
      - "8404:8404"   # Stats
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - lab-net
    depends_on:
      - patroni-1
      - patroni-2
      - patroni-3

networks:
  lab-net:
    driver: bridge
```

## Étape 3 : Démarrer et tester

```bash
# IMPORTANT : si tu relances après un changement de config, supprime les volumes
# pour que le cluster soit réinitialisé avec les bons paramètres :
# docker compose -f docker-compose-haproxy.yml down -v

# Démarrer tout
docker compose -f docker-compose-haproxy.yml up -d

# Attendre que le cluster Patroni soit prêt (~30s)
sleep 30

# Vérifier
docker compose -f docker-compose-haproxy.yml ps
docker exec -it patroni-1 patronictl list
```

> **Note lab — Spilo vs Patroni** :
>
> - **Variables de mots de passe** : Spilo utilise `PGPASSWORD_SUPERUSER` et
>   `PGPASSWORD_STANDBY`, **pas** les variables Patroni (`PATRONI_SUPERUSER_PASSWORD`).
>   Si on utilise les mauvaises variables, Spilo applique ses défauts (mot de passe
>   `zalando`) et les connexions échouent avec `password authentication failed`.
> - **`ALLOW_NOSSL=true`** : ajoute des entrées `host` (sans SSL) dans
>   `pg_hba.conf`. Sans ça, Spilo exige du SSL et HAProxy (qui fait du TCP pur)
>   se fait rejeter avec `no encryption`.
>
> En production, on configure SSL de bout en bout.

## Étape 4 : Explorer HAProxy

### 4.1 Page de statistiques
Ouvre ton navigateur : **http://localhost:8404/stats**

Tu verras :
- **pg-write** : 1 serveur UP (le leader), 2 serveurs DOWN (les replicas)
- **pg-read** : 2 serveurs UP (les replicas), 1 serveur DOWN (le leader)

### 4.2 Se connecter via HAProxy
```bash
# On exporte le mot de passe pour éviter le prompt à chaque commande
export PGPASSWORD=postgres

# Écriture via HAProxy (port 5000 → leader)
psql -h localhost -p 5000 -U postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
# → pg_is_in_recovery = false (c'est le leader)

# Lecture via HAProxy (port 5001 → replica)
psql -h localhost -p 5001 -U postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
# → pg_is_in_recovery = true (c'est un replica)

# Créer des données via le port écriture
psql -h localhost -p 5000 -U postgres -c "CREATE DATABASE haproxy_test;"
psql -h localhost -p 5000 -U postgres -d haproxy_test -c "CREATE TABLE test (id serial, data text);"
psql -h localhost -p 5000 -U postgres -d haproxy_test -c "INSERT INTO test (data) VALUES ('via haproxy');"

# Lire via le port lecture
psql -h localhost -p 5001 -U postgres -d haproxy_test -c "SELECT * FROM test;"

# Tenter d'écrire via le port lecture (doit échouer)
psql -h localhost -p 5001 -U postgres -d haproxy_test -c "INSERT INTO test (data) VALUES ('tentative');"
# → ERROR: cannot execute INSERT in a read-only transaction
```

## Étape 5 : Observer le failover

### 5.1 Ouvrir la page stats dans le navigateur
Garde **http://localhost:8404/stats** ouvert et regarde en temps réel.

### 5.2 Kill le leader
```bash
# Identifier le leader
docker exec -it patroni-1 patronictl list

# Supposons patroni-1 est le leader
docker kill patroni-1

# REGARDE la page stats :
# - pg-write : patroni-1 passe de UP (vert) à DOWN (rouge)
# - Après le failover Patroni (~30s) : un autre nœud passe UP dans pg-write
# - pg-read : les backends se réorganisent aussi
```

### 5.3 Vérifier la continuité de service
```bash
# Après le failover, l'écriture fonctionne toujours via HAProxy
# (PGPASSWORD doit toujours être exporté, cf. étape 4.2)
psql -h localhost -p 5000 -U postgres -d haproxy_test -c "INSERT INTO test (data) VALUES ('après failover');"
psql -h localhost -p 5000 -U postgres -d haproxy_test -c "SELECT * FROM test;"

# Redémarrer l'ancien leader
docker start patroni-1
sleep 15

# Vérifier dans les stats : patroni-1 réapparait dans pg-read (comme replica)
```

## Étape 6 : Nettoyage

```bash
docker compose -f docker-compose-haproxy.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Observer le load balancing en lecture
1. Avec `pg-read` en roundrobin, fais 10 connexions successives sur le port 5001
2. Vérifie que les connexions sont distribuées entre les replicas
3. Utilise `SELECT inet_server_addr()` pour voir quel nœud répond

### Exercice 2 : Switchover et HAProxy
1. Fais un switchover Patroni
2. Observe dans les stats HAProxy le changement des backends UP/DOWN
3. Mesure combien de temps HAProxy met à détecter le changement

### Exercice 3 : Maintenir un backend en maintenance
1. Connecte-toi au conteneur HAProxy
2. Via le socket, mets un backend en maintenance
3. Observe dans les stats
4. Remets-le en service
