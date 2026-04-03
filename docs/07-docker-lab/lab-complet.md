# Lab Docker Complet — Stack Supervision Transactis

Ce lab monte **toute la stack de supervision** en une seule commande : exporters pour
tous les composants, alertes de production, recording rules, Thanos (déduplication + S3),
7 dashboards Grafana auto-provisionnés et webhook LogNcall.

## Architecture

```
                              ┌───────────┐
                              │  Grafana  │ :3000
                              │ 7 dashboards auto-provisionnés
                              └─────┬─────┘
                                    │
                           ┌────────▼────────┐
                           │  Thanos Query   │ :19192
                           │ (déduplication) │
                           └───┬─────────┬───┘
                               │         │
                 ┌─────────────▼┐   ┌────▼────────────┐
                 │ Prometheus-1 │   │  Prometheus-2   │
                 │ + Sidecar    │   │  + Sidecar      │
                 │  :9090       │   │   :9091         │
                 └──────┬───────┘   └────┬────────────┘
                        │   scrape       │
    ┌──────┬────────┬───┼───┬────────┬───┼───┐
    │      │        │   │   │        │   │   │
  pg-exp pgb-exp pgbr-exp etcd patron haprox node
  :9187  :9127   :9854   :2379 :8008  :8405 :9100
    │      │       │              │       │
    │   PgBouncer  │         HAProxy   Patroni/PG x3
    │    :6432     │        :5000/:5001   │
    └──────┴───────┴──────────────────────┘
                      etcd x3
         MinIO (S3) :9001 ← Thanos Sidecar upload
         Thanos Store ← requêtes long terme
         Thanos Compactor ← downsampling
         Alertmanager :9093 → Webhook LogNcall
```

## Métriques couvertes par dashboard

| Dashboard | Exporter | Métriques clés |
|---|---|---|
| etcd | natif :2379 | `etcd_server_has_leader`, `etcd_disk_wal_fsync_*`, `etcd_mvcc_db_total_size_*`, `grpc_server_*` |
| Patroni | natif :8008 | `patroni_primary`, `patroni_replica`, `patroni_xlog_*`, `patroni_postgres_running` |
| PostgreSQL (x2) | postgres-exporter | `pg_stat_database_*`, `pg_stat_activity_*`, `pg_locks_*`, `pg_stat_bgwriter_*`, `pg_stat_statements_*` |
| pgBackRest | pgbackrest-exporter | `pgbackrest_backup_*`, `pgbackrest_stanza_*`, `pgbackrest_wal_archive_*` |
| HAProxy | natif :8405 | `haproxy_backend_*`, `haproxy_frontend_*`, `haproxy_process_*` |
| PgBouncer | pgbouncer-exporter | `pgbouncer_pools_*`, `pgbouncer_stats_*`, `pgbouncer_databases_*` |

---

## Fichiers nécessaires

### 1. prometheus.yml (instance 1)

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: transactis-lab
    replica: prom-1

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

remote_write:
  - url: http://mimir:9009/api/v1/push

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

  - job_name: 'pgbackrest'
    static_configs:
      - targets: ['pgbackrest-exporter:9854']

  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy-1:8405', 'haproxy-2:8405']
    metrics_path: /metrics

  - job_name: 'pgbouncer'
    static_configs:
      - targets: ['pgbouncer-exporter:9127']

  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'mimir'
    static_configs:
      - targets: ['mimir:9009']
    metrics_path: /metrics

  - job_name: 'tempo'
    static_configs:
      - targets: ['tempo:3200']
    metrics_path: /metrics
```

### 2. prometheus-2.yml (instance 2)

Identique sauf `replica: prom-2` :

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: transactis-lab
    replica: prom-2

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

remote_write:
  - url: http://mimir:9009/api/v1/push

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

  - job_name: 'pgbackrest'
    static_configs:
      - targets: ['pgbackrest-exporter:9854']

  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy-1:8405', 'haproxy-2:8405']
    metrics_path: /metrics

  - job_name: 'pgbouncer'
    static_configs:
      - targets: ['pgbouncer-exporter:9127']

  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'mimir'
    static_configs:
      - targets: ['mimir:9009']
    metrics_path: /metrics

  - job_name: 'tempo'
    static_configs:
      - targets: ['tempo:3200']
    metrics_path: /metrics
```

### 3. rules/all-alerts.yml

```yaml
groups:
  # ==================== ETCD ====================
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

      - alert: EtcdProposalsFailing
        expr: increase(etcd_server_proposals_failed_total[5m]) > 5
        for: 1m
        labels:
          severity: critical
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} Raft proposals failing"

      - alert: EtcdHighLeaderChanges
        expr: increase(etcd_server_leader_changes_seen_total[1h]) > 3
        for: 5m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd cluster unstable — {{ $value }} leader changes in 1h"

      - alert: EtcdDiskLatencyHigh
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.1
        for: 2m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} WAL fsync p99 > 100ms"

      - alert: EtcdDatabaseSizeLarge
        expr: etcd_mvcc_db_total_size_in_bytes > 500000000
        for: 5m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} DB size > 500MB"

      - alert: EtcdBackendCommitSlow
        expr: histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])) > 0.1
        for: 2m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} backend commit p99 > 100ms"

      - alert: EtcdSlowApply
        expr: increase(etcd_server_slow_apply_total[5m]) > 0
        for: 2m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} slow applies detected"

      - alert: EtcdQuotaNearLimit
        expr: (etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes) > 0.8
        for: 5m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} DB size > 80% of quota"

  # ==================== PATRONI ====================
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

      - alert: PatroniFailoverDetected
        expr: changes(patroni_primary[5m]) > 0
        for: 0s
        labels:
          severity: warning
          component: patroni
        annotations:
          summary: "Patroni failover detected — leadership changed"

      - alert: PatroniPostgresNotRunning
        expr: patroni_postgres_running == 0
        for: 30s
        labels:
          severity: critical
          component: patroni
        annotations:
          summary: "PostgreSQL not running on {{ $labels.name }}"

      - alert: PatroniPendingRestart
        expr: patroni_pending_restart == 1
        for: 10m
        labels:
          severity: warning
          component: patroni
        annotations:
          summary: "{{ $labels.name }} has pending restart"

      - alert: PatroniReplicationLag
        expr: patroni_xlog_location - on(scope) group_right patroni_xlog_replayed_location > 50000000
        for: 2m
        labels:
          severity: warning
          component: patroni
        annotations:
          summary: "Patroni replication lag > 50MB on {{ $labels.name }}"

  # ==================== POSTGRESQL ====================
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

      - alert: PostgreSQLReplicationLagWarning
        expr: pg_replication_lag > 1
        for: 1m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Replication lag {{ $value }}s"

      - alert: PostgreSQLReplicationLagCritical
        expr: pg_replication_lag > 10
        for: 30s
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "Replication lag CRITICAL {{ $value }}s"

      - alert: PostgreSQLConnectionsHigh
        expr: pg_stat_activity_count / pg_settings_max_connections > 0.8
        for: 2m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "PostgreSQL connections > 80% capacity"

      - alert: PostgreSQLDeadlocks
        expr: increase(pg_stat_database_deadlocks[5m]) > 0
        for: 1m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Deadlocks detected on {{ $labels.datname }}"

      - alert: PostgreSQLLongTransaction
        expr: pg_slow_queries_count > 0
        for: 1m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "{{ $value }} queries running > 5 minutes"

      - alert: PostgreSQLLocksWaiting
        expr: pg_locks_waiting_count > 10
        for: 2m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "{{ $value }} locks waiting"

      - alert: PostgreSQLReplicationSlotLagHigh
        expr: pg_replication_slots_lag_bytes > 1073741824
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Replication slot {{ $labels.slot_name }} lag > 1GB"

      - alert: PostgreSQLDeadTuplesHigh
        expr: pg_table_size_dead_tuples > 100000
        for: 10m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Table {{ $labels.relname }} has {{ $value }} dead tuples"

      - alert: PostgreSQLVacuumTooOld
        expr: pg_vacuum_age_seconds > 86400
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Oldest autovacuum > 24h"

      - alert: PostgreSQLTempFilesHigh
        expr: increase(pg_stat_database_temp_files[5m]) > 10
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "High temp files usage on {{ $labels.datname }}"

      - alert: PostgreSQLCacheHitRatioLow
        expr: pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read + 1) < 0.9
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Cache hit ratio < 90% on {{ $labels.datname }}"

  # ==================== PGBACKREST ====================
  - name: pgbackrest
    rules:
      - alert: PgBackRestExporterDown
        expr: up{job="pgbackrest"} == 0
        for: 30s
        labels:
          severity: warning
          component: pgbackrest
        annotations:
          summary: "pgBackRest exporter is DOWN"

      - alert: PgBackRestStanzaError
        expr: pgbackrest_stanza_status != 0
        for: 5m
        labels:
          severity: critical
          component: pgbackrest
        annotations:
          summary: "pgBackRest stanza {{ $labels.stanza }} in error state"

      - alert: PgBackRestBackupTooOld
        expr: pgbackrest_backup_since_last_completion_seconds{backup_type="full"} > 604800
        for: 10m
        labels:
          severity: warning
          component: pgbackrest
        annotations:
          summary: "Last full backup > 7 days old"

      - alert: PgBackRestBackupFailed
        expr: pgbackrest_backup_error_status == 1
        for: 1m
        labels:
          severity: critical
          component: pgbackrest
        annotations:
          summary: "pgBackRest backup error on stanza {{ $labels.stanza }}"

      - alert: PgBackRestWALArchiveFailing
        expr: pgbackrest_wal_archive_status != 0
        for: 5m
        labels:
          severity: critical
          component: pgbackrest
        annotations:
          summary: "pgBackRest WAL archiving failing on {{ $labels.stanza }}"

  # ==================== HAPROXY ====================
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

      - alert: HAProxyNoReadBackend
        expr: haproxy_backend_active_servers{proxy="pg-read"} == 0
        for: 10s
        labels:
          severity: critical
          component: haproxy
        annotations:
          summary: "HAProxy pg-read has NO active backend"

      - alert: HAProxyBackendDown
        expr: haproxy_server_status{proxy=~"pg-.*"} == 0
        for: 30s
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy backend {{ $labels.server }} DOWN in {{ $labels.proxy }}"

      - alert: HAProxySessionsHigh
        expr: haproxy_frontend_current_sessions / haproxy_process_max_connections > 0.8
        for: 2m
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy sessions > 80% on {{ $labels.proxy }}"

      - alert: HAProxyBackendConnectTimeHigh
        expr: haproxy_backend_connect_time_average_seconds > 0.5
        for: 2m
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy backend connect time > 500ms on {{ $labels.proxy }}"

      - alert: HAProxyHighErrorRate
        expr: rate(haproxy_backend_http_responses_total{code=~"5.."}[5m]) > 1
        for: 2m
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy high 5xx error rate on {{ $labels.proxy }}"

  # ==================== PGBOUNCER ====================
  - name: pgbouncer
    rules:
      - alert: PgBouncerDown
        expr: pgbouncer_up == 0 or up{job="pgbouncer"} == 0
        for: 30s
        labels:
          severity: critical
          component: pgbouncer
        annotations:
          summary: "PgBouncer is DOWN"

      - alert: PgBouncerPoolExhausted
        expr: pgbouncer_pools_server_idle_connections == 0 and pgbouncer_pools_client_waiting_connections > 0
        for: 30s
        labels:
          severity: critical
          component: pgbouncer
        annotations:
          summary: "PgBouncer pool exhausted — clients waiting, no idle servers"

      - alert: PgBouncerClientsWaiting
        expr: pgbouncer_pools_client_waiting_connections > 5
        for: 1m
        labels:
          severity: warning
          component: pgbouncer
        annotations:
          summary: "PgBouncer {{ $value }} clients waiting"

      - alert: PgBouncerPoolUsageHigh
        expr: pgbouncer_pools_server_active_connections / (pgbouncer_pools_server_active_connections + pgbouncer_pools_server_idle_connections + 1) > 0.8
        for: 2m
        labels:
          severity: warning
          component: pgbouncer
        annotations:
          summary: "PgBouncer pool usage > 80%"

      - alert: PgBouncerMaxWaitHigh
        expr: pgbouncer_pools_client_maxwait_seconds > 5
        for: 1m
        labels:
          severity: warning
          component: pgbouncer
        annotations:
          summary: "PgBouncer max client wait time {{ $value }}s"

  # ==================== NODE ====================
  - name: node
    rules:
      - alert: NodeDiskAlmostFull
        expr: (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) > 0.85
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "Disk usage > 85%"

      - alert: NodeMemoryHigh
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "Memory usage > 90%"

      - alert: NodeCPUHigh
        expr: (1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.9
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "CPU usage > 90%"
```

### 4. rules/recording-rules.yml

```yaml
groups:
  - name: recording_etcd
    rules:
      - record: etcd:wal_fsync_p99
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

      - record: etcd:backend_commit_p99
        expr: histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m]))

      - record: etcd:db_usage_ratio
        expr: etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes

      - record: etcd:grpc_request_rate
        expr: sum(rate(grpc_server_started_total[5m])) by (grpc_service, grpc_method)

      - record: etcd:grpc_error_rate
        expr: sum(rate(grpc_server_handled_total{grpc_code!="OK"}[5m])) by (grpc_service)

  - name: recording_postgresql
    rules:
      - record: pg:transactions_per_second
        expr: sum(rate(pg_stat_database_xact_commit[5m])) + sum(rate(pg_stat_database_xact_rollback[5m]))

      - record: pg:cache_hit_ratio
        expr: sum(pg_stat_database_blks_hit) / (sum(pg_stat_database_blks_hit) + sum(pg_stat_database_blks_read) + 1)

      - record: pg:connections_usage_ratio
        expr: pg_stat_activity_count / pg_settings_max_connections

      - record: pg:rollback_ratio
        expr: sum(rate(pg_stat_database_xact_rollback[5m])) / (sum(rate(pg_stat_database_xact_commit[5m])) + sum(rate(pg_stat_database_xact_rollback[5m])) + 1)

      - record: pg:rows_per_second
        expr: sum(rate(pg_stat_database_tup_inserted[5m])) + sum(rate(pg_stat_database_tup_updated[5m])) + sum(rate(pg_stat_database_tup_deleted[5m]))

      - record: pg:temp_files_rate
        expr: sum(rate(pg_stat_database_temp_files[5m]))

      - record: pg:bgwriter_buffers_rate
        expr: rate(pg_stat_bgwriter_buffers_checkpoint[5m]) + rate(pg_stat_bgwriter_buffers_clean[5m]) + rate(pg_stat_bgwriter_buffers_backend[5m])

  - name: recording_haproxy
    rules:
      - record: haproxy:write_backends_up_ratio
        expr: haproxy_backend_active_servers{proxy="pg-write"} / haproxy_backend_servers_total{proxy="pg-write"}

      - record: haproxy:read_backends_up_ratio
        expr: haproxy_backend_active_servers{proxy="pg-read"} / haproxy_backend_servers_total{proxy="pg-read"}

      - record: haproxy:session_usage_ratio
        expr: haproxy_frontend_current_sessions / haproxy_process_max_connections

      - record: haproxy:frontend_bytes_in_rate
        expr: rate(haproxy_frontend_bytes_in_total[5m])

      - record: haproxy:frontend_bytes_out_rate
        expr: rate(haproxy_frontend_bytes_out_total[5m])

      - record: haproxy:backend_sessions_rate
        expr: rate(haproxy_backend_sessions_total[5m])

  - name: recording_pgbouncer
    rules:
      - record: pgbouncer:pool_usage_ratio
        expr: pgbouncer_pools_server_active_connections / (pgbouncer_pools_server_active_connections + pgbouncer_pools_server_idle_connections + 1)

      - record: pgbouncer:queries_rate
        expr: rate(pgbouncer_stats_queries_pooled_total[5m])

      - record: pgbouncer:bytes_in_rate
        expr: rate(pgbouncer_stats_received_bytes_total[5m])

      - record: pgbouncer:bytes_out_rate
        expr: rate(pgbouncer_stats_sent_bytes_total[5m])

      - record: pgbouncer:avg_query_duration
        expr: rate(pgbouncer_stats_queries_duration_seconds_total[5m]) / (rate(pgbouncer_stats_queries_pooled_total[5m]) + 1)

  - name: recording_node
    rules:
      - record: node:cpu_usage_ratio
        expr: 1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))

      - record: node:memory_usage_ratio
        expr: 1 - (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)

      - record: node:disk_usage_ratio
        expr: 1 - (node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"})
```

### 5. queries.yml (custom metrics postgres-exporter)

```yaml
pg_database_size:
  query: "SELECT datname, pg_database_size(datname) as size_bytes FROM pg_database WHERE datallowconn"
  metrics:
    - datname:
        usage: "LABEL"
    - size_bytes:
        usage: "GAUGE"
        description: "Database size in bytes"

pg_slow_queries:
  query: "SELECT count(*) as count FROM pg_stat_activity WHERE state = 'active' AND now() - query_start > interval '5 minutes'"
  metrics:
    - count:
        usage: "GAUGE"
        description: "Queries running longer than 5 minutes"

pg_locks_waiting:
  query: "SELECT count(*) as count FROM pg_locks WHERE NOT granted"
  metrics:
    - count:
        usage: "GAUGE"
        description: "Number of locks waiting"

pg_deadlocks:
  query: "SELECT deadlocks FROM pg_stat_database WHERE datname = current_database()"
  metrics:
    - deadlocks:
        usage: "COUNTER"
        description: "Number of deadlocks"

pg_vacuum_age:
  query: "SELECT coalesce(max(extract(epoch from now() - last_autovacuum)), 0) as seconds FROM pg_stat_user_tables WHERE last_autovacuum IS NOT NULL"
  metrics:
    - seconds:
        usage: "GAUGE"
        description: "Seconds since oldest autovacuum"

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

pg_table_size:
  query: |
    SELECT schemaname, relname,
           pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) as total_bytes,
           n_live_tup as live_tuples, n_dead_tup as dead_tuples
    FROM pg_stat_user_tables
    ORDER BY pg_total_relation_size(quote_ident(schemaname)||'.'||quote_ident(relname)) DESC LIMIT 10
  metrics:
    - schemaname:
        usage: "LABEL"
    - relname:
        usage: "LABEL"
    - total_bytes:
        usage: "GAUGE"
        description: "Total table size"
    - live_tuples:
        usage: "GAUGE"
        description: "Live rows"
    - dead_tuples:
        usage: "GAUGE"
        description: "Dead rows (need vacuum)"

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

### 6. alertmanager.yml

```yaml
global:
  resolve_timeout: 2m

route:
  group_by: ['alertname', 'component']
  group_wait: 10s
  group_interval: 30s
  repeat_interval: 5m
  receiver: 'logncall-webhook'
  routes:
    - match:
        severity: critical
      receiver: 'logncall-webhook'
      group_wait: 5s
      continue: true
    - match:
        severity: warning
      receiver: 'logncall-webhook'

inhibit_rules:
  - source_matchers: ['alertname = EtcdDown']
    target_matchers: ['alertname = PatroniNoLeader']
  - source_matchers: ['alertname = HAProxyDown']
    target_matchers: ['alertname =~ "HAProxy.*Backend.*"']
  - source_matchers: ['alertname = PatroniDown']
    target_matchers: ['alertname = PostgreSQLDown']

receivers:
  - name: 'logncall-webhook'
    webhook_configs:
      - url: 'http://webhook-logger:8080/webhook'
        send_resolved: true
```

### 7. keepalived/keepalived-master.conf

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

### 8. keepalived/keepalived-backup.conf

Identique sauf `state BACKUP` et `priority 100`.

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

### 9. haproxy.cfg

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

### 8. mimir.yml

```yaml
multitenancy_enabled: false

server:
  http_listen_port: 9009
  grpc_listen_port: 9095

blocks_storage:
  backend: s3
  s3:
    endpoint: minio:9000
    bucket_name: mimir-blocks
    access_key_id: minioadmin
    secret_access_key: minioadmin
    insecure: true
  tsdb:
    dir: /data/tsdb
  bucket_store:
    sync_dir: /data/tsdb-sync

compactor:
  data_dir: /data/compactor
  sharding_ring:
    kvstore:
      store: memberlist

distributor:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: memberlist

ingester:
  ring:
    instance_addr: 127.0.0.1
    kvstore:
      store: memberlist
    replication_factor: 1

store_gateway:
  sharding_ring:
    replication_factor: 1

limits:
  max_global_series_per_user: 0
  ingestion_rate: 100000
  ingestion_burst_size: 200000
```

### 9. tempo.yml

```yaml
server:
  http_listen_port: 3200

distributor:
  receivers:
    otlp:
      protocols:
        grpc:
          endpoint: "0.0.0.0:4317"
        http:
          endpoint: "0.0.0.0:4318"

storage:
  trace:
    backend: s3
    s3:
      endpoint: minio:9000
      bucket: tempo-traces
      access_key: minioadmin
      secret_key: minioadmin
      insecure: true
    wal:
      path: /var/tempo/wal
    local:
      path: /var/tempo/blocks

metrics_generator:
  registry:
    external_labels:
      source: tempo
  storage:
    path: /var/tempo/generator/wal
    remote_write:
      - url: http://prometheus-1:9090/api/v1/write
        send_exemplars: true

overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics]
```

### 10. otel-collector.yml

```yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: "0.0.0.0:4317"
      http:
        endpoint: "0.0.0.0:4318"

processors:
  batch:
    timeout: 5s
    send_batch_size: 1000

exporters:
  otlp/tempo:
    endpoint: tempo:4317
    tls:
      insecure: true

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [otlp/tempo]
```

### 11. bucket.yml (Thanos → MinIO)

```yaml
type: S3
config:
  bucket: thanos
  endpoint: minio:9000
  access_key: minioadmin
  secret_key: minioadmin
  insecure: true
```

### 9. grafana/provisioning/datasources/datasources.yml

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
  - name: Mimir
    type: prometheus
    access: proxy
    url: http://mimir:9009/prometheus
    editable: false
  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    editable: false
    jsonData:
      tracesToMetrics:
        datasourceUid: thanos
      serviceMap:
        datasourceUid: thanos
      nodeGraph:
        enabled: true
  - name: Alertmanager
    type: alertmanager
    access: proxy
    url: http://alertmanager:9093
    jsonData:
      implementation: prometheus
    editable: false
```

### 10. grafana/provisioning/dashboards/dashboards.yml

```yaml
apiVersion: 1
providers:
  - name: 'Transactis'
    orgId: 1
    folder: 'Transactis'
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30
    options:
      path: /var/lib/grafana/dashboards
      foldersFromFilesStructure: false
```

### 11. webhook-server.py

```python
#!/usr/bin/env python3
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
from datetime import datetime

class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(content_length)
        data = json.loads(body)

        print(f"\n{'='*60}")
        print(f"[{datetime.now().strftime('%H:%M:%S')}] ALERT - Status: {data.get('status')}")
        print(f"{'='*60}")

        for alert in data.get('alerts', []):
            status = alert['status']
            labels = alert.get('labels', {})
            annotations = alert.get('annotations', {})
            icon = 'FIRING' if status == 'firing' else 'RESOLVED'
            print(f"  [{icon}] {labels.get('alertname')} | {labels.get('severity')} | {labels.get('component')}")
            print(f"          {annotations.get('summary', '')}")

        print(f"{'='*60}\n", flush=True)

        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'ok')

    def log_message(self, format, *args):
        pass

if __name__ == '__main__':
    print("Webhook logger (LogNcall simulator) ready on :8080\n", flush=True)
    HTTPServer(('0.0.0.0', 8080), WebhookHandler).serve_forever()
```

### 12. Dockerfile.webhook

```dockerfile
FROM python:3.12-slim
COPY webhook-server.py /app/webhook-server.py
CMD ["python3", "-u", "/app/webhook-server.py"]
```

### 13. docker-compose-full-lab.yml

```yaml
services:
  # ==================== ETCD CLUSTER ====================
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
      - --initial-cluster-token=full-lab
      - --metrics=extensive
    ports:
      - "2379:2379"
    networks:
      - fullstack

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
      - --initial-cluster-token=full-lab
      - --metrics=extensive
    networks:
      - fullstack

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
      - --initial-cluster-token=full-lab
      - --metrics=extensive
    networks:
      - fullstack

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
    ports:
      - "5432:5432"
      - "8008:8008"
    networks:
      - fullstack
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
      ALLOW_NOSSL: "true"
    ports:
      - "5433:5432"
      - "8009:8008"
    networks:
      - fullstack
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
      ALLOW_NOSSL: "true"
    ports:
      - "5434:5432"
      - "8010:8008"
    networks:
      - fullstack
    depends_on:
      - etcd-1
      - etcd-2
      - etcd-3

  # ==================== HAPROXY HA (2 nodes + Keepalived) ====================
  haproxy-1:
    image: haproxy:2.9
    container_name: haproxy-1
    hostname: haproxy-1
    ports:
      - "5000:5000"
      - "5001:5001"
      - "8404:8404"
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      fullstack:
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
      fullstack:
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

  # ==================== PGBOUNCER (via VIP) ====================
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
      MIN_POOL_SIZE: "2"
      MAX_CLIENT_CONN: "200"
      ADMIN_USERS: postgres
      LISTEN_PORT: "6432"
    ports:
      - "6432:6432"
    networks:
      - fullstack
    depends_on:
      - haproxy-1
      - haproxy-2

  # ==================== EXPORTERS ====================
  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:latest
    container_name: postgres-exporter
    environment:
      DATA_SOURCE_NAME: "postgresql://postgres:postgres@172.20.0.100:5000/postgres?sslmode=disable"
    command:
      - --extend.query-path=/etc/postgres-exporter/queries.yml
    volumes:
      - ./queries.yml:/etc/postgres-exporter/queries.yml:ro
    ports:
      - "9187:9187"
    networks:
      - fullstack
    depends_on:
      - haproxy-1

  pgbouncer-exporter:
    image: prometheuscommunity/pgbouncer-exporter:latest
    container_name: pgbouncer-exporter
    command:
      - --pgBouncer.connectionString=postgres://postgres:postgres@pgbouncer:6432/pgbouncer?sslmode=disable
    ports:
      - "9127:9127"
    networks:
      - fullstack
    depends_on:
      - pgbouncer

  pgbackrest-exporter:
    image: woblerr/pgbackrest_exporter:latest
    container_name: pgbackrest-exporter
    environment:
      BACKREST_STANZA: pg-cluster
      BACKREST_HOST: patroni-1
      BACKREST_HOST_USER: postgres
    ports:
      - "9854:9854"
    networks:
      - fullstack
    depends_on:
      - patroni-1

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    networks:
      - fullstack

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
      - fullstack

  minio-init:
    image: minio/mc:latest
    container_name: minio-init
    entrypoint: >
      /bin/sh -c "
      sleep 5 &&
      mc alias set local http://minio:9000 minioadmin minioadmin &&
      mc mb --ignore-existing local/thanos &&
      mc mb --ignore-existing local/mimir-blocks &&
      mc mb --ignore-existing local/tempo-traces &&
      echo 'Bucket thanos created'
      "
    networks:
      - fullstack
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
      - --query.max-concurrency=20
      - --query.max-samples=50000000
      - --query.timeout=2m
    networks:
      - fullstack

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
      - fullstack
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
      - --query.max-concurrency=20
      - --query.max-samples=50000000
      - --query.timeout=2m
    networks:
      - fullstack

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
      - fullstack
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
      - fullstack
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
      - fullstack
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
      - fullstack
    depends_on:
      - minio-init

  # ==================== MIMIR (long-term metrics) ====================
  mimir:
    image: grafana/mimir:latest
    container_name: mimir
    command:
      - --config.file=/etc/mimir/mimir.yml
    volumes:
      - ./mimir.yml:/etc/mimir/mimir.yml:ro
    ports:
      - "9009:9009"
    networks:
      - fullstack
    depends_on:
      - minio-init

  # ==================== TEMPO (tracing) ====================
  tempo:
    image: grafana/tempo:latest
    container_name: tempo
    command:
      - --config.file=/etc/tempo/tempo.yml
    volumes:
      - ./tempo.yml:/etc/tempo/tempo.yml:ro
    ports:
      - "3200:3200"
      - "4317:4317"
      - "4318:4318"
    networks:
      - fullstack
    depends_on:
      - minio-init

  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: otel-collector
    command:
      - --config=/etc/otel/config.yml
    volumes:
      - ./otel-collector.yml:/etc/otel/config.yml:ro
    networks:
      - fullstack
    depends_on:
      - tempo

  trace-generator:
    build:
      context: .
      dockerfile: Dockerfile.tracegen
    container_name: trace-generator
    networks:
      - fullstack
    depends_on:
      - otel-collector

  # ==================== ALERTMANAGER ====================
  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
    networks:
      - fullstack

  # ==================== WEBHOOK LOGGER (LogNcall) ====================
  webhook-logger:
    build:
      context: .
      dockerfile: Dockerfile.webhook
    container_name: webhook-logger
    networks:
      - fullstack

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
      - ./dashboards:/var/lib/grafana/dashboards:ro
    networks:
      - fullstack

volumes:
  prom1-data:
  prom2-data:

networks:
  fullstack:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
          gateway: 172.20.0.1
```

---

## Guide de démarrage rapide

```bash
# 1. Se placer dans le dossier du lab
cd docs/07-docker-lab/

# 2. Créer l'arborescence
mkdir -p rules keepalived grafana/provisioning/datasources grafana/provisioning/dashboards dashboards

# 3. Copier les fichiers de config dans ce dossier :
#    prometheus.yml, prometheus-2.yml, alertmanager.yml, haproxy.cfg,
#    bucket.yml, queries.yml, webhook-server.py, Dockerfile.webhook
#    keepalived/keepalived-master.conf, keepalived/keepalived-backup.conf
#    mimir.yml, tempo.yml, otel-collector.yml
#    trace-generator.py, Dockerfile.tracegen
#    rules/all-alerts.yml, rules/recording-rules.yml
#    grafana/provisioning/datasources/datasources.yml
#    grafana/provisioning/dashboards/dashboards.yml

# 4. Copier les 7 dashboards Grafana
cp ../../grafana_dashboards/*.json dashboards/

# 5. Démarrer tout
docker compose -f docker-compose-full-lab.yml up -d --build

# 6. Attendre que tout démarre (~60 secondes)
sleep 60

# 7. Vérifier
docker compose -f docker-compose-full-lab.yml ps
docker exec -it patroni-1 patronictl list
```

## URLs d'accès

| Service | URL / Port | Credentials |
|---------|------------|-------------|
| **Grafana** | http://localhost:3000 | admin / admin |
| **Thanos Query** | http://localhost:19192 | - |
| **Prometheus-1** | http://localhost:9090 | - |
| **Prometheus-2** | http://localhost:9091 | - |
| **Alertmanager** | http://localhost:9093 | - |
| **MinIO Console** | http://localhost:9001 | minioadmin / minioadmin |
| **HAProxy-1 Stats** | http://localhost:8404/stats | - |
| **HAProxy-2 Stats** | http://172.20.0.11:8404/stats (interne) | - |
| **VIP Write** | 172.20.0.100:5000 (interne) / localhost:5000 | postgres / postgres |
| **VIP Read** | 172.20.0.100:5001 (interne) / localhost:5001 | postgres / postgres |
| **PgBouncer** | localhost:6432 | postgres / postgres |
| **PG Exporter** | http://localhost:9187/metrics | - |
| **PgB Exporter** | http://localhost:9127/metrics | - |
| **pgBackRest Exp** | http://localhost:9854/metrics | - |
| **Mimir** | http://localhost:9009 | - |
| **Tempo** | http://localhost:3200 | - |
| **Patroni API** | http://localhost:8008 | - |

> **Astuce** : `export PGPASSWORD=postgres` pour éviter le prompt mot de passe.

## Dashboards auto-provisionnés

Au démarrage, Grafana charge automatiquement les 7 dashboards dans le dossier **Transactis** :

| Dashboard | Ce qu'il montre |
|---|---|
| **etcd** | Leader, proposals, WAL fsync, DB size, gRPC, network peers |
| **Patroni** | Primary/replica status, timeline, xlog position, DCS, pending restart |
| **PostgreSQL Exporter** | Transactions, connections, locks, cache hit, replication lag, temp files |
| **PostgreSQL Quickstart** | BGWriter buffers, conflicts, deadlocks, tuples CRUD |
| **pgBackRest** | Backup status, duration, size, WAL archive, stanza health |
| **HAProxy** | Frontends/backends, sessions, bytes in/out, connect time, errors |
| **PgBouncer** | Pool usage, clients waiting/active, server connections, query duration |

---

## Scénarios de test

> ```bash
> export PGPASSWORD=postgres
> ```

### Scénario 1 : Panne etcd + alertes + inhibitions

```bash
# AVANT
docker exec -it etcd-1 etcdctl endpoint health --cluster
docker exec -it patroni-1 patronictl list

# Kill 1 etcd → quorum maintenu
docker stop etcd-3
# → Prometheus: EtcdDown firing
# → Webhook: alerte reçue
# → Patroni: cluster PG OK

# Aggraver : kill 2ème etcd → perte de quorum
docker stop etcd-2
# → EtcdNoLeader firing
# → PatroniNoLeader inhibé (inhibition rule)
# → Vérifier dans docker logs webhook-logger

# Restaurer
docker start etcd-2 etcd-3
```

### Scénario 2 : Failover PostgreSQL complet

```bash
docker exec -it patroni-1 patronictl list
docker kill patroni-1

# Observer :
# 1. PatroniDown + HAProxyBackendDown → webhook
# 2. PatroniFailoverDetected (warning)
# 3. HAProxy Stats: bascule dans pg-write
# 4. Grafana Patroni dashboard: changement de primary
# 5. postgres-exporter continue via HAProxy

psql -h localhost -p 5000 -U postgres -c "SELECT 'write OK after failover';"
psql -h localhost -p 6432 -U postgres -c "SELECT 'pgbouncer OK after failover';"

docker start patroni-1
sleep 15
docker exec -it patroni-2 patronictl list
```

### Scénario 3 : Switchover planifié

```bash
docker exec -it patroni-1 patronictl switchover --candidate patroni-2 --force
# → HAProxy: bascule propre
# → PatroniFailoverDetected peut se déclencher
# → PgBouncer: aucune interruption
```

### Scénario 4 : Lag de réplication

```bash
psql -h localhost -p 5000 -U postgres -c "
  CREATE TABLE IF NOT EXISTS loadtest (id serial, data text, ts timestamp default now());
  INSERT INTO loadtest (data) SELECT md5(random()::text) FROM generate_series(1, 100000);
"
# → Observer dans Grafana: pg_replication_lag, pg:transactions_per_second
```

### Scénario 5 : Saturation PgBouncer

```bash
for i in $(seq 1 30); do
    psql -h localhost -p 6432 -U postgres -c "SELECT pg_sleep(15);" &
done
# → PgBouncerClientsWaiting + PgBouncerPoolUsageHigh → webhook
# → Grafana PgBouncer dashboard: cl_waiting, pool usage
psql -h localhost -p 6432 -U postgres pgbouncer -c "SHOW POOLS;"
```

### Scénario 6 : Failover HAProxy HA (Keepalived)

```bash
# Vérifier qui a la VIP
docker logs keepalived-1 2>&1 | grep -E "MASTER|BACKUP" | tail -1
# → "Entering MASTER STATE"

# Kill le MASTER HAProxy
docker stop haproxy-1

# Keepalived-2 prend la VIP (~2s)
docker logs keepalived-2 2>&1 | grep -E "MASTER|172.20.0.100" | tail -3
# → "Entering MASTER STATE"
# → "Sending gratuitous ARP for 172.20.0.100"

# La connexion via VIP fonctionne toujours
docker run --rm --network training_fullstack -e PGPASSWORD=postgres \
  postgres:16-alpine psql -h 172.20.0.100 -p 5000 -U postgres \
  -c "SELECT 'HAProxy failover OK';"

# PgBouncer continue de servir (connecté à la VIP)
psql -h localhost -p 6432 -U postgres -c "SELECT 'PgBouncer via VIP OK';"

# Restaurer → preemption : haproxy-1 reprend la VIP (priority 150 > 100)
docker start haproxy-1
sleep 5
docker logs keepalived-1 2>&1 | grep "MASTER" | tail -1
```

### Scénario 6b : Perte des 2 HAProxy

```bash
docker stop haproxy-1 haproxy-2
# → HAProxyDown (critical) pour les 2 → webhook
# → PgBouncer + postgres-exporter perdent la connexion
# → Patroni + etcd continuent de fonctionner

docker start haproxy-1 haproxy-2
# → VIP revient sur haproxy-1, tout se reconnecte
```

### Scénario 7 : Déduplication Prometheus

```bash
# Vérifier les external_labels
curl -s 'http://localhost:9090/api/v1/status/config' | grep -A3 external_labels
curl -s 'http://localhost:9091/api/v1/status/config' | grep -A3 external_labels

# Sans dédup: chaque cible x2
curl -s 'http://localhost:19192/api/v1/query?query=count(up)&dedup=false'
# → ~18 (9 cibles x 2)

# Avec dédup: chaque cible x1
curl -s 'http://localhost:19192/api/v1/query?query=count(up)&dedup=true'
# → ~9

# Kill un Prometheus → Thanos continue
docker stop prometheus-2
curl -s 'http://localhost:19192/api/v1/query?query=count(up)&dedup=true'
# → Toujours ~9
docker start prometheus-2
```

### Scénario 8 : S3 / MinIO

```bash
# Vérifier que les sidecars sont ready
docker logs thanos-sidecar-1 2>&1 | grep -E "ready|external_labels"

# Shipper status
docker exec thanos-sidecar-1 cat /prometheus/data/thanos.shipper.json

# Après ~5 min (min-block-duration=5m), les uploads commencent
docker logs thanos-sidecar-1 2>&1 | grep -i upload

# Vérifier dans MinIO: http://localhost:9001 → Bucket "thanos"
```

### Scénario 9 : Cascade de pannes

```bash
docker stop etcd-3
docker kill patroni-1
docker stop pgbouncer

# Observer :
# - Cascade d'alertes: EtcdDown, PatroniDown, PgBouncerDown
# - Inhibitions actives
# - HAProxy failover
# - Prometheus HA: les 2 collectent toujours

docker start etcd-3 patroni-1 pgbouncer
```

### Scénario 10 : Mimir — stockage long-terme via remote_write

```bash
# Mimir est ready ?
curl -s http://localhost:9009/ready
# → ready

# Vérifier que Prometheus écrit vers Mimir (remote_write)
curl -s 'http://localhost:9090/api/v1/status/config' | grep remote_write
# → url: http://mimir:9009/api/v1/push

# Requête via Mimir (même API que Prometheus)
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=up' | python3 -m json.tool | head -10

# Comparer : Prometheus local (retention 3d) vs Mimir (illimité dans S3)
# Kill Prometheus → Mimir a toujours les données
docker stop prometheus-1
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=up' | python3 -m json.tool | head -10
# → les données sont là (remote_write a poussé avant)
docker start prometheus-1

# Métriques self-monitoring de Mimir
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=cortex_ingester_active_series'
```

### Scénario 11 : Tempo — tracing distribué

```bash
# Tempo est ready ?
curl -s http://localhost:3200/ready
# → ready

# Le trace-generator envoie des traces ?
docker logs trace-generator 2>&1 | head -3

# Chercher des traces
curl -s 'http://localhost:3200/api/search?limit=5' | python3 -m json.tool | head -20

# Chercher des traces lentes (> 500ms)
curl -s 'http://localhost:3200/api/search?q={duration>500ms}&limit=5' | python3 -m json.tool

# Dans Grafana → Explore → datasource Tempo :
# - Voir les traces client.request → pgbouncer.pool → haproxy.route → postgresql.query
# - Service Graph : flux entre les composants
# - Filtrer par db.slow_query=true pour les requêtes lentes

# MinIO : vérifier le bucket tempo-traces
# http://localhost:9001 → bucket tempo-traces
```

### Scénario 12 : Validation tuning Prometheus

```bash
# Santé Prometheus
curl -s 'http://localhost:9090/api/v1/query?query=process_resident_memory_bytes' | python3 -m json.tool | head -10
curl -s 'http://localhost:9090/api/v1/query?query=prometheus_tsdb_head_series' | python3 -m json.tool | head -10

# Recording rules
curl -s 'http://localhost:19192/api/v1/query?query=pg:transactions_per_second'
curl -s 'http://localhost:19192/api/v1/query?query=node:cpu_usage_ratio'
curl -s 'http://localhost:19192/api/v1/query?query=haproxy:write_backends_up_ratio'
curl -s 'http://localhost:19192/api/v1/query?query=pgbouncer:pool_usage_ratio'
curl -s 'http://localhost:19192/api/v1/query?query=etcd:wal_fsync_p99'

# Flags Prometheus
curl -s 'http://localhost:9090/api/v1/status/flags' | python3 -m json.tool | grep -E "retention|compression|concurrency|samples"
```

---

## Nettoyage

```bash
docker compose -f docker-compose-full-lab.yml down -v
```

---

## Checklist de validation finale

### Infrastructure
- [ ] Tous les containers UP (`docker compose ps`)
- [ ] Cluster Patroni sain (1 leader, 2 replicas)
- [ ] Cluster etcd sain (3/3 healthy)
- [ ] Tous les targets Prometheus UP (9 jobs)

### Alertes (48 règles)
- [ ] etcd: 9 alertes (Down, NoLeader, Proposals, LeaderChanges, DiskLatency, DBSize, BackendCommit, SlowApply, QuotaLimit)
- [ ] Patroni: 6 alertes (Down, NoLeader, Failover, PGNotRunning, PendingRestart, ReplicationLag)
- [ ] PostgreSQL: 12 alertes (Down, LagWarn/Crit, Connections, Deadlocks, SlowQueries, Locks, SlotLag, DeadTuples, Vacuum, TempFiles, CacheHitRatio)
- [ ] pgBackRest: 5 alertes (Down, StanzaError, BackupOld, BackupFailed, WALFailing)
- [ ] HAProxy: 7 alertes (Down, NoWrite/NoRead, BackendDown, Sessions, ConnectTime, ErrorRate)
- [ ] PgBouncer: 5 alertes (Down, PoolExhausted, ClientsWaiting, PoolUsage, MaxWait)
- [ ] Node: 3 alertes (Disk, Memory, CPU)
- [ ] Inhibitions: EtcdDown→PatroniNoLeader, HAProxyDown→BackendDown, PatroniDown→PostgreSQLDown

### Recording rules (25)
- [ ] etcd: wal_fsync_p99, backend_commit_p99, db_usage_ratio, grpc_request_rate, grpc_error_rate
- [ ] PostgreSQL: transactions/s, cache_hit, connections, rollback_ratio, rows/s, temp_files, bgwriter
- [ ] HAProxy: write/read_backends_ratio, session_usage, bytes_in/out, sessions_rate
- [ ] PgBouncer: pool_usage, queries_rate, bytes_in/out, avg_query_duration
- [ ] Node: cpu, memory, disk

### Dashboards Grafana (7)
- [ ] etcd, Patroni, PostgreSQL (x2), pgBackRest, HAProxy, PgBouncer
- [ ] Auto-provisionnés dans le dossier Transactis
- [ ] Datasource = Thanos (dédupliqué)

### Thanos / S3
- [ ] 2 Prometheus collectent en parallèle
- [ ] Thanos Query déduplique (`count(up)` dedup=false vs true)
- [ ] Kill un Prometheus → Thanos continue
- [ ] MinIO reçoit les blocs après ~5 min
- [ ] Compactor tourne (`docker logs thanos-compactor`)

### HAProxy HA / Keepalived
- [ ] VIP `172.20.0.100` assignée à haproxy-1 (MASTER)
- [ ] Kill haproxy-1 → VIP bascule sur haproxy-2 (~2s)
- [ ] Restart haproxy-1 → preemption, VIP revient
- [ ] PgBouncer via VIP : aucune interruption

### Mimir (stockage long-terme)
- [ ] Mimir ready (`curl http://localhost:9009/ready`)
- [ ] `remote_write` fonctionne (Prometheus → Mimir)
- [ ] Requête via Mimir retourne les données
- [ ] Kill Prometheus → Mimir sert toujours les données historiques
- [ ] MinIO → bucket `mimir-blocks` contient des données

### Tempo (tracing)
- [ ] Tempo ready (`curl http://localhost:3200/ready`)
- [ ] trace-generator envoie des traces
- [ ] Traces visibles dans Grafana → Explore → Tempo
- [ ] Service Graph visible (client → pgbouncer → haproxy → postgresql)
- [ ] Filtrage par durée et erreurs fonctionne
- [ ] MinIO → bucket `tempo-traces` contient des données

### Circuit d'alerte
- [ ] Panne → Prometheus → Alertmanager → Webhook (LogNcall) → Résolution
- [ ] Inhibitions fonctionnent (EtcdDown inhibe PatroniNoLeader)
- [ ] Silencing fonctionne dans Alertmanager
