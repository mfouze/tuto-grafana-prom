# La Supervision dans un Grand SI — Théorie Complète

## Comment fonctionne la supervision de bout en bout dans une entreprise comme Transactis

---

## 1. Le contexte : un SI de grande taille

### 1.1 Qu'est-ce qu'un grand SI ?

Un **Système d'Information** (SI) de la taille de Transactis, c'est :
- Des **dizaines à centaines de serveurs** (physiques ou virtuels)
- Des **dizaines d'applications** qui communiquent entre elles
- Des **bases de données** qui stockent des données critiques (transactions financières)
- Des **flux réseau** complexes entre les composants
- Des **équipes** différentes qui gèrent différentes parties (DBA, infra, réseau, dev, sécurité)
- Des **engagements de disponibilité** (SLA) envers les clients (ex: 99.99% = max 52 minutes de panne par an)

### 1.2 Pourquoi la supervision est vitale

Sans supervision, tu es **aveugle**. Tu ne sais pas :
- Si un serveur est en train de manquer de disque
- Si la réplication PostgreSQL accumule du retard
- Si un composant est tombé il y a 10 minutes et personne ne s'en est rendu compte
- Si les performances se dégradent progressivement

**L'objectif de la supervision** : détecter les problèmes **avant** qu'ils impactent les utilisateurs, ou **immédiatement** quand ils surviennent.

```
SANS supervision :
  Client appelle → "Ça marche plus" → On cherche → On trouve → On répare
  Temps de résolution : 30 min à plusieurs heures
  Impact : perte financière, image dégradée

AVEC supervision :
  Alerte automatique → L'équipe est prévenue en 1 min → Diagnostic rapide → Réparation
  Temps de résolution : 5-15 minutes
  Impact : minimisé
```

---

## 2. Les couches de supervision

Dans un grand SI, on supervise **tout**, à **plusieurs niveaux** :

```
┌─────────────────────────────────────────────────────────────────┐
│                    COUCHE MÉTIER (Business)                      │
│  "Est-ce que les clients peuvent faire des transactions ?"      │
│  Supervision : taux de transactions/s, taux d'erreur, latence  │
├─────────────────────────────────────────────────────────────────┤
│                    COUCHE APPLICATION                            │
│  "Est-ce que les applications répondent correctement ?"         │
│  Supervision : temps de réponse API, erreurs HTTP, queues       │
├─────────────────────────────────────────────────────────────────┤
│                    COUCHE MIDDLEWARE                              │
│  "Est-ce que les composants intermédiaires fonctionnent ?"      │
│  Supervision : HAProxy, PgBouncer, message brokers              │
├─────────────────────────────────────────────────────────────────┤
│                    COUCHE DONNÉES                                │
│  "Est-ce que les bases de données fonctionnent ?"               │
│  Supervision : PostgreSQL, Patroni, etcd, réplication, backups  │
├─────────────────────────────────────────────────────────────────┤
│                    COUCHE INFRASTRUCTURE                         │
│  "Est-ce que les serveurs sont en bonne santé ?"                │
│  Supervision : CPU, RAM, disque, réseau, processus              │
├─────────────────────────────────────────────────────────────────┤
│                    COUCHE RÉSEAU                                 │
│  "Est-ce que les machines communiquent entre elles ?"           │
│  Supervision : latence réseau, perte de paquets, bande passante │
└─────────────────────────────────────────────────────────────────┘
```

**Notre intervention chez Transactis** se concentre sur les couches **Données** et **Middleware**, mais il faut comprendre que ça s'inscrit dans un ensemble plus large.

---

## 3. L'architecture de supervision chez Transactis

### 3.1 Vue d'ensemble complète

```
                                    UTILISATEURS / CLIENTS
                                           │
                                    ┌──────▼──────┐
                                    │  Applications│
                                    │  Transactis  │
                                    └──────┬──────┘
                                           │
═══════════════════════════════════════════════════════════════════
            CE QUE NOUS SUPERVISONS (notre périmètre)
═══════════════════════════════════════════════════════════════════
                                           │
                                    ┌──────▼──────┐
                                    │   HAProxy    │ ← Point d'entrée BDD
                                    │   (cluster)  │
                                    └──────┬──────┘
                                           │
                                    ┌──────▼──────┐
                                    │  PgBouncer   │ ← Pooling connexions
                                    │   (cluster)  │
                                    └──────┬──────┘
                                           │
                        ┌──────────────────┼──────────────────┐
                        │                  │                  │
                  ┌─────▼─────┐     ┌─────▼─────┐     ┌─────▼─────┐
                  │ PostgreSQL│     │ PostgreSQL│     │ PostgreSQL│
                  │ + Patroni │     │ + Patroni │     │ + Patroni │
                  │  (Leader) │     │ (Replica) │     │ (Replica) │
                  └─────┬─────┘     └─────┬─────┘     └─────┬─────┘
                        │                 │                  │
                        └─────────────────┼──────────────────┘
                                          │
                                   ┌──────▼──────┐
                                   │    etcd      │ ← Consensus
                                   │   (cluster)  │
                                   └──────────────┘

═══════════════════════════════════════════════════════════════════
                    SYSTÈME DE SUPERVISION
═══════════════════════════════════════════════════════════════════

  ┌────────────┐     scrape      ┌───────────────────────────┐
  │  Exporters │ ◄───────────────│       Prometheus          │
  │            │    /metrics     │  (collecte + stocke +     │
  │ pg_exporter│                 │   évalue les règles)      │
  │ etcd native│                 │                           │
  │ haproxy    │                 │  Prometheus-1 (instance A)│
  │ pgbouncer  │                 │  Prometheus-2 (instance B)│ ← HA
  │ node_exp.  │                 └────────┬──────────────────┘
  └────────────┘                          │
                                          │ alertes (si condition remplie)
                                          ▼
                                 ┌──────────────────┐
                                 │   Alertmanager    │
                                 │                  │
                                 │ - Route           │
                                 │ - Group           │
                                 │ - Silence          │
                                 │ - Inhibit          │
                                 └───────┬──────────┘
                                         │
                          ┌──────────────┼──────────────┐
                          │              │              │
                   ┌──────▼──────┐ ┌─────▼─────┐ ┌─────▼──────┐
                   │   LogNcall  │ │   Email   │ │   Slack    │
                   │  (astreinte)│ │           │ │            │
                   └──────┬──────┘ └───────────┘ └────────────┘
                          │
                   ┌──────▼──────┐
                   │  Ingénieur  │
                   │ d'astreinte │
                   └─────────────┘

                                 ┌──────────────────┐
                                 │ Thanos Query      │ ← Déduplication
                                 │ + Thanos Store    │ ← Requête S3
                                 │ + Thanos Compact  │ ← Downsampling
                                 └───────┬──────────┘
                                         │
                                 ┌───────▼──────────┐
                                 │     Grafana       │ ← Visualisation
                                 │   (dashboards)    │
                                 └──────────────────┘
```

### 3.2 Les acteurs du système

| Acteur | Rôle | Analogie |
|--------|------|----------|
| **Exporters** | Traducteurs : convertissent les métriques internes en format Prometheus | Des capteurs de température dans chaque pièce |
| **Prometheus** | Collecteur + cerveau : scrape, stocke et évalue les règles | Le système d'alarme central |
| **Alertmanager** | Dispatcheur : route les alertes vers les bonnes personnes | Le standard téléphonique d'urgence |
| **LogNcall** | Notificateur : appelle/SMS l'équipe d'astreinte | Le téléphone qui sonne chez le pompier |
| **Thanos** | Archiviste + dédupliqueur : gère le stockage long terme et la dédup | Les archives qui gardent l'historique |
| **Grafana** | Visualiseur : tableaux de bord pour les humains | L'écran de contrôle dans la salle de supervision |

---

## 4. Le parcours d'un incident — De bout en bout

Prenons un **scénario réaliste** : le serveur physique hébergeant le leader PostgreSQL a un disque qui lâche.

### Phase 1 : L'incident se produit (T=0)

```
14:30:00 — Le disque SSD du serveur pg-node1 commence à avoir des erreurs I/O
           PostgreSQL (leader) commence à ralentir puis crashe
           Patroni sur pg-node1 détecte que PostgreSQL est arrêté
```

### Phase 2 : Détection par les métriques (T+10s à T+30s)

```
14:30:10 — Prometheus scrape pg-node1:
           • pg_up = 0 (PostgreSQL ne répond plus)
           • node_disk_io_errors > 0 (erreurs disque)

14:30:15 — Prometheus scrape Patroni API sur pg-node1:
           • Patroni renvoie une erreur ou timeout
           • up{job="patroni", instance="pg-node1"} = 0

14:30:20 — Prometheus scrape HAProxy:
           • haproxy_server_status{server="pg-node1", backend="pg-write"} = 0
           • HAProxy a détecté que pg-node1 ne passe plus les health checks
```

### Phase 3 : Évaluation des règles d'alerte (T+30s à T+60s)

```
14:30:30 — Prometheus évalue ses règles d'alerte :

           Règle: PostgreSQLDown
           Expr:  pg_up == 0
           For:   1m
           → Condition VRAIE → État: PENDING (compteur démarre)

           Règle: PatroniDown
           Expr:  up{job="patroni"} == 0
           For:   30s
           → Condition VRAIE → État: PENDING

           Règle: HAProxyBackendDown
           Expr:  haproxy_server_status == 0
           For:   1m
           → Condition VRAIE → État: PENDING
```

### Phase 4 : Failover automatique Patroni (T+30s à T+60s)

**En parallèle** de la détection par Prometheus, Patroni gère le failover :

```
14:30:30 — Patroni sur pg-node1 ne renouvelle plus son verrou etcd
           (ttl = 30s → le verrou expire)

14:30:35 — Les agents Patroni sur pg-node2 et pg-node3 détectent
           que le verrou du leader a expiré

14:30:36 — pg-node2 a le moins de lag (0 bytes) → il tente de
           prendre le verrou dans etcd

14:30:37 — pg-node2 obtient le verrou → il se promeut LEADER
           • pg_promote() est exécuté
           • PostgreSQL sur pg-node2 passe de replica à primary
           • pg-node2 accepte maintenant les écritures

14:30:38 — pg-node3 se reconfigure pour répliquer depuis pg-node2
           (le nouveau leader)

14:30:40 — HAProxy détecte le changement :
           • Health check GET /primary sur pg-node2 → 200 OK
           • pg-node2 passe UP dans le backend pg-write
           • Le trafic est redirigé vers pg-node2
```

### Phase 5 : Les alertes passent en FIRING (T+60s à T+90s)

```
14:31:00 — L'alerte PatroniDown (for: 30s) a été pending pendant 30s
           → Passe en FIRING
           → Prometheus envoie l'alerte à Alertmanager

14:31:30 — L'alerte PostgreSQLDown (for: 1m) a été pending pendant 1m
           → Passe en FIRING
           → Prometheus envoie l'alerte à Alertmanager
```

### Phase 6 : Alertmanager traite les alertes (T+90s)

```
14:31:00 — Alertmanager reçoit l'alerte PatroniDown

           1. ROUTING :
              severity = critical → route vers receiver "logncall-critical"

           2. GROUPING :
              L'alerte est groupée avec d'autres alertes du même composant
              group_by: [alertname, component]
              group_wait: 10s → attend 10s pour voir si d'autres alertes arrivent

           3. INHIBITION :
              Vérifie les règles d'inhibition :
              - PostgreSQLDown inhibe PostgreSQLReplicationLag (même instance)
              → L'alerte de lag ne sera PAS envoyée (inutile si PG est down)

           4. SILENCE :
              Vérifie si un silence est actif pour cette alerte → non

14:31:10 — Après le group_wait de 10s, Alertmanager envoie la notification
```

### Phase 7 : LogNcall notifie l'équipe (T+100s)

```
14:31:10 — Alertmanager envoie le webhook HTTP à LogNcall :

           POST https://logncall.transactis.com/api/webhook/prometheus
           {
             "status": "firing",
             "alerts": [{
               "labels": {
                 "alertname": "PatroniDown",
                 "severity": "critical",
                 "instance": "pg-node1:8008"
               },
               "annotations": {
                 "summary": "Patroni is down on pg-node1"
               }
             }]
           }

14:31:11 — LogNcall consulte le planning d'astreinte :
           → Qui est d'astreinte cette semaine ? → Ahmed (DBA)

14:31:12 — LogNcall appelle Ahmed sur son téléphone
           → SMS : "🔴 CRITICAL - Patroni is down on pg-node1"
           → Si Ahmed ne répond pas en 5 min → escalade vers Responsable
```

### Phase 8 : L'ingénieur d'astreinte intervient (T+3min à T+15min)

```
14:33:00 — Ahmed reçoit l'appel, acquitte l'alerte dans LogNcall

14:33:30 — Ahmed se connecte au VPN et ouvre :
           • Grafana → Dashboard PostgreSQL pour voir la situation
           • Terminal SSH pour diagnostiquer

14:34:00 — Ahmed exécute son diagnostic :
           $ patronictl list
           → pg-node2 est le nouveau leader, pg-node1 est DOWN
           → Le failover a fonctionné ! ✓

           $ ssh pg-node1 dmesg | grep -i error
           → "I/O error, dev sda, sector 12345" → Disque défectueux

14:35:00 — Ahmed constate :
           • Le failover Patroni a fonctionné ✓
           • Les applications fonctionnent via pg-node2 ✓
           • pg-node1 a un problème hardware (disque)
           • Action : créer un ticket pour remplacement disque
           • Pas d'urgence immédiate (le cluster fonctionne à 2 nœuds)
```

### Phase 9 : Résolution et notification (T+variable)

```
Le lendemain — Le disque de pg-node1 est remplacé
             → Patroni reconstruit pg-node1 comme replica automatiquement
             → pg_basebackup depuis pg-node2 vers pg-node1
             → pg-node1 rejoint le cluster en streaming replication

             → Prometheus détecte : pg_up{instance="pg-node1"} = 1
             → L'alerte PostgreSQLDown passe de FIRING à RESOLVED
             → Alertmanager envoie une notification de résolution à LogNcall
             → LogNcall notifie Ahmed : "🟢 RESOLVED - pg-node1 is back"
```

### Chronologie résumée

```
T=0s      │ Disque lâche → PostgreSQL crashe
T=10s     │ Prometheus détecte pg_up=0
T=30s     │ Alertes passent en PENDING
T=35s     │ Patroni failover → pg-node2 devient leader
T=40s     │ HAProxy redirige le trafic → SERVICE RESTAURÉ
T=60-90s  │ Alertes passent en FIRING
T=90s     │ Alertmanager → LogNcall → Appel ingénieur
T=3min    │ Ingénieur acquitte et diagnostique
T=5min    │ Ingénieur confirme : failover OK, ticket hardware créé
T=24h     │ Disque remplacé → pg-node1 rejoint le cluster → RESOLVED
```

**Point clé** : le **service est restauré en ~40 secondes** grâce au failover automatique. L'intervention humaine sert à **vérifier, diagnostiquer et planifier la réparation**, pas à restaurer le service en urgence.

---

## 5. Comment Alertmanager envoie vers LogNcall — Le mécanisme technique détaillé

C'est une question essentielle : comment, concrètement, une alerte dans Prometheus finit par faire sonner le téléphone d'un ingénieur d'astreinte à 3h du matin ?

### 5.1 Le protocole : Webhook HTTP

Alertmanager et LogNcall communiquent via un **webhook HTTP**. C'est un mécanisme très simple :

```
Alertmanager  ───POST HTTP───►  LogNcall
                 (JSON)          (endpoint API)
```

Concrètement :
1. Alertmanager fait un **POST HTTP** vers une URL exposée par LogNcall
2. Le corps de la requête est un **document JSON** contenant toutes les informations de l'alerte
3. LogNcall répond avec un **code HTTP 200** pour confirmer la réception
4. Si LogNcall ne répond pas (timeout, erreur 500...) → Alertmanager **réessaie** automatiquement

C'est exactement le même mécanisme que quand tu remplis un formulaire sur un site web et que tu cliques "Envoyer" : ton navigateur fait un POST HTTP vers le serveur.

### 5.2 La configuration côté Alertmanager

Voici ce qui est configuré dans le fichier `alertmanager.yml` :

```yaml
# /etc/alertmanager/alertmanager.yml

global:
  resolve_timeout: 5m    # Si une alerte n'est plus reçue pendant 5 min → considérée résolue

# L'ARBRE DE ROUTAGE — c'est ici que tout se décide
route:
  # Regrouper les alertes par nom et composant
  # → Évite d'envoyer 10 notifications si 10 nœuds tombent en même temps
  group_by: ['alertname', 'component']

  # Attendre 30s avant d'envoyer → permet de grouper les alertes qui arrivent ensemble
  group_wait: 30s

  # Si de nouvelles alertes arrivent dans un groupe déjà notifié → attendre 5m
  group_interval: 5m

  # Si l'alerte persiste → re-notifier toutes les 4h (pas toutes les 30s !)
  repeat_interval: 4h

  # Receiver par défaut (si aucune route spécifique ne matche)
  receiver: 'email-equipe'

  # ROUTES SPÉCIFIQUES — les alertes sont matchées de haut en bas
  routes:
    # ┌─────────────────────────────────────────────────────────┐
    # │  ROUTE 1 : Alertes CRITIQUES → LogNcall (appel/SMS)   │
    # └─────────────────────────────────────────────────────────┘
    - match:
        severity: critical           # Si le label severity = critical
      receiver: 'logncall-critical'  # → envoyer vers LogNcall
      group_wait: 10s                # → attendre seulement 10s (c'est urgent !)
      repeat_interval: 1h            # → re-notifier toutes les heures si ça persiste
      continue: false                # → STOP, ne pas regarder les routes suivantes

    # ┌─────────────────────────────────────────────────────────┐
    # │  ROUTE 2 : Alertes WARNING → Email                     │
    # └─────────────────────────────────────────────────────────┘
    - match:
        severity: warning
      receiver: 'email-equipe'
      repeat_interval: 4h

    # ┌─────────────────────────────────────────────────────────┐
    # │  ROUTE 3 : Alertes spécifiques etcd → Canal Slack DBA  │
    # └─────────────────────────────────────────────────────────┘
    - match:
        component: etcd
      receiver: 'slack-dba'

# LES RECEIVERS — les destinations des alertes
receivers:
  # ══════════════════════════════════════════════════════════════
  # RECEIVER LOGNCALL — C'est ici que la magie opère
  # ══════════════════════════════════════════════════════════════
  - name: 'logncall-critical'
    webhook_configs:
      # L'URL du endpoint LogNcall
      - url: 'https://logncall.transactis.com/api/v1/webhooks/prometheus'

        # Envoyer aussi quand l'alerte est RÉSOLUE (pas seulement quand elle fire)
        send_resolved: true

        # Authentification pour sécuriser l'accès
        http_config:
          basic_auth:
            username: 'alertmanager-prod'
            password: 'un-mot-de-passe-secret'
          # OU via un token
          # authorization:
          #   type: Bearer
          #   credentials: 'token-secret-logncall'

          # Timeout de la requête HTTP
          # Si LogNcall ne répond pas en 10s → retry
          tls_config:
            insecure_skip_verify: false  # Vérifier le certificat TLS

  # ══════════════════════════════════════════════════════════════
  # RECEIVER EMAIL
  # ══════════════════════════════════════════════════════════════
  - name: 'email-equipe'
    email_configs:
      - to: 'dba-team@transactis.com'
        from: 'alertmanager@transactis.com'
        smarthost: 'smtp.transactis.com:587'
        auth_username: 'alertmanager@transactis.com'
        auth_password: 'smtp-password'
        send_resolved: true
        headers:
          Subject: '[{{ .Status | toUpper }}] {{ .GroupLabels.alertname }}'

  # ══════════════════════════════════════════════════════════════
  # RECEIVER SLACK
  # ══════════════════════════════════════════════════════════════
  - name: 'slack-dba'
    slack_configs:
      - api_url: 'https://hooks.slack.com/services/T00000/B00000/XXXXXX'
        channel: '#dba-alertes'
        title: '{{ .GroupLabels.alertname }}'
        text: '{{ .CommonAnnotations.summary }}'
        send_resolved: true

# INHIBITIONS — supprimer les alertes redondantes
inhibit_rules:
  # Si PostgreSQL est DOWN → ne pas alerter sur le lag de réplication
  # (le lag est une conséquence, pas la cause)
  - source_match:
      alertname: PostgreSQLDown
    target_match:
      alertname: PostgreSQLReplicationLag
    equal: ['instance']

  # Si HAProxy est DOWN → ne pas alerter sur les backends DOWN
  - source_match:
      alertname: HAProxyDown
    target_match:
      alertname: HAProxyBackendDown
```

### 5.3 Le payload JSON envoyé à LogNcall

Quand Alertmanager décide d'envoyer une notification, il construit un **document JSON** et l'envoie en POST HTTP à LogNcall. Voici exactement ce que LogNcall reçoit :

```json
{
  "version": "4",
  "groupKey": "{}:{alertname=\"PostgreSQLDown\", component=\"postgresql\"}",
  "truncatedAlerts": 0,
  "status": "firing",
  "receiver": "logncall-critical",
  "groupLabels": {
    "alertname": "PostgreSQLDown",
    "component": "postgresql"
  },
  "commonLabels": {
    "alertname": "PostgreSQLDown",
    "severity": "critical",
    "component": "postgresql",
    "job": "postgresql"
  },
  "commonAnnotations": {
    "summary": "PostgreSQL is down"
  },
  "externalURL": "http://alertmanager.transactis.com:9093",
  "alerts": [
    {
      "status": "firing",
      "labels": {
        "alertname": "PostgreSQLDown",
        "severity": "critical",
        "component": "postgresql",
        "instance": "pg-node1:9187",
        "job": "postgresql"
      },
      "annotations": {
        "summary": "PostgreSQL is down on pg-node1:9187",
        "description": "Le nœud PostgreSQL pg-node1 ne répond plus depuis plus d'1 minute.",
        "runbook": "https://wiki.transactis.com/runbooks/postgresql-down"
      },
      "startsAt": "2026-03-30T14:31:00.000Z",
      "endsAt": "0001-01-01T00:00:00Z",
      "generatorURL": "http://prometheus:9090/graph?g0.expr=pg_up+%3D%3D+0",
      "fingerprint": "a]b7c8d9e0f1"
    }
  ]
}
```

#### Explication de chaque champ

| Champ | Signification | Exemple |
|-------|---------------|---------|
| `version` | Version du format webhook | `"4"` |
| `status` | L'état global du groupe | `"firing"` ou `"resolved"` |
| `receiver` | Quel receiver a été choisi | `"logncall-critical"` |
| `groupLabels` | Les labels utilisés pour le regroupement | `alertname`, `component` |
| `commonLabels` | Labels communs à toutes les alertes du groupe | Partagés par toutes |
| `alerts[]` | **La liste des alertes individuelles** | Peut contenir plusieurs alertes |
| `alerts[].status` | État de cette alerte spécifique | `"firing"` |
| `alerts[].labels` | Tous les labels de l'alerte | `instance`, `severity`, etc. |
| `alerts[].annotations` | Les annotations (textes humains) | `summary`, `description`, `runbook` |
| `alerts[].startsAt` | Quand l'alerte a commencé à fire | ISO 8601 timestamp |
| `alerts[].endsAt` | Quand l'alerte s'est résolue | `0001-01-01...` = pas encore résolue |
| `alerts[].generatorURL` | Lien vers Prometheus pour voir la requête | URL clickable |
| `alerts[].fingerprint` | Identifiant unique de cette alerte | Hash |

### 5.4 Ce que LogNcall fait quand il reçoit le webhook

```
LogNcall reçoit le POST HTTP
    │
    ▼
1. PARSING du JSON
   → Extraire : alertname, severity, instance, summary, status
    │
    ▼
2. CLASSIFICATION
   → severity = "critical" → déclencher le circuit d'astreinte
   → severity = "warning" → enregistrer, notifier par email
    │
    ▼
3. CONSULTATION DU PLANNING D'ASTREINTE
   → Qui est d'astreinte en ce moment ?
   → Quel est son numéro de téléphone ?
   → Quel est le canal d'escalade ?
    │
    ▼
4. NOTIFICATION (pour les alertes critiques)
   │
   ├── Étape 1 : SMS à l'ingénieur d'astreinte
   │   "🔴 CRITICAL - PostgreSQLDown - pg-node1 - PostgreSQL is down"
   │
   ├── Étape 2 : Appel téléphonique (si pas d'acquittement en 3 min)
   │   "Bonjour, alerte critique sur le cluster PostgreSQL..."
   │
   ├── Étape 3 : ESCALADE (si pas d'acquittement en 5 min)
   │   → Appeler le responsable d'équipe
   │
   └── Étape 4 : ESCALADE N+2 (si toujours pas d'acquittement en 15 min)
       → Appeler le directeur des opérations
    │
    ▼
5. ACQUITTEMENT
   → L'ingénieur répond au SMS ou décroche le téléphone
   → Il acquitte l'alerte dans l'interface LogNcall
   → L'escalade est stoppée
    │
    ▼
6. SUIVI
   → LogNcall enregistre la timeline de l'incident :
     14:31:10 - Alerte reçue
     14:31:11 - SMS envoyé à Ahmed
     14:31:15 - SMS reçu par Ahmed
     14:33:00 - Acquittement par Ahmed
     14:35:00 - Résolution (quand le status passe à "resolved")
```

### 5.5 Le message de résolution

Quand l'incident est résolu, Alertmanager envoie un **second webhook** avec `"status": "resolved"` :

```json
{
  "status": "resolved",
  "receiver": "logncall-critical",
  "alerts": [
    {
      "status": "resolved",
      "labels": {
        "alertname": "PostgreSQLDown",
        "instance": "pg-node1:9187"
      },
      "annotations": {
        "summary": "PostgreSQL is down on pg-node1:9187"
      },
      "startsAt": "2026-03-30T14:31:00.000Z",
      "endsAt": "2026-03-31T10:15:00.000Z"
    }
  ]
}
```

LogNcall reçoit ce message → envoie une notification de résolution → clôture l'incident.

### 5.6 Schéma technique complet du flux Alertmanager → LogNcall

```
                    PROMETHEUS
                    ┌──────────────────────────────────┐
                    │                                  │
                    │  Règle d'alerte évaluée           │
                    │  expr: pg_up == 0                │
                    │  for: 1m                         │
                    │  → condition vraie depuis 1min    │
                    │  → état: FIRING                  │
                    │                                  │
                    │  POST /api/v1/alerts             │
                    │  → Alertmanager                  │
                    └───────────┬──────────────────────┘
                                │
                                │ HTTP POST (JSON avec les alertes)
                                ▼
                    ALERTMANAGER
                    ┌──────────────────────────────────┐
                    │                                  │
                    │  1. Réception de l'alerte         │
                    │                                  │
                    │  2. Routing (arbre de décision)   │
                    │     severity=critical ?           │
                    │     → OUI → receiver logncall    │
                    │                                  │
                    │  3. Grouping                      │
                    │     group_by: [alertname]         │
                    │     group_wait: 10s               │
                    │     → attendre 10s pour grouper   │
                    │                                  │
                    │  4. Inhibition                    │
                    │     PostgreSQLDown inhibe          │
                    │     PostgreSQLReplicationLag ?     │
                    │     → OUI → lag alerté supprimée  │
                    │                                  │
                    │  5. Silences                       │
                    │     Un silence actif ?             │
                    │     → NON → continuer             │
                    │                                  │
                    │  6. Envoi du webhook              │
                    │                                  │
                    └───────────┬──────────────────────┘
                                │
                                │ HTTP POST
                                │ URL: https://logncall.transactis.com/api/v1/webhooks/prometheus
                                │ Auth: Basic (alertmanager-prod:password)
                                │ Body: JSON (voir section 5.3)
                                │ Content-Type: application/json
                                ▼
                    LOGNCALL
                    ┌──────────────────────────────────┐
                    │                                  │
                    │  1. Réception du webhook          │
                    │     → HTTP 200 OK (accusé)       │
                    │                                  │
                    │  2. Parsing du JSON               │
                    │     → alertname: PostgreSQLDown   │
                    │     → severity: critical          │
                    │     → instance: pg-node1          │
                    │                                  │
                    │  3. Lookup planning astreinte     │
                    │     → Qui est d'astreinte ?       │
                    │     → Ahmed, tel: +33 6 XX XX XX │
                    │                                  │
                    │  4. Notification                  │
                    │     ┌─── SMS ──► 📱 Ahmed        │
                    │     ├─── Appel ──► 📞 Ahmed      │
                    │     └─── Email ──► 📧 Ahmed      │
                    │                                  │
                    │  5. Escalade (si pas d'acquit.)   │
                    │     └─── Appel ──► 📞 Manager    │
                    │                                  │
                    └──────────────────────────────────┘
```

### 5.7 Que se passe-t-il si LogNcall ne répond pas ?

C'est un cas critique : le système de notification est lui-même en panne.

```
Alertmanager envoie le webhook → LogNcall ne répond pas (timeout)
    │
    ▼
Alertmanager réessaie automatiquement (retry avec backoff exponentiel)
    │
    ├── Retry 1 : après 30s
    ├── Retry 2 : après 1min
    ├── Retry 3 : après 2min
    └── ... jusqu'à ce que ça marche ou que l'alerte soit résolue
```

**C'est pour ça qu'il faut "superviser le superviseur"** :

```yaml
# Alerte Watchdog : TOUJOURS active
# Si LogNcall ne la reçoit plus → LogNcall sait que la chaîne est cassée
- alert: Watchdog
  expr: vector(1)        # Toujours vrai → toujours firing
  labels:
    severity: none        # Pas de sévérité, c'est juste un heartbeat
  annotations:
    summary: "Watchdog - this alert should always be firing"
```

LogNcall attend le Watchdog toutes les X minutes. S'il ne le reçoit plus → LogNcall déclenche sa propre alerte interne ("la chaîne de monitoring est cassée").

### 5.8 Résumé : les 3 questions clés

| Question | Réponse |
|----------|---------|
| **Comment Alertmanager parle à LogNcall ?** | Via un POST HTTP (webhook) avec un body JSON contenant les alertes |
| **Comment LogNcall sait qui appeler ?** | Il consulte son planning d'astreinte interne (configuré séparément) |
| **Comment s'assurer que ça fonctionne ?** | Alerte Watchdog (heartbeat permanent) + tests réguliers du circuit |

---

## 6. Les différents types d'incidents et leur traitement

### 6.1 Matrice des incidents

| Incident | Impact utilisateur | Failover auto ? | Délai restauration | Sévérité |
|----------|-------------------|-----------------|---------------------|----------|
| **1 nœud etcd DOWN** | Aucun | N/A (quorum maintenu) | 0s | WARNING |
| **2 nœuds etcd DOWN** (perte quorum) | Aucun immédiat, mais plus de failover possible | Non | 0s (mais danger) | CRITIQUE |
| **Leader PG DOWN** | Coupure ~40s | Oui (Patroni) | ~40s | CRITIQUE |
| **1 replica PG DOWN** | Aucun (si pas de lecture sur replica) | N/A | 0s | WARNING |
| **HAProxy DOWN** | **Total** (plus de connexion) | Keepalived/VIP si configuré | 5-30s | CRITIQUE |
| **PgBouncer DOWN** | **Total** (plus de connexion poolée) | Dépend de l'architecture | 5-30s | CRITIQUE |
| **Lag réplication élevé** | Données stale sur replicas | N/A | Variable | WARNING |
| **Sauvegarde échouée** | Aucun immédiat | N/A | N/A | CRITIQUE (RPO) |
| **Disque plein (PG)** | Crash PG imminent | N/A | Variable | CRITIQUE |
| **Disque plein (etcd)** | Perte quorum etcd | N/A | Variable | CRITIQUE |

### 6.2 Arbre de décision pour le diagnostic

```
ALERTE REÇUE
    │
    ├── Quel composant ?
    │   │
    │   ├── etcd
    │   │   ├── 1 nœud down → Quorum OK ? → Oui → WARNING, planifier réparation
    │   │   └── 2+ nœuds down → URGENCE : restaurer le quorum ASAP
    │   │
    │   ├── PostgreSQL / Patroni
    │   │   ├── Leader down → Failover Patroni fait ? → Oui → Vérifier nouveau leader
    │   │   │                                        → Non → Pourquoi ? (etcd OK ? lag trop grand ?)
    │   │   ├── Replica down → Combien de replicas restants ? → ≥1 → OK, planifier
    │   │   │                                                  → 0 → WARNING (plus de HA)
    │   │   └── Lag élevé → Cause ? → Réseau / Charge / Long query sur replica
    │   │
    │   ├── HAProxy
    │   │   ├── HAProxy down → VIP basculée ? → Oui → OK, réparer l'instance
    │   │   │                                 → Non → URGENCE, restart HAProxy
    │   │   └── Backend down → Patroni a fait un failover ? → Normal
    │   │
    │   └── PgBouncer
    │       ├── PgBouncer down → Restart PgBouncer
    │       └── Pool saturé → Augmenter pool_size ou investiguer transactions longues
    │
    └── Quelle sévérité ?
        ├── CRITICAL → Action immédiate requise
        └── WARNING → Investigation dans les heures qui suivent
```

---

## 7. L'organisation humaine de la supervision

### 7.1 Les équipes

Dans un grand SI comme Transactis, la supervision implique plusieurs équipes :

```
┌─────────────────────────────────────────────────────────────┐
│                     DIRECTION DES OPÉRATIONS                 │
├─────────────┬──────────────┬──────────────┬────────────────┤
│   Équipe    │   Équipe     │   Équipe     │   Équipe       │
│    DBA      │   Infra      │   Réseau     │   Applicative  │
│             │              │              │                │
│ PostgreSQL  │ Serveurs     │ Switches     │ Applications   │
│ Patroni     │ Stockage     │ Firewalls    │ APIs           │
│ etcd        │ Virtualisation│ Load Bal.   │ Microservices  │
│ Backups     │ OS           │ DNS          │                │
├─────────────┴──────────────┴──────────────┴────────────────┤
│                    ÉQUIPE SUPERVISION / SRE                  │
│              (maintient Prometheus, Grafana, alertes)        │
│              C'est ici que s'inscrit notre intervention      │
└─────────────────────────────────────────────────────────────┘
```

### 7.2 Le planning d'astreinte

```
Semaine type d'astreinte :

Lundi     │ Ahmed (DBA) + Karim (Infra)
Mardi     │ Ahmed (DBA) + Karim (Infra)
Mercredi  │ Ahmed (DBA) + Karim (Infra)
Jeudi     │ Sophie (DBA) + Marc (Infra)
Vendredi  │ Sophie (DBA) + Marc (Infra)
Week-end  │ Sophie (DBA) + Marc (Infra)

Escalade si pas de réponse en 5 min :
  Niveau 1 : Ingénieur d'astreinte
  Niveau 2 : Responsable d'équipe
  Niveau 3 : Directeur des opérations
```

### 7.3 Les rituels de supervision

| Rituel | Fréquence | Qui | Contenu |
|--------|-----------|-----|---------|
| **Revue des alertes** | Quotidien | Équipe | Passer en revue les alertes des dernières 24h |
| **Revue de capacité** | Hebdo | DBA + Infra | Tendances disque, CPU, connexions |
| **Test de failover** | Mensuel | DBA | Switchover planifié pour valider le mécanisme |
| **Test de restauration** | Mensuel | DBA | Restaurer un backup pour valider la procédure |
| **Revue des dashboards** | Trimestriel | Supervision | Les dashboards sont-ils pertinents ? Manque-t-il des métriques ? |

---

## 8. Les niveaux de maturité de la supervision

### Niveau 1 : Réactif (le minimum)
```
"On attend que ça casse et on répare"
- Alertes basiques : UP/DOWN
- Pas de dashboards
- Pas de procédures formalisées
```

### Niveau 2 : Proactif (ce qu'on met en place)
```
"On détecte les problèmes avant qu'ils impactent"
- Alertes sur les tendances (disque qui se remplit, lag qui augmente)
- Dashboards par composant
- Procédures de réaction documentées (runbooks)
- Tests réguliers de failover
```

### Niveau 3 : Prédictif (l'objectif à terme)
```
"On anticipe les problèmes grâce aux données historiques"
- Machine learning sur les métriques
- Capacity planning automatisé
- Corrélation automatique des incidents
- Auto-remédiation (scripts qui réparent automatiquement)
```

**Notre intervention chez Transactis vise le Niveau 2** : mettre en place une supervision proactive complète avec alertes intelligentes et dashboards opérationnels.

---

## 9. Les pièges à éviter dans un grand SI

### 9.1 L'alert fatigue
```
❌ 200 alertes par jour → tout le monde les ignore
✅ 5-10 alertes par jour → chacune est importante et actionnée

Comment éviter :
- Utiliser des seuils réalistes (pas trop bas)
- Utiliser le paramètre "for" pour filtrer les faux positifs
- Utiliser les inhibitions (si PG est DOWN, pas besoin de 5 alertes différentes)
- Revoir régulièrement les alertes : si une alerte n'est jamais actionnée → la supprimer
```

### 9.2 Le monitoring sans action
```
❌ "On a un joli dashboard mais personne ne le regarde"
✅ Chaque métrique supervisée doit avoir une action associée

Pour chaque alerte, se poser la question :
1. Qui doit être prévenu ?
2. Que doit-il faire ?
3. Est-ce documenté dans un runbook ?
```

### 9.3 La duplication de supervision
```
❌ 3 outils différents qui supervisent la même chose
✅ Un outil centralisé (Prometheus) avec une source de vérité unique

Chez Transactis :
- Prometheus = collecte et alertes (source de vérité)
- Grafana = visualisation (n'alerte pas, affiche seulement)
- LogNcall = notification (ne collecte pas, notifie seulement)
→ Chaque outil a UN rôle clair
```

### 9.4 Superviser le superviseur
```
Qui surveille que Prometheus fonctionne ?
Qui surveille que Alertmanager fonctionne ?
Qui surveille que LogNcall fonctionne ?

Solutions :
- 2 instances Prometheus qui se supervisent mutuellement
- Watchdog alert : une alerte qui est TOUJOURS active → si LogNcall ne la reçoit
  plus → c'est que la chaîne est cassée
- Health checks externes (service tiers qui vérifie que tout répond)
```

---

## 10. Synthèse : le flux complet dans le SI Transactis

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                     │
│  1. COLLECTE                                                        │
│     Chaque composant expose ses métriques (/metrics)                │
│     Prometheus scrape toutes les 15 secondes                        │
│     Les données sont stockées en local (TSDB) + archivées en S3    │
│                                                                     │
│  2. DÉTECTION                                                       │
│     Prometheus évalue les règles d'alerte toutes les 15 secondes    │
│     Si une condition est vraie pendant la durée "for" → FIRING      │
│                                                                     │
│  3. ROUTAGE                                                         │
│     Alertmanager reçoit l'alerte                                    │
│     Il la route selon la sévérité :                                 │
│       CRITICAL → LogNcall (appel/SMS immédiat)                     │
│       WARNING → Email/Slack (notification différée)                 │
│     Il groupe les alertes similaires pour éviter le spam            │
│     Il inhibe les alertes redondantes                               │
│                                                                     │
│  4. NOTIFICATION                                                    │
│     LogNcall reçoit le webhook et appelle l'ingénieur d'astreinte  │
│     Si pas de réponse → escalade automatique                        │
│                                                                     │
│  5. DIAGNOSTIC                                                      │
│     L'ingénieur consulte Grafana pour comprendre la situation       │
│     Il se connecte en SSH si nécessaire                             │
│     Il suit le runbook associé à l'alerte                           │
│                                                                     │
│  6. RÉSOLUTION                                                      │
│     L'ingénieur corrige le problème                                 │
│     Les métriques reviennent à la normale                           │
│     Prometheus détecte la résolution                                │
│     Alertmanager envoie une notification RESOLVED                   │
│     LogNcall clôture l'incident                                     │
│                                                                     │
│  7. POST-MORTEM                                                     │
│     Analyse de l'incident : cause racine, timeline, actions         │
│     Amélioration : faut-il ajouter une alerte ? Modifier un seuil ?│
│     Documentation : mettre à jour le runbook                        │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 11. Glossaire

| Terme | Définition |
|-------|------------|
| **SLA** | Service Level Agreement — engagement de disponibilité (ex: 99.99%) |
| **SLO** | Service Level Objective — objectif interne de performance |
| **SLI** | Service Level Indicator — métrique qui mesure le SLO |
| **MTTR** | Mean Time To Recovery — temps moyen de restauration après panne |
| **MTTD** | Mean Time To Detect — temps moyen pour détecter un problème |
| **RTO** | Recovery Time Objective — durée max acceptable d'indisponibilité |
| **RPO** | Recovery Point Objective — perte de données max acceptable |
| **Runbook** | Procédure documentée de réaction à un incident |
| **Post-mortem** | Analyse d'un incident après sa résolution |
| **Astreinte** | Période pendant laquelle un ingénieur est joignable 24/7 |
| **Escalade** | Passage au niveau supérieur si l'incident n'est pas résolu |
| **SPOF** | Single Point of Failure — composant dont la panne arrête tout |
| **HA** | High Availability — haute disponibilité (redondance) |
| **DCS** | Distributed Configuration Store — stockage distribué (etcd) |
| **TSDB** | Time Series Database — base de données temporelle (Prometheus) |
| **Exporter** | Programme qui expose des métriques au format Prometheus |
| **Scrape** | Action de Prometheus qui collecte les métriques |
| **PromQL** | Langage de requête de Prometheus |
| **Recording Rule** | Requête PromQL pré-calculée et stockée comme nouvelle métrique |
| **Watchdog** | Alerte qui doit toujours être active pour vérifier la chaîne |
