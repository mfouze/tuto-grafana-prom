# Tutoriel Pratique : Alerting & LogNcall sur Docker

## Prérequis
- Docker et Docker Compose installés
- Avoir fait le tutoriel Prometheus/Grafana Partie 1 (`docs/05-prometheus-grafana/tutoriel-docker.md`)
- Avoir lu le cours Alerting/LogNcall

## Objectifs
1. Configurer des alertes pour **tous les composants** (etcd, Patroni, PostgreSQL, HAProxy, PgBouncer)
2. Configurer Alertmanager avec webhook (simulation LogNcall) **et envoi d'emails**
3. Configurer les **inhibition rules** (éviter les cascades d'alertes)
4. Simuler des pannes et observer le circuit complet : panne → Prometheus → Alertmanager → LogNcall/Email → résolution

---

## Architecture du circuit d'alerte

```
  Panne (docker kill patroni-1)
    │
    ▼
  Prometheus scrape toutes les 15s
    │ condition vraie ?
    ▼
  Alerte passe en PENDING (attente du "for: 30s")
    │ toujours vraie après 30s ?
    ▼
  Alerte passe en FIRING
    │
    ▼
  Alertmanager reçoit l'alerte
    │ groupement par (alertname, component)
    │ inhibition rules (EtcdDown inhibe PatroniNoLeader)
    │
    ├──► severity: critical → Webhook LogNcall + Email
    ├──► severity: warning  → Email uniquement
    │
    ▼
  Incident résolu → Alertmanager envoie RESOLVED (webhook + email)
```

> **MailHog** est utilise comme serveur SMTP local dans le lab. Il capture les emails
> et les affiche dans une interface web sur http://localhost:8025. Aucun email ne sort
> reellement du lab.

---

## Étape 1 : Fichiers de configuration

### rules/all-alerts.yml

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

      - alert: EtcdHighLeaderChanges
        expr: increase(etcd_server_leader_changes_seen_total[10m]) > 3
        for: 1m
        labels:
          severity: warning
          component: etcd
        annotations:
          summary: "etcd leader changes too frequently"

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

      - alert: PostgreSQLReplicationLagCritical
        expr: pg_replication_lag > 10
        for: 30s
        labels:
          severity: critical
          component: postgresql
        annotations:
          summary: "Replication lag {{ $value }}s"

      - alert: PostgreSQLSlowQueries
        expr: pg_slow_queries_count > 0
        for: 1m
        labels:
          severity: warning
          component: postgresql
        annotations:
          summary: "{{ $value }} queries running > 5 minutes"

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

      - alert: HAProxyBackendDown
        expr: haproxy_server_status{proxy=~"pg-.*"} == 0
        for: 30s
        labels:
          severity: warning
          component: haproxy
        annotations:
          summary: "HAProxy backend {{ $labels.server }} DOWN in {{ $labels.proxy }}"

  # ==================== PGBOUNCER ====================
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
          summary: "Disk usage > 85% on {{ $labels.instance }}"

      - alert: NodeDiskCritical
        expr: (1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) > 0.95
        for: 2m
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Disk usage > 95% on {{ $labels.instance }} — risk of service crash"

      - alert: NodeMemoryHigh
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "Memory usage > 90% on {{ $labels.instance }}"

      - alert: NodeMemoryCritical
        expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.95
        for: 2m
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Memory usage > 95% on {{ $labels.instance }} — OOM killer risk"

      - alert: NodeCPUHigh
        expr: (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.9
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "CPU usage > 90% on {{ $labels.instance }}"

      - alert: NodeDown
        expr: up{job="node"} == 0
        for: 30s
        labels:
          severity: critical
          component: node
        annotations:
          summary: "Node exporter {{ $labels.instance }} is DOWN"

      - alert: NodeNetworkErrors
        expr: increase(node_network_receive_errs_total[5m]) > 0 or increase(node_network_transmit_errs_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "Network errors detected on {{ $labels.instance }} ({{ $labels.device }})"

      - alert: NodeFileDescriptorsHigh
        expr: node_filefd_allocated / node_filefd_maximum > 0.8
        for: 5m
        labels:
          severity: warning
          component: node
        annotations:
          summary: "File descriptors > 80% on {{ $labels.instance }}"
```

### alertmanager.yml

```yaml
global:
  resolve_timeout: 2m
  # SMTP : MailHog en local (capture les emails sans les envoyer)
  smtp_smarthost: 'mailhog:1025'
  smtp_from: 'alertmanager@transactis-lab.local'
  smtp_require_tls: false

# Template HTML externe pour les emails
templates:
  - '/etc/alertmanager/templates/*.tmpl'

route:
  group_by: ['alertname', 'component']
  group_wait: 10s
  group_interval: 30s
  repeat_interval: 5m
  receiver: 'email-all'
  routes:
    # CRITICAL → webhook LogNcall + email
    - match:
        severity: critical
      receiver: 'logncall-critical'
      group_wait: 5s
      continue: true      # continue = true → passe aussi au receiver suivant
    # Tout → email (catch-all, y compris critical grace au continue)
    - receiver: 'email-all'

receivers:
  # Webhook LogNcall (pour les critiques)
  - name: 'logncall-critical'
    webhook_configs:
      - url: 'http://webhook-logger:8080/alert'
        send_resolved: true

  # Email pour toutes les alertes (utilise le template HTML)
  - name: 'email-all'
    email_configs:
      - to: 'dba-team@transactis-lab.local'
        send_resolved: true
        headers:
          Subject: '{{ template "email.custom.subject" . }}'
        html: '{{ template "email.custom.html" . }}'

# Inhibition : si un composant parent est down, on supprime les alertes dependantes
inhibit_rules:
  # Si etcd est down → pas besoin d'alerter sur PatroniNoLeader (il ne peut pas elire)
  - source_matchers: ['alertname = EtcdDown']
    target_matchers: ['alertname = PatroniNoLeader']

  # Si HAProxy est down → pas besoin d'alerter sur chaque backend individuel
  - source_matchers: ['alertname = HAProxyDown']
    target_matchers: ['alertname =~ "HAProxy.*Backend.*"']

  # Si Patroni est down → pas besoin d'alerter sur PostgreSQL exporter (il passe par HAProxy)
  - source_matchers: ['alertname = PatroniDown']
    target_matchers: ['alertname = PostgreSQLDown']
```

**Comment ca marche :**
- **`continue: true`** sur la route critical : l'alerte est d'abord envoyee au webhook LogNcall, puis continue vers le receiver suivant (email)
- Les alertes **warning** vont directement au receiver email (pas de webhook)
- Les alertes **critical** vont aux deux (webhook + email)
- **MailHog** capture tous les emails localement. Rien ne sort du lab

> **Inhibition rules** : quand `EtcdDown` est en firing, `PatroniNoLeader` est
> automatiquement supprime. Ca evite les cascades d'alertes inutiles.

### alertmanager-templates/email.tmpl

Template HTML pour les emails d'alerte. Header colore (rouge=firing, vert=resolved),
badges de severite, tableau des alertes, liens vers les outils.

```html
{{ define "email.custom.subject" }}[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }} — {{ .GroupLabels.component }}{{ end }}

{{ define "email.custom.html" }}
<!DOCTYPE html>
<html>
<head>
<style>
  body { font-family: Arial, sans-serif; background: #f4f4f4; padding: 20px; }
  .container { max-width: 700px; margin: 0 auto; background: #fff; border-radius: 8px;
               overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }
  .header-firing { background: #e74c3c; color: #fff; padding: 20px 30px; }
  .header-resolved { background: #27ae60; color: #fff; padding: 20px 30px; }
  .header h1 { margin: 0; font-size: 22px; }
  .header p { margin: 5px 0 0; opacity: 0.9; font-size: 14px; }
  .content { padding: 20px 30px; }
  table { width: 100%; border-collapse: collapse; margin: 15px 0; }
  th { background: #34495e; color: #fff; padding: 10px 12px; text-align: left; font-size: 13px; }
  td { padding: 10px 12px; border-bottom: 1px solid #eee; font-size: 13px; }
  tr:hover td { background: #f9f9f9; }
  .badge { display: inline-block; padding: 3px 10px; border-radius: 12px;
           font-size: 12px; font-weight: bold; color: #fff; }
  .badge-critical { background: #e74c3c; }
  .badge-warning { background: #f39c12; }
  .footer { padding: 15px 30px; background: #f8f8f8; border-top: 1px solid #eee;
            font-size: 12px; color: #888; }
  .footer a { color: #3498db; text-decoration: none; }
</style>
</head>
<body>
<div class="container">

  {{ if eq .Status "firing" }}
  <div class="header-firing">
    <h1>ALERTE — {{ .GroupLabels.alertname }}</h1>
    <p>Composant : {{ .GroupLabels.component }} |
       {{ .Alerts.Firing | len }} alerte(s) active(s)</p>
  </div>
  {{ else }}
  <div class="header-resolved">
    <h1>RESOLUE — {{ .GroupLabels.alertname }}</h1>
    <p>Composant : {{ .GroupLabels.component }} |
       {{ .Alerts.Resolved | len }} alerte(s) resolue(s)</p>
  </div>
  {{ end }}

  <div class="content">

    {{ if .Alerts.Firing }}
    <h3 style="color: #e74c3c;">En cours</h3>
    <table>
      <tr><th>Alerte</th><th>Severite</th><th>Instance</th><th>Description</th></tr>
      {{ range .Alerts.Firing }}
      <tr>
        <td><strong>{{ .Labels.alertname }}</strong></td>
        <td>
          {{ if eq .Labels.severity "critical" }}<span class="badge badge-critical">CRITICAL</span>
          {{ else }}<span class="badge badge-warning">WARNING</span>{{ end }}
        </td>
        <td>{{ .Labels.instance }}</td>
        <td>{{ .Annotations.summary }}</td>
      </tr>
      {{ end }}
    </table>
    {{ end }}

    {{ if .Alerts.Resolved }}
    <h3 style="color: #27ae60;">Resolue(s)</h3>
    <table>
      <tr><th>Alerte</th><th>Severite</th><th>Instance</th><th>Description</th></tr>
      {{ range .Alerts.Resolved }}
      <tr>
        <td><strong>{{ .Labels.alertname }}</strong></td>
        <td>
          {{ if eq .Labels.severity "critical" }}<span class="badge badge-critical">CRITICAL</span>
          {{ else }}<span class="badge badge-warning">WARNING</span>{{ end }}
        </td>
        <td>{{ .Labels.instance }}</td>
        <td>{{ .Annotations.summary }}</td>
      </tr>
      {{ end }}
    </table>
    {{ end }}

  </div>

  <div class="footer">
    <a href="http://localhost:9093">Alertmanager</a> |
    <a href="http://localhost:9090/alerts">Prometheus Alerts</a> |
    <a href="http://localhost:3000">Grafana</a>
  </div>

</div>
</body>
</html>
{{ end }}
```

### webhook-server.py (simule LogNcall)

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

### Dockerfile.webhook

```dockerfile
FROM python:3.12-slim
COPY webhook-server.py /app/webhook-server.py
CMD ["python3", "-u", "/app/webhook-server.py"]
```

### prometheus.yml

```yaml
global:
  scrape_interval: 15s
  evaluation_interval: 15s
  external_labels:
    cluster: lab
    replica: prom-1

rule_files:
  - /etc/prometheus/rules/*.yml

alerting:
  alertmanagers:
    - static_configs:
        - targets: ['alertmanager:9093']

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

## Étape 2 : Docker Compose

Crée `docker-compose-alerting.yml` — reprend toute la stack + Alertmanager + webhook :

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
      - --initial-cluster-token=alert-lab
      - --metrics=extensive
    networks:
      - alert-net

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
      - --initial-cluster-token=alert-lab
      - --metrics=extensive
    networks:
      - alert-net

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
      - --initial-cluster-token=alert-lab
      - --metrics=extensive
    networks:
      - alert-net

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
      - alert-net

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
      - alert-net

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
      - alert-net

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
      - alert-net
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
      - alert-net
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
    networks:
      - alert-net
    depends_on:
      - haproxy

  pgbouncer-exporter:
    image: prometheuscommunity/pgbouncer-exporter:latest
    container_name: pgbouncer-exporter
    command:
      - --pgBouncer.connectionString=postgres://postgres:postgres@pgbouncer:6432/pgbouncer?sslmode=disable
    networks:
      - alert-net
    depends_on:
      - pgbouncer

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
      - --storage.tsdb.retention.time=1d
      - --storage.tsdb.wal-compression
      - --web.enable-lifecycle
    networks:
      - alert-net

  # ==================== ALERTMANAGER ====================
  alertmanager:
    image: prom/alertmanager:latest
    container_name: alertmanager
    ports:
      - "9093:9093"
    volumes:
      - ./alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro
      - ./alertmanager-templates:/etc/alertmanager/templates:ro
    networks:
      - alert-net

  # ==================== WEBHOOK LOGGER (LogNcall) ====================
  webhook-logger:
    build:
      context: .
      dockerfile: Dockerfile.webhook
    container_name: webhook-logger
    hostname: webhook-logger
    networks:
      - alert-net

  # ==================== MAILHOG (serveur SMTP local) ====================
  mailhog:
    image: mailhog/mailhog:latest
    container_name: mailhog
    hostname: mailhog
    ports:
      - "8025:8025"    # Interface web (consulter les emails)
      - "1025:1025"    # SMTP (Alertmanager envoie ici)
    networks:
      - alert-net

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
      - alert-net

networks:
  alert-net:
    driver: bridge
```

## Étape 3 : Démarrer

```bash
mkdir -p rules alertmanager-templates
# Copier : prometheus.yml, alertmanager.yml, haproxy.cfg, queries.yml,
#          rules/all-alerts.yml, alertmanager-templates/email.tmpl,
#          webhook-server.py, Dockerfile.webhook

docker compose -f docker-compose-alerting.yml up -d --build
sleep 45
docker compose -f docker-compose-alerting.yml ps
docker exec -it patroni-1 patronictl list
```

## Étape 4 : Vérifier la configuration

### 4.1 Prometheus
1. Ouvre **http://localhost:9090** → **Status → Targets**
2. Tous les jobs UP : etcd (3), patroni (3), postgres (1), haproxy (1), pgbouncer (1)
3. **Alerts** → toutes les alertes en état `inactive` (vert)

### 4.2 Alertmanager
1. Ouvre **http://localhost:9093**
2. L'UI est vide (pas d'alerte en cours)

### 4.3 Webhook logger
```bash
docker logs -f webhook-logger
# → "Webhook logger (LogNcall simulator) ready on :8080"
```

### 4.4 MailHog (emails)
1. Ouvre **http://localhost:8025**
2. L'inbox est vide (pas d'alerte en cours)
3. Quand une alerte se declenchera, l'email apparaitra ici automatiquement

---

## Étape 5 : Scénario 1 — Kill etcd (circuit d'alerte simple)

### 5.1 Ouvrir 4 fenetres

- **Fenetre 1** : http://localhost:9090/alerts (Prometheus)
- **Fenetre 2** : http://localhost:9093 (Alertmanager)
- **Fenetre 3** : `docker logs -f webhook-logger`
- **Fenetre 4** : http://localhost:8025 (MailHog — emails)

### 5.2 Provoquer

```bash
docker stop etcd-3
```

### 5.3 Observer le circuit

| Temps | Où | Ce qui se passe |
|---|---|---|
| +0s | Prometheus | `EtcdDown` condition vraie, passe en **pending** |
| +30s | Prometheus | `EtcdDown` passe en **firing** (for: 30s écoulé) |
| +35s | Alertmanager | Reçoit l'alerte, la groupe par `(alertname, component)` |
| +40s | Webhook | Recoit la notification FIRING |
| +40s | MailHog | Recoit l'email FIRING |

```
============================================================
[14:30:45] ALERT - Status: firing
============================================================
  [FIRING] EtcdDown | critical | etcd
          etcd etcd-3:2379 is DOWN
============================================================
```

Dans **MailHog** (http://localhost:8025), tu recois un email avec :
- **Sujet** : `[FIRING] EtcdDown — etcd`
- **Corps** : tableau HTML avec l'alerte, la severite, l'instance et la description

### 5.4 Résoudre

```bash
docker start etcd-3
```

Observer :
- Prometheus : alerte repasse en `inactive`
- Webhook : notification `RESOLVED`

```
  [RESOLVED] EtcdDown | critical | etcd
             etcd etcd-3:2379 is DOWN
```

## Étape 6 : Scénario 2 — Kill le leader PG (alertes multiples)

```bash
# Identifier le leader
docker exec -it patroni-1 patronictl list

# Kill le leader (supposons patroni-1)
docker kill patroni-1
```

Observer dans le webhook logger — **plusieurs alertes** arrivent :

```
[FIRING] PatroniDown | critical | patroni
        Patroni patroni-1:8008 is DOWN

[FIRING] HAProxyBackendDown | warning | haproxy
        HAProxy backend patroni-1 DOWN in pg-write

[FIRING] PatroniFailoverDetected | warning | patroni
        Patroni failover detected — leadership changed
```

Après le failover (~30s), HAProxy bascule → le nouveau leader prend le relais.

```bash
# Restaurer
docker start patroni-1
sleep 15
docker exec -it patroni-2 patronictl list
# → Toutes les alertes se résolvent
```

## Étape 7 : Scénario 3 — Inhibition rules (cascade de pannes)

Ce scénario teste les **inhibition rules** : quand etcd tombe, `PatroniNoLeader` ne doit PAS être notifié (inhibé).

```bash
# Arrêter 2 etcd → perte de quorum
docker stop etcd-2 etcd-3
```

Observer dans le webhook logger :

```
[FIRING] EtcdDown | critical | etcd           ← envoyé
        etcd etcd-2:2379 is DOWN

[FIRING] EtcdDown | critical | etcd           ← envoyé
        etcd etcd-3:2379 is DOWN

# PatroniNoLeader ne sera PAS envoyé au webhook
# car inhibé par EtcdDown (cf. inhibit_rules dans alertmanager.yml)
```

Vérifier dans Alertmanager (http://localhost:9093) :
- `EtcdDown` est affiché (firing)
- `PatroniNoLeader` est **inhibé** (visible dans Prometheus mais pas envoyé)

```bash
# Restaurer
docker start etcd-2 etcd-3
```

## Étape 8 : Scénario 4 — Kill HAProxy (tout le trafic coupé)

```bash
docker stop haproxy
```

Observer :
- `HAProxyDown` (critical) → webhook
- `PostgreSQLDown` (inhibé par PatroniDown dans certains cas)
- PgBouncer ne peut plus atteindre PG → erreurs mais PgBouncer lui-même reste UP

```bash
docker start haproxy
# → Tout se reconnecte automatiquement
```

## Étape 9 : Scénario 5 — Saturation PgBouncer

```bash
export PGPASSWORD=postgres

# Lancer 30 connexions longues (pool_size = 10)
for i in $(seq 1 30); do
    psql -h localhost -p 6432 -U postgres -c "SELECT pg_sleep(15);" &
done

# Observer dans le webhook après ~1 min :
# [FIRING] PgBouncerClientsWaiting | warning | pgbouncer
#          PgBouncer 20 clients waiting
```

## Étape 10 : Explorer Alertmanager

### 10.1 Silencer une alerte
1. Provoque une alerte (`docker stop etcd-3`)
2. Ouvre http://localhost:9093
3. Clique sur **Silence** à côté de l'alerte
4. Remplis : durée = 10m, commentaire = "test silence"
5. Pendant le silence → pas de notification au webhook
6. Le silence expire → la notification reprend

### 10.2 Voir les silences actifs
Onglet **Silences** dans Alertmanager

### 10.3 Comprendre le groupement
Les alertes sont groupées par `alertname` + `component`. Si 2 etcd tombent en même temps, tu reçois **une seule notification** contenant les 2 alertes (pas 2 notifications séparées).

```bash
# Restaurer
docker start etcd-3
```

## Étape 11 : Nettoyage

```bash
docker compose -f docker-compose-alerting.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Circuit complet chronométré
1. Démarre le lab
2. Note l'heure exacte
3. Kill un nœud etcd
4. Note l'heure à laquelle le webhook reçoit l'alerte
5. Calcule le délai total : `scrape_interval (15s) + for (30s) + group_wait (10s)` ≈ 55s

### Exercice 2 : Ajouter une alerte custom
1. Ajoute une alerte `EtcdDatabaseSizeLarge` si la taille dépasse 1 MB
2. Recharge Prometheus : `curl -X POST http://localhost:9090/-/reload`
3. Écris des données dans etcd pour faire grossir la base :
   ```bash
   for i in $(seq 1 10000); do
     docker exec etcd-1 etcdctl put /test/key$i "value-$i-$(date)"
   done
   ```
4. Observe le déclenchement dans le webhook

### Exercice 3 : Tester les inhibitions
1. Stop 2 etcd (perte de quorum)
2. Vérifie dans Prometheus que `PatroniNoLeader` est en firing
3. Vérifie dans Alertmanager que `PatroniNoLeader` n'est **pas** envoyé au webhook
4. Vérifie dans les logs webhook que seul `EtcdDown` est reçu
5. Restaure les etcd et vérifie la résolution

### Exercice 4 : Routing avancé (2 receivers)
1. Duplique le webhook-logger sur un 2ème port (8081)
2. Configure Alertmanager avec 2 receivers :
   - `critical-receiver` → webhook port 8080
   - `warning-receiver` → webhook port 8081
3. Provoque des alertes critical et warning
4. Vérifie que chaque receiver reçoit uniquement son niveau
