# Pgpool-II — Cours Complet pour Debutants

## 1. C'est quoi Pgpool-II ?

**Pgpool-II** est un middleware entre les clients et PostgreSQL. Il offre :
- **Connection pooling** (comme PgBouncer)
- **Load balancing** des lectures sur les replicas
- **Haute disponibilite** (failover automatique)
- **Limitation de connexions** en parallele

### Pgpool-II vs PgBouncer vs HAProxy

| Fonctionnalite | Pgpool-II | PgBouncer | HAProxy |
|----------------|-----------|-----------|---------|
| **Connection pooling** | Oui (lourd) | Oui (leger, optimise) | Non |
| **Load balancing reads** | Oui (SQL-aware) | Non | Oui (TCP/HTTP health checks) |
| **Failover automatique** | Oui (integre) | Non | Non (depend de Patroni) |
| **Query routing** | Oui (parse le SQL) | Non | Non |
| **Replication logique** | Oui (native replication mode) | Non | Non |
| **Performance pooling** | Moyenne | Excellente | N/A |
| **Watchdog (HA de Pgpool)** | Oui | Non | Keepalived necessaire |
| **Complexite** | Elevee | Faible | Moyenne |

### Quand utiliser quoi ?

```
Pgpool-II : quand on veut un "tout-en-un" (pooling + routing + failover)
             ou quand il n'y a pas de Patroni/HAProxy en place

PgBouncer + HAProxy + Patroni : la stack separee, chaque outil fait une chose bien
                                  → c'est l'approche chez Transactis
```

En pratique, Pgpool-II est souvent utilise dans les architectures ou il n'y a **pas** de Patroni.
Il gere lui-meme le failover et le routing write/read.

## 2. Architecture

### Mode standalone

```
  Client
    |
    v
  Pgpool-II :9999
    |
    |── SELECT → Replica (load balanced)
    |── INSERT/UPDATE/DELETE → Primary
    |
    v
  PostgreSQL Primary (:5432)
  PostgreSQL Replica-1 (:5433)
  PostgreSQL Replica-2 (:5434)
```

### Mode HA (avec Watchdog)

```
  VIP (IP virtuelle)
    |
    v
  ┌─────────────┐     heartbeat     ┌─────────────┐
  │ Pgpool-II-1 │ ◄───────────────► │ Pgpool-II-2 │
  │  (active)   │     watchdog      │  (standby)   │
  └──────┬──────┘                   └──────┬──────┘
         |                                  |
         └──────────┬───────────────────────┘
                    |
          ┌─────────┼─────────┐
          v         v         v
       Primary   Replica   Replica
```

Le **Watchdog** surveille l'etat de Pgpool-II et bascule la VIP si l'instance active tombe.
C'est l'equivalent de Keepalived pour HAProxy.

## 3. Fonctionnalites detaillees

### 3.1 Connection Pooling

Pgpool-II maintient des connexions ouvertes vers PostgreSQL et les reutilise.

```
SANS Pgpool-II :
200 clients → 200 connexions PG → 200 processus backend

AVEC Pgpool-II :
200 clients → 200 connexions Pgpool → 50 connexions PG
                (pool partage)
```

**Parametres cles :**

| Parametre | Description |
|-----------|-------------|
| `num_init_children` | Nombre de processus Pgpool qui acceptent les connexions clients |
| `max_pool` | Nombre de connexions PG cachees par processus enfant |
| `child_max_connections` | Nombre max de connexions qu'un processus enfant traite avant d'etre recycle |
| `connection_life_time` | Duree de vie d'une connexion PG dans le cache (en secondes) |

> **Attention** : le pooling de Pgpool-II est moins performant que PgBouncer.
> PgBouncer est mono-processus asynchrone (leger), Pgpool-II est multi-processus prefork (plus lourd).

### 3.2 Load Balancing (routing des lectures)

Pgpool-II **parse le SQL** pour determiner si une requete est en lecture ou ecriture :

```
SELECT * FROM orders   → envoyee vers un Replica (load balanced)
INSERT INTO orders ... → envoyee vers le Primary
BEGIN; UPDATE ...; COMMIT; → tout le bloc vers le Primary
```

**Parametres cles :**

| Parametre | Description |
|-----------|-------------|
| `load_balance_mode` | `on` pour activer le load balancing des SELECT |
| `backend_weight0`, `backend_weight1` | Poids pour la distribution (0 = pas de lecture) |
| `statement_level_load_balance` | Balance au niveau de chaque requete (pas de la session) |
| `disable_load_balance_on_write` | Apres un write, les SELECT suivants vont sur le Primary |

### 3.3 Health Check et Failover

Pgpool-II verifie regulierement l'etat des backends PostgreSQL :

```
Pgpool-II ──health_check──► Primary    → OK
Pgpool-II ──health_check──► Replica-1  → OK
Pgpool-II ──health_check──► Replica-2  → FAILED → detache du pool
```

**Parametres cles :**

| Parametre | Description |
|-----------|-------------|
| `health_check_period` | Intervalle entre les health checks (secondes) |
| `health_check_timeout` | Timeout d'un health check |
| `health_check_max_retries` | Nombre de retries avant de declarer un backend DOWN |
| `failover_command` | Script execute lors d'un failover (promote du replica) |
| `follow_primary_command` | Script execute sur les replicas apres un failover |

### 3.4 Watchdog (HA de Pgpool-II lui-meme)

Le Watchdog assure la haute disponibilite de Pgpool-II :
- Heartbeat entre les instances Pgpool-II
- Election d'un leader (qui porte la VIP)
- Failover automatique si le leader tombe

```
pgpool-1 (leader, VIP) ◄──heartbeat──► pgpool-2 (standby)

Si pgpool-1 tombe :
  → pgpool-2 detecte la perte de heartbeat
  → pgpool-2 prend la VIP
  → les clients basculent automatiquement
```

## 4. Configuration

### 4.1 pgpool.conf (fichier principal)

```ini
# === Connexion ===
listen_addresses = '*'
port = 9999
pcp_listen_addresses = '*'
pcp_port = 9898

# === Backends PostgreSQL ===
backend_hostname0 = 'pg-primary'
backend_port0 = 5432
backend_weight0 = 1
backend_flag0 = 'ALLOW_TO_FAILOVER'

backend_hostname1 = 'pg-replica1'
backend_port1 = 5432
backend_weight1 = 1
backend_flag1 = 'ALLOW_TO_FAILOVER'

backend_hostname2 = 'pg-replica2'
backend_port2 = 5432
backend_weight2 = 1
backend_flag2 = 'ALLOW_TO_FAILOVER'

# === Pooling ===
num_init_children = 32
max_pool = 4
child_max_connections = 0       # 0 = illimite
connection_life_time = 0        # 0 = pas de timeout

# === Load Balancing ===
load_balance_mode = on
statement_level_load_balance = on
disable_load_balance_on_write = 'transaction'

# === Health Check ===
health_check_period = 10
health_check_timeout = 20
health_check_user = 'pgpool'
health_check_password = 'pgpool_pass'
health_check_max_retries = 3
health_check_retry_delay = 1

# === Failover ===
failover_command = '/etc/pgpool2/failover.sh %d %h %p %D %m %H %M %P %r %R'
follow_primary_command = '/etc/pgpool2/follow_primary.sh %d %h %p %D %m %H %M %P %r %R'

# === Streaming Replication Check ===
sr_check_user = 'pgpool'
sr_check_password = 'pgpool_pass'
sr_check_period = 10

# === Watchdog (HA de Pgpool) ===
use_watchdog = on
wd_hostname = 'pgpool-1'
wd_port = 9000
wd_heartbeat_port = 9694
delegate_ip = '10.0.0.100'     # VIP

other_pgpool_hostname0 = 'pgpool-2'
other_pgpool_port0 = 9999
other_wd_port0 = 9000

# === Logging ===
log_statement = on
log_per_node_statement = on
log_client_messages = off
log_hostname = on
log_connections = on
log_disconnections = on
```

### 4.2 pool_hba.conf (authentification)

```
# TYPE  DATABASE  USER      ADDRESS       METHOD
local   all       all                     trust
host    all       all       0.0.0.0/0     md5
host    all       all       ::0/0         md5
```

### 4.3 pcp.conf (admin tool)

Le PCP (Pgpool Control Port) permet d'administrer Pgpool-II en ligne de commande :

```
# Format : username:md5hash
pgpool:e8a48653851e28c69d0506508fb27fc5
```

Commandes PCP utiles :

| Commande | Description |
|----------|-------------|
| `pcp_node_count` | Nombre de backends configures |
| `pcp_node_info -n 0` | Info sur le backend 0 (etat, role, poids) |
| `pcp_attach_node -n 1` | Rattacher un backend detache |
| `pcp_detach_node -n 1` | Detacher un backend manuellement |
| `pcp_promote_node -n 1` | Promouvoir un replica en primary |
| `pcp_pool_status` | Etat du pool de connexions |

## 5. Pgpool-II vs la stack Patroni + HAProxy + PgBouncer

```
┌──────────────────────────────────────────────────────┐
│  Stack Transactis (separee)                           │
│                                                       │
│  Patroni   → gere le failover PostgreSQL              │
│  HAProxy   → route write/read selon health checks     │
│  PgBouncer → pool de connexions performant            │
│                                                       │
│  + : chaque outil est specialise et optimise          │
│  + : PgBouncer pooling bien plus performant           │
│  + : Patroni failover robuste et eprouve              │
│  - : 3 composants a gerer/monitorer                   │
└──────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────┐
│  Stack Pgpool-II (tout-en-un)                         │
│                                                       │
│  Pgpool-II → failover + routing + pooling             │
│                                                       │
│  + : un seul composant a gerer                        │
│  + : routing SQL-aware (parse les requetes)           │
│  - : pooling moins performant que PgBouncer           │
│  - : configuration complexe                           │
│  - : failover moins robuste que Patroni               │
│  - : un seul point de failure (sauf avec Watchdog)    │
└──────────────────────────────────────────────────────┘
```

## 6. Metriques et monitoring

### 6.1 Metriques Pgpool-II

Pgpool-II expose des metriques via la commande `SHOW POOL_NODES` et via l'exporter Prometheus `pgpool2_exporter`.

| Metrique | Description |
|----------|-------------|
| `pgpool2_pool_nodes_status` | Etat de chaque backend (up/down/unused) |
| `pgpool2_pool_nodes_role` | Role du backend (primary/standby) |
| `pgpool2_pool_nodes_select_cnt` | Nombre de SELECT envoyes a chaque backend |
| `pgpool2_pool_nodes_replication_delay` | Delay de replication en octets |
| `pgpool2_frontend_total` | Nombre total de connexions clients |
| `pgpool2_frontend_used` | Connexions clients actuellement utilisees |
| `pgpool2_pool_cache_hit_ratio` | Ratio de hit du query cache (si active) |
| `pgpool2_health_check_stats_fail_count` | Nombre de health checks echoues par backend |
| `pgpool2_health_check_stats_average_duration` | Duree moyenne des health checks |

### 6.2 Commandes SQL utiles

```sql
-- Etat des backends
SHOW pool_nodes;
-- Affiche : node_id, hostname, port, status, role, select_cnt, replication_delay

-- Etat des processus Pgpool
SHOW pool_processes;
-- Affiche : pid, database, username, start_time, pool_counter

-- Etat des pools
SHOW pool_pools;
-- Affiche : pool_pid, database, username, backend_pid, status

-- Version
SHOW pool_version;

-- Etat du cache (si query_cache active)
SHOW pool_cache;
```

### 6.3 Ports exposes

| Port | Service |
|------|---------|
| `9999` | Port client Pgpool-II (les applications se connectent ici) |
| `9898` | PCP (Pgpool Control Port) — administration |
| `9000` | Watchdog |
| `9694` | Watchdog heartbeat |
| `9719` | pgpool2_exporter (metriques Prometheus) |
