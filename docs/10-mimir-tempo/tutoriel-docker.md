# Tutoriel Pratique : Mimir & Tempo sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel Prometheus/Grafana (`docs/05-prometheus-grafana/tutoriel-docker.md`)
- Avoir lu le cours Mimir & Tempo (`docs/10-mimir-tempo/cours.md`)

## Objectifs
1. Déployer Mimir comme stockage long-terme pour Prometheus
2. Configurer 2 Prometheus en HA avec déduplication
3. Vérifier la rétention long-terme vs rétention courte Prometheus
4. Déployer Tempo pour le tracing distribué
5. Générer et explorer des traces dans Grafana

---

# Partie 1 — Grafana Mimir

## Architecture

```
  Prometheus-1 (prom-1) ──remote_write──┐
                                         ├──► Mimir ──► MinIO (S3)
  Prometheus-2 (prom-2) ──remote_write──┘       │
                                                 │
                                        Grafana ──┘ (query via Mimir)

  + toute la stack : etcd x3, Patroni x3, HAProxy, node-exporter
```

## Étape 1 : Fichiers de configuration

### mimir.yml

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

ruler_storage:
  backend: local
  local:
    directory: /data/rules

limits:
  max_global_series_per_user: 0
  ingestion_rate: 100000
  ingestion_burst_size: 200000
  # Déduplication HA : le distributor drop le label "replica" à l'ingestion
  # et ne garde qu'une copie par couple (cluster, replica)
  ha_cluster_label: "cluster"
  ha_replica_label: "replica"
```

**Points clés de la config :**

| Paramètre | Rôle |
|-----------|------|
| `multitenancy_enabled: false` | Pas d'isolation par tenant. Toutes les requêtes sont "anonymous" |
| `blocks_storage.backend: s3` | Stockage des blocs TSDB dans MinIO (S3 local) |
| `memberlist` | Les composants se découvrent entre eux par gossip (pas besoin de Consul/etcd) |
| `replication_factor: 1` | Mode single-node (lab). En prod on mettrait 3 |
| `ruler_storage.local` | Stockage local des recording/alerting rules |
| `ha_cluster_label` / `ha_replica_label` | Active la déduplication HA : le distributor ne garde qu'un replica par cluster |

### prometheus-mimir.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: mimir-lab
    replica: prom-1

# ===== REMOTE WRITE VERS MIMIR =====
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

  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy:8405']
    metrics_path: /metrics

  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'mimir'
    static_configs:
      - targets: ['mimir:9009']
    metrics_path: /metrics
```

### prometheus-2-mimir.yml

Identique à `prometheus-mimir.yml` mais avec `replica: prom-2` :

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: mimir-lab
    replica: prom-2

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

  - job_name: 'haproxy'
    static_configs:
      - targets: ['haproxy:8405']
    metrics_path: /metrics

  - job_name: 'node'
    static_configs:
      - targets: ['node-exporter:9100']

  - job_name: 'mimir'
    static_configs:
      - targets: ['mimir:9009']
    metrics_path: /metrics
```

### grafana/provisioning/datasources/datasources.yml

```yaml
apiVersion: 1
datasources:
  - name: Mimir
    uid: mimir
    type: prometheus
    access: proxy
    url: http://mimir:9009/prometheus
    isDefault: true
    editable: false
  - name: Prometheus (local)
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    editable: false
```

Grafana utilise le même type de datasource `prometheus` pour Mimir car Mimir expose une **API 100% compatible Prometheus**. Seule l'URL change.

### docker-compose-mimir.yml

```yaml
services:
  # ===== ETCD =====
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
      - --initial-cluster-token=mimir-lab
      - --metrics=extensive
    networks:
      - mimir-net

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
      - --initial-cluster-token=mimir-lab
      - --metrics=extensive
    networks:
      - mimir-net

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
      - --initial-cluster-token=mimir-lab
      - --metrics=extensive
    networks:
      - mimir-net

  # ===== PATRONI =====
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
      - mimir-net

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
      - mimir-net

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
      - mimir-net

  # ===== HAPROXY =====
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
      - mimir-net
    depends_on:
      - patroni-1
      - patroni-2
      - patroni-3

  # ===== NODE EXPORTER =====
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    networks:
      - mimir-net

  # ===== MINIO (S3) =====
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
      - mimir-net

  minio-init:
    image: minio/mc:latest
    container_name: minio-init
    entrypoint: >
      /bin/sh -c "
      sleep 5 &&
      mc alias set local http://minio:9000 minioadmin minioadmin &&
      mc mb --ignore-existing local/mimir-blocks &&
      mc mb --ignore-existing local/tempo-traces &&
      echo 'Buckets created'
      "
    networks:
      - mimir-net
    depends_on:
      - minio

  # ===== MIMIR =====
  mimir:
    image: grafana/mimir:latest
    container_name: mimir
    command:
      - --config.file=/etc/mimir/mimir.yml
    volumes:
      - ./mimir.yml:/etc/mimir/mimir.yml:ro
      - mimir-rules:/data/rules
    ports:
      - "9009:9009"
    networks:
      - mimir-net
    depends_on:
      - minio-init

  # ===== PROMETHEUS 1 (remote_write vers Mimir) =====
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus-mimir.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=5m
      - --web.enable-lifecycle
    networks:
      - mimir-net

  # ===== PROMETHEUS 2 (HA, remote_write vers Mimir) =====
  prometheus-2:
    image: prom/prometheus:latest
    container_name: prometheus-2
    ports:
      - "9091:9090"
    volumes:
      - ./prometheus-2-mimir.yml:/etc/prometheus/prometheus.yml:ro
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=5m
      - --web.enable-lifecycle
    networks:
      - mimir-net

  # ===== GRAFANA =====
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
      - mimir-net

volumes:
  mimir-rules:

networks:
  mimir-net:
    driver: bridge
```

> **Note :** Le volume `mimir-rules` crée automatiquement le dossier `/data/rules` au démarrage.
> L'image Mimir est distroless (pas de shell), donc on ne peut pas faire `mkdir` dans le `command`.

## Étape 2 : Démarrer la stack

```bash
mkdir -p grafana/provisioning/datasources

# Copier les fichiers :
# - mimir.yml
# - prometheus-mimir.yml
# - prometheus-2-mimir.yml
# - haproxy.cfg (depuis le lab 03)
# - grafana/provisioning/datasources/datasources.yml
# - docker-compose-mimir.yml

docker compose -f docker-compose-mimir.yml up -d
sleep 45
docker compose -f docker-compose-mimir.yml ps
```

## Étape 3 : Vérifier que tout fonctionne

```bash
# Mimir est UP ?
curl -s http://localhost:9009/ready
# → ready

# Prometheus 1 et 2 font du remote_write ?
curl -s http://localhost:9090/api/v1/status/config | grep remote_write
curl -s http://localhost:9091/api/v1/status/config | grep remote_write
# → url: http://mimir:9009/api/v1/push

# Requête via Mimir (API compatible Prometheus)
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=up' | python3 -m json.tool | head -15

# Vérifier la déduplication HA : un seul replica par série
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=up' | python3 -m json.tool | grep replica
# → on ne voit qu'un seul replica (prom-1 ou prom-2), pas les deux
# Grâce à ha_cluster_label/ha_replica_label, le distributor ne garde qu'une copie

# Comparer avec Prometheus local
curl -s 'http://localhost:9090/api/v1/query?query=up' | python3 -m json.tool | head -15
```

## Étape 4 : Explorer dans Grafana

1. Ouvre http://localhost:3000 → Login **admin/admin**
2. Va dans **Connections → Data sources** → tu dois voir 2 datasources :
   - **Mimir** (défaut) → `http://mimir:9009/prometheus` — stockage long-terme
   - **Prometheus (local)** → `http://prometheus:9090` — rétention 5 min
3. Clique sur **Mimir** → **Save & Test** → "Successfully queried the Prometheus API"
4. Va dans **Explore** (icône compas)
5. Datasource **Mimir** → requête `up` → Run query → tu vois les métriques de toute la stack
6. Change pour **Prometheus (local)** → même requête → mêmes données mais rétention limitée

## Étape 5 : Tester la rétention long-terme

```bash
# Prometheus local : rétention 5 minutes
curl -s 'http://localhost:9090/api/v1/status/flags' | python3 -m json.tool | grep retention
# → "storage.tsdb.retention.time": "5m"

# Attends 5+ min puis compare :

# Prometheus local → peu/pas de données anciennes
curl -s 'http://localhost:9090/api/v1/query?query=up[10m]' | python3 -m json.tool | head -10

# Mimir → données toujours là (stockées dans MinIO)
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=up[10m]' | python3 -m json.tool | head -10
```

## Étape 6 : Tester la HA

```bash
# Stoppe Prometheus 1
docker stop prometheus

# Mimir reçoit toujours les données via Prometheus 2
sleep 30
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=up' | python3 -m json.tool | grep replica
# → prom-2 prend le relais

# Redémarre Prometheus 1
docker start prometheus
```

## Étape 7 : Métriques internes Mimir (self-monitoring)

```bash
# Séries actives dans Mimir
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=cortex_ingester_active_series' | python3 -m json.tool

# Samples reçus par le distributor
curl -s 'http://localhost:9009/prometheus/api/v1/query?query=cortex_distributor_received_samples_total' | python3 -m json.tool

# Dans Grafana → Explore → Mimir :
# cortex_ingester_active_series → nombre de séries actives
# cortex_distributor_received_samples_total → total des samples ingérés
```

## Étape 8 : Vérifier MinIO

1. Ouvre http://localhost:9001
2. Login **minioadmin / minioadmin**
3. Bucket **mimir-blocks** → tu vois les blocs TSDB stockés par Mimir
4. Ces blocs persistent même si Prometheus ou Mimir restart

---

# Partie 2 — Grafana Tempo

## Architecture

```
  OpenTelemetry Collector ──► Tempo ──► MinIO (S3)
         ▲                      │
         │                      │
    trace-generator            Grafana (query traces)
    (simule PgBouncer →
     HAProxy → PostgreSQL)
```

## Étape 1 : Fichiers de configuration

### tempo.yml

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
      - url: http://prometheus:9090/api/v1/write
        send_exemplars: true

overrides:
  defaults:
    metrics_generator:
      processors: [service-graphs, span-metrics]
```

**Points clés :**

| Paramètre | Rôle |
|-----------|------|
| `distributor.receivers.otlp` | Tempo reçoit les traces au format OTLP (gRPC sur 4317, HTTP sur 4318) |
| `storage.trace.backend: s3` | Stockage des traces dans MinIO |
| `metrics_generator` | Génère des métriques (latence, débit) à partir des traces et les pousse vers Prometheus |
| `processors: [service-graphs, span-metrics]` | Deux types de métriques : graphe de services et métriques par span |

### otel-collector.yml

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

L'OTel Collector reçoit les traces, les batch (regroupe), et les forward vers Tempo.

### trace-generator.py

Script Python qui simule des requêtes traversant notre stack :

```python
#!/usr/bin/env python3
"""Generates fake traces simulating PgBouncer → HAProxy → PostgreSQL flow."""
import time
import random
from opentelemetry import trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource

resource = Resource.create({
    "service.name": "pg-client-simulator",
    "service.version": "1.0.0",
    "deployment.environment": "lab"
})

provider = TracerProvider(resource=resource)
exporter = OTLPSpanExporter(endpoint="otel-collector:4317", insecure=True)
provider.add_span_processor(BatchSpanProcessor(exporter))
trace.set_tracer_provider(provider)

tracer = trace.get_tracer("pg-simulator")

OPERATIONS = [
    ("SELECT", "read", "pg-read"),
    ("INSERT", "write", "pg-write"),
    ("UPDATE", "write", "pg-write"),
    ("DELETE", "write", "pg-write"),
    ("BEGIN...COMMIT", "transaction", "pg-write"),
]

def simulate_request():
    op, op_type, haproxy_backend = random.choice(OPERATIONS)

    with tracer.start_as_current_span("client.request",
        attributes={"operation": op, "type": op_type}) as root:

        # PgBouncer span
        with tracer.start_as_current_span("pgbouncer.pool",
            attributes={"pgbouncer.pool_mode": "transaction",
                        "pgbouncer.database": "postgres"}) as pgb:
            time.sleep(random.uniform(0.001, 0.005))

            # HAProxy span
            with tracer.start_as_current_span("haproxy.route",
                attributes={"haproxy.backend": haproxy_backend,
                            "haproxy.server": f"patroni-{random.randint(1,3)}"}) as ha:
                time.sleep(random.uniform(0.001, 0.003))

                # PostgreSQL span
                with tracer.start_as_current_span("postgresql.query",
                    attributes={"db.system": "postgresql",
                                "db.operation": op,
                                "db.name": "postgres"}) as pg:

                    # Simulate query time
                    if op == "BEGIN...COMMIT":
                        time.sleep(random.uniform(0.01, 0.1))
                    else:
                        time.sleep(random.uniform(0.002, 0.02))

                    # Simulate occasional slow query
                    if random.random() < 0.05:
                        time.sleep(random.uniform(0.5, 2.0))
                        pg.set_attribute("db.slow_query", True)

                    # Simulate occasional error
                    if random.random() < 0.02:
                        pg.set_status(trace.StatusCode.ERROR, "deadlock detected")
                        pg.set_attribute("db.error", "deadlock")

if __name__ == "__main__":
    print("Trace generator started — sending traces to otel-collector:4317", flush=True)
    while True:
        simulate_request()
        time.sleep(random.uniform(0.1, 1.0))
```

### Dockerfile.tracegen

```dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir opentelemetry-api opentelemetry-sdk \
    opentelemetry-exporter-otlp-proto-grpc
COPY trace-generator.py /app/trace-generator.py
CMD ["python3", "-u", "/app/trace-generator.py"]
```

### prometheus-tempo.yml

```yaml
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']

  - job_name: 'tempo'
    static_configs:
      - targets: ['tempo:3200']
    metrics_path: /metrics
```

### grafana-tempo/provisioning/datasources/datasources.yml

```yaml
apiVersion: 1
datasources:
  - name: Tempo
    uid: tempo
    type: tempo
    access: proxy
    url: http://tempo:3200
    isDefault: false
    editable: false
    jsonData:
      tracesToMetrics:
        datasourceUid: prometheus
        tags: [{key: "service.name", value: "service"}]
      serviceMap:
        datasourceUid: prometheus
      nodeGraph:
        enabled: true
  - name: Prometheus
    uid: prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
    editable: false
```

### docker-compose-tempo.yml

```yaml
services:
  # ===== MINIO (S3) =====
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
      - tempo-net

  minio-init:
    image: minio/mc:latest
    container_name: minio-init
    entrypoint: >
      /bin/sh -c "
      sleep 5 &&
      mc alias set local http://minio:9000 minioadmin minioadmin &&
      mc mb --ignore-existing local/tempo-traces &&
      echo 'Bucket created'
      "
    networks:
      - tempo-net
    depends_on:
      - minio

  # ===== TEMPO =====
  tempo:
    image: grafana/tempo:latest
    container_name: tempo
    command:
      - --config.file=/etc/tempo/tempo.yml
    volumes:
      - ./tempo.yml:/etc/tempo/tempo.yml:ro
    ports:
      - "3200:3200"   # HTTP API
      - "4317:4317"   # OTLP gRPC
      - "4318:4318"   # OTLP HTTP
    networks:
      - tempo-net
    depends_on:
      - minio-init

  # ===== OTEL COLLECTOR =====
  otel-collector:
    image: otel/opentelemetry-collector-contrib:latest
    container_name: otel-collector
    command:
      - --config=/etc/otel/config.yml
    volumes:
      - ./otel-collector.yml:/etc/otel/config.yml:ro
    networks:
      - tempo-net
    depends_on:
      - tempo

  # ===== TRACE GENERATOR =====
  trace-generator:
    build:
      context: .
      dockerfile: Dockerfile.tracegen
    container_name: trace-generator
    networks:
      - tempo-net
    depends_on:
      - otel-collector

  # ===== PROMETHEUS (pour les span metrics) =====
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    ports:
      - "9090:9090"
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --web.enable-remote-write-receiver
      - --web.enable-lifecycle
    volumes:
      - ./prometheus-tempo.yml:/etc/prometheus/prometheus.yml:ro
    networks:
      - tempo-net

  # ===== GRAFANA =====
  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: admin
    volumes:
      - ./grafana-tempo/provisioning:/etc/grafana/provisioning:ro
    networks:
      - tempo-net

networks:
  tempo-net:
    driver: bridge
```

## Étape 2 : Démarrer la stack Tempo

```bash
mkdir -p grafana-tempo/provisioning/datasources

# Copier les fichiers :
# - tempo.yml, otel-collector.yml, prometheus-tempo.yml
# - trace-generator.py, Dockerfile.tracegen
# - grafana-tempo/provisioning/datasources/datasources.yml
# - docker-compose-tempo.yml

docker compose -f docker-compose-tempo.yml up -d --build
sleep 30
docker compose -f docker-compose-tempo.yml ps
```

## Étape 3 : Vérifier que les traces arrivent

```bash
# Tempo est ready ?
curl -s http://localhost:3200/ready
# → ready

# Le générateur envoie des traces ?
docker logs trace-generator 2>&1 | head -3
# → "Trace generator started"

# Chercher des traces dans Tempo
curl -s 'http://localhost:3200/api/search?q={}' | python3 -m json.tool | head -20
```

## Étape 4 : Explorer les traces dans Grafana

1. Ouvre http://localhost:3000 → Login **admin/admin**
2. Menu gauche → **Explore**
3. Sélectionne la datasource **Tempo**
4. **Search** → tu vois les traces du `pg-client-simulator`
5. Clique sur une trace → tu vois les **spans** imbriqués :
   - `client.request` (parent)
   - `pgbouncer.pool` (2-5ms)
   - `haproxy.route` (1-3ms)
   - `postgresql.query` (2-100ms)

### Service Graph

Dans Grafana Explore avec Tempo, active le **Service Graph** :
- Tu vois le flux : `pg-client-simulator` → `postgresql`
- Les noeuds montrent le débit et la latence

### Span Metrics

Tempo génère automatiquement des métriques à partir des traces grâce au `metrics_generator`.
Dans Grafana → Explore → Prometheus :
- `traces_spanmetrics_latency_bucket` — histogramme de latence par service
- `traces_service_graph_request_total` — requêtes par service

## Étape 5 : Trouver une trace lente

```bash
# Chercher les traces > 500ms
curl -s 'http://localhost:3200/api/search?q={duration>500ms}' | python3 -m json.tool | head -20
```

Dans Grafana → Explore → Tempo → Search :
- Filtre **Duration > 500ms**
- Tu trouveras les traces avec l'attribut `db.slow_query=true`

## Étape 6 : Trouver une trace en erreur

```bash
# Chercher les traces avec status ERROR
curl -s 'http://localhost:3200/api/search?q={status=error}' | python3 -m json.tool | head -20
```

Dans Grafana → Explore → Tempo → Search :
- Filtre **Status = Error**
- Attribut `db.error = "deadlock"` → tu vois exactement quel composant a échoué

## Étape 7 : Vérifier MinIO

1. Ouvre http://localhost:9001 → login **minioadmin / minioadmin**
2. Bucket **tempo-traces** → les traces sont stockées dans S3
3. Kill Tempo, restart → les anciennes traces sont toujours accessibles

## Étape 8 : Nettoyage

```bash
docker compose -f docker-compose-tempo.yml down -v
```

---

# Exercices

## Exercice 1 : Tester la HA Mimir

1. Stoppe `prometheus` → vérifie que Mimir reçoit toujours les données via `prometheus-2`
2. Redémarre `prometheus`, stoppe `prometheus-2` → même résultat
3. Observe dans les logs Mimir : `msg="deduplication: rejecting sample from non-elected replica"`

## Exercice 2 : Recording rules dans Mimir

1. Crée un fichier de rules et monte-le dans le volume `mimir-rules`
2. Configure une recording rule `pg:transactions_per_second`
3. Vérifie via l'API Mimir : `curl http://localhost:9009/prometheus/api/v1/rules`

## Exercice 3 : Corréler Metrics + Traces

1. Observe un pic de latence dans Grafana (datasource Mimir ou Prometheus)
2. Va dans Tempo et cherche les traces correspondant à cette période
3. Identifie quel composant cause la latence (PgBouncer ? HAProxy ? PostgreSQL ?)

## Exercice 4 : Ajouter un attribut custom aux traces

1. Modifie `trace-generator.py` pour ajouter un attribut `db.table` (ex: "orders", "users")
2. Rebuild : `docker compose -f docker-compose-tempo.yml up -d --build trace-generator`
3. Cherche les traces par table dans Grafana
