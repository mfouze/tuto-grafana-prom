# Jour 4 — Jeudi 2 Avril : Supervision PgBouncer + Déduplication Prometheus/Grafana

## Chronogramme

```
09:00 ┬─────────────────────────────────────────────────────────────┐
      │  BLOC 1 : Audit cluster PgBouncer (1h)                     │
      │  • État actuel, configuration, pools                       │
      │  • Architecture HA PgBouncer                               │
10:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 2 : Métriques PgBouncer + Prometheus (1h)            │
      │  • Installer/configurer pgbouncer_exporter                 │
      │  • Ajouter les targets dans Prometheus                     │
11:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 3 : Alertes PgBouncer + Dashboard Grafana (1h)       │
      │  • Règles d'alerte PgBouncer                               │
      │  • Dashboard Grafana PgBouncer                             │
12:00 ┼═══════════════════ PAUSE DÉJEUNER ══════════════════════════┤
14:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 4 : Audit déduplication Prometheus (1h)               │
      │  • Combien d'instances Prometheus ?                        │
      │  • Identifier les doublons de métriques                    │
      │  • Architecture Thanos si en place                         │
15:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 5 : Configuration déduplication (1h30)                │
      │  • External labels + Thanos ou remote_write                │
      │  • Configurer le query layer dédupliqué                    │
16:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 6 : Validation déduplication + tests globaux (1h30)   │
      │  • Vérifier dans Grafana : pas de doublons                 │
      │  • Tests de bout en bout PgBouncer                         │
      │  • Documentation                                           │
18:00 ┴─────────────────────────────────────────────────────────────┘
```

---

## BLOC 1 — Audit cluster PgBouncer (09:00-10:00)

### Actions

#### 1.1 Identifier l'architecture PgBouncer
```bash
# Se connecter au(x) serveur(s) PgBouncer
ssh user@pgbouncer-node1

# Version et état
pgbouncer --version
systemctl status pgbouncer

# Configuration
cat /etc/pgbouncer/pgbouncer.ini
```

**Noter :**
- [ ] Nombre d'instances PgBouncer : ___________
- [ ] Architecture HA (Keepalived ? HAProxy devant ? Sidecar ?) : ___________
- [ ] Port d'écoute : ___________
- [ ] Pool mode (session/transaction/statement) : ___________
- [ ] default_pool_size : ___________
- [ ] max_client_conn : ___________

#### 1.2 Explorer la console admin PgBouncer
```bash
# Se connecter à la console admin
psql -h localhost -p 6432 -U postgres pgbouncer

# Dans la console :
SHOW POOLS;
SHOW STATS;
SHOW CLIENTS;
SHOW SERVERS;
SHOW DATABASES;
SHOW CONFIG;
```

**Noter :**
- [ ] Nombre de pools actifs : ___________
- [ ] cl_active / cl_waiting actuels : ___________
- [ ] sv_active / sv_idle actuels : ___________
- [ ] avg_query_time : ___________
- [ ] avg_wait_time : ___________

### Livrable
- [ ] Architecture PgBouncer documentée
- [ ] État des pools noté

---

## BLOC 2 — Métriques PgBouncer + Prometheus (10:00-11:00)

### Actions

#### 2.1 Installer pgbouncer_exporter
```bash
# Vérifier s'il existe déjà
which pgbouncer_exporter
systemctl status pgbouncer_exporter

# Si non installé :
# Télécharger depuis https://github.com/prometheus-community/pgbouncer_exporter/releases

# Configurer la connexion
# pgbouncer_exporter se connecte à la base admin "pgbouncer"
pgbouncer_exporter \
  --pgBouncer.connectionString="postgres://postgres:password@localhost:6432/pgbouncer?sslmode=disable" \
  --web.listen-address=":9127"

# Vérifier les métriques
curl -s http://localhost:9127/metrics | head -30
curl -s http://localhost:9127/metrics | grep pgbouncer_up
```

#### 2.2 Ajouter dans Prometheus
```yaml
  - job_name: 'pgbouncer'
    scrape_interval: 15s
    static_configs:
      - targets:
        - 'pgbouncer-node1:9127'
        # Si plusieurs instances :
        # - 'pgbouncer-node2:9127'
```

```bash
promtool check config /etc/prometheus/prometheus.yml
curl -X POST http://localhost:9090/-/reload
# Vérifier : Targets → pgbouncer UP
```

#### 2.3 Vérifier les métriques clés dans Prometheus
```promql
# Dans l'UI Prometheus, tester :
pgbouncer_up
pgbouncer_pools_server_active_connections
pgbouncer_pools_server_idle_connections
pgbouncer_pools_client_waiting_connections
pgbouncer_stats_queries_duration_seconds_total
```

### Livrable
- [ ] pgbouncer_exporter installé et fonctionnel
- [ ] Target PgBouncer UP dans Prometheus

---

## BLOC 3 — Alertes PgBouncer + Dashboard Grafana (11:00-12:00)

### Actions

#### 3.1 Créer les alertes PgBouncer

Créer `/etc/prometheus/rules/pgbouncer-alerts.yml` :

```yaml
groups:
  - name: pgbouncer_health
    rules:
      # CRITIQUE : PgBouncer injoignable
      - alert: PgBouncerDown
        expr: pgbouncer_up == 0
        for: 30s
        labels:
          severity: critical
          component: pgbouncer
          team: dba
        annotations:
          summary: "PgBouncer DOWN sur {{ $labels.instance }}"
          description: >
            PgBouncer ne répond plus. Les applications ne peuvent plus
            se connecter à PostgreSQL via le pool de connexions.
          runbook: "https://wiki.transactis.com/runbooks/pgbouncer-down"

      # CRITIQUE : pool épuisé avec clients en attente
      - alert: PgBouncerPoolExhausted
        expr: >
          pgbouncer_pools_server_idle_connections == 0
          and pgbouncer_pools_client_waiting_connections > 5
        for: 1m
        labels:
          severity: critical
          component: pgbouncer
          team: dba
        annotations:
          summary: "Pool PgBouncer épuisé sur {{ $labels.instance }}"
          description: >
            Plus aucune connexion idle dans le pool et {{ $value }}
            clients en attente. Les applications sont bloquées.

      # WARNING : clients en attente
      - alert: PgBouncerClientsWaiting
        expr: pgbouncer_pools_client_waiting_connections > 0
        for: 2m
        labels:
          severity: warning
          component: pgbouncer
          team: dba
        annotations:
          summary: "{{ $value }} clients en attente dans PgBouncer"
          description: >
            Des clients attendent une connexion depuis plus de 2 minutes.
            Le pool est peut-être trop petit ou il y a des transactions longues.

      # WARNING : pool serveur > 80% utilisé
      - alert: PgBouncerPoolUsageHigh
        expr: >
          pgbouncer_pools_server_active_connections
          / (pgbouncer_pools_server_active_connections + pgbouncer_pools_server_idle_connections + 1)
          > 0.8
        for: 5m
        labels:
          severity: warning
          component: pgbouncer
          team: dba
        annotations:
          summary: "Pool PgBouncer > 80% utilisé sur {{ $labels.instance }}"

  - name: pgbouncer_recording
    rules:
      - record: pgbouncer:pool_usage_ratio
        expr: >
          pgbouncer_pools_server_active_connections
          / (pgbouncer_pools_server_active_connections + pgbouncer_pools_server_idle_connections + 1)

      - record: pgbouncer:avg_query_duration_seconds
        expr: rate(pgbouncer_stats_queries_duration_seconds_total[5m]) / (rate(pgbouncer_stats_queries_total[5m]) + 1)
```

```bash
promtool check rules /etc/prometheus/rules/pgbouncer-alerts.yml
curl -X POST http://localhost:9090/-/reload
```

#### 3.2 Dashboard Grafana PgBouncer

**Row 1 : Santé**

| Panel | Type | Query |
|-------|------|-------|
| PgBouncer UP | Stat | `pgbouncer_up` |
| Clients en attente | Stat | `sum(pgbouncer_pools_client_waiting_connections)` (rouge si > 0) |
| Pool usage | Gauge | `pgbouncer:pool_usage_ratio` |

**Row 2 : Pools**

| Panel | Type | Query |
|-------|------|-------|
| Connexions serveur actives | Time series | `pgbouncer_pools_server_active_connections` |
| Connexions serveur idle | Time series | `pgbouncer_pools_server_idle_connections` |
| Clients en attente | Time series | `pgbouncer_pools_client_waiting_connections` |
| Clients actifs | Time series | `pgbouncer_pools_client_active_connections` |

**Row 3 : Performance**

| Panel | Type | Query |
|-------|------|-------|
| Requêtes/s | Time series | `rate(pgbouncer_stats_queries_total[5m])` |
| Durée moyenne requête | Time series | `pgbouncer:avg_query_duration_seconds` |
| Transactions/s | Time series | `rate(pgbouncer_stats_transactions_total[5m])` |

### Livrable
- [ ] Alertes PgBouncer déployées
- [ ] Dashboard Grafana PgBouncer créé

---

## BLOC 4 — Audit déduplication Prometheus (13:00-14:00)

### Actions

#### 4.1 Identifier l'architecture Prometheus HA
```bash
# Combien d'instances Prometheus existe-t-il ?
# → Vérifier avec l'équipe Transactis

# Si 2 instances Prometheus :
# Vérifier les external_labels de chaque instance
ssh user@prometheus-1
grep -A 5 "external_labels" /etc/prometheus/prometheus.yml

ssh user@prometheus-2
grep -A 5 "external_labels" /etc/prometheus/prometheus.yml

# Résultat attendu :
# prometheus-1 : external_labels: { cluster: prod, replica: prom-1 }
# prometheus-2 : external_labels: { cluster: prod, replica: prom-2 }
```

**Noter :**
- [ ] Nombre d'instances Prometheus : ___________
- [ ] External labels configurés : ___________
- [ ] Thanos est-il en place ? ___________
- [ ] Si oui : Thanos Sidecar ? Store ? Query ? Compactor ? ___________

#### 4.2 Vérifier la présence de doublons
```bash
# Dans Grafana, vérifier si les métriques sont doublées
# Exécuter une requête simple :
# etcd_server_has_leader
# → Si 6 résultats au lieu de 3 → doublons !

# Vérifier les labels des résultats :
# Si les résultats diffèrent uniquement par le label "replica" → c'est un doublon
```

#### 4.3 Identifier la solution en place ou à mettre en place
```
Situation 1 : 1 seul Prometheus → pas de problème de déduplication
Situation 2 : 2 Prometheus + Thanos → vérifier la config Thanos
Situation 3 : 2 Prometheus sans Thanos → configurer la déduplication
```

### Livrable
- [ ] Architecture Prometheus HA documentée
- [ ] Problème de doublons identifié ou non

---

## BLOC 5 — Configuration déduplication (14:00-15:30)

### Actions selon la situation

#### Situation A : Thanos est déjà en place

##### Vérifier la configuration Thanos Query
```bash
# Sur le serveur Thanos Query
systemctl status thanos-query

# Vérifier les flags
systemctl cat thanos-query | grep ExecStart
# Doit contenir : --query.replica-label=replica

# Vérifier les stores connectés
curl -s http://thanos-query:9090/api/v1/stores | python3 -m json.tool
```

##### Vérifier dans Grafana
```
1. Aller dans Grafana → Data Sources
2. Vérifier que le data source pointe vers Thanos Query (pas Prometheus directement)
   URL attendue : http://thanos-query:9090
3. Tester une requête : les résultats ne doivent PAS être doublés
```

##### Corriger si nécessaire
```bash
# Si les doublons persistent :
# 1. Vérifier les external_labels dans chaque prometheus.yml
#    → Le label "replica" doit être DIFFÉRENT sur chaque instance

# 2. Vérifier que Thanos Query a le flag --query.replica-label
#    → Il doit correspondre au nom du label (ex: "replica")

# 3. Vérifier dans l'UI Thanos Query (http://thanos:9090)
#    → Cocher "deduplication" dans les options de requête
```

#### Situation B : Pas de Thanos, 2 Prometheus

##### Option 1 : Installer Thanos (recommandé)
```bash
# 1. Installer Thanos Sidecar sur chaque Prometheus
thanos sidecar \
  --tsdb.path=/var/lib/prometheus \
  --prometheus.url=http://localhost:9090 \
  --grpc-address=0.0.0.0:10901

# 2. Installer Thanos Query
thanos query \
  --http-address=0.0.0.0:9090 \
  --store=prometheus-1:10901 \
  --store=prometheus-2:10901 \
  --query.replica-label=replica

# 3. Configurer Grafana pour pointer vers Thanos Query
```

##### Option 2 : Si Thanos n'est pas possible
```
Utiliser des recording rules identiques sur les 2 Prometheus
+ Configurer Grafana avec UN SEUL data source (le Prometheus primaire)
+ L'autre Prometheus sert de secours en cas de panne du premier
```

#### Situation C : 1 seul Prometheus

```
Pas de déduplication nécessaire.
Mais attention : pas de HA Prometheus = SPOF sur le monitoring.
→ Documenter le risque et recommander l'ajout d'un second Prometheus.
```

### Livrable
- [ ] Déduplication configurée ou non nécessaire
- [ ] Grafana pointe vers le bon data source (Thanos Query ou Prometheus)
- [ ] Pas de doublons dans les dashboards

---

## BLOC 6 — Validation + tests globaux (15:30-17:00)

### Actions

#### 6.1 Vérifier la déduplication dans Grafana
```
Pour chaque dashboard créé les jours précédents :
1. Ouvrir le dashboard
2. Vérifier que les métriques ne sont pas doublées
3. Vérifier que les graphiques montrent les bonnes valeurs
4. Si doublons → corriger le data source ou les requêtes
```

#### 6.2 Test de bout en bout PgBouncer
```bash
# Test 1 : Envoyer une alerte de test PgBouncer
curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[{
    "labels": {
      "alertname": "TestPgBouncerDown",
      "severity": "critical",
      "component": "pgbouncer",
      "instance": "test"
    },
    "annotations": {
      "summary": "Test alerte PgBouncer — à ignorer"
    }
  }]'

# Vérifier dans LogNcall → notification reçue
# Puis résoudre l'alerte
```

#### 6.3 Documenter

```
VALIDATION JOUR 4 — PgBouncer + Déduplication
Date : 02/04/2026

1. PgBouncer
   - [ ] pgbouncer_exporter installé et fonctionnel
   - [ ] Alertes PgBouncer configurées (X alertes)
   - [ ] Dashboard Grafana PgBouncer créé
   - [ ] Test alerte → LogNcall : OK

2. Déduplication
   - [ ] Architecture Prometheus : ___________
   - [ ] Méthode de déduplication : ___________
   - [ ] Doublons éliminés dans Grafana : OUI / NON / N/A
   - [ ] Data source Grafana correct

3. Dashboards créés jusqu'ici
   - [ ] etcd : OK
   - [ ] PostgreSQL / Patroni : OK
   - [ ] HAProxy : OK
   - [ ] PgBouncer : OK

Problèmes rencontrés :
- ___________

Actions pour demain :
- ___________
```

### Livrable
- [ ] PgBouncer supervisé de bout en bout
- [ ] Déduplication validée
- [ ] Jour 4 validé
