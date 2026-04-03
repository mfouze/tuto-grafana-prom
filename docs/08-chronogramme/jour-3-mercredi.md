# Jour 3 — Mercredi 1er Avril : Patroni Switchover/Failover + HAProxy

## Chronogramme

```
09:00 ┬─────────────────────────────────────────────────────────────┐
      │  BLOC 1 : Dashboard Grafana PostgreSQL/Patroni (1h)        │
      │  • Créer le dashboard de supervision PG                    │
      │  • Panels : réplication, connexions, transactions          │
10:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 2 : Test switchover Patroni supervisé (1h30)         │
      │  • Switchover planifié avec monitoring actif                │
      │  • Vérifier les alertes, les métriques, les dashboards     │
11:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 3 : Alertes LogNcall pour Patroni switchover/        │
      │           failover (30min)                                 │
      │  • Affiner les règles pour distinguer switchover/failover  │
12:00 ┼═══════════════════ PAUSE DÉJEUNER ══════════════════════════┤
14:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 4 : Audit cluster HAProxy (1h)                       │
      │  • État actuel, configuration, backends                    │
      │  • Activer les métriques Prometheus                        │
15:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 5 : Alertes HAProxy + LogNcall (1h30)                │
      │  • Règles d'alerte HAProxy                                 │
      │  • Configurer dans Alertmanager                            │
16:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 6 : Dashboard Grafana HAProxy + tests (1h30)         │
      │  • Dashboard HAProxy                                       │
      │  • Test failover backend et vérification alertes           │
18:00 ┴─────────────────────────────────────────────────────────────┘
```

---

## BLOC 1 — Dashboard Grafana PostgreSQL/Patroni (09:00-10:00)

### Actions

#### 1.1 Créer le dashboard PostgreSQL dans Grafana

Se connecter à Grafana, créer un nouveau dashboard "PostgreSQL / Patroni — Supervision".

**Row 1 : Vue d'ensemble cluster**

| Panel | Type | Query PromQL |
|-------|------|-------------|
| Cluster Has Leader | Stat | `count(patroni_primary == 1)` |
| Nombre de nœuds UP | Stat | `count(up{job="postgresql"} == 1)` |
| Leader actuel | Table | `patroni_primary == 1` |
| Lag max réplication | Stat | `max(pg_stat_replication_replay_lag)` |

**Row 2 : Réplication**

| Panel | Type | Query PromQL |
|-------|------|-------------|
| Lag par replica (graph) | Time series | `pg_stat_replication_replay_lag` |
| État réplication | Table | `pg_stat_replication_replay_lag` avec labels |

**Row 3 : Connexions**

| Panel | Type | Query PromQL |
|-------|------|-------------|
| Connexions totales | Time series | `sum by (instance) (pg_stat_activity_count)` |
| Ratio connexions/max | Gauge | `pg:connections_usage_ratio` |
| Connexions par état | Time series | `pg_stat_activity_count` by state |

**Row 4 : Performance**

| Panel | Type | Query PromQL |
|-------|------|-------------|
| Transactions/s | Time series | `pg:transactions_per_second` |
| Cache hit ratio | Stat | `pg:cache_hit_ratio` |
| Taille des bases | Table | `pg_database_size_bytes` |

**Row 5 : Sauvegardes**

| Panel | Type | Query PromQL |
|-------|------|-------------|
| Âge dernière backup | Stat | `pgbackrest_last_backup_age_seconds / 3600` (en heures) |
| WAL archiving failed | Stat | `pg_stat_archiver_failed_count` |

### Livrable
- [ ] Dashboard PostgreSQL/Patroni créé dans Grafana
- [ ] Tous les panels fonctionnels avec des données

---

## BLOC 2 — Test switchover Patroni supervisé (10:00-11:30)

### Objectif
Faire un switchover planifié et observer le comportement de bout en bout dans le monitoring.

### Actions

#### 2.1 Préparer l'observation
Ouvrir en parallèle :
- **Terminal 1** : `watch -n 2 "patronictl list"` (état du cluster)
- **Navigateur tab 1** : Grafana — Dashboard PostgreSQL/Patroni
- **Navigateur tab 2** : Prometheus — page Alerts
- **Navigateur tab 3** : HAProxy — page Stats (http://haproxy:8404/stats)

#### 2.2 Vérifier les conditions avant le switchover
```bash
patronictl list
# → Tous les nœuds en "running" / "streaming"
# → Lag = 0 sur tous les replicas

# Vérifier qu'il n'y a pas de transactions longues
sudo -u postgres psql -c "
SELECT pid, now() - xact_start AS duration, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL AND state != 'idle'
ORDER BY duration DESC;
"
```

#### 2.3 Exécuter le switchover
```bash
# Noter l'heure exacte
date  # → ___________

# Exécuter le switchover
patronictl switchover --candidate pg-node2 --force

# Observer :
# 1. patronictl list → les rôles changent
# 2. Grafana → le panel "Leader actuel" change
# 3. Prometheus → l'alerte PatroniFailoverDetected peut flasher brièvement
# 4. HAProxy stats → les backends basculent (UP/DOWN changent)
```

#### 2.4 Mesurer et documenter
```
SWITCHOVER TEST
Heure début : ___________
Heure fin (nouveau leader UP) : ___________
Durée totale d'indisponibilité : ___________ secondes

Ancien leader : ___________ → nouveau rôle : ___________
Nouveau leader : ___________
Lag après switchover : ___________

Alertes déclenchées : OUI / NON
  Si oui, lesquelles : ___________
  Résolution automatique : OUI / NON

HAProxy : temps de bascule : ___________ secondes

Problèmes observés :
- ___________
```

#### 2.5 Valider la continuité des données
```bash
# Créer une table de test avant le switchover
sudo -u postgres psql -c "CREATE TABLE IF NOT EXISTS switchover_test (id serial, ts timestamp default now(), node text);"
sudo -u postgres psql -c "INSERT INTO switchover_test (node) VALUES ('avant switchover');"

# Après le switchover, vérifier sur le nouveau leader
sudo -u postgres psql -c "SELECT * FROM switchover_test;"
sudo -u postgres psql -c "INSERT INTO switchover_test (node) VALUES ('après switchover');"
sudo -u postgres psql -c "SELECT * FROM switchover_test;"
```

### Livrable
- [ ] Switchover exécuté avec succès
- [ ] Durée d'indisponibilité mesurée
- [ ] Comportement du monitoring documenté

---

## BLOC 3 — Affiner les alertes Patroni (11:30-12:00)

### Actions

Après avoir observé le switchover, affiner les alertes pour éviter les faux positifs :

```yaml
# Ajuster le PatroniFailoverDetected pour ne pas alerter sur les switchovers planifiés
# Option : augmenter le "for" pour ne pas alerter sur les bascules courtes

- alert: PatroniUnexpectedFailover
  expr: changes(patroni_primary[5m]) > 0
  for: 0s
  labels:
    severity: warning
    component: patroni
  annotations:
    summary: "Changement de leader Patroni détecté"
    description: >
      Un switchover ou failover vient de se produire.
      Vérifier si c'est planifié. Si non planifié → investiguer immédiatement.
      patronictl list pour voir l'état actuel.
```

### Livrable
- [ ] Alertes Patroni affinées après observation du switchover

---

## BLOC 4 — Audit cluster HAProxy (13:00-14:00)

### Actions

#### 4.1 État actuel de HAProxy
```bash
ssh user@haproxy-node1

# Version et état
haproxy -v
systemctl status haproxy

# Configuration
cat /etc/haproxy/haproxy.cfg

# Noter :
# - Frontends configurés (ports) : ___________
# - Backends configurés : ___________
# - Mode de health check : ___________
# - Stats page activée ? ___________
```

#### 4.2 Vérifier la page de statistiques
```bash
# Accéder à la page stats dans le navigateur
# http://haproxy-node1:8404/stats (ou le port configuré)

# Ou en ligne de commande
echo "show stat" | socat stdio /var/run/haproxy.sock | column -t -s,
```

**Noter :**
- [ ] Backends pg-write : combien UP ? ___________
- [ ] Backends pg-read : combien UP ? ___________
- [ ] Nombre de connexions actives : ___________

#### 4.3 Activer les métriques Prometheus (si pas déjà fait)
Dans `/etc/haproxy/haproxy.cfg`, ajouter :
```cfg
frontend prometheus
    bind *:8405
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    no log
```

```bash
# Vérifier la syntaxe
haproxy -c -f /etc/haproxy/haproxy.cfg

# Recharger HAProxy (sans coupure)
sudo systemctl reload haproxy

# Vérifier les métriques
curl -s http://localhost:8405/metrics | head -30
```

#### 4.4 Ajouter HAProxy dans Prometheus
```yaml
  - job_name: 'haproxy'
    scrape_interval: 15s
    static_configs:
      - targets:
        - 'haproxy-node1:8405'
        # Si cluster HAProxy :
        # - 'haproxy-node2:8405'
```

```bash
curl -X POST http://prometheus:9090/-/reload
# Vérifier dans Targets → haproxy UP
```

### Livrable
- [ ] HAProxy audité et documenté
- [ ] Métriques Prometheus activées
- [ ] Target HAProxy UP dans Prometheus

---

## BLOC 5 — Alertes HAProxy + LogNcall (14:00-15:30)

### Actions

Créer `/etc/prometheus/rules/haproxy-alerts.yml` :

```yaml
groups:
  - name: haproxy_health
    rules:
      # CRITIQUE : HAProxy est injoignable
      - alert: HAProxyDown
        expr: up{job="haproxy"} == 0
        for: 30s
        labels:
          severity: critical
          component: haproxy
          team: dba
        annotations:
          summary: "HAProxy DOWN sur {{ $labels.instance }}"
          description: >
            HAProxy ne répond plus. Les applications ne peuvent plus
            accéder à PostgreSQL !
          runbook: "https://wiki.transactis.com/runbooks/haproxy-down"

      # CRITIQUE : aucun backend d'écriture disponible
      - alert: HAProxyNoWriteBackend
        expr: haproxy_backend_active_servers{proxy="pg-write"} == 0
        for: 15s
        labels:
          severity: critical
          component: haproxy
          team: dba
        annotations:
          summary: "Aucun backend d'écriture disponible dans HAProxy"
          description: >
            Le backend pg-write n'a plus aucun serveur actif.
            Aucune écriture PostgreSQL possible !

      # CRITIQUE : aucun backend de lecture disponible
      - alert: HAProxyNoReadBackend
        expr: haproxy_backend_active_servers{proxy="pg-read"} == 0
        for: 15s
        labels:
          severity: critical
          component: haproxy
          team: dba
        annotations:
          summary: "Aucun backend de lecture disponible dans HAProxy"

      # WARNING : un backend est DOWN
      - alert: HAProxyBackendDown
        expr: haproxy_server_status{proxy=~"pg-.*"} == 0
        for: 1m
        labels:
          severity: warning
          component: haproxy
          team: dba
        annotations:
          summary: "Backend {{ $labels.server }} DOWN dans {{ $labels.proxy }}"

      # WARNING : sessions proches du max
      - alert: HAProxySessionsHigh
        expr: haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions > 0.8
        for: 5m
        labels:
          severity: warning
          component: haproxy
          team: dba
        annotations:
          summary: "Sessions HAProxy > 80% de la limite"

      # WARNING : erreurs de connexion backend
      - alert: HAProxyBackendErrors
        expr: rate(haproxy_backend_connection_errors_total[5m]) > 1
        for: 5m
        labels:
          severity: warning
          component: haproxy
          team: dba
        annotations:
          summary: "Erreurs de connexion backend HAProxy"

  - name: haproxy_recording
    rules:
      - record: haproxy:backend_active_ratio
        expr: haproxy_backend_active_servers / haproxy_backend_servers_total

      - record: haproxy:sessions_usage_ratio
        expr: haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions
```

```bash
promtool check rules /etc/prometheus/rules/haproxy-alerts.yml
curl -X POST http://localhost:9090/-/reload
```

Mettre à jour Alertmanager avec les inhibitions :
```yaml
inhibit_rules:
  # Si HAProxy est DOWN → pas besoin d'alerter sur les backends
  - source_match:
      alertname: HAProxyDown
    target_match_re:
      alertname: HAProxy(BackendDown|NoWriteBackend|NoReadBackend)
```

### Livrable
- [ ] Alertes HAProxy configurées
- [ ] Inhibitions ajoutées dans Alertmanager

---

## BLOC 6 — Dashboard Grafana HAProxy + Tests (15:30-17:00)

### Actions

#### 6.1 Dashboard HAProxy dans Grafana

**Row 1 : Vue d'ensemble**

| Panel | Type | Query |
|-------|------|-------|
| HAProxy UP | Stat | `up{job="haproxy"}` |
| Backends Write actifs | Stat | `haproxy_backend_active_servers{proxy="pg-write"}` |
| Backends Read actifs | Stat | `haproxy_backend_active_servers{proxy="pg-read"}` |

**Row 2 : Sessions**

| Panel | Type | Query |
|-------|------|-------|
| Sessions courantes | Time series | `haproxy_frontend_current_sessions` |
| Ratio sessions/limit | Gauge | `haproxy:sessions_usage_ratio` |

**Row 3 : Backends**

| Panel | Type | Query |
|-------|------|-------|
| État des serveurs | Table | `haproxy_server_status` |
| Connexions par backend | Time series | `haproxy_server_current_sessions` |
| Erreurs backend | Time series | `rate(haproxy_backend_connection_errors_total[5m])` |

#### 6.2 Test : observer un switchover dans HAProxy
```bash
# Faire un switchover Patroni et observer dans le dashboard HAProxy
patronictl switchover --candidate pg-node1 --force

# Observer :
# → Les backends pg-write changent (ancien leader → DOWN, nouveau → UP)
# → Les backends pg-read se réorganisent
# → L'alerte HAProxyBackendDown peut se déclencher brièvement
```

#### 6.3 Documenter

```
VALIDATION JOUR 3 — Patroni Switchover/Failover + HAProxy
Date : 01/04/2026

1. Switchover Patroni
   - [ ] Switchover exécuté avec succès
   - [ ] Durée indisponibilité mesurée : ___________
   - [ ] Alertes observées : ___________
   - [ ] Dashboard Grafana reflète le changement

2. HAProxy
   - [ ] Métriques Prometheus activées et scrapées
   - [ ] Alertes configurées
   - [ ] Dashboard Grafana créé
   - [ ] Bascule backends observée lors du switchover

3. LogNcall
   - [ ] Alertes HAProxy routées vers LogNcall

Problèmes rencontrés :
- ___________

Actions pour demain :
- ___________
```

### Livrable
- [ ] Dashboard HAProxy opérationnel
- [ ] Tests de bascule effectués et documentés
- [ ] Jour 3 validé
