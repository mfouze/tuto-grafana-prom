# PostgreSQL, Réplication & Patroni — Cours Complet pour Débutants

## Partie 1 : PostgreSQL — Les Bases

### 1.1 C'est quoi PostgreSQL ?
PostgreSQL (souvent "PG" ou "Postgres") est un **système de gestion de base de données relationnelle** (SGBDR) open source. C'est l'un des plus robustes et des plus utilisés au monde.

### 1.2 Concepts clés pour la supervision

#### Connexions
Chaque client qui se connecte à PostgreSQL crée un **processus backend** dédié. Chaque processus consomme de la mémoire (~10 MB).

```sql
-- Voir les connexions actives
SELECT datname, usename, state, query, backend_start
FROM pg_stat_activity
WHERE state != 'idle'
ORDER BY backend_start;

-- Compter les connexions par état
SELECT state, count(*)
FROM pg_stat_activity
GROUP BY state;
```

**Paramètre clé** : `max_connections` (par défaut 100). Si on atteint cette limite → plus aucun client ne peut se connecter → panne applicative.

#### Transactions
Une transaction est un ensemble d'opérations SQL qui s'exécutent de manière atomique (tout ou rien).

```sql
-- Transaction longue = danger ! Elle bloque les locks et empêche le vacuum
SELECT pid, now() - xact_start AS duration, query
FROM pg_stat_activity
WHERE xact_start IS NOT NULL
ORDER BY duration DESC;
```

#### Locks (verrous)
PostgreSQL utilise des verrous pour gérer les accès concurrents. Des locks qui s'accumulent = signe de problème.

```sql
-- Voir les locks en attente
SELECT blocked.pid AS blocked_pid,
       blocking.pid AS blocking_pid,
       blocked.query AS blocked_query
FROM pg_stat_activity blocked
JOIN pg_locks bl ON bl.pid = blocked.pid
JOIN pg_locks bbl ON bbl.relation = bl.relation AND bbl.pid != bl.pid
JOIN pg_stat_activity blocking ON blocking.pid = bbl.pid
WHERE NOT bl.granted;
```

#### VACUUM
PostgreSQL ne supprime pas physiquement les lignes effacées (il les marque comme "mortes"). Le **VACUUM** nettoie ces lignes mortes et récupère l'espace.

```sql
-- Voir les tables qui ont besoin de vacuum
SELECT schemaname, relname, n_dead_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC;
```

### 1.3 Les WAL (Write-Ahead Logs)

Les WAL sont le journal de transactions de PostgreSQL. **Chaque modification est d'abord écrite dans les WAL avant d'être appliquée aux fichiers de données.**

Pourquoi c'est important :
- **Récupération après crash** : PostgreSQL rejoue les WAL pour retrouver un état cohérent
- **Réplication** : les WAL sont envoyés aux réplicas pour les maintenir à jour
- **Sauvegarde PITR** : on peut restaurer à n'importe quel point dans le temps en rejouant les WAL

```sql
-- Voir la position actuelle dans les WAL
SELECT pg_current_wal_lsn();

-- Voir le WAL courant
SELECT pg_walfile_name(pg_current_wal_lsn());
```

---

## Partie 2 : Réplication PostgreSQL

### 2.1 Streaming Replication

La réplication streaming est le mécanisme natif de PostgreSQL pour maintenir des copies (réplicas) synchronisées.

```
┌──────────────┐   WAL stream   ┌──────────────┐
│   Primary    │ ──────────────►│   Replica 1   │
│  (Leader)    │                │  (Standby)    │
│              │   WAL stream   ├──────────────┐│
│  Écritures   │ ──────────────►│   Replica 2   │
│  Lectures    │                │  (Standby)    │
└──────────────┘                └──────────────┘
                                  Lectures only
```

**Primary (Leader)** : accepte les lectures ET les écritures
**Replica (Standby)** : accepte uniquement les lectures, reçoit les WAL du primary

### 2.2 Réplication synchrone vs asynchrone

| | Asynchrone | Synchrone |
|---|---|---|
| **Principe** | Le primary n'attend pas la confirmation du replica | Le primary attend que le replica confirme |
| **Performance** | Rapide (pas d'attente) | Plus lent (latence réseau) |
| **Perte de données** | Possible (données pas encore répliquées) | Zéro perte (garantie) |
| **Utilisation** | Par défaut | Pour les données critiques |

### 2.3 Le lag de réplication

Le **lag** est le retard entre le primary et un replica. C'est LA métrique la plus importante à surveiller.

```sql
-- Sur le PRIMARY : voir l'état de la réplication
SELECT client_addr,
       state,
       sent_lsn,
       write_lsn,
       flush_lsn,
       replay_lsn,
       write_lag,
       flush_lag,
       replay_lag
FROM pg_stat_replication;
```

**Pourquoi le lag est critique :**
- Si le lag est élevé et qu'un failover se produit → le nouveau leader a des données obsolètes → perte de données
- Les applications qui lisent sur les réplicas voient des données en retard

**Causes courantes de lag :**
1. Réseau lent entre primary et replica
2. Replica surchargé (trop de requêtes de lecture)
3. Disque lent sur le replica
4. Requête longue sur le replica qui bloque le replay des WAL

### 2.4 Vérifier la réplication depuis le replica

```sql
-- Sur le REPLICA : suis-je en recovery ?
SELECT pg_is_in_recovery();  -- true = je suis un replica

-- Position actuelle du replay
SELECT pg_last_wal_receive_lsn(),
       pg_last_wal_replay_lsn(),
       pg_last_xact_replay_timestamp();
```

---

## Partie 3 : pgBackRest — Sauvegarde & Restauration

### 3.1 C'est quoi pgBackRest ?
pgBackRest est un outil de sauvegarde pour PostgreSQL. Il supporte :
- **Sauvegarde Full** : copie complète de la base
- **Sauvegarde Differential** : uniquement ce qui a changé depuis le dernier full
- **Sauvegarde Incremental** : uniquement ce qui a changé depuis la dernière sauvegarde (full, diff ou incr)
- **PITR** (Point-In-Time Recovery) : restauration à un instant précis grâce aux WAL archivés

### 3.2 Architecture pgBackRest

```
┌──────────┐     WAL archive     ┌──────────────────┐
│ Primary  │ ───────────────────►│  Backup Storage   │
│ PG       │     pgbackrest      │  (local ou S3)    │
│          │     backup           │                  │
│          │ ───────────────────►│  Full backups     │
└──────────┘                     │  Diff backups     │
                                 │  Incr backups     │
                                 │  WAL archives     │
                                 └──────────────────┘
```

### 3.3 Commandes pgBackRest essentielles

```bash
# Voir l'état des sauvegardes
pgbackrest info

# Résultat typique :
# stanza: main
#     status: ok
#     cipher: none
#
#     db (current)
#         wal archive min/max (16): 000000010000000000000001/00000001000000000000000A
#
#         full backup: 20260325-020000F
#             timestamp start/stop: 2026-03-25 02:00:00+00 / 2026-03-25 02:15:30+00
#             database size: 5.2GB, database backup size: 5.2GB
#
#         diff backup: 20260325-020000F_20260326-020000D
#             timestamp start/stop: 2026-03-26 02:00:00+00 / 2026-03-26 02:02:15+00
#             database size: 5.3GB, database backup size: 150MB

# Vérifier la configuration
pgbackrest check

# Lancer une sauvegarde manuelle
pgbackrest backup --stanza=main --type=full
pgbackrest backup --stanza=main --type=diff
```

### 3.4 Métriques à surveiller pour pgBackRest

| Ce qu'il faut vérifier | Comment | Seuil |
|---|---|---|
| Dernière sauvegarde full réussie | `pgbackrest info` → timestamp | < 7 jours |
| Dernière sauvegarde diff réussie | `pgbackrest info` → timestamp | < 24h |
| WAL archiving actif | `pg_stat_archiver` → `last_archived_wal` | récent |
| Échecs d'archivage WAL | `pg_stat_archiver` → `failed_count` | == 0 |
| Espace stockage backup | `df -h` ou métriques S3 | < 80% |

```sql
-- Vérifier l'état de l'archivage WAL
SELECT archived_count, failed_count,
       last_archived_wal, last_archived_time,
       last_failed_wal, last_failed_time
FROM pg_stat_archiver;
```

---

## Partie 4 : Patroni — Haute Disponibilité PostgreSQL

### 4.1 C'est quoi Patroni ?
Patroni est un **orchestrateur de haute disponibilité** pour PostgreSQL. Il automatise :
- L'élection du leader PostgreSQL
- Le failover automatique en cas de panne du leader
- Le switchover planifié pour la maintenance
- La gestion de la configuration PostgreSQL

### 4.2 Comment Patroni fonctionne

```
┌──────────┐     ┌──────────┐     ┌──────────┐
│ Patroni  │     │ Patroni  │     │ Patroni  │
│ Agent 1  │     │ Agent 2  │     │ Agent 3  │
│          │     │          │     │          │
│ PG Node1 │     │ PG Node2 │     │ PG Node3 │
│ (Leader) │     │ (Replica)│     │ (Replica)│
└────┬─────┘     └────┬─────┘     └────┬─────┘
     │                │                │
     └────────────────┼────────────────┘
                      │
               ┌──────▼──────┐
               │    etcd     │  ← DCS (Distributed Config Store)
               └─────────────┘
```

1. Chaque nœud PostgreSQL a un **agent Patroni** qui tourne à côté
2. Patroni écrit dans etcd : "je suis vivant" (heartbeat)
3. Le leader Patroni tient un **verrou** dans etcd
4. Si le leader ne renouvelle pas son verrou → les replicas tentent de prendre le verrou → **failover**

### 4.3 États d'un nœud Patroni

| État | Signification |
|------|---------------|
| `running` | Le nœud fonctionne normalement |
| `streaming` | Le replica reçoit les WAL en streaming |
| `in archive recovery` | Le replica récupère des WAL depuis les archives |
| `stopped` | PostgreSQL est arrêté |
| `start failed` | PostgreSQL n'a pas pu démarrer |
| `creating replica` | Un replica est en cours de création (base backup) |

### 4.4 Commandes patronictl essentielles

```bash
# Voir l'état du cluster
patronictl list
# Résultat :
# + Cluster: pg-cluster (7329449584387654321) ---+----+-----------+
# | Member | Host    | Role    | State   | TL | Lag in MB |
# +--------+---------+---------+---------+----+-----------+
# | node1  | 10.0.1.1| Leader  | running |  3 |           |
# | node2  | 10.0.1.2| Replica | streaming|  3 |         0 |
# | node3  | 10.0.1.3| Replica | streaming|  3 |         0 |
# +--------+---------+---------+---------+----+-----------+

# Voir la configuration du cluster
patronictl show-config

# Éditer la configuration
patronictl edit-config

# Voir l'historique des événements
patronictl history
```

### 4.5 Switchover (bascule planifiée)

Un switchover est une **bascule volontaire** du leader vers un replica. On fait ça pour :
- Maintenance sur le serveur leader
- Rééquilibrer la charge
- Tester le mécanisme de bascule

```bash
# Switchover interactif
patronictl switchover

# Switchover en spécifiant le candidat
patronictl switchover --candidate node2 --force

# Ce qui se passe :
# 1. Patroni vérifie que le replica est à jour (lag = 0)
# 2. L'ancien leader arrête d'accepter les écritures
# 3. Le replica finit de rejouer les WAL
# 4. Le replica est promu en leader
# 5. L'ancien leader redémarre en tant que replica
# 6. Durée typique : 5-15 secondes d'indisponibilité
```

### 4.6 Failover (bascule d'urgence)

Un failover est une **bascule automatique** quand le leader est en panne.

```
Scénario de failover :
1. Leader PG tombe (crash, perte réseau, etc.)
2. Patroni agents détectent que le leader ne renouvelle pas son verrou etcd
3. Délai : ttl (30s par défaut) + loop_wait (10s par défaut)
4. Le replica avec le moins de lag tente de prendre le verrou
5. S'il réussit → il se promeut leader
6. Les autres replicas se reconnectent au nouveau leader
7. Durée typique : 30-60 secondes
```

```bash
# Forcer un failover manuel (si l'automatique ne fonctionne pas)
patronictl failover --candidate node2 --force
```

### 4.7 Configuration Patroni type

```yaml
scope: pg-cluster
name: node1
namespace: /patroni/

restapi:
  listen: 0.0.0.0:8008
  connect_address: node1:8008

etcd3:
  hosts: etcd-1:2379,etcd-2:2379,etcd-3:2379

bootstrap:
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    maximum_lag_on_failover: 1048576  # 1MB max lag pour failover
    postgresql:
      use_pg_rewind: true
      parameters:
        max_connections: 200
        shared_buffers: 4GB
        wal_level: replica
        max_wal_senders: 10
        max_replication_slots: 10
        hot_standby: 'on'

postgresql:
  listen: 0.0.0.0:5432
  connect_address: node1:5432
  data_dir: /var/lib/postgresql/data
  authentication:
    replication:
      username: replicator
      password: rep_password
    superuser:
      username: postgres
      password: postgres_password

tags:
  nofailover: false
  noloadbalance: false
  clonefrom: false
```

### 4.8 API REST Patroni

Patroni expose une API REST sur le port 8008 qui est très utile pour le monitoring et les health checks HAProxy.

```bash
# Santé du nœud (200 = leader, 503 = replica)
curl -s http://node1:8008/

# Retourne 200 si le nœud est le leader
curl -s -o /dev/null -w "%{http_code}" http://node1:8008/primary

# Retourne 200 si le nœud est un replica
curl -s -o /dev/null -w "%{http_code}" http://node1:8008/replica

# Retourne 200 si le nœud est un replica synchrone
curl -s -o /dev/null -w "%{http_code}" http://node1:8008/sync

# Informations détaillées du cluster
curl -s http://node1:8008/cluster | python3 -m json.tool

# Informations de configuration
curl -s http://node1:8008/config | python3 -m json.tool
```

---

## Partie 5 : pgexporter (postgres_exporter)

### 5.1 C'est quoi ?
`postgres_exporter` (aussi appelé pgexporter dans certains contextes) est un exporter Prometheus pour PostgreSQL. Il se connecte à PostgreSQL et expose les métriques internes au format Prometheus.

### 5.2 Métriques exposées

```promql
# PostgreSQL est-il joignable ?
pg_up  # 1 = oui, 0 = non

# Nombre de connexions par état
pg_stat_activity_count{state="active"}
pg_stat_activity_count{state="idle"}

# Taille des bases de données
pg_database_size_bytes{datname="mydb"}

# Réplication (sur le primary)
pg_stat_replication_pg_wal_lsn_diff  # lag en bytes

# Transactions
pg_stat_database_xact_commit{datname="mydb"}   # commits
pg_stat_database_xact_rollback{datname="mydb"} # rollbacks

# Locks
pg_locks_count{mode="ExclusiveLock"}

# Cache hit ratio (devrait être > 99%)
pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read)
```

### 5.3 Requêtes custom
On peut ajouter des métriques custom avec un fichier de queries :

```yaml
# queries.yaml
pg_replication:
  query: |
    SELECT
      CASE WHEN pg_is_in_recovery() THEN 1 ELSE 0 END AS is_replica,
      COALESCE(EXTRACT(EPOCH FROM now() - pg_last_xact_replay_timestamp()), 0) AS lag_seconds
  master: true
  metrics:
    - is_replica:
        usage: "GAUGE"
        description: "Is this node a replica"
    - lag_seconds:
        usage: "GAUGE"
        description: "Replication lag in seconds"
```

---

## Partie 6 : Résumé — Ce qu'il faut retenir

### Les 5 métriques les plus importantes

1. **`pg_up`** : PostgreSQL est-il vivant ? (0 = CRITIQUE)
2. **Lag de réplication** : les replicas sont-ils à jour ? (> 30s = WARNING)
3. **Connexions actives** : approche-t-on de `max_connections` ? (> 80% = WARNING)
4. **`patroni_cluster_has_leader`** : le cluster a-t-il un leader ? (0 = CRITIQUE)
5. **Archivage WAL** : les sauvegardes peuvent-elles fonctionner ? (failed_count > 0 = CRITIQUE)

### Les commandes à retenir

```bash
# Diagnostic rapide
patronictl list                                    # État du cluster Patroni
psql -c "SELECT * FROM pg_stat_replication;"       # État de la réplication
psql -c "SELECT state, count(*) FROM pg_stat_activity GROUP BY state;"  # Connexions
pgbackrest info                                    # État des sauvegardes
```

### Le flux en cas de panne

```
Leader PG tombe
    ↓
Patroni détecte (timeout ~30-40s)
    ↓
Patroni vérifie le lag des replicas
    ↓
Le replica avec le moins de lag est promu
    ↓
L'ancien leader redémarre en replica (pg_rewind)
    ↓
HAProxy détecte le changement (health check)
    ↓
Le trafic est redirigé vers le nouveau leader
    ↓
Les applications reconnnectent via PgBouncer/HAProxy
```
