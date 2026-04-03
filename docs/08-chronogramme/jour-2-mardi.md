# Jour 2 — Mardi 31 Mars : Supervision PostgreSQL / Patroni + pgBackRest

## Chronogramme

```
09:00 ┬─────────────────────────────────────────────────────────────┐
      │  BLOC 1 : Audit du cluster PostgreSQL / Patroni (1h30)     │
      │  • État Patroni, rôles, timeline                           │
      │  • Configuration PostgreSQL et réplication                  │
10:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 2 : Configuration pgexporter (1h)                    │
      │  • Vérifier / installer postgres_exporter                  │
      │  • Configurer les métriques custom                         │
11:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 3 : Scrape Prometheus + dashboards Grafana (30min)   │
      │  • Ajouter les targets PostgreSQL dans Prometheus           │
12:00 ┼═══════════════════ PAUSE DÉJEUNER ══════════════════════════┤
14:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 4 : Règles d'alerte PostgreSQL / Patroni (1h30)      │
      │  • Alertes réplication, connexions, locks                   │
      │  • Alertes Patroni (leader, failover)                       │
15:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 5 : Supervision pgBackRest (1h)                      │
      │  • Audit des sauvegardes existantes                        │
      │  • Alertes sur l'âge des backups et l'archivage WAL        │
16:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 6 : Configuration Alertmanager + tests (1h30)         │
      │  • Ajouter les routes pour les alertes PG/Patroni          │
      │  • Tests de bout en bout                                   │
      │  • Documentation                                           │
18:00 ┴─────────────────────────────────────────────────────────────┘
```

---

## BLOC 1 — Audit du cluster PostgreSQL / Patroni (09:00-10:30)

### Actions

#### 1.1 État du cluster Patroni
```bash
# Se connecter à un nœud Patroni
ssh user@pg-node1

# État du cluster
patronictl list

# Noter :
# - Qui est le leader ? ___________
# - Combien de replicas ? ___________
# - Lag de chaque replica ? ___________
# - Timeline (TL) ? ___________
# - État de chaque nœud (running/streaming) ? ___________

# Configuration Patroni
patronictl show-config

# Historique des switchovers/failovers
patronictl history
```

#### 1.2 Configuration PostgreSQL
```bash
# Se connecter en psql sur le leader
sudo -u postgres psql

# Version
SELECT version();

# Paramètres critiques
SHOW max_connections;
SHOW shared_buffers;
SHOW wal_level;           -- Doit être 'replica' ou 'logical'
SHOW max_wal_senders;     -- Nombre max de connexions de réplication
SHOW max_replication_slots;
SHOW archive_mode;        -- Doit être 'on' pour pgBackRest
SHOW archive_command;
```

#### 1.3 État de la réplication
```bash
# Sur le LEADER :
sudo -u postgres psql -c "
SELECT client_addr,
       application_name,
       state,
       sync_state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;
"

# Sur chaque REPLICA :
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
sudo -u postgres psql -c "
SELECT pg_last_wal_receive_lsn(),
       pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp(),
       now() - pg_last_xact_replay_timestamp() AS replay_delay;
"
```

#### 1.4 État des connexions
```bash
sudo -u postgres psql -c "
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state
ORDER BY count DESC;
"

sudo -u postgres psql -c "
SELECT datname, count(*)
FROM pg_stat_activity
GROUP BY datname
ORDER BY count DESC;
"
```

### Livrable
- [ ] Cluster Patroni documenté (leader, replicas, lag, timeline)
- [ ] Paramètres PostgreSQL critiques notés
- [ ] État de la réplication vérifié

---

## BLOC 2 — Configuration pgexporter (10:30-11:30)

### Actions

#### 2.1 Vérifier si postgres_exporter est installé
```bash
# Sur chaque nœud PostgreSQL
which postgres_exporter
systemctl status postgres_exporter

# Vérifier les métriques exposées
curl -s http://localhost:9187/metrics | head -20
curl -s http://localhost:9187/metrics | wc -l
```

#### 2.2 Si non installé, installer postgres_exporter
```bash
# Télécharger la dernière version
# https://github.com/prometheus-community/postgres_exporter/releases

# Créer l'utilisateur de monitoring dans PostgreSQL
sudo -u postgres psql -c "
CREATE USER monitoring WITH PASSWORD 'monitoring_password';
GRANT pg_monitor TO monitoring;
"

# Configurer la connexion
export DATA_SOURCE_NAME="postgresql://monitoring:monitoring_password@localhost:5432/postgres?sslmode=disable"

# Démarrer l'exporter
postgres_exporter --web.listen-address=:9187
```

#### 2.3 Ajouter des requêtes custom (si nécessaire)
Créer `/etc/postgres_exporter/queries.yml` :
```yaml
pg_replication_lag:
  query: |
    SELECT
      CASE WHEN pg_is_in_recovery() THEN 1 ELSE 0 END AS is_replica,
      COALESCE(EXTRACT(EPOCH FROM replay_lag), 0) AS replay_lag_seconds
    FROM pg_stat_replication
  master: true
  metrics:
    - is_replica:
        usage: "GAUGE"
        description: "1 if replica, 0 if primary"
    - replay_lag_seconds:
        usage: "GAUGE"
        description: "Replication replay lag in seconds"

pg_long_running_transactions:
  query: |
    SELECT
      COALESCE(MAX(EXTRACT(EPOCH FROM now() - xact_start)), 0) AS max_duration_seconds
    FROM pg_stat_activity
    WHERE state != 'idle'
      AND xact_start IS NOT NULL
  metrics:
    - max_duration_seconds:
        usage: "GAUGE"
        description: "Duration of longest running transaction in seconds"
```

#### 2.4 Vérifier les métriques clés
```bash
# pg_up doit être 1
curl -s http://localhost:9187/metrics | grep "^pg_up"

# Réplication
curl -s http://localhost:9187/metrics | grep pg_stat_replication

# Connexions
curl -s http://localhost:9187/metrics | grep pg_stat_activity

# Taille des bases
curl -s http://localhost:9187/metrics | grep pg_database_size
```

### Livrable
- [ ] postgres_exporter fonctionnel sur chaque nœud
- [ ] Métriques custom ajoutées si nécessaire
- [ ] Métriques vérifiées (pg_up, réplication, connexions)

---

## BLOC 3 — Scrape Prometheus + Dashboards (11:30-12:00)

### Actions

#### 3.1 Ajouter les targets dans Prometheus
```yaml
# Dans /etc/prometheus/prometheus.yml
scrape_configs:
  # ... jobs existants ...

  - job_name: 'postgresql'
    scrape_interval: 15s
    static_configs:
      - targets:
        - 'pg-node1:9187'
        - 'pg-node2:9187'
        - 'pg-node3:9187'

  - job_name: 'patroni'
    scrape_interval: 15s
    static_configs:
      - targets:
        - 'pg-node1:8008'
        - 'pg-node2:8008'
        - 'pg-node3:8008'
    metrics_path: /metrics
```

```bash
promtool check config /etc/prometheus/prometheus.yml
curl -X POST http://localhost:9090/-/reload
```

#### 3.2 Vérifier dans Prometheus
- Ouvrir Targets : jobs `postgresql` et `patroni` avec tous les nœuds UP

### Livrable
- [ ] Targets PostgreSQL et Patroni UP dans Prometheus

---

## BLOC 4 — Règles d'alerte PostgreSQL / Patroni (13:00-14:30)

### Actions

Créer `/etc/prometheus/rules/postgresql-patroni-alerts.yml` :

```yaml
groups:
  - name: postgresql_health
    rules:
      # CRITIQUE : PostgreSQL injoignable
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
          component: postgresql
          team: dba
        annotations:
          summary: "PostgreSQL DOWN sur {{ $labels.instance }}"
          description: "postgres_exporter ne peut plus joindre PostgreSQL sur {{ $labels.instance }}."
          runbook: "https://wiki.transactis.com/runbooks/postgresql-down"

      # CRITIQUE : lag de réplication > 5 min
      - alert: PostgreSQLReplicationLagCritical
        expr: pg_stat_replication_replay_lag > 300
        for: 2m
        labels:
          severity: critical
          component: postgresql
          team: dba
        annotations:
          summary: "Lag réplication CRITIQUE > 5min sur {{ $labels.instance }}"
          description: "Lag actuel : {{ $value | humanizeDuration }}. Risque de perte de données en cas de failover."

      # WARNING : lag de réplication > 30s
      - alert: PostgreSQLReplicationLagWarning
        expr: pg_stat_replication_replay_lag > 30
        for: 2m
        labels:
          severity: warning
          component: postgresql
          team: dba
        annotations:
          summary: "Lag réplication > 30s sur {{ $labels.instance }}"
          description: "Lag actuel : {{ $value }}s."

      # WARNING : connexions > 80% de max_connections
      - alert: PostgreSQLConnectionsHigh
        expr: sum by (instance) (pg_stat_activity_count) / pg_settings_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
          component: postgresql
          team: dba
        annotations:
          summary: "Connexions PG > 80% sur {{ $labels.instance }}"
          description: "{{ $value | humanizePercentage }} de max_connections utilisées."

      # WARNING : transaction longue > 5min
      - alert: PostgreSQLLongTransaction
        expr: pg_long_running_transactions_max_duration_seconds > 300
        for: 1m
        labels:
          severity: warning
          component: postgresql
          team: dba
        annotations:
          summary: "Transaction longue > 5min sur {{ $labels.instance }}"

      # CRITIQUE : archivage WAL en échec
      - alert: PostgreSQLWALArchiveFailing
        expr: pg_stat_archiver_failed_count > 0
        for: 5m
        labels:
          severity: critical
          component: postgresql
          team: dba
        annotations:
          summary: "Archivage WAL en échec sur {{ $labels.instance }}"
          description: "{{ $value }} WAL ont échoué à l'archivage. Les sauvegardes PITR sont compromises."

  - name: patroni_health
    rules:
      # CRITIQUE : le cluster Patroni n'a pas de leader
      - alert: PatroniNoLeader
        expr: count(patroni_primary == 1) == 0
        for: 30s
        labels:
          severity: critical
          component: patroni
          team: dba
        annotations:
          summary: "Le cluster Patroni n'a PAS de leader"
          description: "Aucun nœud Patroni ne se déclare leader. Aucune écriture possible !"
          runbook: "https://wiki.transactis.com/runbooks/patroni-no-leader"

      # CRITIQUE : Patroni down
      - alert: PatroniDown
        expr: up{job="patroni"} == 0
        for: 1m
        labels:
          severity: critical
          component: patroni
          team: dba
        annotations:
          summary: "Patroni injoignable sur {{ $labels.instance }}"

      # WARNING : failover détecté (changement de timeline)
      - alert: PatroniFailoverDetected
        expr: changes(patroni_primary[5m]) > 0
        for: 0s
        labels:
          severity: warning
          component: patroni
          team: dba
        annotations:
          summary: "Changement de leader Patroni détecté"
          description: "Un switchover ou failover vient de se produire. Vérifier patronictl list."

  - name: postgresql_recording_rules
    rules:
      - record: pg:connections_usage_ratio
        expr: sum by (instance) (pg_stat_activity_count) / pg_settings_max_connections

      - record: pg:replication_lag_seconds
        expr: pg_stat_replication_replay_lag

      - record: pg:transactions_per_second
        expr: rate(pg_stat_database_xact_commit[5m]) + rate(pg_stat_database_xact_rollback[5m])

      - record: pg:cache_hit_ratio
        expr: pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read + 1)
```

```bash
promtool check rules /etc/prometheus/rules/postgresql-patroni-alerts.yml
curl -X POST http://localhost:9090/-/reload
```

### Livrable
- [ ] Règles d'alerte PG/Patroni déployées
- [ ] Recording rules fonctionnelles
- [ ] Alertes visibles dans Prometheus UI

---

## BLOC 5 — Supervision pgBackRest (14:30-15:30)

### Actions

#### 5.1 Audit des sauvegardes existantes
```bash
# Sur le serveur de backup (ou sur le primary)
sudo -u postgres pgbackrest info

# Noter :
# - Stanza name : ___________
# - Dernière sauvegarde full : date ___________
# - Dernière sauvegarde diff : date ___________
# - WAL archive min/max : ___________

# Vérifier la configuration
sudo -u postgres pgbackrest check
cat /etc/pgbackrest/pgbackrest.conf
```

#### 5.2 Métriques pgBackRest
Si un exporter pgBackRest existe (ex: `pgbackrest_exporter`), vérifier les métriques.

Sinon, créer un script de monitoring :
```bash
#!/bin/bash
# /usr/local/bin/pgbackrest-metrics.sh
# Exécuté par un cron, écrit les métriques dans un fichier texte
# que node_exporter peut exposer via le textfile collector

OUTPUT="/var/lib/node_exporter/textfile_collector/pgbackrest.prom"

# Âge de la dernière sauvegarde full (en secondes)
LAST_FULL=$(sudo -u postgres pgbackrest info --output=json | \
  python3 -c "import sys,json; data=json.load(sys.stdin); \
  print(data[0]['backup'][-1]['timestamp']['stop'])" 2>/dev/null || echo "0")

if [ "$LAST_FULL" != "0" ]; then
  AGE=$(($(date +%s) - LAST_FULL))
  echo "pgbackrest_last_backup_age_seconds $AGE" > "$OUTPUT"
else
  echo "pgbackrest_last_backup_age_seconds 999999" > "$OUTPUT"
fi

# Statut du check
sudo -u postgres pgbackrest check > /dev/null 2>&1
echo "pgbackrest_check_ok $?" >> "$OUTPUT"
```

```bash
chmod +x /usr/local/bin/pgbackrest-metrics.sh
# Ajouter au cron (toutes les 5 minutes)
echo "*/5 * * * * root /usr/local/bin/pgbackrest-metrics.sh" | sudo tee /etc/cron.d/pgbackrest-metrics
```

#### 5.3 Alertes pgBackRest
Ajouter dans les rules Prometheus :
```yaml
  - name: pgbackrest
    rules:
      - alert: PgBackRestBackupTooOld
        expr: pgbackrest_last_backup_age_seconds > 604800
        for: 1h
        labels:
          severity: critical
          component: pgbackrest
          team: dba
        annotations:
          summary: "Dernière sauvegarde pgBackRest > 7 jours"

      - alert: PgBackRestCheckFailing
        expr: pgbackrest_check_ok != 0
        for: 30m
        labels:
          severity: critical
          component: pgbackrest
          team: dba
        annotations:
          summary: "pgbackrest check échoue"
```

### Livrable
- [ ] Sauvegardes pgBackRest auditées et documentées
- [ ] Métriques pgBackRest exposées vers Prometheus
- [ ] Alertes backup configurées

---

## BLOC 6 — Tests et validation (15:30-17:00)

### Actions

#### 6.1 Mettre à jour Alertmanager
Ajouter les inhibitions pour PostgreSQL :
```yaml
inhibit_rules:
  # ... règles existantes etcd ...

  # Si PG est DOWN, ne pas alerter sur le lag
  - source_match:
      alertname: PostgreSQLDown
    target_match:
      alertname: PostgreSQLReplicationLagWarning
    equal: ['instance']

  - source_match:
      alertname: PostgreSQLDown
    target_match:
      alertname: PostgreSQLReplicationLagCritical
    equal: ['instance']
```

#### 6.2 Tests
```bash
# Test 1 : Vérifier que toutes les alertes sont inactive
# → http://prometheus:9090/alerts

# Test 2 : Envoyer une alerte de test Patroni
curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {
      "alertname": "TestPatroniDown",
      "severity": "critical",
      "component": "patroni",
      "instance": "test"
    },
    "annotations": {
      "summary": "Test alerte Patroni — à ignorer"
    }
  }]'

# Vérifier réception dans LogNcall
# Puis résoudre l'alerte de test
```

#### 6.3 Documenter

```
VALIDATION JOUR 2 — PostgreSQL / Patroni / pgBackRest
Date : 31/03/2026

1. Cluster Patroni
   - [ ] Leader : ___________
   - [ ] Replicas : ___________ lag : ___________
   - [ ] Timeline : ___________

2. postgres_exporter
   - [ ] Installé et fonctionnel sur les 3 nœuds
   - [ ] Métriques custom ajoutées

3. Alertes PostgreSQL
   - [ ] X alertes configurées, toutes en état inactive
   - [ ] Recording rules fonctionnelles

4. pgBackRest
   - [ ] Dernière full backup : ___________
   - [ ] WAL archiving : OK / NOK
   - [ ] Alertes backup configurées

5. LogNcall
   - [ ] Test alerte Patroni reçu dans LogNcall

Problèmes rencontrés :
- ___________

Actions pour demain :
- ___________
```

### Livrable
- [ ] Supervision PG/Patroni complète et testée
- [ ] pgBackRest monitoré
- [ ] Document de validation rempli
