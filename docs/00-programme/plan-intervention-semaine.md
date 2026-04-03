# Plan Détaillé de l'Intervention — Semaine du 30 Mars 2026

## Vue d'ensemble de l'architecture

```
                    ┌─────────────┐
                    │   Clients   │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │   HAProxy   │  ← Load Balancer / Failover
                    │  (cluster)  │
                    └──────┬──────┘
                           │
                    ┌──────▼──────┐
                    │  PgBouncer  │  ← Connection Pooler
                    │  (cluster)  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              │            │            │
        ┌─────▼────┐ ┌────▼─────┐ ┌────▼─────┐
        │ PG Node1 │ │ PG Node2 │ │ PG Node3 │  ← PostgreSQL + Patroni
        │ (Leader)  │ │(Replica) │ │(Replica) │
        └─────┬────┘ └────┬─────┘ └────┬─────┘
              │            │            │
              └────────────┼────────────┘
                           │
                    ┌──────▼──────┐
                    │    etcd     │  ← Consensus / Leader Election
                    │  (cluster)  │
                    └─────────────┘

        ┌──────────────────────────────────────┐
        │  Prometheus → Grafana → LogNcall     │  ← Monitoring & Alerting
        │  (S3 storage, sampling, dedup)       │
        └──────────────────────────────────────┘
```

---

## Lundi 30 Mars — etcd & Fondations

### Matin (9h-12h) : Supervision du cluster etcd

**Ce que ça implique :**
- **etcd** est un store clé-valeur distribué qui sert de "cerveau" au cluster. C'est lui qui garde l'information "qui est le leader PostgreSQL en ce moment ?"
- **Quorum** : avec 3 nœuds etcd, il faut au moins 2 nœuds en vie pour que le cluster fonctionne (majorité). Si 2 nœuds tombent → perte de quorum → le cluster PostgreSQL ne peut plus élire de nouveau leader
- **Switchover** : bascule volontaire et planifiée du leader etcd (maintenance)
- **Failover** : bascule automatique quand un nœud etcd tombe en panne

**Tâches concrètes :**
1. Vérifier la santé du cluster etcd (`etcdctl endpoint health`)
2. Monitorer les métriques etcd exposées sur le port 2379 (métriques Prometheus)
3. Configurer les alertes sur :
   - Perte d'un membre etcd
   - Latence des requêtes etcd > seuil
   - Espace disque etcd (compaction)
   - Perte de quorum
4. Configurer le déclenchement d'alerte LogNcall en cas d'incident

**Métriques clés à surveiller :**
| Métrique | Signification | Seuil d'alerte |
|----------|---------------|-----------------|
| `etcd_server_has_leader` | Le nœud a-t-il un leader ? | == 0 → CRITIQUE |
| `etcd_server_leader_changes_seen_total` | Nombre de changements de leader | > 3/heure → WARNING |
| `etcd_disk_wal_fsync_duration_seconds` | Latence écriture disque | > 100ms → WARNING |
| `etcd_network_peer_sent_failures_total` | Échecs communication entre nœuds | croissant → WARNING |
| `etcd_server_proposals_failed_total` | Propositions Raft échouées | croissant → CRITIQUE |
| `etcd_mvcc_db_total_size_in_bytes` | Taille de la BDD etcd | > 2GB → WARNING |

### Après-midi (14h-17h) : Mise en place des alertes LogNcall pour etcd

**Ce que ça implique :**
- **LogNcall** est un système d'alerte qui envoie des notifications (SMS, appel, email) aux équipes d'astreinte quand un incident survient
- Il faut configurer des règles d'alerte dans Prometheus qui déclenchent des alertes vers LogNcall via Alertmanager

**Tâches concrètes :**
1. Définir les règles d'alerte Prometheus pour etcd
2. Configurer Alertmanager pour router les alertes vers LogNcall
3. Tester le circuit d'alerte complet (simuler une panne → vérifier réception)
4. Documenter les procédures de réaction aux alertes

---

## Mardi 31 Mars — PostgreSQL / Patroni (Supervision)

### Matin (9h-12h) : Supervision PostgreSQL et pgexporter

**Ce que ça implique :**
- **pgexporter** (ou postgres_exporter) est un outil qui expose les métriques internes de PostgreSQL au format Prometheus
- Il faut surveiller les performances, les connexions, les locks, la réplication, etc.
- **Lag de réplication** : c'est le retard entre le serveur principal (leader) et les réplicas. Si le lag augmente, les réplicas ont des données obsolètes → danger en cas de failover

**Tâches concrètes :**
1. Vérifier que pgexporter est installé et fonctionnel sur chaque nœud
2. Configurer les métriques custom si nécessaire
3. Créer les dashboards Grafana pour PostgreSQL
4. Configurer les alertes sur les métriques PostgreSQL

**Métriques clés PostgreSQL :**
| Métrique | Signification | Seuil d'alerte |
|----------|---------------|-----------------|
| `pg_stat_replication_replay_lag` | Retard de réplication (secondes) | > 30s → WARNING, > 300s → CRITIQUE |
| `pg_stat_activity_connections` | Nombre de connexions actives | > 80% max_connections → WARNING |
| `pg_stat_activity_max_tx_duration` | Durée max transaction | > 300s → WARNING |
| `pg_locks_count` | Nombre de locks | > 100 → WARNING |
| `pg_database_size_bytes` | Taille des bases | croissance anormale → WARNING |
| `pg_up` | PostgreSQL est-il joignable ? | == 0 → CRITIQUE |

### Après-midi (14h-17h) : pgBackRest et sauvegarde

**Ce que ça implique :**
- **pgBackRest** est l'outil de sauvegarde de PostgreSQL. Il gère les sauvegardes complètes (full), différentielles (diff) et incrémentales (incr)
- En supervision, il faut vérifier que les sauvegardes s'exécutent correctement et dans les temps
- **WAL archiving** : les Write-Ahead Logs sont archivés en continu pour permettre la restauration point-in-time (PITR)

**Tâches concrètes :**
1. Vérifier la configuration pgBackRest existante
2. Monitorer l'âge de la dernière sauvegarde réussie
3. Monitorer l'archivage WAL (retard, échecs)
4. Configurer des alertes si sauvegarde échoue ou trop ancienne

**Métriques clés pgBackRest :**
| Métrique | Signification | Seuil d'alerte |
|----------|---------------|-----------------|
| `pgbackrest_backup_last_full_age` | Âge dernière sauvegarde full | > 7 jours → WARNING |
| `pgbackrest_backup_last_diff_age` | Âge dernière sauvegarde diff | > 24h → WARNING |
| `pgbackrest_backup_error` | Erreur de sauvegarde | == 1 → CRITIQUE |
| `pg_stat_archiver_failed_count` | WAL archiving échoué | > 0 → CRITIQUE |

---

## Mercredi 1er Avril — Patroni (Switchover/Failover) + HAProxy

### Matin (9h-12h) : Supervision du cluster Patroni

**Ce que ça implique :**
- **Patroni** est le gestionnaire de haute disponibilité pour PostgreSQL. Il utilise etcd pour l'élection du leader et gère automatiquement les failovers
- **Switchover Patroni** : bascule volontaire du leader PostgreSQL vers un replica (ex: maintenance sur le serveur leader)
- **Failover Patroni** : bascule automatique quand le leader PostgreSQL tombe. Patroni élit un nouveau leader parmi les replicas
- Le **quorum** Patroni dépend du quorum etcd — si etcd perd son quorum, Patroni ne peut plus fonctionner

**Tâches concrètes :**
1. Monitorer l'état du cluster Patroni (`patronictl list`)
2. Surveiller les changements de rôle (leader ↔ replica)
3. Configurer les alertes sur les événements Patroni
4. Tester un switchover planifié et vérifier les métriques
5. Configurer les alertes LogNcall pour les incidents Patroni

**Métriques clés Patroni :**
| Métrique | Signification | Seuil d'alerte |
|----------|---------------|-----------------|
| `patroni_postgres_running` | PostgreSQL est-il en fonctionnement ? | == 0 → CRITIQUE |
| `patroni_primary` | Ce nœud est-il le leader ? | changement inattendu → WARNING |
| `patroni_xlog_location` / `patroni_xlog_replayed_location` | Lag de réplication (diff WAL primary vs replica) | écart > 30s → WARNING |
| `patroni_cluster_has_leader` | Le cluster a-t-il un leader ? | == 0 → CRITIQUE |
| `patroni_failover_count` | Nombre de failovers | augmentation → WARNING |

### Après-midi (14h-17h) : Supervision du cluster HAProxy

**Ce que ça implique :**
- **HAProxy** est le load balancer qui distribue le trafic entre les nœuds PostgreSQL. Il est le point d'entrée pour les applications
- Il utilise des **health checks** pour savoir quel nœud est le leader et quels sont les replicas
- **Failover des backends** : quand HAProxy détecte qu'un backend (nœud PG) est DOWN, il redirige automatiquement le trafic vers les backends UP
- Si HAProxy lui-même tombe → les applications ne peuvent plus accéder à PostgreSQL → CRITIQUE

**Tâches concrètes :**
1. Activer la page de statistiques HAProxy (`stats enable`)
2. Configurer l'export des métriques HAProxy vers Prometheus (haproxy_exporter ou stats natif)
3. Monitorer l'état des backends (UP/DOWN)
4. Configurer les alertes sur l'indisponibilité de HAProxy et des backends
5. Configurer les alertes LogNcall

**Métriques clés HAProxy :**
| Métrique | Signification | Seuil d'alerte |
|----------|---------------|-----------------|
| `haproxy_up` | HAProxy est-il joignable ? | == 0 → CRITIQUE |
| `haproxy_backend_status` | État des backends | DOWN → CRITIQUE |
| `haproxy_backend_active_servers` | Nombre serveurs actifs | == 0 → CRITIQUE |
| `haproxy_frontend_current_sessions` | Sessions en cours | > 80% maxconn → WARNING |
| `haproxy_backend_response_time_average` | Temps de réponse moyen | > 1s → WARNING |
| `haproxy_backend_connection_errors_total` | Erreurs de connexion | croissant rapide → WARNING |

---

## Jeudi 2 Avril — PgBouncer + Prometheus/Grafana Déduplication

### Matin (9h-12h) : Supervision du cluster PgBouncer

**Ce que ça implique :**
- **PgBouncer** est un pooler de connexions. Il maintient un pool de connexions ouvertes vers PostgreSQL et les partage entre les clients
- Sans PgBouncer, chaque client ouvre sa propre connexion → PostgreSQL sature rapidement (chaque connexion = ~10MB RAM)
- **Failover PgBouncer** : si PgBouncer tombe, les applications perdent l'accès à la BDD → il faut un mécanisme de haute disponibilité (ex: Keepalived, HAProxy devant PgBouncer)

**Tâches concrètes :**
1. Monitorer les métriques PgBouncer (`SHOW STATS`, `SHOW POOLS`, `SHOW CLIENTS`)
2. Configurer l'export des métriques vers Prometheus (pgbouncer_exporter)
3. Surveiller les pools de connexions (actives, en attente, libres)
4. Configurer les alertes sur l'indisponibilité et la saturation
5. Configurer les alertes LogNcall

**Métriques clés PgBouncer :**
| Métrique | Signification | Seuil d'alerte |
|----------|---------------|-----------------|
| `pgbouncer_up` | PgBouncer est-il joignable ? | == 0 → CRITIQUE |
| `pgbouncer_pools_server_active` | Connexions serveur actives | > 80% pool_size → WARNING |
| `pgbouncer_pools_client_waiting` | Clients en attente de connexion | > 0 prolongé → WARNING |
| `pgbouncer_pools_server_idle` | Connexions serveur libres | == 0 → WARNING |
| `pgbouncer_stats_avg_query_time` | Temps moyen des requêtes | > seuil normal → WARNING |

### Après-midi (14h-17h) : Déduplication des métriques Prometheus/Grafana

**Ce que ça implique :**
- Quand on a plusieurs instances Prometheus (pour la haute disponibilité), chacune scrape les mêmes cibles → **métriques dupliquées**
- **Déduplication** : on utilise Thanos ou un mécanisme similaire pour ne garder qu'une seule copie de chaque série temporelle
- Dans Grafana, il faut s'assurer que les dashboards ne montrent pas de valeurs doublées

**Tâches concrètes :**
1. Identifier la stratégie de déduplication en place (Thanos ? Prometheus HA ?)
2. Configurer les `external_labels` dans Prometheus pour différencier les instances
3. Configurer la déduplication au niveau du query layer
4. Vérifier dans Grafana que les métriques ne sont pas doublées
5. Tester avec un dashboard de contrôle

---

## Vendredi 3 Avril — Prometheus S3, Sampling & Tuning

### Matin (9h-12h) : Configuration Prometheus avec S3 et sampling

**Ce que ça implique :**
- **Stockage S3** : au lieu de garder toutes les métriques en local, on archive les anciennes métriques vers S3 (stockage objet, moins cher). Typiquement via Thanos Sidecar + Thanos Store Gateway
- **Sampling** : réduire la résolution des métriques anciennes. Ex: garder 1 point par seconde pour les dernières 24h, puis 1 point par 5 minutes pour les 30 derniers jours, puis 1 point par heure pour l'historique
- Cela permet de maîtriser les coûts de stockage et les performances des requêtes

**Tâches concrètes :**
1. Configurer le remote_write ou Thanos Sidecar vers S3
2. Définir les règles de rétention locale et distante
3. Configurer les recording rules pour le downsampling
4. Tester la lecture des métriques historiques depuis S3

### Après-midi (14h-17h) : Validation du tuning Prometheus/Grafana

**Ce que ça implique :**
- **Tuning Prometheus** : ajuster la configuration pour que Prometheus soit performant (scrape_interval, evaluation_interval, taille TSDB, mémoire, etc.)
- **Tuning Grafana** : optimiser les dashboards (requêtes efficaces, variables bien utilisées, pas de requêtes trop lourdes)
- **Validation** : s'assurer que tout le dispositif de supervision fonctionne de bout en bout

**Tâches concrètes :**
1. Vérifier les paramètres de performance Prometheus
   - `--storage.tsdb.retention.time` et `--storage.tsdb.retention.size`
   - `--query.max-concurrency`
   - `--storage.tsdb.wal-compression`
2. Optimiser les requêtes PromQL dans les dashboards Grafana
3. Vérifier les recording rules (pré-calcul des requêtes lourdes)
4. Test de charge / validation de bout en bout
5. Documentation finale et transfert de connaissances

---

## Checklist globale de la semaine

- [ ] Lundi : etcd supervisé + alertes LogNcall opérationnelles
- [ ] Mardi : PostgreSQL/Patroni supervisé + pgBackRest monitoré
- [ ] Mercredi : Patroni failover supervisé + HAProxy supervisé
- [ ] Jeudi : PgBouncer supervisé + déduplication métriques configurée
- [ ] Vendredi : S3 configuré + tuning validé + documentation complète
