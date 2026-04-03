# Jour 1 — Lundi 30 Mars : Supervision etcd + Alertes LogNcall

## Chronogramme

```
09:00 ┬─────────────────────────────────────────────────────────────┐
      │  BLOC 1 : Prise en main de l'environnement (1h)            │
      │  • Accès aux serveurs, VPN, SSH                             │
      │  • Inventaire des machines et rôles                         │
10:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 2 : Audit du cluster etcd (1h30)                     │
      │  • Vérifier l'état actuel du cluster                        │
      │  • Identifier la version, la topologie, les ports           │
      │  • Vérifier les métriques existantes                        │
11:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 3 : Configuration Prometheus pour etcd (30min)        │
      │  • Ajouter/vérifier les scrape targets etcd                 │
12:00 ┼═══════════════════ PAUSE DÉJEUNER ══════════════════════════┤
14:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 4 : Règles d'alerte etcd dans Prometheus (1h30)       │
      │  • Créer les fichiers de rules                              │
      │  • Tester les expressions PromQL                            │
15:30 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 5 : Configuration Alertmanager → LogNcall (1h30)      │
      │  • Configurer le receiver webhook LogNcall                  │
      │  • Configurer le routing pour les alertes etcd              │
17:00 ┼─────────────────────────────────────────────────────────────┤
      │  BLOC 6 : Tests et validation (1h)                          │
      │  • Simuler une panne etcd (ou tester en staging)            │
      │  • Vérifier la réception dans LogNcall                      │
      │  • Documenter                                               │
18:00 ┴─────────────────────────────────────────────────────────────┘
```

---

## BLOC 1 — Prise en main de l'environnement (09:00-10:00)

### Objectif
Se familiariser avec l'infrastructure, obtenir tous les accès, comprendre la topologie.

### Actions

#### 1.1 Obtenir les accès
```bash
# Vérifier l'accès SSH à chaque serveur
ssh user@etcd-node1
ssh user@etcd-node2
ssh user@etcd-node3
ssh user@pg-node1
ssh user@pg-node2
ssh user@pg-node3
ssh user@prometheus-server
ssh user@grafana-server
```

#### 1.2 Inventorier les machines
Créer un fichier d'inventaire (à compléter sur place) :

| Rôle | Hostname | IP | OS | CPU | RAM | Disque |
|------|----------|----|----|-----|-----|--------|
| etcd-1 | | | | | | |
| etcd-2 | | | | | | |
| etcd-3 | | | | | | |
| pg-node1 (Patroni) | | | | | | |
| pg-node2 (Patroni) | | | | | | |
| pg-node3 (Patroni) | | | | | | |
| HAProxy-1 | | | | | | |
| HAProxy-2 | | | | | | |
| PgBouncer-1 | | | | | | |
| PgBouncer-2 | | | | | | |
| Prometheus | | | | | | |
| Grafana | | | | | | |

#### 1.3 Vérifier les outils déjà en place
```bash
# Sur le serveur Prometheus
systemctl status prometheus
prometheus --version
cat /etc/prometheus/prometheus.yml

# Grafana
systemctl status grafana-server
# Ouvrir l'URL Grafana dans le navigateur

# Alertmanager (s'il est déjà installé)
systemctl status alertmanager
cat /etc/alertmanager/alertmanager.yml
```

### Livrable
- [ ] Fichier d'inventaire rempli
- [ ] Tous les accès SSH fonctionnels
- [ ] Version et état de chaque composant noté

---

## BLOC 2 — Audit du cluster etcd (10:00-11:30)

### Objectif
Comprendre l'état actuel du cluster etcd, documenter sa configuration, identifier les éventuels problèmes.

### Actions

#### 2.1 État du cluster
```bash
# Se connecter sur un nœud etcd
ssh user@etcd-node1

# Version d'etcd
etcd --version
etcdctl version

# Santé du cluster
etcdctl endpoint health --cluster
# Attendu : les 3 endpoints sont healthy

# Liste des membres
etcdctl member list -w table

# Statut détaillé (qui est leader, taille DB, etc.)
etcdctl endpoint status --cluster -w table
```

**Noter :**
- [ ] Version d'etcd : ___________
- [ ] Nombre de membres : ___________
- [ ] Qui est le leader : ___________
- [ ] Taille de la DB par nœud : ___________
- [ ] Les 3 nœuds sont-ils healthy ? ___________

#### 2.2 Configuration actuelle
```bash
# Trouver le fichier de configuration
cat /etc/etcd/etcd.conf.yml
# OU
cat /etc/default/etcd
# OU
systemctl cat etcd | grep ExecStart  # voir les flags de démarrage
```

**Paramètres à noter :**
- [ ] `heartbeat-interval` : ___________
- [ ] `election-timeout` : ___________
- [ ] `quota-backend-bytes` : ___________
- [ ] `auto-compaction-retention` : ___________
- [ ] `metrics` (doit être `extensive`) : ___________
- [ ] Ports client/peer : ___________

#### 2.3 Vérifier que les métriques sont exposées
```bash
# Les métriques doivent être accessibles sur le port client
curl -s http://etcd-node1:2379/metrics | head -20

# Si ça ne marche pas, vérifier que --metrics=extensive est configuré
curl -s http://etcd-node1:2379/metrics | wc -l
# Attendu : > 200 lignes de métriques
```

#### 2.4 Vérifier les clés Patroni dans etcd
```bash
# Patroni stocke ses données dans etcd
etcdctl get /patroni/ --prefix --keys-only
# Ou selon le namespace configuré :
etcdctl get /service/ --prefix --keys-only

# Voir les données du cluster Patroni
etcdctl get /patroni/pg-cluster/leader
etcdctl get /patroni/pg-cluster/members/ --prefix
```

### Livrable
- [ ] Document d'audit etcd rempli
- [ ] Problèmes identifiés listés (s'il y en a)
- [ ] Métriques accessibles confirmé

---

## BLOC 3 — Configuration Prometheus pour etcd (11:30-12:00)

### Objectif
S'assurer que Prometheus scrape correctement les métriques etcd.

### Actions

#### 3.1 Vérifier ou ajouter le job etcd dans Prometheus
```bash
ssh user@prometheus-server
sudo vim /etc/prometheus/prometheus.yml
```

Ajouter ou vérifier la section :
```yaml
scrape_configs:
  # ... jobs existants ...

  - job_name: 'etcd'
    scrape_interval: 15s
    static_configs:
      - targets:
        - 'etcd-node1:2379'
        - 'etcd-node2:2379'
        - 'etcd-node3:2379'
        labels:
          cluster: 'transactis-prod'
          environment: 'production'
```

#### 3.2 Recharger Prometheus
```bash
# Vérifier la syntaxe avant de recharger
promtool check config /etc/prometheus/prometheus.yml

# Recharger sans redémarrer (si --web.enable-lifecycle est activé)
curl -X POST http://localhost:9090/-/reload

# OU redémarrer le service
sudo systemctl reload prometheus
```

#### 3.3 Vérifier dans l'UI Prometheus
- Ouvrir `http://prometheus-server:9090/targets`
- Le job `etcd` doit apparaître avec 3 targets en état **UP**
- Tester une requête : `etcd_server_has_leader`

### Livrable
- [ ] Job etcd configuré dans prometheus.yml
- [ ] 3 targets etcd en état UP dans Prometheus

---

## BLOC 4 — Règles d'alerte etcd (13:00-14:30)

### Objectif
Créer les règles d'alerte pour détecter tous les problèmes etcd.

### Actions

#### 4.1 Créer le fichier de rules
```bash
sudo vim /etc/prometheus/rules/etcd-alerts.yml
```

```yaml
groups:
  - name: etcd_cluster_health
    rules:
      # ══════════════════════════════════════════
      # ALERTES CRITIQUES
      # ══════════════════════════════════════════

      # Un nœud etcd n'a plus de leader
      - alert: EtcdNoLeader
        expr: etcd_server_has_leader == 0
        for: 1m
        labels:
          severity: critical
          component: etcd
          team: dba
        annotations:
          summary: "etcd {{ $labels.instance }} n'a plus de leader"
          description: >
            Le nœud etcd {{ $labels.instance }} ne voit plus de leader
            depuis plus d'1 minute. Risque de perte de quorum.
          runbook: "https://wiki.transactis.com/runbooks/etcd-no-leader"

      # Un nœud etcd est injoignable
      - alert: EtcdDown
        expr: up{job="etcd"} == 0
        for: 1m
        labels:
          severity: critical
          component: etcd
          team: dba
        annotations:
          summary: "etcd {{ $labels.instance }} est injoignable"
          description: >
            Prometheus ne peut plus scraper les métriques de {{ $labels.instance }}.
            Le nœud est peut-être arrêté ou injoignable réseau.
          runbook: "https://wiki.transactis.com/runbooks/etcd-down"

      # Propositions Raft échouent
      - alert: EtcdProposalsFailing
        expr: rate(etcd_server_proposals_failed_total[5m]) > 0
        for: 5m
        labels:
          severity: critical
          component: etcd
          team: dba
        annotations:
          summary: "Propositions Raft en échec sur {{ $labels.instance }}"
          description: >
            Des propositions de consensus Raft échouent, signe que le cluster
            etcd a des difficultés à atteindre un consensus.

      # ══════════════════════════════════════════
      # ALERTES WARNING
      # ══════════════════════════════════════════

      # Changements de leader fréquents
      - alert: EtcdHighLeaderChanges
        expr: increase(etcd_server_leader_changes_seen_total[1h]) > 3
        for: 5m
        labels:
          severity: warning
          component: etcd
          team: dba
        annotations:
          summary: "Changements de leader etcd trop fréquents"
          description: >
            Plus de 3 changements de leader en 1 heure.
            Causes possibles : réseau instable, disque lent, CPU saturé.

      # Latence disque élevée
      - alert: EtcdDiskLatencyHigh
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.1
        for: 5m
        labels:
          severity: warning
          component: etcd
          team: dba
        annotations:
          summary: "Latence disque etcd élevée sur {{ $labels.instance }}"
          description: >
            La latence d'écriture WAL p99 dépasse 100ms sur {{ $labels.instance }}.
            etcd a besoin de disques rapides (SSD recommandé).

      # Base etcd trop grande
      - alert: EtcdDatabaseSizeLarge
        expr: etcd_mvcc_db_total_size_in_bytes > 6442450944
        for: 10m
        labels:
          severity: warning
          component: etcd
          team: dba
        annotations:
          summary: "Base etcd > 6GB sur {{ $labels.instance }}"
          description: >
            La base etcd fait {{ $value | humanize1024 }}.
            Une compaction et défragmentation sont nécessaires.

      # Propositions en attente (signe de surcharge)
      - alert: EtcdProposalsPending
        expr: etcd_server_proposals_pending > 5
        for: 5m
        labels:
          severity: warning
          component: etcd
          team: dba
        annotations:
          summary: "Propositions Raft en attente sur {{ $labels.instance }}"
          description: >
            {{ $value }} propositions en attente. Le cluster est peut-être
            surchargé ou un nœud est lent.

      # Échecs réseau entre les pairs
      - alert: EtcdPeerCommunicationFailing
        expr: rate(etcd_network_peer_sent_failures_total[5m]) > 0
        for: 5m
        labels:
          severity: warning
          component: etcd
          team: dba
        annotations:
          summary: "Échecs de communication entre pairs etcd"
          description: >
            Des échecs de communication réseau entre les nœuds etcd sont détectés.
            Vérifier le réseau entre les nœuds.

  # ══════════════════════════════════════════
  # RECORDING RULES (pré-calculs)
  # ══════════════════════════════════════════
  - name: etcd_recording_rules
    rules:
      - record: etcd:wal_fsync_duration_p99
        expr: histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

      - record: etcd:backend_commit_duration_p99
        expr: histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m]))

      - record: etcd:peer_round_trip_time_p99
        expr: histogram_quantile(0.99, rate(etcd_network_peer_round_trip_time_seconds_bucket[5m]))

      - record: etcd:leader_changes_rate_1h
        expr: increase(etcd_server_leader_changes_seen_total[1h])
```

#### 4.2 Valider la syntaxe
```bash
promtool check rules /etc/prometheus/rules/etcd-alerts.yml
# Attendu : SUCCESS

# Tester les expressions PromQL dans l'UI Prometheus avant de déployer
# Ouvrir http://prometheus:9090 et tester chaque expr manuellement
```

#### 4.3 Recharger Prometheus
```bash
curl -X POST http://localhost:9090/-/reload
```

#### 4.4 Vérifier les alertes dans Prometheus
- Ouvrir `http://prometheus:9090/alerts`
- Toutes les alertes etcd doivent apparaître en état **inactive** (vert)

### Livrable
- [ ] Fichier `/etc/prometheus/rules/etcd-alerts.yml` créé et validé
- [ ] Alertes visibles dans l'UI Prometheus
- [ ] Recording rules fonctionnelles

---

## BLOC 5 — Configuration Alertmanager → LogNcall (14:30-16:00)

### Objectif
Configurer Alertmanager pour router les alertes critiques etcd vers LogNcall.

### Actions

#### 5.1 Vérifier / installer Alertmanager
```bash
ssh user@prometheus-server

# Vérifier s'il est installé
alertmanager --version
systemctl status alertmanager

# S'il n'est pas installé :
# Suivre la documentation d'installation Alertmanager
# https://prometheus.io/download/#alertmanager
```

#### 5.2 Configurer Alertmanager
```bash
sudo vim /etc/alertmanager/alertmanager.yml
```

```yaml
global:
  resolve_timeout: 5m

route:
  group_by: ['alertname', 'component']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  receiver: 'default-email'

  routes:
    # Alertes CRITIQUES → LogNcall
    - match:
        severity: critical
      receiver: 'logncall-critical'
      group_wait: 10s
      repeat_interval: 1h

    # Alertes WARNING → Email
    - match:
        severity: warning
      receiver: 'default-email'

receivers:
  - name: 'logncall-critical'
    webhook_configs:
      - url: 'https://logncall.transactis.com/api/v1/webhooks/prometheus'
        # ^^^ REMPLACER par l'URL réelle fournie par l'équipe Transactis
        send_resolved: true
        http_config:
          basic_auth:
            username: 'alertmanager'
            password: 'MOT_DE_PASSE_A_DEMANDER'
            # ^^^ DEMANDER les credentials à l'équipe Transactis

  - name: 'default-email'
    email_configs:
      - to: 'dba-team@transactis.com'
        # ^^^ REMPLACER par l'adresse réelle
        from: 'alertmanager@transactis.com'
        smarthost: 'smtp.transactis.com:587'
        # ^^^ DEMANDER la config SMTP à l'équipe
        send_resolved: true

inhibit_rules:
  # Ne pas alerter sur les problèmes réseau etcd si etcd est DOWN
  - source_match:
      alertname: EtcdDown
    target_match:
      alertname: EtcdPeerCommunicationFailing
    equal: ['instance']
```

> **IMPORTANT** : Les URLs, mots de passe et adresses email sont à obtenir auprès de l'équipe Transactis le jour J. Préparer la liste des informations à demander.

#### 5.3 Informations à demander à l'équipe Transactis
- [ ] URL du webhook LogNcall
- [ ] Credentials d'authentification LogNcall (user/password ou token)
- [ ] Adresse email de l'équipe DBA
- [ ] Configuration SMTP (serveur, port, credentials)
- [ ] Y a-t-il un canal Slack à configurer ?
- [ ] Quel est le planning d'astreinte dans LogNcall ?

#### 5.4 Valider et démarrer Alertmanager
```bash
# Vérifier la syntaxe
amtool check-config /etc/alertmanager/alertmanager.yml

# Redémarrer Alertmanager
sudo systemctl restart alertmanager
sudo systemctl status alertmanager

# Vérifier l'UI
# Ouvrir http://alertmanager-server:9093
```

#### 5.5 Connecter Prometheus à Alertmanager
Vérifier dans `/etc/prometheus/prometheus.yml` :
```yaml
alerting:
  alertmanagers:
    - static_configs:
        - targets:
          - 'localhost:9093'  # ou alertmanager-server:9093
```

```bash
curl -X POST http://localhost:9090/-/reload
```

### Livrable
- [ ] Alertmanager configuré avec le receiver LogNcall
- [ ] Alertmanager démarré et joignable sur :9093
- [ ] Prometheus connecté à Alertmanager
- [ ] Credentials LogNcall obtenus et configurés

---

## BLOC 6 — Tests et validation (16:00-17:00)

### Objectif
Valider que le circuit complet fonctionne : métrique → alerte → LogNcall.

### Actions

#### 6.1 Test 1 : Vérifier les alertes dans Prometheus
```bash
# Ouvrir http://prometheus:9090/alerts
# Toutes les alertes doivent être en état "inactive"
# Si une est en "firing" → investiguer (il y a peut-être un vrai problème !)
```

#### 6.2 Test 2 : Envoyer une alerte de test à Alertmanager
```bash
# Envoyer une alerte manuelle à Alertmanager pour tester le circuit
curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[
    {
      "labels": {
        "alertname": "TestAlerte",
        "severity": "critical",
        "component": "etcd",
        "instance": "test"
      },
      "annotations": {
        "summary": "Alerte de test — à ignorer",
        "description": "Test du circuit Alertmanager → LogNcall"
      }
    }
  ]'

# Vérifier dans l'UI Alertmanager : http://localhost:9093
# L'alerte doit apparaître

# Vérifier que LogNcall a bien reçu la notification
# → Demander à l'équipe de vérifier dans l'interface LogNcall

# Résoudre l'alerte de test (envoyer avec endsAt dans le passé)
curl -X POST http://localhost:9093/api/v1/alerts \
  -H 'Content-Type: application/json' \
  -d '[
    {
      "labels": {
        "alertname": "TestAlerte",
        "severity": "critical",
        "component": "etcd",
        "instance": "test"
      },
      "endsAt": "2026-03-30T00:00:00.000Z"
    }
  ]'
```

#### 6.3 Test 3 : Test réaliste (si environnement de staging dispo)
```bash
# UNIQUEMENT si un environnement de staging est disponible :
# Arrêter temporairement un nœud etcd non-leader

# 1. Identifier le leader
etcdctl endpoint status --cluster -w table

# 2. Arrêter un follower (PAS le leader !)
sudo systemctl stop etcd  # sur le follower

# 3. Observer dans Prometheus → l'alerte EtcdDown passe en pending puis firing
# 4. Observer dans Alertmanager → l'alerte est routée
# 5. Observer dans LogNcall → la notification est reçue

# 6. Redémarrer le nœud
sudo systemctl start etcd

# 7. Observer → l'alerte passe en resolved
```

> **ATTENTION** : Ne JAMAIS tester sur la production sans accord explicite. Demander s'il y a un environnement de staging.

#### 6.4 Documenter
Créer un document de validation :

```
VALIDATION JOUR 1 — etcd
Date : 30/03/2026

1. Cluster etcd
   - [ ] 3 nœuds healthy
   - [ ] Leader identifié : ___________
   - [ ] Métriques exposées sur :2379/metrics

2. Prometheus
   - [ ] Job etcd configuré, 3 targets UP
   - [ ] Rules etcd chargées (X alertes, Y recording rules)
   - [ ] Toutes les alertes en état inactive

3. Alertmanager
   - [ ] Configuré avec receiver LogNcall
   - [ ] Connecté à Prometheus
   - [ ] Test d'alerte manuelle : ✓ / ✗

4. LogNcall
   - [ ] Webhook fonctionnel
   - [ ] Notification reçue lors du test
   - [ ] Résolution reçue lors du test

Problèmes rencontrés :
- ___________
- ___________

Actions pour demain :
- ___________
- ___________
```

### Livrable
- [ ] Circuit d'alerte testé de bout en bout
- [ ] Document de validation rempli
- [ ] Problèmes éventuels notés pour résolution
