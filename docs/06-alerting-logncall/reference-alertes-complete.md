# Reference Complete des Alertes — Stack Supervision

Ce document regroupe **toutes les alertes** configurees dans la stack de supervision, classees par composant. Pour chaque alerte : la requete PromQL, la severite, la signification et l'action a mener.

---

## Sommaire

1. [etcd (9 alertes)](#1-etcd)
2. [Patroni (6 alertes)](#2-patroni)
3. [PostgreSQL (12 alertes)](#3-postgresql)
4. [pgBackRest (5 alertes)](#4-pgbackrest)
5. [HAProxy (7 alertes)](#5-haproxy)
6. [PgBouncer (5 alertes)](#6-pgbouncer)
7. [Pgpool-II (10 alertes)](#7-pgpool-ii)
8. [Node / OS (3 alertes)](#8-node--os)

**Total : 57 alertes** (27 critical, 30 warning)

---

## Comment lire ce document

Chaque alerte est presentee ainsi :

| Champ | Description |
|-------|-------------|
| **Nom** | Nom unique de l'alerte dans Prometheus |
| **Severite** | `critical` (action immediate) ou `warning` (attention requise) |
| **Expr** | Requete PromQL qui declenche l'alerte |
| **For** | Duree pendant laquelle la condition doit etre vraie avant de declencher |
| **Signification** | Ce que l'alerte veut dire en langage clair |
| **Impact** | Consequence si on ne reagit pas |
| **Action** | Que faire quand l'alerte se declenche |

---

## 1. etcd

etcd est le store de consensus utilise par Patroni pour l'election du leader PostgreSQL.
Si etcd tombe, Patroni ne peut plus elire de leader → plus d'ecritures PostgreSQL.

### EtcdDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `up{job="etcd"} == 0` |
| **For** | 30s |
| **Signification** | Un noeud etcd ne repond plus au scraping Prometheus |
| **Impact** | Si 2/3 noeuds tombent → perte de quorum → Patroni ne peut plus fonctionner |
| **Action** | Verifier que le conteneur/process etcd tourne. `docker ps`, `docker logs etcd-X`. Redemarrer si necessaire |

### EtcdNoLeader

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `etcd_server_has_leader == 0` |
| **For** | 30s |
| **Signification** | Le noeud etcd n'a pas de leader. Le cluster a perdu le quorum |
| **Impact** | Aucune ecriture possible dans etcd → Patroni freeze → PostgreSQL ne peut pas basculer |
| **Action** | Verifier l'etat du cluster : `etcdctl endpoint status`. Si quorum perdu (2/3 noeuds down), remonter les noeuds. Si 1 seul noeud reste, envisager un restore |

### EtcdProposalsFailing

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `increase(etcd_server_proposals_failed_total[5m]) > 5` |
| **For** | 1m |
| **Signification** | Des propositions Raft echouent. Les noeuds n'arrivent pas a s'accorder |
| **Impact** | Instabilite du cluster etcd, risque de perte de quorum |
| **Action** | Verifier la connectivite reseau entre les noeuds etcd. Verifier les logs etcd pour des erreurs de communication |

### EtcdHighLeaderChanges

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `increase(etcd_server_leader_changes_seen_total[1h]) > 3` |
| **For** | 5m |
| **Signification** | Le leader change plus de 3 fois par heure. Le cluster est instable |
| **Impact** | Performance degradee, risque de split-brain temporaire |
| **Action** | Verifier la latence reseau entre les noeuds. Verifier les performances disque (WAL fsync). Un disque lent cause des timeouts de heartbeat |

### EtcdDiskLatencyHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m])) > 0.1` |
| **For** | 2m |
| **Signification** | L'ecriture du WAL (Write-Ahead Log) prend plus de 100ms au p99 |
| **Impact** | Le leader devient lent, risque de provoquer des elections de leader |
| **Action** | Verifier les I/O disque (`iostat`, `iotop`). etcd a besoin d'un disque rapide (SSD recommande). Verifier s'il y a contention I/O avec d'autres processus |

### EtcdDatabaseSizeLarge

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `etcd_mvcc_db_total_size_in_bytes > 500000000` |
| **For** | 5m |
| **Signification** | La base etcd depasse 500 MB |
| **Impact** | Performance degradee, risque d'atteindre le quota (defaut 2 GB) |
| **Action** | Verifier les revisions : `etcdctl compact $(etcdctl endpoint status -w json | jq '.[0].Status.header.revision')`. Lancer un defrag : `etcdctl defrag` |

### EtcdBackendCommitSlow

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m])) > 0.1` |
| **For** | 2m |
| **Signification** | Les commits backend (bbolt) prennent plus de 100ms au p99 |
| **Impact** | Meme impact que EtcdDiskLatencyHigh. Le backend est le stockage persistant |
| **Action** | Meme action : verifier les I/O disque. Envisager un defrag de la base etcd |

### EtcdSlowApply

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `increase(etcd_server_slow_apply_total[5m]) > 0` |
| **For** | 2m |
| **Signification** | Des operations Raft sont appliquees lentement (> 100ms) |
| **Impact** | Latence dans la propagation des changements de configuration Patroni |
| **Action** | Verifier la charge CPU et disque du noeud. Si persistant, le noeud est sous-dimensionne |

### EtcdQuotaNearLimit

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `(etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes) > 0.8` |
| **For** | 5m |
| **Signification** | La base etcd utilise plus de 80% du quota alloue |
| **Impact** | Si le quota est atteint, etcd passe en mode alarm et refuse les ecritures |
| **Action** | Compacter les anciennes revisions et defragmenter. Si le quota est trop bas, l'augmenter (max recommande : 8 GB) |

---

## 2. Patroni

Patroni gere la haute disponibilite de PostgreSQL : election du leader, failover automatique, gestion des replicas.

### PatroniDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `up{job="patroni"} == 0` |
| **For** | 30s |
| **Signification** | L'API REST de Patroni ne repond plus |
| **Impact** | Ce noeud PostgreSQL n'est plus gere par Patroni. Pas de failover automatique si c'est le leader |
| **Action** | Verifier le process Patroni : `systemctl status patroni` ou `docker logs patroni-X`. Redemarrer si necessaire |

### PatroniNoLeader

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `count(patroni_primary == 1) == 0` |
| **For** | 30s |
| **Signification** | Aucun noeud du cluster n'est leader. Pas de primary PostgreSQL |
| **Impact** | Aucune ecriture possible. Les applications qui ecrivent sont en erreur |
| **Action** | Verifier l'etat du cluster : `patronictl list`. Verifier etcd (souvent la cause). Si etcd est OK, forcer une election : `patronictl failover` |

### PatroniFailoverDetected

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `changes(patroni_primary[5m]) > 0` |
| **For** | 0s (immediat) |
| **Signification** | Le leader Patroni a change dans les 5 dernieres minutes. Un failover a eu lieu |
| **Impact** | Interruption temporaire des ecritures pendant le failover (quelques secondes). Les connexions existantes vers l'ancien leader sont coupees |
| **Action** | Alerte informative. Verifier pourquoi le failover a eu lieu (crash ? maintenance ?). Verifier que le nouveau leader fonctionne correctement. Verifier que les replicas suivent le nouveau leader |

### PatroniPostgresNotRunning

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `patroni_postgres_running == 0` |
| **For** | 30s |
| **Signification** | Le processus PostgreSQL n'est pas en cours d'execution sur ce noeud |
| **Impact** | Si c'est le leader, les ecritures sont impossibles (failover en cours ou a venir). Si c'est un replica, une source de lecture est perdue |
| **Action** | Verifier les logs PostgreSQL (`pg_log/`). Verifier si Patroni tente de redemarrer PG. Si le noeud ne revient pas, envisager un reinit : `patronictl reinit` |

### PatroniPendingRestart

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `patroni_pending_restart == 1` |
| **For** | 10m |
| **Signification** | Un parametre PostgreSQL a ete modifie et necessite un redemarrage pour prendre effet |
| **Impact** | Le parametre modifie n'est pas actif. Ca peut etre un parametre de securite, de performance, etc. |
| **Action** | Planifier un redemarrage du noeud. Si c'est le leader, faire un switchover d'abord : `patronictl switchover` puis redemarrer |

### PatroniReplicationLag

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `patroni_xlog_location - on(scope) group_right patroni_xlog_replayed_location > 50000000` |
| **For** | 2m |
| **Signification** | Le replica a plus de 50 MB de retard sur le leader |
| **Impact** | Les lectures sur ce replica retournent des donnees obsoletes |
| **Action** | Verifier la charge I/O du replica. Verifier le debit reseau. Si le lag persiste, le replica est peut-etre sous-dimensionne |

---

## 3. PostgreSQL

Les alertes PostgreSQL viennent du `postgres-exporter` qui expose les metriques des vues systemes (pg_stat_*, pg_settings, etc.).

### PostgreSQLDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `up{job="postgres"} == 0` |
| **For** | 30s |
| **Signification** | L'exporter PostgreSQL ne repond plus (postgres-exporter ne peut plus se connecter a PG) |
| **Impact** | PostgreSQL est probablement DOWN. Verifier aussi PatroniDown et PatroniNoLeader |
| **Action** | Verifier les logs PG. Si Patroni est en place, il devrait redemarrer PG automatiquement. Sinon, redemarrer manuellement |

### PostgreSQLReplicationLagWarning

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_replication_lag > 1` |
| **For** | 1m |
| **Signification** | Le lag de replication depasse 1 seconde |
| **Impact** | Les lectures sur les replicas sont legerement obsoletes (acceptable pour du reporting) |
| **Action** | Surveiller l'evolution. Souvent transitoire lors de grosses transactions ou de pics de charge |

### PostgreSQLReplicationLagCritical

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pg_replication_lag > 10` |
| **For** | 30s |
| **Signification** | Le lag de replication depasse 10 secondes |
| **Impact** | Donnees tres obsoletes sur les replicas. Si le primary tombe, risque de perte de donnees |
| **Action** | Verifier les I/O du replica. Verifier si une grosse transaction est en cours sur le primary. Verifier le reseau entre primary et replica |

### PostgreSQLConnectionsHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_stat_activity_count / pg_settings_max_connections > 0.8` |
| **For** | 2m |
| **Signification** | Plus de 80% des connexions PostgreSQL sont utilisees |
| **Impact** | Les nouvelles connexions seront bientot refusees (erreur "too many connections") |
| **Action** | Verifier les connexions actives : `SELECT * FROM pg_stat_activity`. Identifier les connexions idle. Si PgBouncer/Pgpool est en place, verifier la config du pool. Augmenter `max_connections` si necessaire (necessite redemarrage) |

### PostgreSQLDeadlocks

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `increase(pg_stat_database_deadlocks[5m]) > 0` |
| **For** | 1m |
| **Signification** | Des deadlocks ont ete detectes dans les 5 dernieres minutes |
| **Impact** | Des transactions sont annulees (une des deux est tuee pour resoudre le deadlock). Impact applicatif : erreurs cote application |
| **Action** | Analyser les logs PG (`deadlock detected`). Identifier les requetes concurrentes qui causent le deadlock. Revoir l'ordre d'acquisition des verrous dans le code applicatif |

### PostgreSQLLongTransaction

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_slow_queries_count > 0` |
| **For** | 1m |
| **Signification** | Des requetes tournent depuis plus de 5 minutes |
| **Impact** | Risque de bloquer l'autovacuum, de gonfler les tables (dead tuples), de bloquer d'autres transactions |
| **Action** | Identifier la requete : `SELECT pid, now()-query_start, query FROM pg_stat_activity WHERE state='active' ORDER BY query_start`. Tuer si necessaire : `SELECT pg_terminate_backend(pid)` |

### PostgreSQLLocksWaiting

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_locks_waiting_count > 10` |
| **For** | 2m |
| **Signification** | Plus de 10 verrous en attente (des requetes attendent qu'un verrou soit libere) |
| **Impact** | Les requetes s'empilent, les temps de reponse augmentent, risque d'effet cascade |
| **Action** | Identifier la requete bloquante : `SELECT * FROM pg_locks WHERE NOT granted` croise avec `pg_stat_activity`. Tuer la requete bloquante si possible |

### PostgreSQLReplicationSlotLagHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_replication_slots_lag_bytes > 1073741824` |
| **For** | 5m |
| **Signification** | Un slot de replication a plus de 1 GB de retard |
| **Impact** | Le primary conserve les WAL correspondants → risque de remplir le disque. Si le slot n'est plus utilise, les WAL ne seront jamais nettoyes |
| **Action** | Verifier si le consommateur du slot est actif. Si le slot est orphelin, le supprimer : `SELECT pg_drop_replication_slot('slot_name')` |

### PostgreSQLDeadTuplesHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_table_size_dead_tuples > 100000` |
| **For** | 10m |
| **Signification** | Une table a plus de 100 000 lignes mortes (dead tuples) |
| **Impact** | La table gonfle (bloat), les requetes deviennent plus lentes, le disque est gaspille |
| **Action** | Verifier que l'autovacuum fonctionne : `SELECT * FROM pg_stat_user_tables WHERE n_dead_tup > 100000`. Lancer un vacuum manuel si necessaire : `VACUUM ANALYZE table_name` |

### PostgreSQLVacuumTooOld

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_vacuum_age_seconds > 86400` |
| **For** | 5m |
| **Signification** | L'autovacuum n'a pas tourne depuis plus de 24 heures |
| **Impact** | Accumulation de dead tuples, bloat des tables et index, degradation progressive des performances |
| **Action** | Verifier les parametres autovacuum. Si des transactions longues bloquent le vacuum, les identifier et les terminer |

### PostgreSQLTempFilesHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `increase(pg_stat_database_temp_files[5m]) > 10` |
| **For** | 5m |
| **Signification** | PostgreSQL cree beaucoup de fichiers temporaires (tris et hash qui debordent de la memoire) |
| **Impact** | Operations lentes (tri sur disque au lieu de la memoire), consommation disque |
| **Action** | Augmenter `work_mem` si possible. Identifier les requetes qui trient de gros volumes. Optimiser les requetes (index, LIMIT, etc.) |

### PostgreSQLCacheHitRatioLow

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pg_stat_database_blks_hit / (pg_stat_database_blks_hit + pg_stat_database_blks_read + 1) < 0.9` |
| **For** | 5m |
| **Signification** | Moins de 90% des blocs sont lus depuis le cache (shared_buffers). Trop de lectures disque |
| **Impact** | Performances degradees, latence des requetes augmente |
| **Action** | Augmenter `shared_buffers` (recommande : 25% de la RAM). Verifier si des tables volumineuses sont scannees sans index (seq scans) |

---

## 4. pgBackRest

pgBackRest gere les sauvegardes et l'archivage WAL de PostgreSQL.

### PgBackRestExporterDown

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `up{job="pgbackrest"} == 0` |
| **For** | 30s |
| **Signification** | L'exporter pgBackRest ne repond plus |
| **Impact** | On perd la visibilite sur l'etat des sauvegardes. Les sauvegardes tournent peut-etre encore mais on ne le sait plus |
| **Action** | Verifier le conteneur/process de l'exporter. Redemarrer si necessaire |

### PgBackRestStanzaError

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgbackrest_stanza_status != 0` |
| **For** | 5m |
| **Signification** | La stanza pgBackRest est en erreur (config invalide, repo inaccessible, etc.) |
| **Impact** | Les sauvegardes et l'archivage WAL ne fonctionnent plus. En cas de crash, pas de recovery possible |
| **Action** | Verifier l'etat : `pgbackrest --stanza=X check`. Verifier les permissions et l'acces au repo. Recreer la stanza si necessaire |

### PgBackRestBackupTooOld

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgbackrest_backup_since_last_completion_seconds{backup_type="full"} > 604800` |
| **For** | 10m |
| **Signification** | La derniere sauvegarde full date de plus de 7 jours |
| **Impact** | En cas de crash, le recovery prendra plus de temps (plus de WAL a rejouer). RPO (Recovery Point Objective) non respecte |
| **Action** | Verifier les logs pgBackRest. Lancer une sauvegarde manuellement : `pgbackrest --stanza=X backup --type=full`. Verifier le cron de sauvegarde |

### PgBackRestBackupFailed

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgbackrest_backup_error_status == 1` |
| **For** | 1m |
| **Signification** | La derniere sauvegarde a echoue |
| **Impact** | Si ca persiste, les sauvegardes sont obsoletes |
| **Action** | Verifier les logs pgBackRest. Causes frequentes : espace disque insuffisant, probleme reseau vers le repo, permissions |

### PgBackRestWALArchiveFailing

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgbackrest_wal_archive_status != 0` |
| **For** | 5m |
| **Signification** | L'archivage des WAL echoue |
| **Impact** | Les WAL s'accumulent sur le primary (risque de remplir le disque). En cas de crash, perte de donnees entre le dernier WAL archive et le crash |
| **Action** | Verifier les logs d'archivage PG et pgBackRest. Verifier l'espace disque du repo. Verifier la connectivite reseau |

---

## 5. HAProxy

HAProxy route le trafic vers PostgreSQL : port 5000 pour les ecritures (primary), port 5001 pour les lectures (replicas).

### HAProxyDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `up{job="haproxy"} == 0` |
| **For** | 30s |
| **Signification** | HAProxy ne repond plus |
| **Impact** | Plus aucune connexion client vers PostgreSQL. Arret total du service |
| **Action** | Verifier le process HAProxy. Redemarrer. Si Keepalived est en place, la VIP devrait basculer sur l'autre HAProxy |

### HAProxyNoWriteBackend

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `haproxy_backend_active_servers{proxy="pg-write"} == 0` |
| **For** | 10s |
| **Signification** | Aucun backend disponible pour les ecritures (port 5000) |
| **Impact** | Les applications ne peuvent plus ecrire dans PostgreSQL |
| **Action** | Verifier l'etat de Patroni et PostgreSQL. Le leader est probablement DOWN et le failover n'a pas encore eu lieu (ou a echoue). Verifier les health checks HAProxy |

### HAProxyNoReadBackend

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `haproxy_backend_active_servers{proxy="pg-read"} == 0` |
| **For** | 10s |
| **Signification** | Aucun backend disponible pour les lectures (port 5001) |
| **Impact** | Les lectures load-balancees sont impossibles. Les applications doivent lire sur le primary |
| **Action** | Verifier l'etat des replicas. Si tous les replicas sont down, verifier Patroni et les logs PG |

### HAProxyBackendDown

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `haproxy_server_status{proxy=~"pg-.*"} == 0` |
| **For** | 30s |
| **Signification** | Un backend PostgreSQL specifique est marque DOWN par HAProxy |
| **Impact** | Un noeud PG est indisponible. Le trafic est redirige vers les noeuds restants |
| **Action** | Verifier le noeud concerne (logs Patroni et PG). Souvent transitoire lors d'un redemarrage ou failover |

### HAProxySessionsHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `haproxy_frontend_current_sessions / haproxy_process_max_connections > 0.8` |
| **For** | 2m |
| **Signification** | Plus de 80% des sessions HAProxy sont utilisees |
| **Impact** | Les nouvelles connexions seront bientot refusees |
| **Action** | Verifier pourquoi il y a autant de connexions (pic de trafic ? fuite de connexions ?). Augmenter `maxconn` dans la config HAProxy si necessaire |

### HAProxyBackendConnectTimeHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `haproxy_backend_connect_time_average_seconds > 0.5` |
| **For** | 2m |
| **Signification** | Le temps de connexion moyen vers les backends PostgreSQL depasse 500ms |
| **Impact** | Latence ajoutee a chaque nouvelle connexion. Degradation des temps de reponse |
| **Action** | Verifier la latence reseau entre HAProxy et PG. Verifier la charge des noeuds PG. Si PgBouncer est en place, verifier son etat |

### HAProxyHighErrorRate

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `rate(haproxy_backend_http_responses_total{code=~"5.."}[5m]) > 1` |
| **For** | 2m |
| **Signification** | Plus de 1 erreur 5xx par seconde sur un backend |
| **Impact** | Les clients recoivent des erreurs. Le service est degrade |
| **Action** | Verifier les logs HAProxy et PG. Identifier la source des erreurs (timeout ? connexion refusee ? crash ?) |

---

## 6. PgBouncer

PgBouncer est le pooler de connexions entre les applications et PostgreSQL.

### PgBouncerDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgbouncer_up == 0 or up{job="pgbouncer"} == 0` |
| **For** | 30s |
| **Signification** | PgBouncer ne repond plus |
| **Impact** | Les applications ne peuvent plus se connecter a PostgreSQL (si PgBouncer est dans le chemin) |
| **Action** | Verifier le process PgBouncer. Verifier les logs. Redemarrer. Cause frequente : erreur de config apres un changement |

### PgBouncerPoolExhausted

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgbouncer_pools_server_idle_connections == 0 and pgbouncer_pools_client_waiting_connections > 0` |
| **For** | 30s |
| **Signification** | Le pool est completement utilise (0 connexion idle) ET des clients attendent |
| **Impact** | Les clients sont bloques en attente. Temps de reponse explose. Timeouts applicatifs |
| **Action** | Augmenter `default_pool_size` dans PgBouncer. Verifier les connexions longues cote PG (`pg_stat_activity`). Verifier si `max_connections` PG est suffisant |

### PgBouncerClientsWaiting

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgbouncer_pools_client_waiting_connections > 5` |
| **For** | 1m |
| **Signification** | Plus de 5 clients attendent une connexion du pool |
| **Impact** | Degradation des temps de reponse pour les clients en attente |
| **Action** | Surveiller l'evolution. Si ca augmente, augmenter le pool. Verifier si des requetes longues monopolisent des connexions |

### PgBouncerPoolUsageHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgbouncer_pools_server_active_connections / (pgbouncer_pools_server_active_connections + pgbouncer_pools_server_idle_connections + 1) > 0.8` |
| **For** | 2m |
| **Signification** | Plus de 80% des connexions du pool sont actives |
| **Impact** | Proche de la saturation. Les prochains pics de charge provoqueront des attentes |
| **Action** | Augmenter le pool de facon preventive. Optimiser les requetes longues |

### PgBouncerMaxWaitHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgbouncer_pools_client_maxwait_seconds > 5` |
| **For** | 1m |
| **Signification** | Un client attend une connexion depuis plus de 5 secondes |
| **Impact** | L'application percoit une latence de 5+ secondes avant meme d'envoyer sa requete |
| **Action** | Meme actions que PgBouncerPoolExhausted. Si `query_wait_timeout` est configure, le client sera deconnecte apres ce delai |

---

## 7. Pgpool-II

Pgpool-II est un middleware qui fait du pooling, load balancing et failover.
Ces alertes s'appliquent si Pgpool-II est utilise a la place de (ou en complement de) la stack Patroni + HAProxy + PgBouncer.

### PgpoolDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `up{job="pgpool2"} == 0` |
| **For** | 30s |
| **Signification** | L'exporter Pgpool-II ne repond plus |
| **Impact** | Pgpool-II est probablement DOWN. Les applications ne peuvent plus se connecter |
| **Action** | Verifier le process Pgpool-II et l'exporter. Redemarrer. Si le Watchdog est actif, l'instance standby prend le relais |

### PgpoolBackendDown

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgpool2_pool_nodes_status != 1` |
| **For** | 1m |
| **Signification** | Un backend PostgreSQL est DOWN du point de vue de Pgpool (status 2=unused, 3=down) |
| **Impact** | Un noeud PG est retire du pool. Moins de capacite de lecture |
| **Action** | Verifier le noeud PG concerne. Rattacher apres reparation : `pcp_attach_node` |

### PgpoolNoPrimary

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `count(pgpool2_pool_nodes_role == 1) == 0` |
| **For** | 30s |
| **Signification** | Aucun backend n'a le role primary |
| **Impact** | Les ecritures sont impossibles |
| **Action** | Verifier l'etat des backends : `SHOW pool_nodes`. Verifier si le failover Pgpool a echoue. Promouvoir manuellement si necessaire : `pcp_promote_node` |

### PgpoolReplicationDelayHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgpool2_pool_nodes_replication_delay > 10485760` |
| **For** | 2m |
| **Signification** | Le lag de replication depasse 10 MB |
| **Impact** | Les lectures sur les replicas retournent des donnees obsoletes |
| **Action** | Verifier les I/O du replica. Verifier le reseau |

### PgpoolReplicationDelayCritical

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgpool2_pool_nodes_replication_delay > 104857600` |
| **For** | 2m |
| **Signification** | Le lag depasse 100 MB |
| **Impact** | Donnees tres obsoletes en lecture. Risque de perte de donnees si le primary tombe |
| **Action** | Action urgente : reduire la charge du primary, verifier le replica, envisager de detacher le replica du load balancing |

### PgpoolConnectionsHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgpool2_frontend_used / pgpool2_frontend_total > 0.8` |
| **For** | 5m |
| **Signification** | Plus de 80% des slots clients Pgpool sont utilises |
| **Impact** | Les nouveaux clients seront bientot rejetes |
| **Action** | Augmenter `num_init_children`. Verifier les connexions longues |

### PgpoolConnectionsSaturated

| | |
|---|---|
| **Severite** | CRITICAL |
| **Expr** | `pgpool2_frontend_used / pgpool2_frontend_total > 0.95` |
| **For** | 1m |
| **Signification** | Plus de 95% des slots sont utilises |
| **Impact** | Les nouveaux clients sont rejetes |
| **Action** | Action immediate : augmenter `num_init_children`, identifier et tuer les connexions idle |

### PgpoolHealthCheckFailing

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `increase(pgpool2_health_check_stats_fail_count[5m]) > 3` |
| **For** | 2m |
| **Signification** | Des health checks echouent regulierement |
| **Impact** | Risque de detachement du backend si ca persiste |
| **Action** | Verifier la connectivite entre Pgpool et le backend concerne. Verifier les logs Pgpool |

### PgpoolHealthCheckSlow

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgpool2_health_check_stats_average_duration > 5` |
| **For** | 5m |
| **Signification** | Les health checks prennent plus de 5 secondes en moyenne |
| **Impact** | Detection lente des pannes. Le failover sera plus lent |
| **Action** | Verifier la latence reseau. Verifier la charge du backend PostgreSQL |

### PgpoolLoadBalancingSkewed

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `pgpool2_pool_nodes_select_cnt / ignoring(hostname, port) group_left sum(pgpool2_pool_nodes_select_cnt) > 0.9` |
| **For** | 10m |
| **Signification** | Un backend recoit plus de 90% des SELECT (desequilibre) |
| **Impact** | Un noeud est surcharge pendant que les autres sont sous-utilises |
| **Action** | Verifier les `backend_weight` dans pgpool.conf. Verifier que les autres backends sont bien UP et rattaches |

---

## 8. Node / OS

Alertes sur les ressources systeme de la machine hote.

### NodeDiskAlmostFull

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `(1 - node_filesystem_avail_bytes{mountpoint="/"} / node_filesystem_size_bytes{mountpoint="/"}) > 0.85` |
| **For** | 5m |
| **Signification** | Le disque est utilise a plus de 85% |
| **Impact** | Si le disque se remplit : PostgreSQL crash, etcd passe en alarm, les logs s'arretent |
| **Action** | Identifier ce qui consomme l'espace : WAL PG, logs, backups. Nettoyer ou agrandir le disque |

### NodeMemoryHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) > 0.9` |
| **For** | 5m |
| **Signification** | La memoire est utilisee a plus de 90% |
| **Impact** | Risque d'OOM Killer qui tue des processus (PostgreSQL, etcd, etc.) |
| **Action** | Identifier les processus gourmands (`top`, `ps aux --sort=-rss`). Reduire `shared_buffers` PG si necessaire. Ajouter de la RAM |

### NodeCPUHigh

| | |
|---|---|
| **Severite** | WARNING |
| **Expr** | `(1 - avg(rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 0.9` |
| **For** | 5m |
| **Signification** | Le CPU est utilise a plus de 90% |
| **Impact** | Latence sur tous les services. Les health checks peuvent echouer (etcd, HAProxy), declenchant des failovers intempestifs |
| **Action** | Identifier le processus consommateur. Optimiser les requetes PG (seq scans, sorts). Ajouter des CPU |

---

## Recapitulatif par severite

### Alertes CRITICAL (action immediate)

| Composant | Alerte | Seuil |
|-----------|--------|-------|
| etcd | EtcdDown | instance unreachable |
| etcd | EtcdNoLeader | pas de leader pendant 30s |
| etcd | EtcdProposalsFailing | > 5 proposals echouees en 5min |
| Patroni | PatroniDown | instance unreachable |
| Patroni | PatroniNoLeader | 0 leader pendant 30s |
| Patroni | PatroniPostgresNotRunning | PG arrete pendant 30s |
| PostgreSQL | PostgreSQLDown | exporter unreachable |
| PostgreSQL | PostgreSQLReplicationLagCritical | lag > 10s |
| pgBackRest | PgBackRestStanzaError | stanza en erreur |
| pgBackRest | PgBackRestBackupFailed | backup echoue |
| pgBackRest | PgBackRestWALArchiveFailing | archivage WAL echoue |
| HAProxy | HAProxyDown | instance unreachable |
| HAProxy | HAProxyNoWriteBackend | 0 backend write |
| HAProxy | HAProxyNoReadBackend | 0 backend read |
| PgBouncer | PgBouncerDown | instance unreachable |
| PgBouncer | PgBouncerPoolExhausted | pool sature + clients en attente |
| Pgpool-II | PgpoolDown | instance unreachable |
| Pgpool-II | PgpoolBackendDown | backend status != up |
| Pgpool-II | PgpoolNoPrimary | 0 primary |
| Pgpool-II | PgpoolReplicationDelayCritical | lag > 100 MB |
| Pgpool-II | PgpoolConnectionsSaturated | slots > 95% |

### Alertes WARNING (attention requise)

| Composant | Alerte | Seuil |
|-----------|--------|-------|
| etcd | EtcdHighLeaderChanges | > 3 changes/h |
| etcd | EtcdDiskLatencyHigh | WAL fsync p99 > 100ms |
| etcd | EtcdDatabaseSizeLarge | DB > 500 MB |
| etcd | EtcdBackendCommitSlow | commit p99 > 100ms |
| etcd | EtcdSlowApply | slow applies detectes |
| etcd | EtcdQuotaNearLimit | DB > 80% quota |
| Patroni | PatroniFailoverDetected | changement de leader |
| Patroni | PatroniPendingRestart | restart en attente > 10min |
| Patroni | PatroniReplicationLag | lag > 50 MB |
| PostgreSQL | PostgreSQLReplicationLagWarning | lag > 1s |
| PostgreSQL | PostgreSQLConnectionsHigh | connexions > 80% |
| PostgreSQL | PostgreSQLDeadlocks | deadlocks detectes |
| PostgreSQL | PostgreSQLLongTransaction | requetes > 5 min |
| PostgreSQL | PostgreSQLLocksWaiting | > 10 locks en attente |
| PostgreSQL | PostgreSQLReplicationSlotLagHigh | slot lag > 1 GB |
| PostgreSQL | PostgreSQLDeadTuplesHigh | > 100k dead tuples |
| PostgreSQL | PostgreSQLVacuumTooOld | vacuum > 24h |
| PostgreSQL | PostgreSQLTempFilesHigh | > 10 temp files en 5min |
| PostgreSQL | PostgreSQLCacheHitRatioLow | cache hit < 90% |
| pgBackRest | PgBackRestExporterDown | exporter unreachable |
| pgBackRest | PgBackRestBackupTooOld | full backup > 7 jours |
| HAProxy | HAProxyBackendDown | 1 backend down |
| HAProxy | HAProxySessionsHigh | sessions > 80% |
| HAProxy | HAProxyBackendConnectTimeHigh | connect time > 500ms |
| HAProxy | HAProxyHighErrorRate | > 1 erreur 5xx/s |
| PgBouncer | PgBouncerClientsWaiting | > 5 clients en attente |
| PgBouncer | PgBouncerPoolUsageHigh | pool usage > 80% |
| PgBouncer | PgBouncerMaxWaitHigh | max wait > 5s |
| Pgpool-II | PgpoolReplicationDelayHigh | lag > 10 MB |
| Pgpool-II | PgpoolConnectionsHigh | slots > 80% |
| Pgpool-II | PgpoolHealthCheckFailing | > 3 echecs en 5min |
| Pgpool-II | PgpoolHealthCheckSlow | duree > 5s |
| Pgpool-II | PgpoolLoadBalancingSkewed | 1 backend > 90% SELECTs |
| Node | NodeDiskAlmostFull | disque > 85% |
| Node | NodeMemoryHigh | RAM > 90% |
| Node | NodeCPUHigh | CPU > 90% |

---

## Circuit d'alerte

```
Metrique collectee (scrape Prometheus)
        |
        v
Regle d'alerte evaluee (toutes les 15s)
        |
        v condition vraie pendant "for" ?
        |
    ┌───┴───┐
    | Non   | Oui
    v       v
 inactive  FIRING → Alertmanager
                        |
              ┌─────────┼─────────┐
              v         v         v
           LogNcall   Email     Slack
           (critical) (warning)
```

### Inhibitions configurees

| Si cette alerte fire... | ...alors on supprime celle-ci |
|-------------------------|-------------------------------|
| PostgreSQLDown | PostgreSQLReplicationLag* |
| HAProxyDown | HAProxyBackendDown |
| PatroniDown | PatroniReplicationLag |
