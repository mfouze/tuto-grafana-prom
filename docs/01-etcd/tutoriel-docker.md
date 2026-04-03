# Tutoriel Pratique : Cluster etcd sur Docker

## Prérequis
- Docker et Docker Compose installés
- Un terminal

## Objectifs
1. Monter un cluster etcd 3 nœuds
2. Explorer les commandes etcdctl
3. Simuler des pannes et observer le comportement
4. Exposer les métriques Prometheus

---

## Étape 1 : Créer le docker-compose

Crée un fichier `docker-compose-etcd.yml` :

```yaml
version: '3.8'

services:
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
      - --initial-cluster-token=etcd-lab
      - --metrics=extensive
    ports:
      - "2379:2379"
    networks:
      - etcd-net
    volumes:
      - etcd1-data:/etcd-data

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
      - --initial-cluster-token=etcd-lab
      - --metrics=extensive
    ports:
      - "2381:2379"
    networks:
      - etcd-net
    volumes:
      - etcd2-data:/etcd-data

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
      - --initial-cluster-token=etcd-lab
      - --metrics=extensive
    ports:
      - "2382:2379"
    networks:
      - etcd-net
    volumes:
      - etcd3-data:/etcd-data

networks:
  etcd-net:
    driver: bridge

volumes:
  etcd1-data:
  etcd2-data:
  etcd3-data:
```

## Étape 2 : Démarrer le cluster

```bash
docker compose -f docker-compose-etcd.yml up -d
```

Vérifie que les 3 conteneurs tournent :
```bash
docker compose -f docker-compose-etcd.yml ps
```

## Étape 3 : Explorer le cluster

### 3.1 Vérifier la santé
```bash
# Se connecter au conteneur etcd-1
docker exec -it etcd-1 etcdctl endpoint health --cluster

# Résultat attendu : les 3 endpoints sont healthy
```

### 3.2 Voir les membres
```bash
docker exec -it etcd-1 etcdctl member list -w table
```

### 3.3 Voir qui est le leader
```bash
docker exec -it etcd-1 etcdctl endpoint status --cluster -w table
# La colonne IS LEADER indique qui est le leader
```

### 3.4 Manipuler des clés
```bash
# Écrire une valeur
docker exec -it etcd-1 etcdctl put /demo/nom "Transactis"

# Lire depuis un autre nœud (la valeur est répliquée !)
docker exec -it etcd-2 etcdctl get /demo/nom

# Écrire plusieurs clés
docker exec -it etcd-1 etcdctl put /demo/ville "Paris"
docker exec -it etcd-1 etcdctl put /demo/projet "Supervision"

# Lister toutes les clés avec préfixe
docker exec -it etcd-3 etcdctl get /demo/ --prefix
```

## Étape 4 : Simuler des pannes

### 4.1 Perte d'un follower (toléré)
```bash
# Identifier qui est le leader
docker exec -it etcd-1 etcdctl endpoint status --cluster -w table

# Arrêter un follower (disons etcd-3)
docker stop etcd-3

# Vérifier : le cluster fonctionne toujours !
docker exec -it etcd-1 etcdctl endpoint health --cluster
# etcd-3 sera "unhealthy" mais les 2 autres OK

# Les écritures fonctionnent toujours (quorum = 2/3 = OK)
docker exec -it etcd-1 etcdctl put /demo/test "ça marche encore"
docker exec -it etcd-2 etcdctl get /demo/test

# Redémarrer etcd-3
docker start etcd-3

# Vérifier : le cluster est de nouveau complet
docker exec -it etcd-1 etcdctl endpoint health --cluster
```

### 4.2 Perte du leader (failover automatique)
```bash
# Identifier le leader
docker exec -it etcd-1 etcdctl endpoint status --cluster -w table

# Supposons que etcd-1 est le leader. Arrêtons-le !
docker stop etcd-1

# Attendre 2-3 secondes que l'élection se fasse

# Vérifier depuis etcd-2 : un nouveau leader a été élu
docker exec -it etcd-2 etcdctl endpoint status --cluster -w table

# Le cluster fonctionne toujours !
docker exec -it etcd-2 etcdctl put /demo/leader "nouveau leader élu"

# Redémarrer etcd-1 : il rejoint en tant que follower
docker start etcd-1
docker exec -it etcd-1 etcdctl endpoint status --cluster -w table
```

### 4.3 Perte de quorum (CRITIQUE)
```bash
# Arrêter 2 nœuds sur 3
docker stop etcd-2 etcd-3

# Le nœud restant ne peut plus écrire !
docker exec -it etcd-1 etcdctl put /demo/test "ça marche ?"
# → Erreur : context deadline exceeded (timeout car pas de quorum)

# Les lectures peuvent encore fonctionner en mode serializable
docker exec -it etcd-1 etcdctl get /demo/nom --consistency=s

# Redémarrer les nœuds pour restaurer le quorum
docker start etcd-2 etcd-3

# Vérifier la restauration
docker exec -it etcd-1 etcdctl endpoint health --cluster
```

## Étape 5 : Explorer les métriques Prometheus

```bash
# Les métriques sont exposées sur le port 2379/metrics
curl -s http://localhost:2379/metrics | head -50

# Chercher des métriques spécifiques
curl -s http://localhost:2379/metrics | grep etcd_server_has_leader
curl -s http://localhost:2379/metrics | grep etcd_server_leader_changes
curl -s http://localhost:2379/metrics | grep etcd_mvcc_db_total_size
curl -s http://localhost:2379/metrics | grep etcd_disk_wal_fsync

# Comparer les métriques entre les nœuds
echo "=== etcd-1 ===" && curl -s http://localhost:2379/metrics | grep etcd_server_has_leader
echo "=== etcd-2 ===" && curl -s http://localhost:2381/metrics | grep etcd_server_has_leader
echo "=== etcd-3 ===" && curl -s http://localhost:2382/metrics | grep etcd_server_has_leader
```

## Étape 6 : Maintenance

### 6.1 Compaction
```bash
# Obtenir la révision actuelle
docker exec -it etcd-1 etcdctl endpoint status -w json | python3 -m json.tool | grep revision

# Compacter (nettoyer l'historique jusqu'à la révision actuelle)
REV=$(docker exec etcd-1 etcdctl endpoint status -w json | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['Status']['header']['revision'])")
docker exec -it etcd-1 etcdctl compact $REV
```

### 6.2 Défragmentation
```bash
docker exec -it etcd-1 etcdctl defrag --cluster
```

### 6.3 Transfer de leadership
```bash
# Lister les membres pour avoir les IDs
docker exec -it etcd-1 etcdctl member list -w table

# Transférer le leadership (remplacer par l'ID réel)
docker exec -it etcd-1 etcdctl move-leader <target-id>
```

## Étape 7 : Nettoyage

```bash
docker compose -f docker-compose-etcd.yml down -v
```

---

## Exercices de validation

### Exercice 1 : Diagnostic
1. Démarre le cluster
2. Arrête un nœud (sans regarder lequel)
3. En utilisant uniquement `etcdctl`, détermine :
   - Quel nœud est arrêté ?
   - Le cluster a-t-il un leader ?
   - Le cluster peut-il accepter des écritures ?

### Exercice 2 : Récupération
1. Simule une perte de quorum (arrête 2 nœuds)
2. Vérifie que les écritures échouent
3. Restaure le quorum
4. Vérifie que les données sont intactes

### Exercice 3 : Métriques
1. Avant de créer une panne, note la valeur de `etcd_server_leader_changes_seen_total`
2. Kill le leader
3. Après le failover, vérifie que le compteur a augmenté
4. Vérifie que `etcd_server_has_leader` est revenu à 1 sur tous les nœuds
