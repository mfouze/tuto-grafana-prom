# Tutoriel Pratique : PgBouncer devant HAProxy/Patroni sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel HAProxy (`docs/03-haproxy/tutoriel-docker.md`)
- Avoir compris le cours PgBouncer (`docs/04-pgbouncer/cours.md`)

## Objectifs
1. Ajouter PgBouncer devant la stack HAProxy/Patroni
2. Comprendre le pooling de connexions
3. Explorer les commandes admin
4. Observer le comportement lors d'un failover Patroni

## Architecture

```
Client
  │
  ▼
┌──────────┐         ┌──────────┐         ┌──────────────────┐
│ PgBouncer│────────▶│ HAProxy  │────────▶│ Patroni / PG     │
│  :6432   │         │  :5000   │         │  (leader :5432)  │
└──────────┘         │  :5001   │         │  (replica :5432) │
                     └──────────┘         └──────────────────┘
```

---

## Étape 1 : docker-compose avec PgBouncer

On reprend la stack HAProxy du tutoriel précédent et on y ajoute PgBouncer.

Crée `docker-compose-pgbouncer.yml` :

```yaml
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
      - --initial-cluster-token=pgbouncer-lab
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
      - --initial-cluster-token=pgbouncer-lab
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
      - --initial-cluster-token=pgbouncer-lab
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

  # ===== PGBOUNCER =====
  pgbouncer:
    image: edoburu/pgbouncer:latest
    container_name: pgbouncer
    hostname: pgbouncer
    environment:
      DB_HOST: haproxy
      DB_PORT: "5000"
      DB_USER: postgres
      DB_PASSWORD: postgres
      AUTH_TYPE: plain
      POOL_MODE: transaction
      DEFAULT_POOL_SIZE: "5"
      MIN_POOL_SIZE: "2"
      MAX_CLIENT_CONN: "100"
      ADMIN_USERS: postgres
      LISTEN_PORT: "6432"
    ports:
      - "6432:6432"
    networks:
      - lab-net
    depends_on:
      - haproxy

networks:
  lab-net:
    driver: bridge
```

> **Note** : PgBouncer se connecte à `haproxy:5000` (port write). HAProxy
> redirige vers le leader Patroni. En cas de failover, HAProxy bascule
> automatiquement → PgBouncer n'a pas besoin de savoir quel nœud est leader.

## Étape 2 : Démarrer et vérifier

```bash
# S'assurer que le haproxy.cfg du tutoriel précédent est dans le même dossier

docker compose -f docker-compose-pgbouncer.yml up -d

# Attendre que le cluster Patroni soit prêt
sleep 40

# Vérifier
docker compose -f docker-compose-pgbouncer.yml ps
docker exec -it patroni-1 patronictl list
```

```bash
export PGPASSWORD=postgres

# Se connecter directement via HAProxy (port 5000 → leader)
psql -h localhost -p 5000 -U postgres -c "SELECT 'Direct HAProxy: OK';"

# Se connecter via PgBouncer (port 6432 → HAProxy → leader)
psql -h localhost -p 6432 -U postgres -c "SELECT 'Via PgBouncer: OK';"
```

## Étape 3 : Explorer la console admin

```bash
# Se connecter à la base admin pgbouncer
psql -h localhost -p 6432 -U postgres pgbouncer
```

Dans la console :
```sql
-- Voir les pools
SHOW POOLS;

-- Voir les stats
SHOW STATS;

-- Voir les clients connectés
SHOW CLIENTS;

-- Voir les connexions vers PostgreSQL (via HAProxy)
SHOW SERVERS;

-- Voir la config active
SHOW CONFIG;

-- Voir les bases configurées
SHOW DATABASES;
```

## Étape 4 : Observer le pooling en action

### 4.1 Créer des données de test
```bash
psql -h localhost -p 6432 -U postgres -c "CREATE DATABASE testdb;"
psql -h localhost -p 6432 -U postgres -d testdb -c "CREATE TABLE test (id serial, data text);"
psql -h localhost -p 6432 -U postgres -d testdb -c "INSERT INTO test (data) VALUES ('via pgbouncer');"
```

### 4.2 Lancer de la charge
```bash
# 20 clients en parallèle, mais seulement 5 connexions PG (pool_size = 5)
for i in $(seq 1 20); do
    psql -h localhost -p 6432 -U postgres -d testdb -c "SELECT pg_sleep(2), 'Client $i';" &
done
```

### 4.3 Observer pendant la charge
Dans un autre terminal :
```bash
export PGPASSWORD=postgres

# Observer les pools toutes les 2 secondes
watch -n 2 "psql -h localhost -p 6432 -U postgres pgbouncer -c 'SHOW POOLS;'"
```

Tu verras :
- `cl_active` : clients en train d'exécuter une requête
- `cl_waiting` : clients en attente d'une connexion (pool saturé)
- `sv_active` : connexions PG utilisées (max = pool_size = 5)

Les 20 clients sont servis à tour de rôle avec seulement 5 connexions réelles.

## Étape 5 : Simuler une saturation

```bash
# Lancer 30 connexions longues (10 secondes chacune)
for i in $(seq 1 30); do
    psql -h localhost -p 6432 -U postgres -d testdb -c "SELECT pg_sleep(10);" &
done

# Observer : beaucoup de clients en attente
psql -h localhost -p 6432 -U postgres pgbouncer -c "SHOW POOLS;"
# → cl_waiting devrait être > 0
# → sv_active = 5 (le pool est plein)
```

## Étape 6 : Pause et Resume

```bash
# Mettre la base en pause (les nouvelles requêtes sont bloquées)
psql -h localhost -p 6432 -U postgres pgbouncer -c "PAUSE postgres;"

# Tenter une requête → elle reste bloquée
timeout 5 psql -h localhost -p 6432 -U postgres -c "SELECT 'pendant pause';" \
  || echo "Timeout (normal, la base est en pause)"

# Reprendre
psql -h localhost -p 6432 -U postgres pgbouncer -c "RESUME postgres;"

# La requête passe maintenant
psql -h localhost -p 6432 -U postgres -c "SELECT 'après resume';"
```

## Étape 7 : PgBouncer + Failover Patroni

C'est le test le plus intéressant : que se passe-t-il côté PgBouncer quand le leader PostgreSQL change ?

```bash
# Identifier le leader actuel
docker exec -it patroni-1 patronictl list

# Vérifier que PgBouncer fonctionne
psql -h localhost -p 6432 -U postgres -c "SELECT inet_server_addr();"

# Kill le leader (supposons patroni-1)
docker kill patroni-1

# Attendre le failover Patroni (~30s)
sleep 30
docker exec -it patroni-2 patronictl list

# Tester : PgBouncer fonctionne-t-il toujours ?
psql -h localhost -p 6432 -U postgres -c "SELECT inet_server_addr(), pg_is_in_recovery();"
# → Nouvelle IP (nouveau leader), pg_is_in_recovery = false

# PgBouncer n'a rien eu à faire : HAProxy a basculé, PgBouncer suit.

# Restaurer l'ancien leader
docker start patroni-1
```

> **Ce qu'il faut retenir** : PgBouncer ne gère pas le failover — c'est HAProxy
> qui le fait. PgBouncer se contente de pooler les connexions vers HAProxy, qui
> redirige vers le bon nœud. Chaque composant a son rôle :
>
> - **Patroni** : failover PostgreSQL
> - **HAProxy** : routage write/read
> - **PgBouncer** : pooling de connexions

## Étape 8 : Nettoyage

```bash
docker compose -f docker-compose-pgbouncer.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Comparer les performances (avec et sans PgBouncer)
```bash
export PGPASSWORD=postgres

# 100 connexions directement via HAProxy
time for i in $(seq 1 100); do
  psql -h localhost -p 5000 -U postgres -c "SELECT 1;" > /dev/null 2>&1
done

# 100 connexions via PgBouncer
time for i in $(seq 1 100); do
  psql -h localhost -p 6432 -U postgres -c "SELECT 1;" > /dev/null 2>&1
done

# PgBouncer devrait être plus rapide : il réutilise les connexions existantes
# au lieu d'en ouvrir une nouvelle à chaque fois
```

### Exercice 2 : Monitoring en continu
Écris un script qui affiche toutes les 5 secondes :
- Nombre de clients actifs et en attente
- Nombre de connexions serveur actives et idle
- Temps moyen d'attente

Lance de la charge et observe les métriques évoluer.

### Exercice 3 : Perte d'etcd + PgBouncer
1. Note les stats PgBouncer (`SHOW POOLS`)
2. Kill 2 nœuds etcd (perte de quorum)
3. Le leader PG continue de fonctionner (pas de failover possible)
4. PgBouncer continue de servir les clients ?
5. Restaure les nœuds etcd
