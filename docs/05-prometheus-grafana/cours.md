# Prometheus & Grafana — Cours Complet pour Débutants

## 1. Vue d'ensemble du monitoring

```
┌──────────┐  scrape   ┌────────────┐  query    ┌──────────┐
│ Targets  │ ◄─────────│ Prometheus │◄──────────│ Grafana  │
│ (etcd,   │           │   (TSDB)   │           │(dashboards)
│  PG,     │  metrics  │            │           │          │
│  HAProxy,│ ─────────►│  Stockage  │           │          │
│  etc.)   │           │  local +   │           │          │
└──────────┘           │  S3        │           └──────────┘
                       │            │
                       │  rules     │  alertes
                       │ ──────────►├──────────►┌──────────────┐
                       │            │           │ Alertmanager │
                       └────────────┘           │   → LogNcall │
                                                └──────────────┘
```

## 2. Prometheus

### 2.1 C'est quoi Prometheus ?
Prometheus est un système de monitoring et d'alerting open source. Il :
- **Scrape** (collecte) les métriques depuis les cibles à intervalles réguliers
- **Stocke** les métriques dans une base de données temporelle (TSDB)
- **Permet de requêter** les métriques avec PromQL
- **Déclenche des alertes** selon des règles définies

### 2.2 Comment ça marche : le modèle Pull

Contrairement à d'autres systèmes (push), Prometheus utilise le modèle **pull** :
- Chaque cible expose ses métriques sur un endpoint HTTP (ex: `/metrics`)
- Prometheus vient les chercher régulièrement (scrape)

```
Prometheus ──GET /metrics──► etcd:2379/metrics     → réponse avec les métriques
Prometheus ──GET /metrics──► pg_exporter:9187/metrics → réponse avec les métriques
Prometheus ──GET /metrics──► haproxy:8405/metrics   → réponse avec les métriques
```

### 2.3 Types de métriques

| Type | Description | Exemple |
|------|-------------|---------|
| **Counter** | Valeur qui ne fait qu'augmenter | `http_requests_total` |
| **Gauge** | Valeur qui monte et descend | `temperature`, `connections_active` |
| **Histogram** | Distribution des valeurs (buckets) | `request_duration_seconds` |
| **Summary** | Comme histogram mais avec quantiles pré-calculés | `request_duration_quantile` |

### 2.4 Configuration Prometheus

```yaml
# /etc/prometheus/prometheus.yml

global:
  scrape_interval: 15s        # Collecte toutes les 15 secondes
  evaluation_interval: 15s    # Évalue les règles toutes les 15 secondes
  external_labels:             # Labels ajoutés à toutes les métriques
    cluster: transactis-prod
    replica: prometheus-1      # Important pour la déduplication !

# Règles d'alerte
rule_files:
  - /etc/prometheus/rules/*.yml

# Configuration Alertmanager
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - alertmanager:9093

# Cibles à scraper
scrape_configs:
  # Prometheus lui-même
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  # Cluster etcd
  - job_name: 'etcd'
    static_configs:
      - targets:
        - 'etcd-1:2379'
        - 'etcd-2:2379'
        - 'etcd-3:2379'

  # PostgreSQL (via postgres_exporter)
  - job_name: 'postgresql'
    static_configs:
      - targets:
        - 'pg-exporter-1:9187'
        - 'pg-exporter-2:9187'
        - 'pg-exporter-3:9187'

  # Patroni (API REST)
  - job_name: 'patroni'
    static_configs:
      - targets:
        - 'patroni-1:8008'
        - 'patroni-2:8008'
        - 'patroni-3:8008'
    metrics_path: /metrics

  # HAProxy
  - job_name: 'haproxy'
    static_configs:
      - targets:
        - 'haproxy-1:8405'
        - 'haproxy-2:8405'

  # PgBouncer (via pgbouncer_exporter)
  - job_name: 'pgbouncer'
    static_configs:
      - targets:
        - 'pgbouncer-exporter-1:9127'
        - 'pgbouncer-exporter-2:9127'

  # Node exporter (métriques système : CPU, RAM, disque)
  - job_name: 'node'
    static_configs:
      - targets:
        - 'node-exporter-1:9100'
        - 'node-exporter-2:9100'
        - 'node-exporter-3:9100'
```

### 2.5 PromQL — Le langage de requête

PromQL est le langage pour interroger les métriques Prometheus.

#### Requêtes de base
```promql
# Valeur instantanée d'une métrique
up

# Filtrer par label
up{job="etcd"}

# Valeur d'une métrique spécifique
etcd_server_has_leader{instance="etcd-1:2379"}
```

#### Fonctions essentielles

```promql
# rate() : taux de variation par seconde (pour les counters)
rate(http_requests_total[5m])
# "Combien de requêtes par seconde en moyenne sur les 5 dernières minutes"

# increase() : augmentation totale sur une période
increase(http_requests_total[1h])
# "Combien de requêtes en tout sur la dernière heure"

# avg_over_time() : moyenne sur une période (pour les gauges)
avg_over_time(pg_stat_activity_count[5m])
# "Moyenne du nombre de connexions sur les 5 dernières minutes"

# max_over_time() : max sur une période
max_over_time(node_memory_MemUsed_bytes[1h])

# histogram_quantile() : calculer un percentile à partir d'un histogram
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))
# "Le 99ème percentile de la durée des requêtes sur 5 minutes"
```

#### Opérateurs
```promql
# Arithmétique
node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes
# "Mémoire utilisée en bytes"

# Pourcentage
(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
# "Pourcentage de mémoire utilisée"

# Comparaison (pour les alertes)
pg_stat_replication_replay_lag > 30
# "Les replicas dont le lag dépasse 30 secondes"

# Agrégation
sum(pg_stat_activity_count) by (datname)
# "Nombre total de connexions par base de données"

avg(rate(node_cpu_seconds_total{mode!="idle"}[5m])) by (instance) * 100
# "Pourcentage CPU utilisé par instance"
```

#### Exemples concrets pour notre stack

```promql
# etcd : cluster en bonne santé ?
min(etcd_server_has_leader) == 0
# → Alerte si un nœud n'a pas de leader

# PostgreSQL : lag de réplication en secondes
pg_stat_replication_replay_lag

# PostgreSQL : ratio de cache hit (devrait être > 0.99)
pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read)

# HAProxy : backends down
haproxy_server_status == 0

# PgBouncer : clients en attente
pgbouncer_pools_client_waiting_connections > 0
```

## 3. Grafana

### 3.1 C'est quoi Grafana ?
Grafana est un outil de **visualisation** et de **dashboarding**. Il se connecte à Prometheus (et d'autres sources) pour afficher des graphiques, des tableaux et des alertes visuelles.

### 3.2 Concepts Grafana

| Concept | Description |
|---------|-------------|
| **Data Source** | Connexion vers Prometheus (ou autre) |
| **Dashboard** | Page contenant plusieurs panneaux |
| **Panel** | Un graphique ou tableau individuel |
| **Variable** | Paramètre dynamique (ex: choisir une instance dans un dropdown) |
| **Alert** | Alerte visuelle sur un panneau |
| **Row** | Groupe de panneaux |

### 3.3 Créer un dashboard

#### Panel Time Series (graphique temporel)
Le plus courant. Exemple de configuration :
- **Query** : `rate(pg_stat_database_xact_commit{datname="mydb"}[5m])`
- **Legend** : `{{instance}}`
- **Title** : "Transactions par seconde"

#### Panel Stat (valeur unique)
Pour afficher une valeur en gros (ex: nombre de connexions).
- **Query** : `sum(pg_stat_activity_count)`
- **Title** : "Connexions totales"

#### Panel Table
Pour afficher un tableau de données.
- **Query** : `pg_stat_replication_replay_lag`
- **Transform** : Labels to columns

#### Variables de dashboard
Permettent de rendre le dashboard dynamique :
```
# Variable "instance" : liste automatique des instances PostgreSQL
label_values(pg_up, instance)

# Variable "database" : liste des bases
label_values(pg_database_size_bytes, datname)
```

### 3.4 Bonnes pratiques de dashboards

1. **Un dashboard par composant** : etcd, PostgreSQL, HAProxy, PgBouncer
2. **Overview en haut** : indicateurs de santé globaux (UP/DOWN, nombre d'alertes)
3. **Détails en dessous** : graphiques temporels, tables
4. **Utiliser des variables** : pour pouvoir filtrer par instance, base, etc.
5. **Ne pas surcharger** : 15-20 panels max par dashboard
6. **Requêtes efficaces** : utiliser des recording rules pour les requêtes complexes

## 4. Déduplication des métriques

### 4.1 Le problème
En production, on a souvent **2 instances Prometheus** pour la haute disponibilité. Chacune scrape les mêmes cibles → chaque métrique existe en double.

```
Prometheus-1 scrape etcd-1 → etcd_server_has_leader = 1
Prometheus-2 scrape etcd-1 → etcd_server_has_leader = 1
                                                        ↑
                                            Même métrique, dupliquée !
```

Dans Grafana, si on requête les deux Prometheus → on voit des valeurs doublées.

### 4.2 La solution : Thanos ou remote_write

#### Option 1 : Thanos (le plus courant)

```
┌──────────────┐     ┌──────────────┐
│ Prometheus-1 │     │ Prometheus-2 │
│ + Thanos     │     │ + Thanos     │
│   Sidecar    │     │   Sidecar    │
└──────┬───────┘     └──────┬───────┘
       │                    │
       └────────┬───────────┘
                │
         ┌──────▼──────┐
         │ Thanos Query │  ← Déduplique les métriques
         └──────┬──────┘
                │
         ┌──────▼──────┐
         │   Grafana    │
         └─────────────┘
```

**Thanos Query** fait la déduplication automatique en comparant les `external_labels` :
- `{cluster="prod", replica="prometheus-1"}`
- `{cluster="prod", replica="prometheus-2"}`
→ Même métrique, juste le label `replica` diffère → dédupliquée

#### Configuration clé pour la déduplication
```yaml
# prometheus.yml - CHAQUE instance a un label replica unique
global:
  external_labels:
    cluster: transactis-prod
    replica: prometheus-1   # ← Différent sur chaque instance
```

```bash
# Thanos Query : activer la déduplication
thanos query \
  --http-address=0.0.0.0:9090 \
  --store=thanos-sidecar-1:10901 \
  --store=thanos-sidecar-2:10901 \
  --query.replica-label=replica    # ← Dédupliquer sur ce label
```

#### Option 2 : remote_write avec déduplication
```yaml
# prometheus.yml
remote_write:
  - url: http://thanos-receive:19291/api/v1/receive
```

### 4.3 Vérifier dans Grafana
- Les requêtes ne doivent PAS avoir de valeurs doublées
- Dans Thanos Query UI : cocher "deduplication" dans les options
- Dans Grafana : utiliser le datasource Thanos Query (pas Prometheus directement)

## 5. Configuration Prometheus avec S3

### 5.1 Pourquoi S3 ?
Les métriques prennent beaucoup d'espace. Garder 1 an de métriques en local → coûteux en SSD. Archiver vers S3 → stockage bon marché et quasi illimité.

### 5.2 Architecture avec Thanos + S3

```
┌──────────────┐     upload      ┌──────────┐
│ Prometheus   │ ──────────────► │    S3    │
│ + Thanos     │   (blocks TSDB) │  Bucket  │
│   Sidecar    │                 └────┬─────┘
└──────────────┘                      │
                                      │ read
                               ┌──────▼──────┐
                               │ Thanos Store │
                               │   Gateway    │
                               └──────┬──────┘
                                      │
                               ┌──────▼──────┐
                               │ Thanos Query │ ← Requête les données locales ET S3
                               └─────────────┘
```

### 5.3 Configuration Thanos Sidecar

```yaml
# bucket.yml - Configuration du stockage S3
type: S3
config:
  bucket: "transactis-prometheus-metrics"
  endpoint: "s3.eu-west-3.amazonaws.com"
  region: "eu-west-3"
  access_key: "${AWS_ACCESS_KEY_ID}"
  secret_key: "${AWS_SECRET_ACCESS_KEY}"
  insecure: false
```

```bash
# Lancer le sidecar Thanos
thanos sidecar \
  --tsdb.path=/var/lib/prometheus \
  --prometheus.url=http://localhost:9090 \
  --objstore.config-file=/etc/thanos/bucket.yml \
  --shipper.upload-compacted
```

### 5.4 Rétention locale vs S3

```yaml
# prometheus.yml - Garder seulement 7 jours en local
global:
  scrape_interval: 15s

# Flags Prometheus
# --storage.tsdb.retention.time=7d      ← Données locales pendant 7 jours
# --storage.tsdb.retention.size=50GB    ← Ou max 50 GB en local
```

Thanos upload les blocks vers S3 → on peut requêter des mois/années de données depuis S3.

## 6. Sampling (downsampling)

### 6.1 C'est quoi le sampling ?
Le **downsampling** réduit la résolution des métriques anciennes pour économiser de l'espace.

```
Dernières 24h  : résolution 15s (1 point toutes les 15 secondes)
Derniers 30j   : résolution 5min (1 point toutes les 5 minutes) → 20x moins de points
Dernière année : résolution 1h (1 point toutes les heures) → 240x moins de points
```

### 6.2 Recording Rules (pré-calcul)
Les **recording rules** pré-calculent des requêtes complexes et stockent le résultat comme de nouvelles métriques.

```yaml
# /etc/prometheus/rules/recording.yml
groups:
  - name: performance_rules
    interval: 30s
    rules:
      # Pré-calculer le taux de requêtes PG
      - record: pg:transactions_per_second
        expr: rate(pg_stat_database_xact_commit[5m]) + rate(pg_stat_database_xact_rollback[5m])

      # Pré-calculer l'utilisation CPU
      - record: node:cpu_usage_percent
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

      # Pré-calculer le cache hit ratio
      - record: pg:cache_hit_ratio
        expr: |
          pg_stat_database_blks_hit
          / (pg_stat_database_blks_hit + pg_stat_database_blks_read)

      # Pré-calculer l'utilisation mémoire
      - record: node:memory_usage_percent
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100
```

### 6.3 Thanos Compactor (downsampling automatique)

```bash
# Le compactor fait le downsampling et le nettoyage dans S3
thanos compact \
  --data-dir=/tmp/thanos-compact \
  --objstore.config-file=/etc/thanos/bucket.yml \
  --retention.resolution-raw=30d \     # Garder la résolution brute 30 jours
  --retention.resolution-5m=180d \     # Garder la résolution 5min pendant 6 mois
  --retention.resolution-1h=365d \     # Garder la résolution 1h pendant 1 an
  --wait                               # Mode continu
```

## 7. Tuning Prometheus / Grafana

### 7.1 Paramètres de performance Prometheus

```bash
# Flags importants au démarrage de Prometheus
prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \           # Rétention en jours
  --storage.tsdb.retention.size=100GB \          # Rétention en taille
  --storage.tsdb.wal-compression \               # Compresser les WAL (économie ~50%)
  --query.max-concurrency=20 \                   # Requêtes simultanées max
  --query.max-samples=50000000 \                 # Échantillons max par requête
  --query.timeout=2m \                           # Timeout des requêtes
  --web.enable-lifecycle                         # Permettre le reload via API
```

### 7.2 Indicateurs de santé Prometheus

```promql
# Mémoire utilisée par Prometheus
process_resident_memory_bytes{job="prometheus"}

# Nombre de séries temporelles actives
prometheus_tsdb_head_series

# Taille de la TSDB
prometheus_tsdb_storage_blocks_bytes

# Durée des scrapes (> 10s = problème)
prometheus_target_interval_length_seconds

# Échecs de scrape
up == 0  # Cibles qui ne répondent pas

# Nombre de samples ingérés par seconde
rate(prometheus_tsdb_head_samples_appended_total[5m])

# Alertes actives
ALERTS{alertstate="firing"}
```

### 7.3 Optimisation Grafana

#### Requêtes efficaces
```promql
# ❌ Mauvais : requête brute sur une longue période
pg_stat_activity_count  # Sur 30 jours = énormément de points

# ✅ Bon : utiliser une recording rule ou réduire la résolution
pg:connections_total    # Recording rule pré-calculée
# Ou configurer le step à 1m/5m dans Grafana pour les longues périodes
```

#### Paramètres Grafana à vérifier
- **Min interval** dans les panels : ajuster selon la période affichée
- **Max data points** : limiter le nombre de points retournés (1000-2000 suffisent)
- **$__rate_interval** : utiliser cette variable Grafana au lieu d'un interval fixe dans `rate()`
- **Cache** : activer le cache des datasources pour les dashboards fréquentés

## 8. Résumé

### Architecture monitoring complète
```
Cibles (etcd, PG, HAProxy, PgBouncer)
    │ /metrics
    ▼
Prometheus (scrape + stocke + alerte)
    │
    ├──► Alertmanager → LogNcall (alertes)
    │
    ├──► Thanos Sidecar → S3 (archivage long terme)
    │
    └──► Thanos Query (déduplication)
            │
            ▼
         Grafana (visualisation)
```

### Les 3 choses les plus importantes
1. **Scrape interval** : 15s est un bon défaut. Plus court = plus de données = plus de stockage
2. **Recording rules** : pré-calculer les requêtes lourdes pour des dashboards rapides
3. **Déduplication** : utiliser `external_labels` + Thanos pour éviter les doubles
