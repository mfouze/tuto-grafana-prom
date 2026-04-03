# Tutoriel Pratique : Pgpool-II sur Docker

## Prerequis
- Docker et Docker Compose installes
- Avoir fait le tutoriel PostgreSQL/Patroni (`docs/02-postgresql-patroni/tutoriel-docker.md`)
- Avoir lu le cours Pgpool-II (`docs/11-pgpool2/cours.md`)

## Objectifs
1. Deployer Pgpool-II devant un cluster PostgreSQL (sans Patroni/HAProxy)
2. Tester le load balancing des lectures
3. Tester le failover automatique
4. Monitorer Pgpool-II avec Prometheus et Grafana
5. Comparer avec la stack Patroni + HAProxy + PgBouncer

---

## Architecture du lab

```
  Client
    |
    v
  Pgpool-II :9999 (SQL)  :9898 (PCP admin)
    |
    |── SELECT → pg-replica (load balanced)
    |── INSERT/UPDATE/DELETE → pg-primary
    |
    v
  pg-primary (:5432)
  pg-replica  (:5433)

  + pgpool2_exporter :9719 → Prometheus :9090 → Grafana :3000
```

## Etape 1 : Fichiers de configuration

### pgpool.conf

```ini
# === Connexion ===
listen_addresses = '*'
port = 9999
pcp_listen_addresses = '*'
pcp_port = 9898

# === Backends PostgreSQL ===
backend_hostname0 = 'pg-primary'
backend_port0 = 5432
backend_weight0 = 1
backend_data_directory0 = '/var/lib/postgresql/data'
backend_flag0 = 'ALLOW_TO_FAILOVER'
backend_application_name0 = 'pg-primary'

backend_hostname1 = 'pg-replica'
backend_port1 = 5432
backend_weight1 = 1
backend_data_directory1 = '/var/lib/postgresql/data'
backend_flag1 = 'ALLOW_TO_FAILOVER'
backend_application_name1 = 'pg-replica'

# === Pooling ===
num_init_children = 32
max_pool = 4
child_max_connections = 0
connection_life_time = 300

# === Load Balancing ===
load_balance_mode = on
statement_level_load_balance = on
disable_load_balance_on_write = 'transaction'

# === Streaming Replication Mode ===
backend_clustering_mode = 'streaming_replication'

# === Health Check ===
health_check_period = 5
health_check_timeout = 10
health_check_user = 'postgres'
health_check_password = 'postgres'
health_check_max_retries = 3
health_check_retry_delay = 1

# === Streaming Replication Check ===
sr_check_user = 'postgres'
sr_check_password = 'postgres'
sr_check_period = 5

# === Failover ===
failover_on_backend_error = on

# === Logging ===
log_statement = on
log_per_node_statement = on
log_connections = on
log_disconnections = on
log_hostname = on
logging_collector = off
log_line_prefix = '%t [%p]: '
```

### pool_hba.conf

```
# TYPE  DATABASE  USER      ADDRESS       METHOD
local   all       all                     trust
host    all       all       0.0.0.0/0     trust
```

### pcp.conf

```
# username:md5_password
# password = "pgpool" → md5("pgpoolpgpool") = bcd65230...
postgres:e8a48653851e28c69d0506508fb27fc5
```

### docker-compose-pgpool.yml

```yaml
services:
  # ===== POSTGRESQL PRIMARY =====
  pg-primary:
    image: postgres:16
    container_name: pg-primary
    hostname: pg-primary
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: testdb
    command:
      - postgres
      - -c
      - wal_level=replica
      - -c
      - max_wal_senders=10
      - -c
      - hot_standby=on
      - -c
      - max_replication_slots=10
    ports:
      - "5432:5432"
    volumes:
      - pg-primary-data:/var/lib/postgresql/data
      - ./init-primary.sh:/docker-entrypoint-initdb.d/init.sh:ro
    networks:
      - pgpool-net

  # ===== POSTGRESQL REPLICA =====
  pg-replica:
    image: postgres:16
    container_name: pg-replica
    hostname: pg-replica
    environment:
      PGUSER: postgres
      PGPASSWORD: postgres
    entrypoint: []
    command: >
      bash -c "
      until pg_isready -h pg-primary -U postgres; do sleep 1; done
      rm -rf /var/lib/postgresql/data/*
      pg_basebackup -h pg-primary -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R
      chmod 0700 /var/lib/postgresql/data
      exec postgres
      "
    ports:
      - "5433:5432"
    volumes:
      - pg-replica-data:/var/lib/postgresql/data
    depends_on:
      - pg-primary
    networks:
      - pgpool-net

  # ===== PGPOOL-II =====
  pgpool:
    image: pgpool/pgpool2:4.5
    container_name: pgpool
    hostname: pgpool
    ports:
      - "9999:9999"
      - "9898:9898"
    volumes:
      - ./pgpool.conf:/etc/pgpool2/pgpool.conf:ro
      - ./pool_hba.conf:/etc/pgpool2/pool_hba.conf:ro
      - ./pcp.conf:/etc/pgpool2/pcp.conf:ro
    environment:
      PGPOOL_PARAMS_BACKEND_HOSTNAME0: pg-primary
      PGPOOL_PARAMS_BACKEND_HOSTNAME1: pg-replica
    depends_on:
      - pg-primary
      - pg-replica
    networks:
      - pgpool-net

  # ===== PGPOOL2 EXPORTER =====
  pgpool2-exporter:
    image: pgpool/pgpool2_exporter:1.2
    container_name: pgpool2-exporter
    environment:
      PGPOOL_SERVICE: pgpool
      PGPOOL_SERVICE_PORT: "9999"
      POSTGRES_USERNAME: postgres
      POSTGRES_PASSWORD: postgres
      PGPOOL_DBI_HOST: pgpool
      PGPOOL_DBI_PORT: "9999"
      PGPOOL_DBI_USER: postgres
      PGPOOL_DBI_PASSWORD: postgres
    ports:
      - "9719:9719"
    depends_on:
      - pgpool
    networks:
      - pgpool-net

  # ===== PROMETHEUS =====
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus-pgpool.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-lifecycle
    networks:
      - pgpool-net

  # ===== GRAFANA =====
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    user: "0"
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
    volumes:
      - ./grafana-pgpool/provisioning:/etc/grafana/provisioning:ro
    networks:
      - pgpool-net

volumes:
  pg-primary-data:
  pg-replica-data:

networks:
  pgpool-net:
    driver: bridge
```

### init-primary.sh (initialisation de la replication)

```bash
#!/bin/bash
set -e

# Creer l'utilisateur de replication
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
    CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replicator';
EOSQL

# Autoriser la replication
echo "host replication replicator 0.0.0.0/0 md5" >> "$PGDATA/pg_hba.conf"
echo "host all all 0.0.0.0/0 trust" >> "$PGDATA/pg_hba.conf"

pg_ctl reload
```

### prometheus-pgpool.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'pgpool2'
    static_configs:
      - targets: ['pgpool2-exporter:9719']
    metrics_path: /metrics
```

### grafana-pgpool/provisioning/datasources/datasources.yml

```yaml
apiVersion: 1
datasources:
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

## Etape 2 : Demarrer

```bash
mkdir -p grafana-pgpool/provisioning/datasources rules

# Copier les fichiers :
# - pgpool.conf, pool_hba.conf, pcp.conf
# - init-primary.sh (rendre executable : chmod +x init-primary.sh)
# - docker-compose-pgpool.yml
# - prometheus-pgpool.yml
# - grafana-pgpool/provisioning/datasources/datasources.yml

docker compose -f docker-compose-pgpool.yml up -d
sleep 30
docker compose -f docker-compose-pgpool.yml ps
```

## Etape 3 : Verifier que Pgpool-II fonctionne

```bash
# Pgpool repond ?
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;"
# → tu dois voir 2 noeuds : pg-primary (primary) et pg-replica (standby)

# Verifier les roles
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;" | grep -E 'primary|standby'

# Tester une connexion directe
psql -h localhost -p 9999 -U postgres -d testdb -c "SELECT 1;"
```

## Etape 4 : Tester le load balancing

```bash
# Creer une table de test
psql -h localhost -p 9999 -U postgres -d testdb -c "
  CREATE TABLE IF NOT EXISTS test_lb (id serial, ts timestamp default now());
  INSERT INTO test_lb DEFAULT VALUES;
"

# Executer des SELECT et observer la distribution
for i in $(seq 1 10); do
  psql -h localhost -p 9999 -U postgres -d testdb -c "SELECT inet_server_addr(), inet_server_port();" 2>/dev/null
done
# → tu devrais voir les requetes distribuees entre pg-primary et pg-replica

# Verifier les compteurs de SELECT par noeud
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;" | awk '{print $1, $2, $10}'
# → la colonne select_cnt montre la distribution
```

## Etape 5 : Tester le failover

```bash
# Etat initial
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;"

# Stopper le replica
docker stop pg-replica

# Attendre que Pgpool detecte le noeud DOWN
sleep 15
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;"
# → pg-replica passe en status "down" (3)

# Les requetes continuent via le primary
psql -h localhost -p 9999 -U postgres -d testdb -c "SELECT 'still working';"

# Redemarrer le replica
docker start pg-replica
sleep 10

# Rattacher le noeud via PCP
pcp_attach_node -h localhost -p 9898 -U postgres -n 1 -w
# Ou via l'API :
psql -h localhost -p 9999 -U postgres -c "SHOW pool_nodes;"
```

## Etape 6 : Metriques Prometheus

```bash
# Pgpool2 exporter expose ses metriques ?
curl -s http://localhost:9719/metrics | head -20

# Metriques cles dans Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=pgpool2_pool_nodes_status' | python3 -m json.tool | head -20

# Dans Grafana → Explore → Prometheus :
# pgpool2_pool_nodes_status       → etat des backends (1=up, 2=unused, 3=down)
# pgpool2_pool_nodes_select_cnt   → nombre de SELECT par backend
# pgpool2_frontend_total           → connexions clients totales
```

## Etape 7 : Nettoyage

```bash
docker compose -f docker-compose-pgpool.yml down -v
```

---

## Exercices

### Exercice 1 : Observer le load balancing
1. Genere 100 SELECT via Pgpool
2. Verifie la distribution avec `SHOW pool_nodes` (colonne `select_cnt`)
3. Change les poids (`backend_weight`) pour envoyer 80% des lectures au replica

### Exercice 2 : Failover du primary
1. Stoppe `pg-primary`
2. Observe le comportement de Pgpool-II (les ecritures echouent)
3. En vrai, le `failover_command` promouverait le replica → dans ce lab simplifie, constate le comportement

### Exercice 3 : Comparer avec la stack Transactis
1. Lance le full lab (Patroni + HAProxy + PgBouncer)
2. Compare les temps de reponse d'un SELECT via Pgpool vs via PgBouncer+HAProxy
3. Compare le nombre de connexions PG ouvertes dans les deux cas
