# Jour 5 — Vendredi 3 Avril : Prometheus S3 + Sampling + Tuning + Validation finale

## Chronogramme

```
09:00 ┬─────────────────────────────────────────────────────────────┐
      │  BLOC 1 : Configuration Prometheus avec S3 (1h30)           │
      │  • Audit stockage actuel                                   │
      │  • Configurer Thanos Sidecar → S3 ou remote_write          │
      │  • Rétention locale vs S3                                  │
10:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 2 : Sampling et recording rules (1h)                  │
      │  • Configurer les recording rules de downsampling          │
      │  • Thanos Compactor si applicable                          │
11:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 3 : Validation stockage S3 (30min)                    │
      │  • Vérifier l'upload des blocks vers S3                    │
      │  • Vérifier la lecture depuis S3 via Thanos Store          │
12:00 ┼═══════════════════ PAUSE DÉJEUNER ══════════════════════════┤
14:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 4 : Tuning Prometheus (1h)                            │
      │  • Paramètres TSDB, mémoire, concurrence                  │
      │  • Optimiser scrape_interval et evaluation_interval        │
15:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 5 : Tuning Grafana (1h)                               │
      │  • Optimiser les dashboards                                │
      │  • Variables, min_interval, max_data_points                │
16:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 6 : Validation finale de bout en bout (1h)            │
      │  • Test complet : panne → détection → alerte → résolution  │
      │  • Vérifier tous les circuits                              │
17:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 7 : Documentation et transfert (1h)                   │
      │  • Document de synthèse final                              │
      │  • Liste des livrables                                     │
      │  • Recommandations et prochaines étapes                    │
18:00 ┴─────────────────────────────────────────────────────────────┘
```

---

## BLOC 1 — Configuration Prometheus avec S3 (09:00-10:30)

### Actions

#### 1.1 Audit du stockage actuel
```bash
ssh user@prometheus-server

# Taille actuelle de la TSDB
du -sh /var/lib/prometheus/

# Rétention actuelle
grep -E "retention" /etc/default/prometheus 2>/dev/null
# Ou dans les flags de démarrage :
systemctl cat prometheus | grep retention

# Espace disque disponible
df -h /var/lib/prometheus/

# Nombre de séries actives
curl -s http://localhost:9090/api/v1/status/tsdb | python3 -m json.tool | grep -E "numSeries|numLabelPairs"
```

**Noter :**
- [ ] Taille TSDB actuelle : ___________
- [ ] Rétention configurée : ___________
- [ ] Espace disque dispo : ___________
- [ ] Nombre de séries actives : ___________

#### 1.2 Configurer le stockage S3

##### Si Thanos Sidecar (recommandé)
```yaml
# /etc/thanos/bucket.yml
type: S3
config:
  bucket: "transactis-prometheus-metrics"
  endpoint: "s3.eu-west-3.amazonaws.com"
  region: "eu-west-3"
  access_key: "${AWS_ACCESS_KEY_ID}"      # Demander les credentials
  secret_key: "${AWS_SECRET_ACCESS_KEY}"
  insecure: false
```

```bash
# Tester l'accès S3
thanos tools bucket ls --objstore.config-file=/etc/thanos/bucket.yml

# Configurer le sidecar pour uploader vers S3
# Dans le service thanos-sidecar, ajouter :
# --objstore.config-file=/etc/thanos/bucket.yml
# --shipper.upload-compacted

sudo systemctl restart thanos-sidecar
```

##### Si remote_write (alternative)
```yaml
# Dans prometheus.yml
remote_write:
  - url: "http://thanos-receive:19291/api/v1/receive"
    # OU vers un autre backend compatible (Cortex, Mimir, VictoriaMetrics)
```

#### 1.3 Ajuster la rétention locale
```bash
# Réduire la rétention locale (les anciennes données sont dans S3)
# Dans les flags Prometheus :
# --storage.tsdb.retention.time=15d     # 15 jours en local
# --storage.tsdb.retention.size=50GB    # OU max 50 GB

# Redémarrer Prometheus
sudo systemctl restart prometheus
```

**Informations à demander à l'équipe Transactis :**
- [ ] Credentials AWS (access key / secret key) ou IAM role
- [ ] Nom du bucket S3 existant ou à créer
- [ ] Région AWS
- [ ] Politique de rétention souhaitée (combien de temps garder les métriques ?)

### Livrable
- [ ] Stockage S3 configuré (ou plan documenté si credentials non disponibles)
- [ ] Rétention locale ajustée

---

## BLOC 2 — Sampling et Recording Rules (10:30-11:30)

### Actions

#### 2.1 Créer les recording rules de pré-calcul

Les recording rules réduisent la charge des dashboards en pré-calculant les requêtes lourdes.

Créer `/etc/prometheus/rules/recording-rules.yml` :

```yaml
groups:
  # ══════════════════════════════════════════
  # MÉTRIQUES PRÉ-CALCULÉES GLOBALES
  # ══════════════════════════════════════════
  - name: global_recording_rules
    interval: 30s
    rules:
      # CPU
      - record: node:cpu_usage_percent
        expr: >
          100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)

      # Mémoire
      - record: node:memory_usage_percent
        expr: >
          (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100

      # Disque
      - record: node:disk_usage_percent
        expr: >
          (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) * 100

  # ══════════════════════════════════════════
  # MÉTRIQUES PRÉ-CALCULÉES POSTGRESQL
  # ══════════════════════════════════════════
  - name: postgresql_recording_rules
    interval: 30s
    rules:
      - record: pg:transactions_per_second
        expr: >
          sum by (instance, datname) (
            rate(pg_stat_database_xact_commit[5m])
            + rate(pg_stat_database_xact_rollback[5m])
          )

      - record: pg:connections_usage_ratio
        expr: >
          sum by (instance) (pg_stat_activity_count)
          / on (instance) pg_settings_max_connections

      - record: pg:cache_hit_ratio
        expr: >
          pg_stat_database_blks_hit
          / (pg_stat_database_blks_hit + pg_stat_database_blks_read + 1)

      - record: pg:replication_lag_seconds
        expr: pg_stat_replication_replay_lag

  # ══════════════════════════════════════════
  # MÉTRIQUES PRÉ-CALCULÉES ETCD
  # ══════════════════════════════════════════
  - name: etcd_recording_rules
    interval: 30s
    rules:
      - record: etcd:wal_fsync_p99
        expr: >
          histogram_quantile(0.99,
            rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])
          )

      - record: etcd:leader_changes_1h
        expr: increase(etcd_server_leader_changes_seen_total[1h])
```

```bash
promtool check rules /etc/prometheus/rules/recording-rules.yml
curl -X POST http://localhost:9090/-/reload
```

#### 2.2 Configurer Thanos Compactor (si Thanos est en place)

Le Compactor fait le downsampling automatique dans S3 :

```bash
# Vérifier si le Compactor est en place
systemctl status thanos-compact

# Configuration recommandée
thanos compact \
  --data-dir=/tmp/thanos-compact \
  --objstore.config-file=/etc/thanos/bucket.yml \
  --retention.resolution-raw=30d \       # Garder la résolution brute 30 jours
  --retention.resolution-5m=180d \       # Résolution 5min pendant 6 mois
  --retention.resolution-1h=365d \       # Résolution 1h pendant 1 an
  --compact.concurrency=1 \
  --downsample.concurrency=1 \
  --wait                                 # Mode continu
```

**Politique de rétention à valider avec l'équipe :**

| Résolution | Durée de rétention | Usage |
|------------|-------------------|-------|
| Brute (15s) | 30 jours | Diagnostic temps réel et récent |
| 5 minutes | 6 mois | Tendances hebdomadaires/mensuelles |
| 1 heure | 1 an | Capacity planning, rapports annuels |

### Livrable
- [ ] Recording rules créées et déployées
- [ ] Thanos Compactor configuré (si applicable)
- [ ] Politique de rétention documentée

---

## BLOC 3 — Validation stockage S3 (11:30-12:00)

### Actions

```bash
# Vérifier que les blocks sont uploadés vers S3
thanos tools bucket ls --objstore.config-file=/etc/thanos/bucket.yml

# Vérifier Thanos Store Gateway (lit depuis S3)
systemctl status thanos-store
curl -s http://thanos-store:9090/api/v1/stores

# Dans Grafana : requêter des données anciennes (> rétention locale)
# Si les données remontent → S3 fonctionne
```

### Livrable
- [ ] Upload S3 vérifié
- [ ] Lecture depuis S3 validée (si applicable)

---

## BLOC 4 — Tuning Prometheus (13:00-14:00)

### Actions

#### 4.1 Vérifier les paramètres actuels
```bash
# Flags de démarrage
systemctl cat prometheus | grep ExecStart

# Métriques internes Prometheus
curl -s http://localhost:9090/api/v1/status/config | python3 -m json.tool | head -50

# Performances
curl -s http://localhost:9090/api/v1/status/runtimeinfo | python3 -m json.tool
```

#### 4.2 Optimiser les paramètres

```bash
# Flags recommandés
prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --storage.tsdb.retention.size=50GB \
  --storage.tsdb.wal-compression \          # Économie ~50% sur les WAL
  --storage.tsdb.max-block-duration=2h \    # Blocs de 2h max
  --query.max-concurrency=20 \              # 20 requêtes simultanées max
  --query.max-samples=50000000 \            # 50M échantillons max par requête
  --query.timeout=2m \                      # Timeout requête 2 min
  --web.enable-lifecycle \                  # Permettre reload via API
  --web.enable-admin-api                    # API admin (attention en prod)
```

#### 4.3 Vérifier les indicateurs de santé
```promql
# Dans Prometheus, vérifier ces métriques :

# Mémoire utilisée (ne doit pas s'approcher du max du serveur)
process_resident_memory_bytes{job="prometheus"}

# Nombre de séries actives (baseline à noter)
prometheus_tsdb_head_series

# Durée des scrapes (doit être < scrape_interval)
prometheus_target_interval_length_seconds{quantile="0.99"}

# Samples ingérés par seconde
rate(prometheus_tsdb_head_samples_appended_total[5m])

# Scrapes qui échouent
up == 0

# Taille de la TSDB
prometheus_tsdb_storage_blocks_bytes
```

#### 4.4 Ajuster scrape_interval si nécessaire
```yaml
# Pour des cibles moins critiques, on peut augmenter l'intervalle
scrape_configs:
  - job_name: 'etcd'
    scrape_interval: 15s     # OK, critique

  - job_name: 'node'
    scrape_interval: 30s     # 30s suffit pour les métriques système

  - job_name: 'postgresql'
    scrape_interval: 15s     # OK, critique

  - job_name: 'haproxy'
    scrape_interval: 15s     # OK, critique

  - job_name: 'pgbouncer'
    scrape_interval: 15s     # OK, critique
```

### Livrable
- [ ] Paramètres Prometheus optimisés
- [ ] Indicateurs de santé baseline notés

---

## BLOC 5 — Tuning Grafana (14:00-15:00)

### Actions

#### 5.1 Optimiser chaque dashboard

Pour chaque dashboard créé cette semaine, vérifier :

```
Pour chaque panel :
1. Utiliser $__rate_interval au lieu d'un intervalle fixe dans rate()
   ❌ rate(metric[5m])
   ✅ rate(metric[$__rate_interval])

2. Configurer le Min interval
   → Dashboard settings → Variables → $__interval
   → Mettre "15s" pour les dashboards détaillés
   → Mettre "1m" pour les dashboards de tendances

3. Configurer Max data points
   → Dans chaque panel : Query options → Max data points → 1000
   → Évite de charger trop de points sur les longues périodes

4. Utiliser les recording rules plutôt que les requêtes complexes
   ❌ histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))
   ✅ etcd:wal_fsync_p99
```

#### 5.2 Ajouter des variables de dashboard

Pour chaque dashboard, ajouter des variables permettant de filtrer :

```
Variable "instance" :
  Type: Query
  Query: label_values(up{job="etcd"}, instance)
  → Permet de filtrer par instance dans le dropdown

Variable "database" (pour le dashboard PG) :
  Type: Query
  Query: label_values(pg_database_size_bytes, datname)
```

#### 5.3 Créer un dashboard "Overview" global

Un dashboard unique qui résume la santé de toute la stack :

**Row 1 : Santé globale**

| Panel | Type | Query | Seuils |
|-------|------|-------|--------|
| etcd Cluster | Stat | `min(etcd_server_has_leader)` | 1=vert, 0=rouge |
| PG Cluster | Stat | `min(pg_up)` | 1=vert, 0=rouge |
| Patroni Leader | Stat | `count(patroni_primary==1)` | 1=vert, 0=rouge |
| HAProxy | Stat | `min(up{job="haproxy"})` | 1=vert, 0=rouge |
| PgBouncer | Stat | `min(pgbouncer_up)` | 1=vert, 0=rouge |
| Alertes firing | Stat | `count(ALERTS{alertstate="firing"})` | 0=vert, >0=rouge |

**Row 2 : Métriques clés**

| Panel | Type | Query |
|-------|------|-------|
| Lag réplication max | Stat | `max(pg:replication_lag_seconds)` |
| Connexions PG | Gauge | `max(pg:connections_usage_ratio) * 100` |
| PgBouncer waiting | Stat | `sum(pgbouncer_pools_client_waiting_connections)` |
| HAProxy write backends | Stat | `haproxy_backend_active_servers{proxy="pg-write"}` |

### Livrable
- [ ] Dashboards optimisés ($__rate_interval, max data points)
- [ ] Variables ajoutées aux dashboards
- [ ] Dashboard Overview créé

---

## BLOC 6 — Validation finale de bout en bout (15:00-16:00)

### Actions

#### 6.1 Checklist de validation globale

```
COMPOSANTS SUPERVISÉS
═══════════════════════════════════════════════════════
                                              Status
etcd
  [ ] 3 targets UP dans Prometheus             ___
  [ ] Alertes configurées (X rules)            ___
  [ ] Recording rules fonctionnelles           ___
  [ ] Dashboard Grafana opérationnel           ___
  [ ] Circuit alerte → LogNcall testé          ___

PostgreSQL / Patroni
  [ ] postgres_exporter sur chaque nœud        ___
  [ ] Patroni API scrapée                      ___
  [ ] Alertes PG configurées (X rules)         ___
  [ ] Alertes Patroni configurées (X rules)    ___
  [ ] Dashboard Grafana opérationnel           ___
  [ ] Switchover testé et observé              ___

pgBackRest
  [ ] Métriques backup exposées                ___
  [ ] Alertes backup configurées               ___

HAProxy
  [ ] Métriques Prometheus activées            ___
  [ ] Alertes configurées (X rules)            ___
  [ ] Dashboard Grafana opérationnel           ___
  [ ] Failover backend observé                 ___

PgBouncer
  [ ] pgbouncer_exporter installé              ___
  [ ] Alertes configurées (X rules)            ___
  [ ] Dashboard Grafana opérationnel           ___

Déduplication
  [ ] External labels configurés               ___
  [ ] Pas de doublons dans Grafana             ___

Stockage S3
  [ ] Upload vers S3 fonctionnel               ___
  [ ] Rétention locale configurée              ___
  [ ] Thanos Compactor configuré               ___

Tuning
  [ ] Prometheus optimisé                      ___
  [ ] Grafana dashboards optimisés             ___
  [ ] Recording rules déployées                ___

CIRCUITS D'ALERTE
═══════════════════════════════════════════════════════
  [ ] Prometheus → Alertmanager connecté       ___
  [ ] Alertmanager → LogNcall (critical)       ___
  [ ] Alertmanager → Email (warning)           ___
  [ ] Inhibitions configurées                  ___
  [ ] Test alerte manuelle → LogNcall          ___
```

#### 6.2 Test final de bout en bout (si staging disponible)

```bash
# Scénario complet : simuler un failover PostgreSQL

# 1. Préparer l'observation
# Ouvrir : Grafana Overview, Prometheus Alerts, HAProxy Stats, LogNcall

# 2. Noter l'heure
date

# 3. Forcer un switchover (safe, c'est planifié)
patronictl switchover --candidate pg-node3 --force

# 4. Observer :
# → Grafana : le leader change dans le dashboard
# → HAProxy : les backends basculent
# → Prometheus : PatroniFailoverDetected se déclenche
# → Alertmanager : l'alerte est routée
# → LogNcall : notification reçue (si WARNING ou CRITICAL)

# 5. Vérifier la résolution automatique
# → Les alertes doivent repasser en inactive après la stabilisation

# 6. Documenter les temps de réaction
```

### Livrable
- [ ] Checklist de validation remplie
- [ ] Test de bout en bout documenté

---

## BLOC 7 — Documentation et transfert (16:00-17:00)

### Actions

#### 7.1 Document de synthèse final

Créer un document de livraison :

```
══════════════════════════════════════════════════════════
RAPPORT DE LIVRAISON — Supervision Infrastructure PostgreSQL
Client : Transactis
Date : 30/03 - 03/04/2026
Intervenant : [Ton nom]
══════════════════════════════════════════════════════════

1. PÉRIMÈTRE COUVERT
   • Supervision cluster etcd (3 nœuds)
   • Supervision cluster PostgreSQL/Patroni (3 nœuds)
   • Supervision pgBackRest (sauvegardes)
   • Supervision HAProxy (load balancer)
   • Supervision PgBouncer (connection pooler)
   • Déduplication métriques Prometheus
   • Stockage S3 et sampling
   • Tuning Prometheus et Grafana

2. LIVRABLES
   Prometheus :
   • X fichiers de rules d'alerte
   • X recording rules
   • Configuration S3 / Thanos
   • Tuning des paramètres

   Alertmanager :
   • Configuration complète (receivers, routes, inhibitions)
   • Intégration LogNcall testée

   Grafana :
   • Dashboard etcd
   • Dashboard PostgreSQL/Patroni
   • Dashboard HAProxy
   • Dashboard PgBouncer
   • Dashboard Overview (synthèse)

3. TESTS EFFECTUÉS
   • [x] Test alerte manuelle → LogNcall
   • [x] Switchover Patroni observé
   • [x] Failover backend HAProxy observé
   • [x] Vérification déduplication

4. RECOMMANDATIONS
   • [Lister les recommandations identifiées pendant la semaine]
   • Exemple : ajouter un 2ème HAProxy avec Keepalived
   • Exemple : planifier des tests de failover mensuels
   • Exemple : réviser les seuils d'alerte après 1 mois

5. PROCHAINES ÉTAPES
   • Monitoring des performances applicatives
   • Dashboard de capacity planning
   • Tests de restauration pgBackRest
   • Formation de l'équipe aux dashboards
```

#### 7.2 Transfert de connaissances

Présenter à l'équipe Transactis :
1. Les dashboards créés et comment les utiliser
2. Comment modifier les alertes (ajouter/modifier des rules)
3. Comment silencer une alerte dans Alertmanager
4. Où trouver les fichiers de configuration
5. Les commandes de diagnostic essentielles

#### 7.3 Liste des fichiers modifiés/créés

```
Fichiers créés/modifiés cette semaine :

Prometheus :
  /etc/prometheus/prometheus.yml (modifié — ajout des targets)
  /etc/prometheus/rules/etcd-alerts.yml (créé)
  /etc/prometheus/rules/postgresql-patroni-alerts.yml (créé)
  /etc/prometheus/rules/haproxy-alerts.yml (créé)
  /etc/prometheus/rules/pgbouncer-alerts.yml (créé)
  /etc/prometheus/rules/recording-rules.yml (créé)

Alertmanager :
  /etc/alertmanager/alertmanager.yml (modifié/créé)

Thanos :
  /etc/thanos/bucket.yml (créé si applicable)

HAProxy :
  /etc/haproxy/haproxy.cfg (modifié — ajout frontend prometheus)

Grafana :
  5 dashboards créés (exportés en JSON si possible)

Scripts :
  /usr/local/bin/pgbackrest-metrics.sh (créé)
  /etc/cron.d/pgbackrest-metrics (créé)
```

### Livrable
- [ ] Rapport de livraison rédigé
- [ ] Transfert de connaissances effectué
- [ ] Semaine terminée avec succès
