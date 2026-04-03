# Tutoriel Pratique : Prometheus, Grafana & Thanos sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel PgBouncer (`docs/04-pgbouncer/tutoriel-docker.md`)
- Avoir lu le cours Prometheus/Grafana

## Objectifs
1. Ajouter Prometheus + Grafana + exporters sur toute la stack (etcd, Patroni, PostgreSQL, HAProxy, PgBouncer)
2. Écrire des requêtes PromQL par composant
3. Créer des dashboards Grafana
4. Monter Prometheus HA (2 instances) + Thanos pour la déduplication
5. Configurer MinIO (S3 local) pour le stockage long terme

---

## Partie 1 — Monitoring de toute la stack

### Architecture

```
                    ┌──────────┐
                    │ Grafana  │ :3000
                    └────┬─────┘
                         │
                  ┌──────▼──────┐
                  │ Prometheus  │ :9090
                  └──────┬──────┘
                         │ scrape
     ┌──────────┬────────┼────────┬──────────┬──────────┐
     │          │        │        │          │          │
  ┌──▼───┐  ┌──▼────┐ ┌─▼──┐ ┌──▼────┐ ┌───▼───┐ ┌───▼───┐
  │pg-exp│  │pgb-exp│ │etcd│ │patron│ │haprox│ │ node  │
  │:9187 │  │:9127  │ │:237│ │:8008 │ │:8405 │ │:9100  │
  └──┬───┘  └──┬────┘ └────┘ └──────┘ └──────┘ └───────┘
     │         │
     │    ┌────▼────┐    ┌───────────┐    ┌───────────────┐
     │    │PgBouncer│    │  HAProxy  │    │ Patroni / PG  │
     │    │ :6432   │    │:5000/:5001│    │ x3 nœuds      │
     │    └─────────┘    └───────────┘    └───────────────┘
     └───────────────────────┘
              etcd x3
```

### Étape 1 : Fichiers de configuration

#### prometheus.yml
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: lab
    replica: prom-1

rule_files:
  - /etc/prometheus/rules/*.yml

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'etcd'
    static_configs:
      - targets: ['etcd-1:2379', 'etcd-2:2379', 'etcd-3:2379']

  - job_name: 'patroni'
    static_configs:
      - targets: ['patroni-1:8008', 'patroni-2:8008', 'patroni-3:8008']
    metrics_path: /metrics

  - job_name: 'postgres'
    static_configs:
      - targets: ['postgres-exporter:9187']

  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy:8405']
    metrics_path: /metrics

  - job_name: 'pgbouncer'
    static_configs:
      - targets: ['pgbouncer-exporter:9127']

  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']
```

> **Note** : etcd, Patroni et HAProxy exposent leurs métriques nativement.
> PostgreSQL et PgBouncer ont besoin d'un **exporter** dédié (conteneur séparé).

#### rules/recording-rules.yml
```yaml
groups:
  - name: recording_etcd
    rules:
      - record: etcd:wal_fsync_p99
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

  - name: recording_postgresql
    rules:
      - record: pg:transactions_per_second
        expr: sum(rate(pg_stat_database_xact_commit[5m])) + sum(rate(pg_stat_database_xact_rollback[5m]))

      - record: pg:cache_hit_ratio
        expr: sum(pg_stat_database_blks_hit) / (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read) + 1)

      - record: pg:connections_usage_ratio
        expr: pg_stat_activity_count / pg_settings_max_connections

  - name: recording_haproxy
    rules:
      - record: haproxy:write_backends_up_ratio
        expr: haproxy_backend_active_servers{proxy="pg-write"} / haproxy_backend_servers_total{proxy="pg-write"}

      - record: haproxy:session_usage_ratio
        expr: haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions

  - name: recording_pgbouncer
    rules:
      - record: pgbouncer:pool_usage_ratio
        expr: pgbouncer_pools_server_active_connections / (pgbouncer_pools_server_active_connections + pgbouncer_pools_server_idle_connections + 1)

  - name: recording_node
    rules:
      - record: node:cpu_usage_ratio
        expr: 1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))

      - record: node:memory_usage_ratio
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)
```

#### rules/all-alerts.yml
```yaml
groups:
  - name: etcd
    rules:
      - alert: EtcdDown
        expr: up{job="etcd"} == 0
        for: 30s
        labels:
          severity: critical
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} is DOWN"

      - alert: EtcdNoLeader
        expr: etcd_server_has_leader == 0
        for: 30s
        labels:
          severity: critical
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} has no leader"

  - name: patroni
    rules:
      - alert: PatroniDown
        expr: up{job="patroni"} == 0
        for: 30s
        labels:
          severity: critical
          component: patroni
        annotations:
          summary: "Patroni {{ $labels.instance }} is DOWN"

      - alert: PatroniNoLeader
        expr: count(patroni_primary == 1) == 0
        for: 30s
        labels:
          severity: critical
          component: patroni
        annotations:
          summary: "Patroni cluster has NO leader"

  - name: postgresql
    rules:
      - alert: PostgreSQLDown
        expr: up{job="postgres"} == 0
        for: 30s
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "PostgreSQL exporter is DOWN"

      - alert: PostgreSQLReplicationLagCritical
        expr: pg_replication_lag > 10
        for: 30s
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "Replication lag {{ $value }}s"

  - name: haproxy
    rules:
      - alert: HAProxyDown
        expr: up{job="haproxy"} == 0
        for: 30s
        labels:
          severity: critical
          component: haproxy
        annotations:
          summary: "HAProxy is DOWN"

      - alert: HAProxyNoWriteBackend
        expr: haproxy_backend_active_servers{proxy="pg-write"} == 0
        for: 10s
        labels:
          severity: critical
          component: haproxy
        annotations:
          summary: "HAProxy pg-write has NO active backend"

  - name: pgbouncer
    rules:
      - alert: PgBouncerDown
        expr: up{job="pgbouncer"} == 0
        for: 30s
        labels:
          severity: critical
          component: pgbouncer
        annotations:
          summary: "PgBouncer exporter is DOWN"

      - alert: PgBouncerClientsWaiting
        expr: pgbouncer_pools_client_waiting_connections > 5
        for: 1m
        labels:
          severity: warning
          component: pgbouncer
        annotations:
          summary: "PgBouncer {{ $value }} clients waiting"
```

#### queries.yml (custom metrics postgres-exporter)
```yaml
# Taille de chaque base de données
pg_database_size:
  query: "SELECT datname, pg_database_size(datname) as size_bytes FROM pg_database WHERE datallowconn"
  metrics:
    - datname:
        usage: "LABEL"
    - size_bytes:
        usage: "GAUGE"
        description: "Database size in bytes"

# Requêtes lentes (actives depuis > 5 minutes)
pg_slow_queries:
  query: "SELECT count(*) as count FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '5 minutes'"
  metrics:
    - count:
        usage: "GAUGE"
        description: "Queries running longer than 5 minutes"

# Locks en attente (signe de contention)
pg_locks_waiting:
  query: "SELECT count(*) as count FROM pg_locks WHERE NOT granted"
  metrics:
    - count:
        usage: "GAUGE"
        description: "Number of locks waiting to be granted"

# Deadlocks détectés (compteur cumulatif)
pg_deadlocks:
  query: "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()"
  metrics:
    - deadlocks:
        usage: "COUNTER"
        description: "Number of deadlocks detected"

# Âge du plus vieux vacuum
pg_vacuum_age:
  query: "SELECT coalesce(max(extract(epoch from now() - last_autovacuum)), 0) as seconds FROM pg_stat_user_tables WHERE last_autovacuum IS NOT NULL"
  metrics:
    - seconds:
        usage: "GAUGE"
        description: "Seconds since oldest autovacuum"

# Slots de réplication et leur lag
pg_replication_slots:
  query: "SELECT slot_name, slot_type, active::int as active, coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn), 0) as lag_bytes FROM pg_replication_slots"
  metrics:
    - slot_name:
        usage: "LABEL"
    - slot_type:
        usage: "LABEL"
    - active:
        usage: "GAUGE"
        description: "Whether the slot is active"
    - lag_bytes:
        usage: "GAUGE"
        description: "Replication slot lag in bytes"

# Tables les plus volumineuses (top 10)
pg_table_size:
  query: |
    SELECT schemaname, relname,
           pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) as total_bytes,
           n_live_tup as live_tuples,
           n_dead_tup as dead_tuples
    FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) DESC
    LIMIT 10
  metrics:
    - schemaname:
        usage: "LABEL"
    - relname:
        usage: "LABEL"
    - total_bytes:
        usage: "GAUGE"
        description: "Total table size including indexes"
    - live_tuples:
        usage: "GAUGE"
        description: "Estimated number of live rows"
    - dead_tuples:
        usage: "GAUGE"
        description: "Estimated number of dead rows (need vacuum)"

# Ratio de transactions commit vs rollback
pg_xact_ratio:
  query: "SELECT sum(xact_commit) as commits, sum(xact_rollback) as rollbacks FROM pg_stat_database"
  metrics:
    - commits:
        usage: "COUNTER"
        description: "Total committed transactions"
    - rollbacks:
        usage: "COUNTER"
        description: "Total rolled back transactions"
```

#### haproxy.cfg
Le même que dans le tutoriel HAProxy (avec le frontend prometheus sur :8405).

### Étape 2 : Docker Compose

Crée `docker-compose-monitoring.yml` :

```yaml
services:
  # ==================== ETCD ====================
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
      - --initial-cluster-token=monitoring-lab
      - --metrics=extensive
    networks:
      - mon-net

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
      - --initial-cluster-token=monitoring-lab
      - --metrics=extensive
    networks:
      - mon-net

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
      - --initial-cluster-token=monitoring-lab
      - --metrics=extensive
    networks:
      - mon-net

  # ==================== PATRONI / POSTGRESQL ====================
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
      - mon-net

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
      - mon-net

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
      - mon-net

  # ==================== HAPROXY ====================
  haproxy:
    image: haproxy:2.9
    container_name: haproxy
    ports:
      - "5000:5000"
      - "5001:5001"
      - "8404:8404"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - mon-net
    depends_on:
      - patroni-1
      - patroni-2
      - patroni-3

  # ==================== PGBOUNCER ====================
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
      DEFAULT_POOL_SIZE: "10"
      MIN_POOL_SIZE: "2"
      MAX_CLIENT_CONN: "200"
      ADMIN_USERS: postgres
      LISTEN_PORT: "6432"
    ports:
      - "6432:6432"
    networks:
      - mon-net
    depends_on:
      - haproxy

  # ==================== EXPORTERS ====================
  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres-exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://postgres:postgres@haproxy:5000/postgres?sslmode=disable"
    command:
      - --extend.query-path=/etc/postgres-exporter/queries.yml
    volumes:
      - ./queries.yml:/etc/postgres-exporter/queries.yml:ro
    ports:
      - "9187:9187"
    networks:
      - mon-net
    depends_on:
      - haproxy

  pgbouncer-exporter:
    image: prometheuscommunity/pgbouncer-exporter:latest
    container_name: pgbouncer-exporter
    command:
      - --pgBouncer.connectionString=postgres://postgres:postgres@pgbouncer:6432/pgbouncer?sslmode=disable
    ports:
      - "9127:9127"
    networks:
      - mon-net
    depends_on:
      - pgbouncer

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    networks:
      - mon-net

  # ==================== PROMETHEUS ====================
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=7d
      - --storage.tsdb.wal-compression
      - --web.enable-lifecycle
    networks:
      - mon-net

  # ==================== GRAFANA ====================
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
    networks:
      - mon-net
    depends_on:
      - prometheus

networks:
  mon-net:
    driver: bridge
```

### Étape 3 : Démarrer

```bash
mkdir -p rules
# Copier : prometheus.yml, haproxy.cfg, rules/recording-rules.yml, rules/all-alerts.yml

docker compose -f docker-compose-monitoring.yml up -d
sleep 45
docker compose -f docker-compose-monitoring.yml ps
docker exec -it patroni-1 patronictl list
```

### Étape 4 : Vérifier les targets Prometheus

Ouvre **http://localhost:9090** → **Status → Targets**

| Job | Targets | Métriques exposées par |
|-----|---------|------------------------|
| `etcd` | 3 cibles | etcd nativement (:2379/metrics) |
| `patroni` | 3 cibles | Patroni nativement (:8008/metrics) |
| `postgres` | 1 cible | postgres-exporter (:9187) |
| `haproxy` | 1 cible | HAProxy intégré (:8405/metrics) |
| `pgbouncer` | 1 cible | pgbouncer-exporter (:9127) |
| `node` | 1 cible | node-exporter (:9100) |
| `prometheus` | 1 cible | Prometheus lui-même |

Toutes les cibles doivent être **UP** (vert).

### Étape 5 : Requêtes PromQL par composant

#### etcd
```promql
# Leader présent ?
etcd_server_has_leader

# Latence WAL (p99)
histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

# Taille de la base
etcd_mvcc_db_total_size_in_bytes

# Changements de leader
increase(etcd_server_leader_changes_seen_total[10m])
```

#### Patroni
```promql
# Qui est le leader ? (1 = leader)
patroni_primary

# Lag de réplication (via Patroni)
# Lag de réplication (différence de WAL position entre primary et replicas)
patroni_xlog_location - on(scope) group_left patroni_xlog_replayed_location

# Nombre de nœuds PostgreSQL running
count(patroni_postgres_running == 1)
```

#### PostgreSQL (via postgres-exporter)
```promql
# Lag de réplication en secondes
pg_replication_lag

# Transactions par seconde (recording rule)
pg:transactions_per_second

# Ratio de cache hit
pg:cache_hit_ratio

# Connexions actives
pg_stat_activity_count

# Ratio connexions / max
pg:connections_usage_ratio
```

#### HAProxy
```promql
# Backends actifs en écriture
haproxy_backend_active_servers{proxy="pg-write"}

# Backends actifs en lecture
haproxy_backend_active_servers{proxy="pg-read"}

# Sessions actives
haproxy_frontend_current_sessions

# Ratio sessions / limite
haproxy:session_usage_ratio
```

#### PgBouncer (via pgbouncer-exporter)
```promql
# Clients en attente
pgbouncer_pools_client_waiting_connections

# Connexions serveur actives
pgbouncer_pools_server_active_connections

# Connexions serveur idle
pgbouncer_pools_server_idle_connections

# Ratio utilisation pool (recording rule)
pgbouncer:pool_usage_ratio
```

#### Node (système)
```promql
# CPU utilisé (recording rule)
node:cpu_usage_ratio

# Mémoire utilisée (recording rule)
node:memory_usage_ratio

# Espace disque
1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})
```

#### Custom metrics PostgreSQL (via queries.yml)
```promql
# Taille de chaque base
pg_database_size_size_bytes

# Requêtes lentes (> 5 min)
pg_slow_queries_count

# Locks en attente
pg_locks_waiting_count

# Deadlocks cumulés
pg_deadlocks

# Âge du dernier vacuum
pg_vacuum_age_seconds

# Lag des slots de réplication en bytes
pg_replication_slots_lag_bytes

# Taille des tables (avec dead tuples = besoin de vacuum)
pg_table_size_dead_tuples

# Ratio commit / rollback
rate(pg_xact_ratio_commits[5m]) / (rate(pg_xact_ratio_commits[5m]) + rate(pg_xact_ratio_rollbacks[5m]) + 1)
```

### Étape 6 : Configurer Grafana

#### 6.1 Ajouter la datasource
1. http://localhost:3000 → Login `admin` / `admin`
2. **Connections → Data Sources → Add → Prometheus**
3. URL : `http://prometheus:9090`
4. **Save & Test**

#### 6.2 Créer un dashboard "Vue d'ensemble"

**Row 1 — Santé du cluster**

| Panel | Type | Query |
|-------|------|-------|
| etcd Has Leader | Stat | `min(etcd_server_has_leader)` — mappings : 0=rouge, 1=vert |
| PG Leader Count | Stat | `count(patroni_primary == 1)` — mappings : 0=rouge, 1=vert |
| HAProxy UP | Stat | `up{job="haproxy"}` |
| PgBouncer UP | Stat | `up{job="pgbouncer"}` |

**Row 2 — PostgreSQL**

| Panel | Type | Query |
|-------|------|-------|
| Replication Lag | Time series | `pg_replication_lag` |
| Transactions/s | Time series | `pg:transactions_per_second` |
| Cache Hit Ratio | Gauge | `pg:cache_hit_ratio` — thresholds : <0.9 rouge, >0.95 vert |
| Connections Usage | Gauge | `pg:connections_usage_ratio` — thresholds : >0.8 rouge |

**Row 3 — HAProxy**

| Panel | Type | Query |
|-------|------|-------|
| Write Backends UP | Stat | `haproxy_backend_active_servers{proxy="pg-write"}` |
| Read Backends UP | Stat | `haproxy_backend_active_servers{proxy="pg-read"}` |
| Active Sessions | Time series | `haproxy_frontend_current_sessions` |

**Row 4 — PgBouncer**

| Panel | Type | Query |
|-------|------|-------|
| Pool Usage | Gauge | `pgbouncer:pool_usage_ratio` |
| Clients Waiting | Stat | `pgbouncer_pools_client_waiting_connections` — >0 = orange |
| Server Active | Time series | `pgbouncer_pools_server_active_connections` |
| Server Idle | Time series | `pgbouncer_pools_server_idle_connections` |

**Row 5 — etcd**

| Panel | Type | Query |
|-------|------|-------|
| WAL Fsync p99 | Time series | `etcd:wal_fsync_p99` |
| DB Size | Time series | `etcd_mvcc_db_total_size_in_bytes` (unit: bytes) |
| Leader Changes | Time series | `increase(etcd_server_leader_changes_seen_total[10m])` |

### Étape 7 : Tester avec des pannes

```bash
export PGPASSWORD=postgres

# Kill le leader PG → observer PatroniDown, HAProxy bascule, PgBouncer suit
docker exec -it patroni-1 patronictl list
docker kill patroni-1
# → Observer les panels : Write Backends, PG Leader, Replication Lag
sleep 30
docker start patroni-1

# Kill un etcd → observer etcd Has Leader, DB Size
docker stop etcd-3
sleep 30
docker start etcd-3

# Saturer PgBouncer → observer Clients Waiting, Pool Usage
for i in $(seq 1 30); do
    psql -h localhost -p 6432 -U postgres -c "SELECT pg_sleep(10);" &
done
# → Observer pgbouncer:pool_usage_ratio et pgbouncer_pools_client_waiting_connections
```

### Nettoyage Partie 1

```bash
docker compose -f docker-compose-monitoring.yml down -v
```

---

## Partie 2 — Prometheus HA + Thanos (déduplication & S3)

### Le problème

Avec 2 Prometheus qui scrapent les mêmes cibles, chaque métrique existe en double.
`sum(rate(...))` retourne **2x la vraie valeur** dans Grafana.

Thanos Query déduplique grâce au label `replica` dans `external_labels`.

### Architecture

```
                        ┌──────────┐
                        │ Grafana  │ :3000
                        └────┬─────┘
                             │
                    ┌────────▼─────────┐
                    │  Thanos Query    │ :19192
                    │  (déduplication) │
                    └───┬──────────┬───┘
                        │          │
          ┌─────────────▼┐   ┌────▼────────────┐
          │ Prometheus-1 │   │  Prometheus-2   │
          │ + Sidecar-1  │   │  + Sidecar-2    │
          │  :9090       │   │   :9091         │
          │ replica=prom1│   │  replica=prom2  │
          └──────────────┘   └─────────────────┘
                  │  scrape (identique)  │
                  └──────────┬───────────┘
                             ▼
              etcd, patroni, haproxy, pgbouncer,
              postgres-exporter, node-exporter

          Sidecars ──upload──► MinIO (S3) :9001
```

### Étape 8 : Fichiers de configuration supplémentaires

#### prometheus-2.yml
Identique à `prometheus.yml` sauf :
```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: lab
    replica: prom-2     # ← seule différence

# ... même rule_files et scrape_configs que prometheus.yml
```

#### bucket.yml (Thanos → MinIO)
```yaml
type: S3
config:
  bucket: thanos
  endpoint: minio:9000
  access_key: minioadmin
  secret_key: minioadmin
  insecure: true
```

### Étape 9 : Docker Compose Thanos

Crée `docker-compose-thanos.yml` — on reprend la même stack et on ajoute le 2ème Prometheus + Thanos + MinIO :

```yaml
services:
  # ==================== ETCD ====================
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
      - --initial-cluster-token=thanos-lab
      - --metrics=extensive
    networks:
      - thanos-net

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
      - --initial-cluster-token=thanos-lab
      - --metrics=extensive
    networks:
      - thanos-net

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
      - --initial-cluster-token=thanos-lab
      - --metrics=extensive
    networks:
      - thanos-net

  # ==================== PATRONI / POSTGRESQL ====================
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
      - thanos-net

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
      - thanos-net

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
      - thanos-net

  # ==================== HAPROXY ====================
  haproxy:
    image: haproxy:2.9
    container_name: haproxy
    ports:
      - "5000:5000"
      - "5001:5001"
      - "8404:8404"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      - thanos-net
    depends_on:
      - patroni-1
      - patroni-2
      - patroni-3

  # ==================== PGBOUNCER ====================
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
      DEFAULT_POOL_SIZE: "10"
      ADMIN_USERS: postgres
      LISTEN_PORT: "6432"
    ports:
      - "6432:6432"
    networks:
      - thanos-net
    depends_on:
      - haproxy

  # ==================== EXPORTERS ====================
  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres-exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://postgres:postgres@haproxy:5000/postgres?sslmode=disable"
    networks:
      - thanos-net
    depends_on:
      - haproxy

  pgbouncer-exporter:
    image: prometheuscommunity/pgbouncer-exporter:latest
    container_name: pgbouncer-exporter
    command:
      - --pgBouncer.connectionString=postgres://postgres:postgres@pgbouncer:6432/pgbouncer?sslmode=disable
    networks:
      - thanos-net
    depends_on:
      - pgbouncer

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    networks:
      - thanos-net

  # ==================== MINIO (S3 local) ====================
  minio:
    image: minio/minio:latest
    container_name: minio
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    ports:
      - "9001:9001"
    networks:
      - thanos-net

  minio-init:
    image: minio/mc:latest
    container_name: minio-init
    entrypoint: >
      /bin/sh -c "
      sleep 5 &&
      mc alias set local http://minio:9000 minioadmin minioadmin &&
      mc mb --ignore-existing local/thanos &&
      echo 'Bucket thanos created'
      "
    networks:
      - thanos-net
    depends_on:
      - minio

  # ==================== PROMETHEUS HA ====================
  prometheus-1:
    image: prom/prometheus:latest
    container_name: prometheus-1
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
      - prom1-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=3d
      - --storage.tsdb.wal-compression
      - --storage.tsdb.min-block-duration=5m
      - --storage.tsdb.max-block-duration=5m
      - --web.enable-lifecycle
      - --web.enable-admin-api
    networks:
      - thanos-net

  thanos-sidecar-1:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-sidecar-1
    user: "65534"
    command:
      - sidecar
      - --tsdb.path=/prometheus/data
      - --prometheus.url=http://prometheus-1:9090
      - --objstore.config-file=/etc/thanos/bucket.yml
      - --grpc-address=0.0.0.0:10901
      - --http-address=0.0.0.0:10902
    volumes:
      - prom1-data:/prometheus
      - ./bucket.yml:/etc/thanos/bucket.yml:ro
    networks:
      - thanos-net
    depends_on:
      - prometheus-1
      - minio-init

  prometheus-2:
    image: prom/prometheus:latest
    container_name: prometheus-2
    ports:
      - "9091:9090"
    volumes:
      - ./prometheus-2.yml:/etc/prometheus/prometheus.yml:ro
      - ./rules:/etc/prometheus/rules:ro
      - prom2-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=3d
      - --storage.tsdb.wal-compression
      - --storage.tsdb.min-block-duration=5m
      - --storage.tsdb.max-block-duration=5m
      - --web.enable-lifecycle
      - --web.enable-admin-api
    networks:
      - thanos-net

  thanos-sidecar-2:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-sidecar-2
    user: "65534"
    command:
      - sidecar
      - --tsdb.path=/prometheus/data
      - --prometheus.url=http://prometheus-2:9090
      - --objstore.config-file=/etc/thanos/bucket.yml
      - --grpc-address=0.0.0.0:10901
      - --http-address=0.0.0.0:10902
    volumes:
      - prom2-data:/prometheus
      - ./bucket.yml:/etc/thanos/bucket.yml:ro
    networks:
      - thanos-net
    depends_on:
      - prometheus-2
      - minio-init

  # ==================== THANOS ====================
  thanos-query:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-query
    command:
      - query
      - --http-address=0.0.0.0:19192
      - --grpc-address=0.0.0.0:10903
      - --store=thanos-sidecar-1:10901
      - --store=thanos-sidecar-2:10901
      - --store=thanos-store:10901
      - --query.replica-label=replica
      - --query.auto-downsampling
    ports:
      - "19192:19192"
    networks:
      - thanos-net
    depends_on:
      - thanos-sidecar-1
      - thanos-sidecar-2

  thanos-store:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-store
    command:
      - store
      - --data-dir=/data
      - --objstore.config-file=/etc/thanos/bucket.yml
      - --grpc-address=0.0.0.0:10901
      - --http-address=0.0.0.0:10902
    volumes:
      - ./bucket.yml:/etc/thanos/bucket.yml:ro
    networks:
      - thanos-net
    depends_on:
      - minio-init

  thanos-compactor:
    image: thanosio/thanos:v0.36.1
    container_name: thanos-compactor
    command:
      - compact
      - --data-dir=/data
      - --objstore.config-file=/etc/thanos/bucket.yml
      - --http-address=0.0.0.0:10902
      - --retention.resolution-raw=30d
      - --retention.resolution-5m=180d
      - --retention.resolution-1h=365d
      - --wait
    volumes:
      - ./bucket.yml:/etc/thanos/bucket.yml:ro
    networks:
      - thanos-net
    depends_on:
      - minio-init

  # ==================== GRAFANA ====================
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
    volumes:
      - ./grafana/provisioning:/etc/grafana/provisioning:ro
    networks:
      - thanos-net

volumes:
  prom1-data:
  prom2-data:

networks:
  thanos-net:
    driver: bridge
```

### Étape 10 : Préparer et démarrer

#### grafana/provisioning/datasources/datasources.yml
```yaml
apiVersion: 1
datasources:
  - name: Thanos
    uid: thanos
    type: prometheus
    access: proxy
    url: http://thanos-query:19192
    isDefault: true
    editable: false
  - name: Prometheus-1
    type: prometheus
    access: proxy
    url: http://prometheus-1:9090
    editable: false
  - name: Prometheus-2
    type: prometheus
    access: proxy
    url: http://prometheus-2:9090
    editable: false
```

```bash
# Créer l'arborescence
mkdir -p rules grafana/provisioning/datasources

# Copier : prometheus.yml, prometheus-2.yml, haproxy.cfg, bucket.yml,
#          queries.yml, rules/recording-rules.yml, rules/all-alerts.yml,
#          grafana/provisioning/datasources/datasources.yml

docker compose -f docker-compose-thanos.yml up -d
sleep 45
docker compose -f docker-compose-thanos.yml ps
docker exec -it patroni-1 patronictl list
```

| Service | URL |
|---------|-----|
| Prometheus-1 | http://localhost:9090 |
| Prometheus-2 | http://localhost:9091 |
| Thanos Query | http://localhost:19192 |
| Grafana | http://localhost:3000 |
| MinIO Console | http://localhost:9001 (minioadmin / minioadmin) |

### Étape 11 : Observer la déduplication

```bash
# Vérifier que les external_labels sont configurés
curl -s 'http://localhost:9090/api/v1/status/config' | grep -A3 external_labels
# → replica: prom-1

curl -s 'http://localhost:9091/api/v1/status/config' | grep -A3 external_labels
# → replica: prom-2

# NOTE : Prometheus n'inclut PAS les external_labels dans ses réponses API locales.
# Seul Thanos (ou Alertmanager, remote_write) les voit.

# Thanos Query — SANS dédup : chaque cible apparaît 2 fois (prom-1 + prom-2)
curl -s 'http://localhost:19192/api/v1/query?query=count(up)&dedup=false'
# → 22 (11 cibles x 2 replicas)

# Thanos Query — AVEC dédup : chaque cible apparaît 1 fois
curl -s 'http://localhost:19192/api/v1/query?query=count(up)&dedup=true'
# → 11 (dédupliqué)
```

#### Dans Grafana

1. Ajouter 3 datasources :
   - **Prometheus-1** → `http://prometheus-1:9090`
   - **Prometheus-2** → `http://prometheus-2:9090`
   - **Thanos** → `http://thanos-query:19192` (**Default**)

2. Créer un panel avec `count(up)` :
   - Via Prometheus-1 : résultat = nombre de cibles
   - Via Thanos (dedup=true) : **même résultat** (dédupliqué)
   - Si on requêtait les 2 Prometheus en brut sans Thanos : **le double**

### Étape 12 : Tester la haute disponibilité

```bash
# Kill Prometheus-2 → Thanos sert via Prometheus-1
docker stop prometheus-2
curl -s 'http://localhost:19192/api/v1/query?query=up' | python3 -m json.tool | head -5
# → Fonctionne toujours

# Kill Prometheus-1 aussi → plus de données récentes
docker stop prometheus-1
# → Thanos Store peut encore servir les données historiques depuis MinIO

# Restaurer
docker start prometheus-1 prometheus-2
```

### Étape 13 : Vérifier le stockage S3

> **Note** : Prometheus écrit un bloc TSDB toutes les **5 minutes** dans ce lab
> (`min-block-duration=5m`). En production, la valeur recommandée est `2h`.

```bash
# Vérifier que le sidecar est healthy et connecté
docker logs thanos-sidecar-1 2>&1 | grep -E "ready|external_labels"
# → "changing probe status" status=ready
# → external_labels="{cluster=\"lab\", replica=\"prom-1\"}"

# Vérifier le fichier shipper (uploaded: null = pas encore de blocs)
docker exec thanos-sidecar-1 cat /prometheus/data/thanos.shipper.json
# → {"version": 1, "uploaded": null}   ← normal au début

# Vérifier s'il y a des blocs TSDB (dossiers type 01JQXX...)
docker exec prometheus-1 ls /prometheus/data/
# → Au début : seulement chunks_head, wal, lock
# → Après ~2h : des dossiers de blocs apparaissent

# Après ~2h, les uploads commencent :
docker logs thanos-sidecar-1 2>&1 | grep -i upload
# → "msg="upload new block" ... "

# Vérifier dans MinIO : http://localhost:9001 → Bucket "thanos"
```

### Nettoyage

```bash
docker compose -f docker-compose-thanos.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Dashboard complet via Thanos
Crée un dashboard Grafana (datasource = Thanos) reprenant tous les panels de l'étape 6 :
etcd, Patroni, PostgreSQL, HAProxy, PgBouncer, Node.

### Exercice 2 : Déduplication prouvée
1. Crée un panel avec `sum(rate(etcd_network_peer_sent_bytes_total[5m]))` via Prometheus-1
2. Crée le même via Thanos
3. Compare les valeurs — elles doivent être identiques (Thanos déduplique)

### Exercice 3 : Failover Prometheus
1. Kill prometheus-1
2. Vérifie que Grafana (via Thanos) continue de fonctionner
3. Provoque un failover Patroni pendant que prometheus-1 est down
4. Restaure prometheus-1 — vérifie qu'il n'y a pas de trou dans les données (prometheus-2 a collecté)

### Exercice 4 : Recording rules utiles
1. Vérifier que toutes les recording rules fonctionnent dans Thanos Query :
   ```promql
   pg:transactions_per_second
   pg:cache_hit_ratio
   haproxy:write_backends_up_ratio
   pgbouncer:pool_usage_ratio
   node:cpu_usage_ratio
   ```
2. Utilise-les dans des panels Grafana (elles sont plus performantes que les requêtes brutes)
