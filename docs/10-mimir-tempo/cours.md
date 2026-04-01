# Mimir & Tempo — Cours Complet pour Débutants

## 1. Le problème : les limites de Prometheus seul

```
┌────────────────────────────────────────────────────┐
│  Prometheus seul                                    │
│                                                     │
│  ✗ Rétention limitée (15j par défaut)              │
│  ✗ Pas de haute dispo native (si crash → trou)     │
│  ✗ Pas de multi-tenant                              │
│  ✗ Stockage local = pas scalable                    │
│  ✗ Pas de tracing (métriques uniquement)           │
└────────────────────────────────────────────────────┘
```

Mimir et Tempo résolvent chacun un de ces problèmes :
- **Mimir** → stockage long-terme des métriques + HA + multi-tenant
- **Tempo** → tracing distribué (suivre une requête à travers les composants)

---

## 2. Grafana Mimir

### 2.1 C'est quoi Mimir ?

Mimir est un **backend de stockage long-terme pour les métriques Prometheus**.
Prometheus collecte les métriques (scrape) et les pousse vers Mimir via `remote_write`.
Mimir les stocke sur un stockage objet (S3, MinIO) et les sert via une API 100% compatible Prometheus.

```
  Prometheus ──remote_write──► Mimir ──► S3 / MinIO
                                 │
                          Grafana ──┘ (query via API Prometheus)
```

### 2.2 Architecture interne

Mimir est composé de plusieurs composants (qui peuvent tourner dans un seul binaire) :

```
                    remote_write
  Prometheus ──────────────────────► DISTRIBUTOR
                                        │
                                        │ répartition (hash ring)
                                        ▼
                                    INGESTER ──► S3 (blocs TSDB)
                                        │
                        ┌───────────────┤
                        ▼               ▼
                   COMPACTOR       STORE GATEWAY
                   (fusionne       (lit les blocs
                    les blocs)      depuis S3)
                                        │
                                        ▼
                                  QUERY FRONTEND
                                        │
                                        ▼
                                    Grafana
```

| Composant | Rôle |
|-----------|------|
| **Distributor** | Point d'entrée des écritures. Valide les samples et les répartit vers les ingesters via un hash ring |
| **Ingester** | Stocke les samples en mémoire, puis les flush vers S3 sous forme de blocs TSDB |
| **Compactor** | Fusionne les petits blocs en gros blocs dans S3 (optimise les requêtes et réduit les fichiers) |
| **Store Gateway** | Lit les blocs historiques depuis S3 pour répondre aux requêtes sur les données anciennes |
| **Query Frontend** | Reçoit les requêtes PromQL, les découpe et les parallélise |
| **Ruler** | Évalue les recording rules et alerting rules côté Mimir (optionnel) |

### 2.3 Mimir vs Thanos

| | Thanos | Mimir |
|---|---|---|
| **Modèle** | Sidecar qui upload les blocs TSDB | Prometheus pousse via `remote_write` |
| **Déduplication** | Via `query.replica-label` au query | Native à l'ingestion (HA tracker) |
| **Multi-tenant** | Non | Oui (header `X-Scope-OrgID`) |
| **Stockage** | S3 (blocs TSDB bruts) | S3 (blocs compactés) |
| **Architecture** | Sidecar + Query + Store + Compactor | Single binary ou microservices |
| **Quand l'utiliser** | Déjà en place, setup simple | Nouveau déploiement, multi-tenant, haute perf |

### 2.4 Multi-tenancy

Le multi-tenant permet d'isoler les données par tenant (équipe, client, environnement) :

```
  Prometheus team-A ──► remote_write + header X-Scope-OrgID: team-A ──► Mimir
  Prometheus team-B ──► remote_write + header X-Scope-OrgID: team-B ──► Mimir

  → team-A ne voit que ses métriques
  → team-B ne voit que ses métriques
```

- `multitenancy_enabled: true` → chaque requête doit inclure le header `X-Scope-OrgID`
- `multitenancy_enabled: false` → tout le monde est "anonymous", pas d'isolation

Le **tenant-id** est un identifiant logique. Il peut représenter une équipe, un client, un environnement, etc.

### 2.5 Haute disponibilité (HA)

Avec 2 Prometheus qui scrapent les mêmes cibles :

```
  Prometheus-1 (replica: prom-1) ──remote_write──┐
                                                   ├──► Mimir (distributor)
  Prometheus-2 (replica: prom-2) ──remote_write──┘
```

Sans déduplication, Mimir stocke **2 copies** de chaque sample.
Avec le HA tracker activé :

```yaml
limits:
  ha_cluster_label: "cluster"    # identifie le cluster
  ha_replica_label: "replica"    # identifie le replica
```

Le distributor élit un replica "actif" par cluster. Les samples de l'autre replica sont ignorés.
Si le replica actif tombe, Mimir bascule automatiquement sur l'autre.

### 2.6 Memberlist (découverte des composants)

Les composants Mimir (distributor, ingester, compactor) se découvrent entre eux via **memberlist** (protocole gossip), sans dépendre d'un service externe comme Consul ou etcd.

```yaml
distributor:
  ring:
    kvstore:
      store: memberlist
```

---

## 3. Grafana Tempo

### 3.1 C'est quoi le tracing distribué ?

Le monitoring par métriques répond à "combien ?" (tx/s, latence p99, CPU%).
Le tracing répond à "quoi exactement ?" — il suit le chemin d'une requête à travers chaque composant.

### 3.2 Concepts clés

| Concept | Description |
|---------|-------------|
| **Trace** | Le parcours complet d'une requête, de bout en bout |
| **Span** | Une étape dans la trace (ex: passage par HAProxy, exécution d'une query SQL) |
| **Trace ID** | Identifiant unique d'une trace (propagé entre composants) |
| **Parent-child** | Les spans s'emboîtent : le span "client.request" contient "haproxy.route" qui contient "postgresql.query" |

### 3.3 Exemple concret dans notre stack

```
Client → PgBouncer → HAProxy → PostgreSQL (leader)
  │         │           │            │
  span1     span2       span3        span4
  (10ms)    (2ms)       (1ms)        (5ms)
  └─────────────────────────────────────┘
                 trace (18ms total)
```

En cliquant sur une trace dans Grafana, tu vois chaque span avec sa durée, ses attributs, et ses erreurs éventuelles.

### 3.4 Metrics vs Traces vs Logs

| Type | Outil | Question | Exemple |
|------|-------|----------|---------|
| **Metrics** | Prometheus/Mimir | "Combien ?" | La latence p99 est à 200ms |
| **Traces** | Tempo | "Quoi exactement ?" | Cette requête a mis 2s à cause d'un deadlock sur PostgreSQL |
| **Logs** | Loki | "Que s'est-il passé ?" | `ERROR: deadlock detected on table orders` |

En supervision, on les combine : les métriques alertent, les traces localisent, les logs expliquent.

### 3.5 Architecture Tempo

```
  App / Générateur ──OTLP──► OpenTelemetry Collector ──► Tempo ──► MinIO (S3)
                                                            │
                                                     Grafana ──┘ (query traces)
```

| Composant | Rôle |
|-----------|------|
| **OpenTelemetry Collector** | Reçoit les traces au format OTLP, les batch et les forward à Tempo |
| **Tempo Distributor** | Reçoit les traces et les répartit vers les ingesters |
| **Tempo Ingester** | Stocke les traces en mémoire puis les flush vers S3 |
| **Tempo Querier** | Lit les traces depuis S3 pour répondre aux requêtes |
| **Metrics Generator** | Génère des métriques (latence, débit) à partir des traces → pousse vers Prometheus |

### 3.6 Span Metrics

Tempo peut automatiquement générer des **métriques à partir des traces** :

```yaml
metrics_generator:
  storage:
    remote_write:
      - url: http://prometheus:9090/api/v1/write
```

Résultat : des métriques comme `traces_spanmetrics_latency_bucket` et `traces_service_graph_request_total`
apparaissent dans Prometheus, sans instrumentation supplémentaire. C'est le pont entre tracing et monitoring.

---

## 4. La stack observabilité Grafana complète

```
                    ┌──────────────────────────────┐
                    │         GRAFANA               │
                    │  Dashboards / Explore / Alerts│
                    └──────┬──────┬──────┬─────────┘
                           │      │      │
                    ┌──────▼──┐ ┌─▼────┐ ┌▼──────┐
                    │  Mimir  │ │Tempo │ │ Loki  │
                    │(metrics)│ │(trace)│ │(logs) │
                    └────┬────┘ └──┬───┘ └──┬────┘
                         │        │        │
                    ┌────▼────────▼────────▼────┐
                    │      S3 / MinIO           │
                    │   (stockage long-terme)    │
                    └───────────────────────────┘
```

Les 3 piliers de l'observabilité, stockés sur S3, interrogés via Grafana.
Dans ce lab, on met en place Mimir (métriques) et Tempo (traces).
