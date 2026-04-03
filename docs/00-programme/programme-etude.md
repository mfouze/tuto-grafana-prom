# Programme d'Étude Personnel — Préparation Intervention Transactis

## Planning de préparation (2 semaines avant l'intervention)

### Semaine 1 (16-20 Mars) : Les Fondamentaux

#### Jour 1-2 : PostgreSQL & Réplication
- [ ] Lire `docs/02-postgresql-patroni/cours.md` — Sections 1 à 3
- [ ] Faire le tutoriel Docker PostgreSQL réplication : `docs/02-postgresql-patroni/tutoriel-docker.md`
- [ ] Comprendre les WAL et le streaming replication
- [ ] Savoir utiliser `psql` pour les commandes de base
- [ ] **Objectif** : être capable de monter un cluster PG 3 nœuds en réplication et vérifier le lag

#### Jour 3 : etcd
- [ ] Lire `docs/01-etcd/cours.md`
- [ ] Faire le tutoriel Docker etcd : `docs/01-etcd/tutoriel-docker.md`
- [ ] Comprendre le consensus Raft et le quorum
- [ ] Savoir utiliser `etcdctl`
- [ ] **Objectif** : être capable de monter un cluster etcd 3 nœuds et simuler une perte de quorum

#### Jour 4 : Patroni
- [ ] Lire `docs/02-postgresql-patroni/cours.md` — Sections 4 à 6
- [ ] Faire le tutoriel Docker Patroni : partie 2 du tutoriel PG
- [ ] Comprendre switchover vs failover
- [ ] Savoir utiliser `patronictl`
- [ ] **Objectif** : monter un cluster Patroni, faire un switchover, simuler un failover

#### Jour 5 : HAProxy & PgBouncer
- [ ] Lire `docs/03-haproxy/cours.md`
- [ ] Lire `docs/04-pgbouncer/cours.md`
- [ ] Faire les tutoriels Docker HAProxy et PgBouncer
- [ ] **Objectif** : comprendre le rôle de chaque composant dans la chaîne de connexion

---

### Semaine 2 (23-27 Mars) : Monitoring & Alerting

#### Jour 1-2 : Prometheus & Grafana
- [ ] Lire `docs/05-prometheus-grafana/cours.md`
- [ ] Faire le tutoriel Docker Prometheus/Grafana : `docs/05-prometheus-grafana/tutoriel-docker.md`
- [ ] Apprendre les bases de PromQL (requêtes Prometheus)
- [ ] Créer un premier dashboard Grafana
- [ ] **Objectif** : savoir écrire des requêtes PromQL, créer des dashboards, comprendre le scraping

#### Jour 3 : Alerting & LogNcall
- [ ] Lire `docs/06-alerting-logncall/cours.md`
- [ ] Faire le tutoriel Docker Alertmanager : `docs/06-alerting-logncall/tutoriel-docker.md`
- [ ] Comprendre le circuit d'alerte : Prometheus → Alertmanager → LogNcall
- [ ] **Objectif** : savoir configurer une règle d'alerte et un receiver Alertmanager

#### Jour 4 : Lab intégré complet
- [ ] Monter le lab Docker complet : `docs/07-docker-lab/lab-complet.md`
- [ ] Tester tous les scénarios de panne :
  - [ ] Kill un nœud etcd → vérifier alerte
  - [ ] Kill le leader PostgreSQL → vérifier failover Patroni → vérifier alerte
  - [ ] Kill HAProxy → vérifier alerte
  - [ ] Kill PgBouncer → vérifier alerte
- [ ] **Objectif** : valider le circuit complet supervision + alerte de bout en bout

#### Jour 5 : Thanos, S3, Tuning & Révision
- [ ] Lire les sections S3/sampling/déduplication dans `docs/05-prometheus-grafana/cours.md`
- [ ] Réviser tous les cours
- [ ] Relire le plan d'intervention : `docs/00-programme/plan-intervention-semaine.md`
- [ ] Préparer une liste de questions pour le premier jour
- [ ] **Objectif** : être prêt et confiant pour le lundi 30 mars

---

## Conseils de préparation

### Méthode d'apprentissage recommandée
1. **Lire le cours** : comprendre les concepts, ne pas mémoriser
2. **Faire le tutoriel** : pratiquer avec Docker, c'est en faisant qu'on retient
3. **Casser des trucs** : simuler des pannes, c'est le meilleur moyen d'apprendre
4. **Prendre des notes** : noter ce qui n'est pas clair pour poser des questions

### Commandes à connaître par cœur
```bash
# etcd
etcdctl endpoint health
etcdctl endpoint status
etcdctl member list

# Patroni
patronictl list
patronictl switchover
patronictl failover
patronictl show-config

# PostgreSQL
psql -c "SELECT * FROM pg_stat_replication;"
psql -c "SELECT pg_is_in_recovery();"
psql -c "SELECT * FROM pg_stat_activity;"

# pgBackRest
pgbackrest info
pgbackrest check

# PgBouncer
psql -p 6432 pgbouncer -c "SHOW POOLS;"
psql -p 6432 pgbouncer -c "SHOW STATS;"
psql -p 6432 pgbouncer -c "SHOW CLIENTS;"

# HAProxy
# Accéder à la page stats : http://haproxy-host:8404/stats

# Prometheus
# Accéder à l'UI : http://prometheus-host:9090
# PromQL : up, rate(), increase(), avg_over_time()

# Grafana
# Accéder à l'UI : http://grafana-host:3000
```

### Ce qu'on attend de toi sur site
- Être capable de **diagnostiquer** une situation en lisant les métriques
- Savoir **configurer** les alertes dans Prometheus/Alertmanager
- Savoir **créer/modifier** des dashboards Grafana
- Comprendre le **flux** : incident → détection → alerte → notification → réaction
- Être **autonome** pour tester et valider les configurations
