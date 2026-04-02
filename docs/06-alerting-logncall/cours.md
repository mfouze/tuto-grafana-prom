# Alerting & LogNcall — Cours Complet pour Débutants

## 1. Le circuit d'alerte

```
Métriques collectées
        │
        ▼
┌──────────────┐   règles d'alerte   ┌───────────────┐
│  Prometheus  │ ───────────────────► │ Alertmanager  │
│              │   condition = true   │               │
│  Évalue les  │   pendant X temps    │  Route        │
│  rules       │                      │  Group        │
└──────────────┘                      │  Silence      │
                                      │  Inhibit      │
                                      └───────┬───────┘
                                              │
                              ┌───────────────┼───────────────┐
                              │               │               │
                        ┌─────▼─────┐   ┌─────▼─────┐  ┌─────▼─────┐
                        │  Email    │   │  Slack    │  │ LogNcall  │
                        │           │   │           │  │ (webhook) │
                        └───────────┘   └───────────┘  └───────────┘
```

### Les 3 étapes
1. **Prometheus** évalue les règles d'alerte (toutes les `evaluation_interval` secondes)
2. Si une condition est vraie pendant la durée `for` → Prometheus envoie l'alerte à **Alertmanager**
3. **Alertmanager** route l'alerte vers le bon destinataire (email, Slack, LogNcall)

## 2. Règles d'alerte Prometheus

### Structure d'une règle

```yaml
groups:
  - name: nom_du_groupe
    rules:
      - alert: NomDeLAlerte        # Nom unique de l'alerte
        expr: <expression PromQL>   # Condition de déclenchement
        for: 5m                     # Durée pendant laquelle la condition doit être vraie
        labels:
          severity: critical         # Labels ajoutés à l'alerte
          team: dba
        annotations:
          summary: "Description courte"
          description: "Description détaillée avec {{ $labels.instance }}"
          runbook: "https://wiki/runbook/alerte-xyz"
```

### États d'une alerte

| État | Signification |
|------|---------------|
| **inactive** | La condition est fausse → tout va bien |
| **pending** | La condition est vraie, mais la durée `for` n'est pas encore atteinte |
| **firing** | La condition est vraie depuis au moins `for` → alerte envoyée ! |

### Le paramètre `for`
C'est un **amortisseur** qui évite les faux positifs. Si un nœud est down pendant 10 secondes puis revient → pas d'alerte si `for: 5m`.

```
Timeline :
  t=0     condition = true  → état: pending
  t=1m    condition = true  → état: pending (1/5 min)
  t=2m    condition = false → état: inactive (reset !)
  t=3m    condition = true  → état: pending (restart)
  t=8m    condition = true  → état: firing ! (5 minutes continues)
```

## 3. Alertes pour notre stack

### 3.1 Alertes etcd

```yaml
groups:
  - name: etcd_alerts
    rules:
      # CRITIQUE : pas de leader
      - alert: EtcdNoLeader
        expr: etcd_server_has_leader == 0
        for: 1m
        labels:
          severity: critical
          component: etcd
        annotations:
          summary: "etcd {{ $labels.instance }} has no leader"
          description: "Le nœud etcd {{ $labels.instance }} n'a pas de leader depuis plus d'1 minute. Risque de perte de quorum."

      # WARNING : changements de leader fréquents
      - alert: EtcdHighLeaderChanges
        expr: increase(etcd_server_leader_changes_seen_total[1h]) > 3
        for: 5m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd leader changes too frequent"
          description: "Plus de 3 changements de leader etcd en 1 heure. Possible instabilité réseau ou disque."

      # CRITIQUE : propositions Raft échouées
      - alert: EtcdProposalsFailing
        expr: rate(etcd_server_proposals_failed_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
          component: etcd
        annotations:
          summary: "etcd proposals are failing"
          description: "Des propositions Raft échouent sur {{ $labels.instance }}. Le cluster etcd est en difficulté."

      # WARNING : latence disque
      - alert: EtcdDiskLatencyHigh
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.1
        for: 5m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd disk latency high on {{ $labels.instance }}"
          description: "Latence d'écriture WAL p99 > 100ms. Le disque est trop lent pour etcd."

      # WARNING : espace disque etcd
      - alert: EtcdDatabaseSizeHigh
        expr: etcd_mvcc_db_total_size_in_bytes > 6442450944  # 6GB
        for: 5m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd database size > 6GB on {{ $labels.instance }}"
          description: "La base etcd dépasse 6GB. Compaction nécessaire."
```

### 3.2 Alertes PostgreSQL / Patroni

```yaml
groups:
  - name: postgresql_alerts
    rules:
      # CRITIQUE : PostgreSQL DOWN
      - alert: PostgreSQLDown
        expr: pg_up == 0
        for: 1m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "PostgreSQL is down on {{ $labels.instance }}"

      # WARNING : lag de réplication > 30s
      - alert: PostgreSQLReplicationLag
        expr: pg_stat_replication_replay_lag > 30
        for: 2m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "Replication lag > 30s on {{ $labels.instance }}"
          description: "Lag actuel : {{ $value }}s"

      # CRITIQUE : lag de réplication > 300s
      - alert: PostgreSQLReplicationLagCritical
        expr: pg_stat_replication_replay_lag > 300
        for: 2m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "CRITICAL replication lag > 5min on {{ $labels.instance }}"

      # WARNING : connexions élevées
      - alert: PostgreSQLConnectionsHigh
        expr: pg_stat_activity_count / pg_settings_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "PostgreSQL connections > 80% on {{ $labels.instance }}"

      # CRITIQUE : Patroni n'a pas de leader
      - alert: PatroniNoLeader
        expr: patroni_cluster_has_leader == 0
        for: 30s
        labels:
          severity: critical
          component: patroni
        annotations:
          summary: "Patroni cluster has no leader"
          description: "Le cluster Patroni n'a pas de leader. Aucune écriture possible !"

      # CRITIQUE : Patroni down
      - alert: PatroniDown
        expr: patroni_postgres_running == 0
        for: 1m
        labels:
          severity: critical
          component: patroni
        annotations:
          summary: "Patroni is down on {{ $labels.instance }}"

  - name: pgbackrest_alerts
    rules:
      # CRITIQUE : sauvegarde trop ancienne
      - alert: PgBackRestBackupTooOld
        expr: time() - pgbackrest_backup_last_full_completion_time > 604800  # 7 jours
        for: 1h
        labels:
          severity: critical
          component: pgbackrest
        annotations:
          summary: "Last full backup is older than 7 days"

      # CRITIQUE : archivage WAL en échec
      - alert: PostgreSQLWALArchiveFailing
        expr: pg_stat_archiver_failed_count > 0
        for: 5m
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "WAL archiving is failing on {{ $labels.instance }}"
```

### 3.3 Alertes HAProxy

```yaml
groups:
  - name: haproxy_alerts
    rules:
      # CRITIQUE : HAProxy DOWN
      - alert: HAProxyDown
        expr: haproxy_up == 0
        for: 30s
        labels:
          severity: critical
          component: haproxy
        annotations:
          summary: "HAProxy is down on {{ $labels.instance }}"
          description: "HAProxy ne répond plus. Les applications ne peuvent plus atteindre PostgreSQL !"

      # CRITIQUE : aucun backend write disponible
      - alert: HAProxyNoWriteBackend
        expr: haproxy_backend_active_servers{backend="pg-write"} == 0
        for: 30s
        labels:
          severity: critical
          component: haproxy
        annotations:
          summary: "No write backend available in HAProxy"

      # WARNING : un backend est DOWN
      - alert: HAProxyBackendDown
        expr: haproxy_server_status == 0
        for: 1m
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy backend {{ $labels.server }} is DOWN in {{ $labels.backend }}"

      # WARNING : sessions élevées
      - alert: HAProxyHighSessions
        expr: haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions > 0.8
        for: 5m
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy sessions > 80% capacity"
```

### 3.4 Alertes PgBouncer

```yaml
groups:
  - name: pgbouncer_alerts
    rules:
      # CRITIQUE : PgBouncer DOWN
      - alert: PgBouncerDown
        expr: pgbouncer_up == 0
        for: 30s
        labels:
          severity: critical
          component: pgbouncer
        annotations:
          summary: "PgBouncer is down on {{ $labels.instance }}"

      # WARNING : clients en attente
      - alert: PgBouncerClientsWaiting
        expr: pgbouncer_pools_client_waiting_connections > 0
        for: 1m
        labels:
          severity: warning
          component: pgbouncer
        annotations:
          summary: "PgBouncer has waiting clients on {{ $labels.instance }}"
          description: "{{ $value }} clients attendent une connexion depuis plus d'1 minute."

      # CRITIQUE : pool épuisé
      - alert: PgBouncerPoolExhausted
        expr: pgbouncer_pools_server_idle_connections == 0 and pgbouncer_pools_client_waiting_connections > 5
        for: 1m
        labels:
          severity: critical
          component: pgbouncer
        annotations:
          summary: "PgBouncer pool exhausted on {{ $labels.instance }}"
```

## 4. Alertmanager

### 4.1 C'est quoi Alertmanager ?
Alertmanager reçoit les alertes de Prometheus et les **route, groupe, déduplique et envoie** vers les bons destinataires.

### 4.2 Concepts clés

| Concept | Description |
|---------|-------------|
| **Route** | Arbre de décision : selon les labels, envoyer vers tel receiver |
| **Receiver** | Destination : email, Slack, webhook (LogNcall), etc. |
| **Grouping** | Regrouper les alertes similaires en une seule notification |
| **Inhibition** | Supprimer une alerte si une autre plus grave est active |
| **Silence** | Mettre en sourdine une alerte pendant une période |

### 4.3 Configuration Alertmanager

```yaml
# /etc/alertmanager/alertmanager.yml

global:
  resolve_timeout: 5m

# Route principale
route:
  group_by: ['alertname', 'component']  # Grouper par nom d'alerte et composant
  group_wait: 30s       # Attendre 30s pour grouper les alertes
  group_interval: 5m    # Intervalle entre les notifications du même groupe
  repeat_interval: 4h   # Re-notifier toutes les 4h si l'alerte persiste
  receiver: 'default'   # Receiver par défaut

  routes:
    # Alertes CRITIQUES → LogNcall (appel/SMS immédiat)
    - match:
        severity: critical
      receiver: 'logncall-critical'
      group_wait: 10s       # Notification rapide pour les critiques
      repeat_interval: 1h

    # Alertes WARNING → Email/Slack
    - match:
        severity: warning
      receiver: 'email-warning'
      repeat_interval: 4h

# Receivers
receivers:
  - name: 'default'
    webhook_configs:
      - url: 'http://logncall-webhook:8080/alert'

  - name: 'logncall-critical'
    webhook_configs:
      - url: 'http://logncall-api:8080/api/v1/alert'
        send_resolved: true
        http_config:
          basic_auth:
            username: 'alertmanager'
            password: 'secret'

  - name: 'email-warning'
    email_configs:
      - to: 'dba-team@transactis.com'
        from: 'alertmanager@transactis.com'
        smarthost: 'smtp.transactis.com:587'
        auth_username: 'alertmanager@transactis.com'
        auth_password: 'smtp_password'
        send_resolved: true

# Inhibitions
inhibit_rules:
  # Si PostgreSQL est DOWN, ne pas alerter sur le lag de réplication
  - source_match:
      alertname: PostgreSQLDown
    target_match:
      alertname: PostgreSQLReplicationLag
    equal: ['instance']

  # Si HAProxy est DOWN, ne pas alerter sur les backends DOWN
  - source_match:
      alertname: HAProxyDown
    target_match:
      alertname: HAProxyBackendDown
```

### 4.4 Explication des paramètres

| Paramètre | Valeur | Signification |
|-----------|--------|---------------|
| `group_by` | `['alertname']` | Toutes les alertes avec le même nom sont groupées |
| `group_wait` | `30s` | Attend 30s pour grouper les alertes avant d'envoyer |
| `group_interval` | `5m` | Si de nouvelles alertes arrivent dans le même groupe, attendre 5m |
| `repeat_interval` | `4h` | Si l'alerte persiste, re-notifier toutes les 4h |
| `send_resolved` | `true` | Envoyer une notification quand l'alerte est résolue |

## 5. LogNcall

### 5.1 C'est quoi LogNcall ?
LogNcall est un système de **notification d'astreinte**. Il :
- Reçoit les alertes d'Alertmanager via webhook
- Appelle/SMS/email l'équipe d'astreinte selon un planning
- Gère l'escalade (si personne ne répond en X minutes → appeler le suivant)
- Trace les acquittements

### 5.2 Intégration avec Alertmanager

LogNcall expose un endpoint webhook HTTP que l'on configure comme receiver dans Alertmanager :

```yaml
# Dans alertmanager.yml
receivers:
  - name: 'logncall'
    webhook_configs:
      - url: 'https://logncall.transactis.com/api/webhook/prometheus'
        send_resolved: true
```

### 5.3 Format des alertes envoyées

Quand Alertmanager envoie une alerte à LogNcall, le payload JSON ressemble à :

```json
{
  "version": "4",
  "groupKey": "{}:{alertname=\"PostgreSQLDown\"}",
  "status": "firing",
  "receiver": "logncall",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "PostgreSQLDown",
        "severity": "critical",
        "instance": "pg-node1:9187",
        "component": "postgresql"
      },
      "annotations": {
        "summary": "PostgreSQL is down on pg-node1:9187",
        "description": "Le nœud PostgreSQL pg-node1 ne répond plus."
      },
      "startsAt": "2026-03-30T14:30:00.000Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://prometheus:9090/graph?g0.expr=pg_up+%3D%3D+0"
    }
  ]
}
```

### 5.4 Circuit complet d'un incident

```
1. PostgreSQL primary tombe
   ↓
2. Prometheus scrape : pg_up == 0
   ↓
3. Règle d'alerte : PostgreSQLDown, for: 1m
   ↓ (1 minute de condition vraie)
4. Alerte passe en état "firing"
   ↓
5. Prometheus envoie l'alerte à Alertmanager
   ↓
6. Alertmanager route : severity=critical → receiver logncall-critical
   ↓
7. Alertmanager envoie le webhook à LogNcall
   ↓
8. LogNcall appelle l'ingénieur d'astreinte
   ↓
9. L'ingénieur acquitte et intervient
   ↓
10. PostgreSQL revient → pg_up == 1
    ↓
11. Alerte passe en état "resolved"
    ↓
12. Alertmanager envoie la résolution à LogNcall
    ↓
13. LogNcall notifie que l'incident est résolu
```

## 6. Bonnes pratiques d'alerting

### Ce qu'il faut alerter
- **CRITIQUE** : ce qui nécessite une action immédiate (service DOWN, perte de quorum, plus de leader)
- **WARNING** : ce qui nécessite une attention mais pas immédiate (lag élevé, ressources élevées)

### Ce qu'il ne faut PAS alerter
- Les métriques informatives (taille de base, nombre de transactions)
- Les conditions transitoires normales (redémarrage planifié)
- Les doublons (si PG est DOWN, pas besoin d'alerter aussi sur le lag)

### La règle des 3
1. Chaque alerte doit être **actionnable** (que dois-je faire ?)
2. Chaque alerte doit avoir un **runbook** (procédure de résolution)
3. Chaque alerte doit être **testée** (simuler la panne, vérifier la notification)

### Anti-patterns
- **Alert fatigue** : trop d'alertes → on les ignore toutes
- **Seuils trop bas** : alertes qui se déclenchent tout le temps
- **Pas de `for`** : alertes qui flashent (true 1s, false, true 1s, false...)
- **Pas d'inhibition** : 10 alertes pour le même incident
