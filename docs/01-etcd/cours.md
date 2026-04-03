# etcd — Cours Complet pour Débutants

## 1. C'est quoi etcd ?

**etcd** (prononcé "et-cee-dee") est un **store clé-valeur distribué**. Imagine un dictionnaire partagé entre plusieurs serveurs, où chaque serveur a la même copie du dictionnaire.

### Analogie simple
Imagine 3 secrétaires qui tiennent le même carnet d'adresses. Quand tu modifies une adresse, les 3 carnets sont mis à jour. Si une secrétaire est absente, les 2 autres continuent de fonctionner. C'est etcd.

### Pourquoi etcd dans notre architecture ?
etcd sert de **source de vérité** pour Patroni. Il stocke :
- Qui est le leader PostgreSQL actuellement
- La configuration du cluster Patroni
- Les informations de santé de chaque nœud

Sans etcd → Patroni ne sait pas qui est le leader → pas de failover automatique → danger.

## 2. Le consensus Raft (simplifié)

### Le problème
Comment s'assurer que 3 serveurs sont d'accord sur la même information, même si l'un d'eux tombe en panne ?

### La solution : l'algorithme Raft
Raft est un algorithme de consensus. Voici comment il fonctionne :

1. **Un leader est élu** parmi les nœuds etcd
2. **Toutes les écritures passent par le leader**
3. Le leader **réplique** l'écriture vers les followers
4. Quand la **majorité** des nœuds confirme l'écriture → elle est validée (commitée)

```
Client → Leader etcd → réplique vers Follower 1
                     → réplique vers Follower 2
         ← majorité confirmée (2/3) → écriture validée ✓
```

### Le Quorum
Le quorum est le nombre minimum de nœuds qui doivent être d'accord.

| Nœuds | Quorum | Pannes tolérées |
|-------|--------|-----------------|
| 1     | 1      | 0               |
| 3     | 2      | 1               |
| 5     | 3      | 2               |
| 7     | 4      | 3               |

**Formule** : Quorum = (N / 2) + 1 (arrondi supérieur)

**Avec 3 nœuds** : quorum = 2. On tolère 1 panne. Si 2 nœuds tombent → perte de quorum → le cluster est en lecture seule (plus d'écriture possible).

## 3. Architecture d'un cluster etcd

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│   etcd-1     │◄───►│   etcd-2     │◄───►│   etcd-3     │
│  (Leader)    │     │  (Follower)  │     │  (Follower)  │
│              │     │              │     │              │
│ Port 2379    │     │ Port 2379    │     │ Port 2379    │
│ (client API) │     │ (client API) │     │ (client API) │
│              │     │              │     │              │
│ Port 2380    │     │ Port 2380    │     │ Port 2380    │
│ (peer comm)  │     │ (peer comm)  │     │ (peer comm)  │
└──────────────┘     └──────────────┘     └──────────────┘
```

### Ports importants
- **2379** : port client — c'est ici que Patroni et les outils se connectent
- **2380** : port peer — communication interne entre les nœuds etcd

## 4. Commandes etcdctl essentielles

### Vérifier la santé du cluster
```bash
# Santé de tous les endpoints
etcdctl endpoint health --cluster

# Résultat attendu :
# http://etcd-1:2379 is healthy: successfully committed proposal: took = 2.5ms
# http://etcd-2:2379 is healthy: successfully committed proposal: took = 3.1ms
# http://etcd-3:2379 is healthy: successfully committed proposal: took = 2.8ms
```

### Voir le statut des membres
```bash
# Liste des membres
etcdctl member list -w table

# Résultat :
# +------------------+---------+--------+-------------------------+-------------------------+
# |        ID        | STATUS  |  NAME  |       PEER ADDRS        |      CLIENT ADDRS       |
# +------------------+---------+--------+-------------------------+-------------------------+
# | 8e9e05c52164694d | started | etcd-1 | http://etcd-1:2380      | http://etcd-1:2379      |
# | 91bc3c398fb3c146 | started | etcd-2 | http://etcd-2:2380      | http://etcd-2:2379      |
# | fd422379fda50e48 | started | etcd-3 | http://etcd-3:2380      | http://etcd-3:2379      |
# +------------------+---------+--------+-------------------------+-------------------------+

# Statut détaillé
etcdctl endpoint status --cluster -w table
```

### Opérations clé-valeur (pour comprendre)
```bash
# Écrire une valeur
etcdctl put /test/key "hello"

# Lire une valeur
etcdctl get /test/key

# Lister les clés avec un préfixe
etcdctl get /patroni/ --prefix --keys-only

# Supprimer une clé
etcdctl del /test/key

# Observer les changements en temps réel
etcdctl watch /patroni/ --prefix
```

### Maintenance
```bash
# Compaction (nettoyer l'historique)
etcdctl compact $(etcdctl endpoint status -w json | jq '.[0].Status.header.revision')

# Défragmentation (récupérer l'espace disque)
etcdctl defrag --cluster

# Vérifier l'espace utilisé
etcdctl endpoint status --cluster -w table
# Regarder la colonne DB SIZE
```

## 5. Métriques etcd pour Prometheus

etcd expose nativement ses métriques au format Prometheus sur `http://etcd-host:2379/metrics`.

### Métriques critiques à monitorer

#### Santé du cluster
```promql
# Le nœud a-t-il un leader ? (1 = oui, 0 = non)
etcd_server_has_leader

# Nombre de changements de leader (devrait être stable)
rate(etcd_server_leader_changes_seen_total[1h])

# Propositions Raft échouées (signe de problème de consensus)
rate(etcd_server_proposals_failed_total[5m])

# Propositions en attente (devrait être ~0)
etcd_server_proposals_pending
```

#### Performance disque
```promql
# Latence d'écriture du WAL (Write-Ahead Log)
# Si > 100ms, le disque est trop lent pour etcd
histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))

# Latence de commit backend
histogram_quantile(0.99, rate(etcd_disk_backend_commit_duration_seconds_bucket[5m]))
```

#### Réseau
```promql
# Latence de communication entre pairs
histogram_quantile(0.99, rate(etcd_network_peer_round_trip_time_seconds_bucket[5m]))

# Échecs d'envoi entre pairs
rate(etcd_network_peer_sent_failures_total[5m])
```

#### Stockage
```promql
# Taille de la base etcd (en bytes)
etcd_mvcc_db_total_size_in_bytes

# Nombre de clés
etcd_debugging_mvcc_keys_total
```

## 6. Switchover et Failover etcd

### Switchover (planifié)
Un switchover etcd est rarement nécessaire car Raft gère automatiquement le leadership. Cependant, pour la maintenance :

```bash
# Transferer le leadership à un autre membre
etcdctl move-leader <target-member-id>

# Exemple :
etcdctl member list  # noter l'ID du membre cible
etcdctl move-leader 91bc3c398fb3c146
```

### Failover (automatique)
Quand le leader etcd tombe :
1. Les followers détectent l'absence de heartbeat (election timeout ~ 1-2s)
2. Un follower se déclare candidat
3. Il demande les votes des autres nœuds
4. S'il obtient la majorité → il devient le nouveau leader
5. Le processus prend généralement **< 3 secondes**

### Que se passe-t-il en cas de perte de quorum ?
```
Scénario : cluster 3 nœuds, 2 tombent
→ Le nœud restant ne peut plus valider d'écritures
→ Les lectures restent possibles (données potentiellement stale)
→ Patroni ne peut plus modifier le cluster PostgreSQL
→ Le leader PostgreSQL continue de fonctionner mais aucun failover possible
→ ALERTE CRITIQUE nécessaire
```

## 7. Configuration type

```yaml
# /etc/etcd/etcd.conf.yml
name: etcd-1
data-dir: /var/lib/etcd

# Écoute client
listen-client-urls: http://0.0.0.0:2379
advertise-client-urls: http://etcd-1:2379

# Écoute peer
listen-peer-urls: http://0.0.0.0:2380
initial-advertise-peer-urls: http://etcd-1:2380

# Cluster initial
initial-cluster: etcd-1=http://etcd-1:2380,etcd-2=http://etcd-2:2380,etcd-3=http://etcd-3:2380
initial-cluster-state: new
initial-cluster-token: etcd-cluster-transactis

# Timeouts
heartbeat-interval: 1000      # 1 seconde
election-timeout: 5000        # 5 secondes

# Métriques
metrics: extensive             # Exposer toutes les métriques

# Quotas
quota-backend-bytes: 8589934592  # 8GB max
auto-compaction-retention: "1"   # Compaction automatique toutes les heures
```

## 8. Problèmes courants et diagnostic

### Symptôme : `etcdctl endpoint health` retourne unhealthy
**Causes possibles :**
1. Le nœud etcd est arrêté → `systemctl status etcd`
2. Problème réseau → `ping etcd-X`
3. Disque plein → `df -h /var/lib/etcd`
4. Quota dépassé → `etcdctl alarm list`

**Résolution quota dépassé :**
```bash
etcdctl alarm list
# Si "NOSPACE" :
etcdctl compact $(etcdctl endpoint status -w json | jq '.[0].Status.header.revision')
etcdctl defrag --cluster
etcdctl alarm disarm
```

### Symptôme : Changements de leader fréquents
**Causes possibles :**
1. Réseau instable entre les nœuds
2. Disque trop lent (HDD au lieu de SSD)
3. CPU saturé sur les nœuds etcd
4. election-timeout trop court

**Diagnostic :**
```bash
# Voir les métriques de latence réseau
curl -s http://etcd-1:2379/metrics | grep etcd_network_peer_round_trip_time

# Voir les métriques disque
curl -s http://etcd-1:2379/metrics | grep etcd_disk_wal_fsync_duration
```

### Symptôme : Perte de quorum
**C'est une urgence !**
1. Identifier quels nœuds sont DOWN
2. Tenter de redémarrer les nœuds DOWN
3. Si un nœud a un disque corrompu : le retirer du cluster et le ré-ajouter
```bash
# Retirer un membre
etcdctl member remove <member-id>

# Ajouter un nouveau membre
etcdctl member add etcd-3 --peer-urls=http://etcd-3:2380
```
