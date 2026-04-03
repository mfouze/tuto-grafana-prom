# Tutoriel Pratique : Cluster PostgreSQL + Patroni sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel etcd (`docs/01-etcd/tutoriel-docker.md`)

## Objectifs
1. Monter un cluster Patroni 3 nœuds avec etcd
2. Observer la réplication
3. Simuler un switchover et un failover
4. Monitorer avec postgres_exporter

---

## Étape 1 : Créer le docker-compose

Crée un fichier `docker-compose-patroni.yml` :

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
      - --initial-cluster-token=patroni-lab
    networks:
      - patroni-net

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
      - --initial-cluster-token=patroni-lab
    networks:
      - patroni-net

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
      - --initial-cluster-token=patroni-lab
    networks:
      - patroni-net

  # ===== CLUSTER PATRONI / POSTGRESQL =====
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
    ports:
      - "5432:5432"
      - "8008:8008"
    networks:
      - patroni-net
    depends_on:
      - etcd-1
      - etcd-2
      - etcd-3

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
    ports:
      - "5433:5432"
      - "8009:8008"
    networks:
      - patroni-net
    depends_on:
      - etcd-1
      - etcd-2
      - etcd-3

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
    ports:
      - "5434:5432"
      - "8010:8008"
    networks:
      - patroni-net
    depends_on:
      - etcd-1
      - etcd-2
      - etcd-3

networks:
  patroni-net:
    driver: bridge
```

## Étape 2 : Démarrer le cluster

```bash
docker compose -f docker-compose-patroni.yml up -d

# Attendre ~30 secondes que le cluster s'initialise
sleep 30

# Vérifier l'état
docker compose -f docker-compose-patroni.yml ps
```

## Étape 3 : Vérifier le cluster Patroni

### 3.1 Via patronictl
```bash
# Voir l'état du cluster
docker exec -it patroni-1 patronictl list

# Résultat attendu :
# + Cluster: pg-cluster ----------+---------+---------+----+-----------+
# | Member    | Host      | Role    | State   | TL | Lag in MB |
# +-----------+-----------+---------+---------+----+-----------+
# | patroni-1 | patroni-1 | Leader  | running |  1 |           |
# | patroni-2 | patroni-2 | Replica | streaming|  1 |         0 |
# | patroni-3 | patroni-3 | Replica | streaming|  1 |         0 |
# +-----------+-----------+---------+---------+----+-----------+
```

### 3.2 Via l'API REST
```bash
# État du leader
curl -s http://localhost:8008/ | python3 -m json.tool

# État de chaque nœud
curl -s http://localhost:8008/cluster | python3 -m json.tool

# Health checks (utilisés par HAProxy)
echo "patroni-1 (leader) :" && curl -s -o /dev/null -w "%{http_code}" http://localhost:8008/primary
echo ""
echo "patroni-2 (replica) :" && curl -s -o /dev/null -w "%{http_code}" http://localhost:8009/replica
echo ""
echo "patroni-3 (replica) :" && curl -s -o /dev/null -w "%{http_code}" http://localhost:8010/replica
```

## Étape 4 : Explorer PostgreSQL

### 4.1 Se connecter au leader
```bash
# Connexion psql au leader (port 5432)
docker exec -it patroni-1 psql -U postgres

# Ou depuis ta machine si psql est installé :
# psql -h localhost -p 5432 -U postgres
```

### 4.2 Créer des données de test
```sql
-- Créer une base de test
CREATE DATABASE testdb;

-- Se connecter à la base
\c testdb

-- Créer une table
CREATE TABLE employes (
    id SERIAL PRIMARY KEY,
    nom VARCHAR(100),
    departement VARCHAR(50),
    salaire NUMERIC(10,2),
    date_embauche DATE DEFAULT CURRENT_DATE
);

-- Insérer des données
INSERT INTO employes (nom, departement, salaire) VALUES
('Alice Dupont', 'IT', 55000),
('Bob Martin', 'Finance', 48000),
('Claire Petit', 'IT', 62000),
('David Roux', 'RH', 45000),
('Emma Garcia', 'Finance', 51000);

-- Vérifier
SELECT * FROM employes;
```

### 4.3 Vérifier la réplication
```bash
# Sur le leader : voir les replicas
docker exec -it patroni-1 psql -U postgres -c "SELECT client_addr, state, replay_lag FROM pg_stat_replication;"

# Sur un replica : vérifier que les données sont là
docker exec -it patroni-2 psql -U postgres -d testdb -c "SELECT * FROM employes;"

# Le replica est bien en mode recovery (lecture seule)
docker exec -it patroni-2 psql -U postgres -c "SELECT pg_is_in_recovery();"
# → true

# Tenter une écriture sur le replica (doit échouer)
docker exec -it patroni-2 psql -U postgres -d testdb -c "INSERT INTO employes (nom, departement, salaire) VALUES ('Test', 'Test', 0);"
# → ERROR: cannot execute INSERT in a read-only transaction
```

## Étape 5 : Switchover

```bash
# Voir l'état avant
docker exec -it patroni-1 patronictl list

# Faire un switchover vers patroni-2
docker exec -it patroni-1 patronictl switchover --candidate patroni-2 --force

# Attendre quelques secondes...
sleep 5

# Vérifier : patroni-2 est maintenant le leader !
docker exec -it patroni-1 patronictl list

# Vérifier que les données sont toujours accessibles
docker exec -it patroni-2 psql -U postgres -d testdb -c "SELECT * FROM employes;"

# L'ancien leader (patroni-1) est maintenant un replica
docker exec -it patroni-1 psql -U postgres -c "SELECT pg_is_in_recovery();"
# → true
```

## Étape 6 : Failover (simuler une panne)

```bash
# Identifier le leader actuel
docker exec -it patroni-1 patronictl list

# Supposons que patroni-2 est le leader après le switchover
# Simuler un crash brutal du leader
docker kill patroni-2

# Observer dans les logs ce qui se passe
docker logs -f patroni-1 &
docker logs -f patroni-3 &

# Attendre le failover (~30-60 secondes)
sleep 45

# Vérifier : un nouveau leader a été élu
docker exec -it patroni-1 patronictl list

# Les données sont toujours là
docker exec -it patroni-1 psql -U postgres -d testdb -c "SELECT * FROM employes;"

# Redémarrer l'ancien leader (il rejoint en tant que replica)
docker start patroni-2
sleep 15
docker exec -it patroni-1 patronictl list
```

## Étape 7 : Simuler du lag de réplication

```bash
# Insérer beaucoup de données rapidement sur le leader
docker exec -it patroni-1 psql -U postgres -d testdb -c "
INSERT INTO employes (nom, departement, salaire)
SELECT 'Employe ' || i, 'Dept ' || (i % 5), random() * 100000
FROM generate_series(1, 100000) AS i;
"

# Pendant l'insertion, vérifier le lag
docker exec -it patroni-1 psql -U postgres -c "
SELECT client_addr, state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS replay_lag_bytes,
       replay_lag
FROM pg_stat_replication;
"

# Via Patroni
docker exec -it patroni-1 patronictl list
# Regarder la colonne "Lag in MB"
```

## Étape 8 : Explorer les métriques Patroni

```bash
# Métriques via l'API REST
curl -s http://localhost:8008/metrics

# Informations détaillées
curl -s http://localhost:8008/ | python3 -m json.tool

# Vérifier l'historique (timeline changes = failovers/switchovers)
docker exec -it patroni-1 patronictl history
```

## Étape 9 : Nettoyage

```bash
docker compose -f docker-compose-patroni.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Switchover circulaire
1. Fais un switchover de patroni-1 → patroni-2
2. Fais un switchover de patroni-2 → patroni-3
3. Fais un switchover de patroni-3 → patroni-1
4. Vérifie à chaque étape que les données sont intactes

### Exercice 2 : Double panne
1. Identifie le leader
2. Kill le leader → observe le failover
3. Sans redémarrer le premier leader, kill le nouveau leader
4. Que se passe-t-il ? (Il ne reste qu'un nœud, peut-il devenir leader ?)

### Exercice 3 : Perte etcd pendant un failover
1. Identifie le leader PG
2. Arrête 2 nœuds etcd (perte de quorum etcd)
3. Kill le leader PG
4. Que se passe-t-il ? (Patroni ne peut pas faire de failover car etcd est indisponible)
5. Redémarre les nœuds etcd → observe ce qui se passe

### Exercice 4 : Monitoring
1. Pendant que le cluster tourne, écris un script qui toutes les 5 secondes :
   - Affiche le résultat de `patronictl list`
   - Affiche le lag de réplication
   - Affiche le nombre de connexions
2. Lance le script dans un terminal, puis fais des opérations dans un autre terminal
