# PgBouncer — Cours Complet pour Débutants

## 1. C'est quoi PgBouncer ?

**PgBouncer** est un **pooler de connexions** (connection pooler) léger pour PostgreSQL.

### Le problème qu'il résout

Chaque connexion à PostgreSQL crée un **processus backend** dédié qui consomme ~10 MB de RAM. Si tu as 500 utilisateurs qui se connectent directement → 500 processus → 5 GB de RAM juste pour les connexions.

### La solution : le pooling

```
SANS PgBouncer :
500 clients → 500 connexions → 500 processus PG → 5 GB RAM

AVEC PgBouncer :
500 clients → 500 connexions PgBouncer → 50 connexions PG → 500 MB RAM
                    (pool de connexions)
```

PgBouncer maintient un **pool de connexions ouvertes** vers PostgreSQL et les partage entre les clients. Quand un client a fini sa requête, sa connexion PG est remise dans le pool pour un autre client.

## 2. Modes de pooling

PgBouncer offre 3 modes de pooling :

| Mode | Description | Quand l'utiliser |
|------|-------------|-----------------|
| **session** | 1 connexion PG par session client (libérée quand le client se déconnecte) | Applications qui utilisent des fonctionnalités session-level (LISTEN/NOTIFY, curseurs, variables de session) |
| **transaction** | 1 connexion PG par transaction (libérée après COMMIT/ROLLBACK) | **Le plus courant**. Bon ratio performance/compatibilité |
| **statement** | 1 connexion PG par requête SQL | Applications simples sans transactions multi-requêtes |

### En pratique chez Transactis
Le mode **transaction** est le plus probable. Il offre le meilleur taux de réutilisation des connexions.

## 3. Architecture dans notre stack

```
Application
    │
    ▼
HAProxy :5000 (write) / :5001 (read)
    │
    ▼
PgBouncer :6432
    │
    ▼ (pool de connexions)
PostgreSQL :5432
```

Ou dans certaines architectures :
```
Application → HAProxy → PostgreSQL (avec PgBouncer en sidecar)
```

## 4. Configuration PgBouncer

### Fichier principal : `pgbouncer.ini`

```ini
[databases]
; Nom vu par les clients = connexion réelle vers PostgreSQL
mydb = host=patroni-leader port=5432 dbname=mydb

; Wildcard : toutes les bases sont accessibles
* = host=patroni-leader port=5432

[pgbouncer]
; Écoute
listen_addr = 0.0.0.0
listen_port = 6432

; Authentification
auth_type = md5
auth_file = /etc/pgbouncer/userlist.txt

; Mode de pooling
pool_mode = transaction

; Taille des pools
default_pool_size = 25          ; Nombre de connexions PG par pool (par user/db)
min_pool_size = 5               ; Connexions minimum maintenues ouvertes
reserve_pool_size = 5           ; Connexions supplémentaires en cas de pic
reserve_pool_timeout = 3        ; Secondes avant d'utiliser les connexions de réserve

; Limites
max_client_conn = 1000          ; Nombre max de clients simultanés
max_db_connections = 100        ; Nombre max de connexions vers PG par database

; Timeouts
server_idle_timeout = 600       ; Fermer les connexions PG inutilisées après 10 min
client_idle_timeout = 0         ; 0 = pas de timeout pour les clients idle
query_timeout = 0               ; 0 = pas de timeout pour les requêtes
query_wait_timeout = 120        ; Timeout si un client attend une connexion du pool

; Logging
log_connections = 1
log_disconnections = 1
log_pooler_errors = 1

; Admin
admin_users = postgres
stats_users = monitoring
```

### Fichier d'authentification : `userlist.txt`

```
"postgres" "md5<hash>"
"app_user" "md5<hash>"
"monitoring" "md5<hash>"
```

Pour générer le hash :
```bash
# Méthode simple (md5 + password + username)
echo -n "md5$(echo -n 'passwordusername' | md5sum | cut -d' ' -f1)"
```

## 5. Commandes d'administration PgBouncer

PgBouncer a une **base de données virtuelle** appelée `pgbouncer` qui permet d'administrer le pooler via des commandes SQL.

```bash
# Se connecter à la console admin PgBouncer
psql -h localhost -p 6432 -U postgres pgbouncer
```

### Commandes de monitoring

```sql
-- Voir les pools de connexions
SHOW POOLS;
-- Colonnes importantes :
-- cl_active : clients qui utilisent une connexion PG actuellement
-- cl_waiting : clients qui attendent une connexion PG ← IMPORTANT
-- sv_active : connexions PG utilisées
-- sv_idle : connexions PG libres dans le pool
-- sv_used : connexions PG récemment utilisées
-- pool_mode : mode de pooling

-- Voir les statistiques
SHOW STATS;
-- total_xact_count : nombre total de transactions
-- total_query_count : nombre total de requêtes
-- avg_xact_time : durée moyenne des transactions (en µs)
-- avg_query_time : durée moyenne des requêtes (en µs)
-- avg_wait_time : durée moyenne d'attente d'une connexion ← IMPORTANT

-- Voir les clients connectés
SHOW CLIENTS;
-- addr : adresse IP du client
-- state : active, used, waiting, idle
-- link : vers quelle connexion serveur ce client est lié

-- Voir les connexions serveur (vers PG)
SHOW SERVERS;
-- state : active, idle, used, tested, new

-- Voir les bases configurées
SHOW DATABASES;

-- Voir la configuration
SHOW CONFIG;

-- Voir les statistiques par base
SHOW STATS_TOTALS;
```

### Commandes d'administration

```sql
-- Recharger la configuration (sans couper les connexions)
RELOAD;

-- Mettre une base en pause (finit les transactions en cours, bloque les nouvelles)
PAUSE mydb;

-- Reprendre
RESUME mydb;

-- Déconnecter les connexions serveur idle
KILL mydb;

-- Activer/désactiver une base
DISABLE mydb;
ENABLE mydb;

-- Shutdown propre
SHUTDOWN;
```

## 6. Métriques PgBouncer pour Prometheus

### Avec pgbouncer_exporter

`pgbouncer_exporter` se connecte à la base `pgbouncer` et expose les métriques au format Prometheus.

### Métriques clés

```promql
# PgBouncer est-il vivant ?
pgbouncer_up  # 1 = oui, 0 = non

# Clients en attente de connexion (devrait être ~0)
pgbouncer_pools_client_waiting_connections{database="mydb"}

# Connexions serveur actives
pgbouncer_pools_server_active_connections{database="mydb"}

# Connexions serveur idle (libres dans le pool)
pgbouncer_pools_server_idle_connections{database="mydb"}

# Temps moyen d'attente (en secondes)
pgbouncer_stats_avg_wait_time_seconds{database="mydb"}

# Temps moyen des requêtes
pgbouncer_stats_avg_query_duration_seconds{database="mydb"}

# Nombre de transactions par seconde
rate(pgbouncer_stats_transactions_total{database="mydb"}[5m])

# Utilisation du pool (ratio connexions actives / pool_size)
pgbouncer_pools_server_active_connections / pgbouncer_config_default_pool_size
```

### Alertes recommandées

| Alerte | Condition | Sévérité |
|--------|-----------|----------|
| PgBouncer DOWN | `pgbouncer_up == 0` | CRITIQUE |
| Clients en attente | `pgbouncer_pools_client_waiting_connections > 0` pendant 1 min | WARNING |
| Pool saturé | `server_active / pool_size > 0.8` | WARNING |
| Temps d'attente élevé | `avg_wait_time > 1s` | WARNING |
| Pool épuisé | `server_idle == 0 AND client_waiting > 0` | CRITIQUE |

## 7. Haute disponibilité PgBouncer

### Le problème
PgBouncer est un **single point of failure**. S'il tombe → plus de connexions → applications en erreur.

### Solutions

#### Option 1 : PgBouncer en sidecar (sur chaque nœud applicatif)
```
App Server 1 → PgBouncer local → HAProxy → PostgreSQL
App Server 2 → PgBouncer local → HAProxy → PostgreSQL
```
Avantage : pas de SPOF, chaque app a son PgBouncer

#### Option 2 : Cluster PgBouncer avec HAProxy devant
```
Application → HAProxy → PgBouncer 1 → PostgreSQL
                      → PgBouncer 2 → PostgreSQL
```

#### Option 3 : PgBouncer avec Keepalived (VIP)
```
Application → VIP → PgBouncer 1 (actif) → PostgreSQL
                   → PgBouncer 2 (passif)
```

## 8. Problèmes courants

### "no more connections allowed"
Le client a atteint `max_client_conn`.
```sql
SHOW CONFIG;  -- Vérifier max_client_conn
SHOW CLIENTS; -- Compter les clients connectés
-- Solution : augmenter max_client_conn ou investiguer les connexions idle
```

### Clients en attente (cl_waiting > 0)
Le pool de connexions PG est épuisé.
```sql
SHOW POOLS;   -- Voir cl_waiting et sv_active
SHOW SERVERS; -- Voir les connexions serveur et leur état
-- Solutions :
-- 1. Augmenter default_pool_size
-- 2. Réduire la durée des transactions
-- 3. Vérifier s'il y a des transactions longues : SELECT * FROM pg_stat_activity WHERE state = 'idle in transaction';
```

### Latence élevée
```sql
SHOW STATS;   -- Regarder avg_query_time et avg_wait_time
-- Si avg_wait_time élevé → pool trop petit
-- Si avg_query_time élevé → problème côté PostgreSQL (requêtes lentes)
```

### PgBouncer ne se connecte pas à PostgreSQL
```bash
# Vérifier la connectivité
psql -h patroni-leader -p 5432 -U app_user mydb

# Vérifier le fichier userlist.txt (hash correct ?)
# Vérifier pg_hba.conf sur PostgreSQL (autorise les connexions depuis PgBouncer ?)
```
