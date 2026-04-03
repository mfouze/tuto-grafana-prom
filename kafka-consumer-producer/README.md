# Scripts Kafka Consumer/Producer pour Tests Prometheus

Ce répertoire contient deux scripts Python permettant de générer une charge de trafic Kafka pour tester et monitorer votre cluster Kafka avec Prometheus.

## 📋 Prérequis

### Option 1 : Installation locale

Les scripts nécessitent les bibliothèques suivantes. Installez-les avec :

```bash
pip install -r requirements.txt
```

Ou manuellement :

```bash
pip install kafka-python confluent-kafka python-dotenv
```

**Note importante** : 
- `kafka_producer_bomber.py` utilise la bibliothèque `kafka-python`
- `kafka_consumer_bomber.py` utilise la bibliothèque `confluent-kafka`
- Les deux scripts utilisent `python-dotenv` pour charger les variables d'environnement depuis un fichier `.env`

### Option 2 : Utilisation avec Docker (recommandé)

Un Dockerfile est fourni pour exécuter les scripts et les outils Kafka perf test dans un conteneur Docker.

**Avantages** :
- ✅ Environnement isolé et reproductible
- ✅ Inclut les outils Kafka perf test officiels
- ✅ Pas besoin d'installer les dépendances localement
- ✅ Compatible avec tous les systèmes d'exploitation

### Configuration Kafka

Les scripts nécessitent :
- Un cluster Kafka avec authentification SASL_SSL/PLAIN
- Des credentials (username/password) valides
- Accès réseau aux brokers Kafka

### Configuration via fichier .env (recommandé)

Pour éviter de passer les credentials en ligne de commande, vous pouvez utiliser un fichier `.env` :

1. **Créer le fichier `.env`** :
   ```bash
   cp env.example .env
   ```

2. **Éditer le fichier `.env`** avec vos paramètres :
   ```bash
   # Paramètres de connexion (requis)
   KAFKA_BOOTSTRAP_SERVERS=kafka1:9092,kafka2:9092
   KAFKA_USERNAME=votre_username
   KAFKA_PASSWORD=votre_password
   
   # Paramètres de sécurité (optionnels)
   KAFKA_SECURITY_PROTOCOL=SASL_SSL
   KAFKA_SASL_MECHANISM=PLAIN
   
   # Paramètres optionnels
   KAFKA_TOPIC_PREFIX=test-prometheus
   KAFKA_NUM_TOPICS=10
   KAFKA_MESSAGES_PER_SECOND=1000
   KAFKA_NUM_THREADS=5
   KAFKA_DURATION_MINUTES=60
   ```

3. **Utiliser les scripts** sans passer les paramètres en ligne de commande :
   ```bash
   python3 kafka_producer_bomber.py
   python3 kafka_consumer_bomber.py
   ```

**Sécurité** : Ajoutez `.env` à votre `.gitignore` pour ne pas commiter vos credentials !

#### Variables d'environnement disponibles

| Variable | Description | Exemple |
|----------|-------------|---------|
| `KAFKA_BOOTSTRAP_SERVERS` | Serveurs Kafka (requis) | `kafka1:9092,kafka2:9092` |
| `KAFKA_USERNAME` | Nom d'utilisateur SASL (requis) | `admin` |
| `KAFKA_PASSWORD` | Mot de passe SASL (requis) | `secret` |
| `KAFKA_SECURITY_PROTOCOL` | Protocole de sécurité | `SASL_SSL`, `SASL_PLAINTEXT`, `SSL`, `PLAINTEXT` |
| `KAFKA_SASL_MECHANISM` | Mécanisme SASL | `PLAIN`, `SCRAM-SHA-256`, `SCRAM-SHA-512` |
| `KAFKA_TOPIC_PREFIX` | Préfixe des topics | `test-prometheus` |
| `KAFKA_NUM_TOPICS` | Nombre de topics | `10` |
| `KAFKA_MESSAGES_PER_SECOND` | Messages/seconde (producteur) | `1000` |
| `KAFKA_NUM_THREADS` | Nombre de threads (producteur) | `5` |
| `KAFKA_CONSUMER_GROUP` | Groupe de consommateurs | `prometheus-test-group` |
| `KAFKA_NUM_CONSUMERS` | Nombre de consommateurs | `1` |
| `KAFKA_AUTO_OFFSET_RESET` | Position de départ | `earliest` ou `latest` |
| `KAFKA_DURATION_MINUTES` | Durée en minutes | `60` |
| `KAFKA_SSL_CAFILE` | Chemin fichier CA SSL | `/path/to/ca.pem` |
| `KAFKA_SSL_CERTFILE` | Chemin fichier certificat SSL | `/path/to/cert.pem` |
| `KAFKA_SSL_KEYFILE` | Chemin fichier clé SSL | `/path/to/key.pem` |
| `KAFKA_SSL_PASSWORD` | Mot de passe clé SSL | `key_password` |
| `KAFKA_VERBOSE` | Mode verbeux | `true` ou `false` |

**Note** : Les paramètres passés en ligne de commande ont priorité sur les variables d'environnement.

---

## 🚀 kafka_producer_bomber.py

### Description

Script qui génère et envoie des messages JSON aléatoires vers plusieurs topics Kafka. Il simule différents types de données (activité utilisateur, métriques système, transactions, logs, données de capteurs) pour créer une charge réaliste sur le cluster.

### Utilisation

#### Commande de base

**Avec fichier .env** (recommandé) :
```bash
python3 kafka_producer_bomber.py
```

**Sans fichier .env** :
```bash
python3 kafka_producer_bomber.py \
  --bootstrap-servers kafka1:9092,kafka2:9092 \
  --username votre_username \
  --password votre_password
```

**Mélange .env + ligne de commande** (les arguments CLI ont priorité) :
```bash
python3 kafka_producer_bomber.py \
  --messages-per-second 2000 \
  --duration-minutes 30
```

#### Options disponibles (ligne de commande)

| Option | Description | Défaut |
|--------|-------------|--------|
| `--bootstrap-servers` | **Requis** (ou via `KAFKA_BOOTSTRAP_SERVERS`). Liste des serveurs Kafka (séparés par des virgules) | Variable d'env ou - |
| `--username` | **Requis** (ou via `KAFKA_USERNAME`). Nom d'utilisateur SASL PLAIN | Variable d'env ou - |
| `--password` | **Requis** (ou via `KAFKA_PASSWORD`). Mot de passe SASL PLAIN | Variable d'env ou - |
| `--security-protocol` | Protocole de sécurité (ou via `KAFKA_SECURITY_PROTOCOL`) | Variable d'env ou `SASL_SSL` |
| `--sasl-mechanism` | Mécanisme SASL (ou via `KAFKA_SASL_MECHANISM`) | Variable d'env ou `PLAIN` |
| `--topic-prefix` | Préfixe des topics à créer (ou via `KAFKA_TOPIC_PREFIX`) | Variable d'env ou `test-prometheus` |
| `--num-topics` | Nombre de topics à utiliser (ou via `KAFKA_NUM_TOPICS`) | Variable d'env ou `10` |
| `--messages-per-second` | Messages par seconde (ou via `KAFKA_MESSAGES_PER_SECOND`) | Variable d'env ou `1000` |
| `--num-threads` | Nombre de threads producteurs (ou via `KAFKA_NUM_THREADS`) | Variable d'env ou `5` |
| `--duration-minutes` | Durée en minutes (ou via `KAFKA_DURATION_MINUTES`) | Variable d'env ou `60` |
| `--verbose` | Mode verbeux (ou via `KAFKA_VERBOSE=true`) | Variable d'env ou `False` |

#### Paramètres de configuration (classe ProducerConfig)

Ces paramètres sont définis dans le code et peuvent être modifiés directement dans le script si nécessaire :

| Paramètre | Description | Valeur par défaut |
|-----------|-------------|-------------------|
| `bootstrap_servers` | Liste des serveurs Kafka | Défini via `--bootstrap-servers` |
| `security_protocol` | Protocole de sécurité | Défini via `--security-protocol` ou `KAFKA_SECURITY_PROTOCOL` (défaut: `SASL_SSL`) |
| `sasl_mechanism` | Mécanisme SASL | Défini via `--sasl-mechanism` ou `KAFKA_SASL_MECHANISM` (défaut: `PLAIN`) |
| `sasl_plain_username` | Nom d'utilisateur SASL | Défini via `--username` |
| `sasl_plain_password` | Mot de passe SASL | Défini via `--password` |
| `topic_prefix` | Préfixe des topics | `test-prometheus` |
| `num_topics` | Nombre de topics | `10` |
| `messages_per_second` | Messages par seconde | `1000` |
| `message_size_kb` | Taille cible des messages en KB | `1` (non utilisé actuellement) |
| `num_threads` | Nombre de threads | `5` |
| `duration_minutes` | Durée en minutes | `60` |

#### Paramètres Kafka Producer (codés en dur)

Ces paramètres sont configurés dans la méthode `_create_producer()` et peuvent être modifiés dans le code :

| Paramètre | Description | Valeur |
|-----------|-------------|--------|
| `acks` | Confirmation requise (all = tous les replicas) | `'all'` |
| `retries` | Nombre de tentatives en cas d'échec | `3` |
| `retry_backoff_ms` | Délai entre les tentatives (ms) | `100` |
| `request_timeout_ms` | Timeout des requêtes (ms) | `30000` (30s) |
| `max_block_ms` | Temps max d'attente pour obtenir des métadonnées (ms) | `10000` (10s) |
| `compression_type` | Type de compression | `'gzip'` |
| `batch_size` | Taille du batch en octets | `16384` (16 KB) |
| `linger_ms` | Délai avant envoi du batch (ms) | `10` |
| `buffer_memory` | Mémoire tampon en octets | `33554432` (32 MB) |
| `max_request_size` | Taille max d'une requête en octets | `1048576` (1 MB) |
| `value_serializer` | Sérialiseur de valeur | JSON encodé en UTF-8 |
| `key_serializer` | Sérialiseur de clé | UTF-8 (si fournie) |

#### Exemples

**Test rapide (5 minutes, 100 msg/s)**
```bash
python3 kafka_producer_bomber.py \
  --bootstrap-servers kafka1:9092 \
  --username admin \
  --password secret \
  --messages-per-second 100 \
  --duration-minutes 5
```

**Test intensif (1 heure, 5000 msg/s, 20 topics)**
```bash
python3 kafka_producer_bomber.py \
  --bootstrap-servers kafka1:9092,kafka2:9092,kafka3:9092 \
  --username admin \
  --password secret \
  --topic-prefix production-test \
  --num-topics 20 \
  --messages-per-second 5000 \
  --num-threads 10 \
  --duration-minutes 60
```

### Types de messages générés

Le script génère 5 types de messages différents :

1. **user_activity** : Activité utilisateur (login, logout, navigation, etc.)
2. **system_metrics** : Métriques système (CPU, mémoire, disque, etc.)
3. **transaction** : Transactions financières
4. **log_event** : Événements de log (DEBUG, INFO, WARN, ERROR, FATAL)
5. **sensor_data** : Données de capteurs IoT (température, humidité, etc.)

#### Paramètres de génération de messages (MessageGenerator)

| Type de données | Plage de valeurs | Description |
|-----------------|------------------|-------------|
| `user_id` | `user_1` à `user_100000` | ID utilisateur aléatoire |
| `session_id` | `session_100000` à `session_999999` | ID de session |
| `ip_address` | `1.1.1.1` à `255.255.255.255` | Adresse IP aléatoire |
| `server_id` | `server_1` à `server_100` | ID serveur |
| `value` (métriques) | `0.0` à `100.0` | Valeur métrique (float) |
| `transaction_id` | `txn_1000000` à `txn_9999999` | ID transaction |
| `amount` | `1.0` à `10000.0` | Montant transaction (float) |
| `currency` | `USD`, `EUR`, `GBP`, `JPY` | Devise aléatoire |
| `level` (logs) | `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL` | Niveau de log |
| `sensor_id` | `sensor_1` à `sensor_1000` | ID capteur |
| `latitude` | `-90.0` à `90.0` | Latitude (6 décimales) |
| `longitude` | `-180.0` à `180.0` | Longitude (6 décimales) |
| `altitude` | `0.0` à `5000.0` | Altitude en mètres |

#### Métadonnées ajoutées automatiquement

Chaque message généré inclut automatiquement un champ `_metadata` :
- `generated_at` : Timestamp ISO de génération
- `message_id` : ID unique du message (`msg_1000000` à `msg_9999999`)
- `version` : Version du format (`1.0`)
- `source` : Source du message (`kafka_producer_bomber`)

### Statistiques affichées

Toutes les 10 secondes, le script affiche :
- Nombre de messages envoyés
- Nombre de messages échoués
- Taux de messages par seconde (msg/s)
- Débit en MB/s
- Nombre de topics utilisés

À la fin de l'exécution, un résumé complet est affiché incluant :
- Messages envoyés totaux
- Messages échoués totaux
- Taux moyen (msg/s)
- Débit moyen (MB/s)
- Durée totale
- Liste des topics utilisés

#### Statistiques collectées (ProducerStats)

| Métrique | Description |
|----------|-------------|
| `messages_sent` | Nombre total de messages envoyés avec succès |
| `messages_failed` | Nombre de messages qui ont échoué |
| `bytes_sent` | Nombre total d'octets envoyés |
| `start_time` | Timestamp de début d'exécution |
| `topics_created` | Ensemble des topics utilisés |

---

## 📥 kafka_consumer_bomber.py

### Description

Script qui consomme des messages JSON depuis plusieurs topics Kafka de manière intensive. Il traite les messages avec une simulation de logique métier pour créer une charge réaliste sur le cluster et mesurer les performances de consommation.

### Utilisation

#### Commande de base

**Avec fichier .env** (recommandé) :
```bash
python3 kafka_consumer_bomber.py
```

**Sans fichier .env** :
```bash
python3 kafka_consumer_bomber.py \
  --bootstrap-servers kafka1:9092,kafka2:9092 \
  --username votre_username \
  --password votre_password
```

**Mélange .env + ligne de commande** (les arguments CLI ont priorité) :
```bash
python3 kafka_consumer_bomber.py \
  --num-consumers 3 \
  --duration-minutes 30
```

#### Options disponibles (ligne de commande)

| Option | Description | Défaut |
|--------|-------------|--------|
| `--bootstrap-servers` | **Requis** (ou via `KAFKA_BOOTSTRAP_SERVERS`). Liste des serveurs Kafka (séparés par des virgules) | Variable d'env ou - |
| `--username` | **Requis** (ou via `KAFKA_USERNAME`). Nom d'utilisateur SASL PLAIN | Variable d'env ou - |
| `--password` | **Requis** (ou via `KAFKA_PASSWORD`). Mot de passe SASL PLAIN | Variable d'env ou - |
| `--security-protocol` | Protocole de sécurité (ou via `KAFKA_SECURITY_PROTOCOL`) | Variable d'env ou `SASL_SSL` |
| `--sasl-mechanism` | Mécanisme SASL (ou via `KAFKA_SASL_MECHANISM`) | Variable d'env ou `PLAIN` |
| `--topic-prefix` | Préfixe des topics à consommer (ou via `KAFKA_TOPIC_PREFIX`) | Variable d'env ou `test-prometheus` |
| `--num-topics` | Nombre de topics à consommer (ou via `KAFKA_NUM_TOPICS`) | Variable d'env ou `10` |
| `--consumer-group` | Groupe de consommateurs (ou via `KAFKA_CONSUMER_GROUP`) | Variable d'env ou `prometheus-test-group` |
| `--num-consumers` | Nombre de consommateurs parallèles (ou via `KAFKA_NUM_CONSUMERS`) | Variable d'env ou `1` |
| `--duration-minutes` | Durée d'exécution en minutes (ou via `KAFKA_DURATION_MINUTES`) | Variable d'env ou `60` |
| `--auto-offset-reset` | Position de départ (ou via `KAFKA_AUTO_OFFSET_RESET`) | Variable d'env ou `earliest` |
| `--ssl-cafile` | Chemin vers le fichier CA SSL (ou via `KAFKA_SSL_CAFILE`) | Variable d'env ou - |
| `--ssl-certfile` | Chemin vers le fichier certificat SSL (ou via `KAFKA_SSL_CERTFILE`) | Variable d'env ou - |
| `--ssl-keyfile` | Chemin vers le fichier clé SSL (ou via `KAFKA_SSL_KEYFILE`) | Variable d'env ou - |
| `--ssl-password` | Mot de passe pour la clé SSL (ou via `KAFKA_SSL_PASSWORD`) | Variable d'env ou - |
| `--verbose` | Mode verbeux (ou via `KAFKA_VERBOSE=true`) | Variable d'env ou `False` |

#### Paramètres de configuration (classe ConsumerConfig)

Ces paramètres sont définis dans le code et peuvent être modifiés directement dans le script si nécessaire :

| Paramètre | Description | Valeur par défaut |
|-----------|-------------|-------------------|
| `bootstrap_servers` | Liste des serveurs Kafka | Défini via `--bootstrap-servers` |
| `security_protocol` | Protocole de sécurité | Défini via `--security-protocol` ou `KAFKA_SECURITY_PROTOCOL` (défaut: `SASL_SSL`) |
| `sasl_mechanism` | Mécanisme SASL | Défini via `--sasl-mechanism` ou `KAFKA_SASL_MECHANISM` (défaut: `PLAIN`) |
| `sasl_plain_username` | Nom d'utilisateur SASL | Défini via `--username` |
| `sasl_plain_password` | Mot de passe SASL | Défini via `--password` |
| `topic_prefix` | Préfixe des topics | `test-prometheus` |
| `num_topics` | Nombre de topics | `10` |
| `consumer_group` | Groupe de consommateurs | `prometheus-test-group` |
| `num_consumers` | Nombre de consommateurs | `5` (mais `1` recommandé) |
| `duration_minutes` | Durée en minutes | `60` |
| `auto_offset_reset` | Position de départ | `earliest` |
| `enable_auto_commit` | Commit automatique des offsets | `True` |
| `max_poll_records` | Nombre max de records par poll | `500` |
| `session_timeout_ms` | Timeout de session (ms) | `30000` (30s) |
| `heartbeat_interval_ms` | Intervalle de heartbeat (ms) | `3000` (3s) |
| `ssl_cafile` | Fichier CA SSL | `None` |
| `ssl_certfile` | Fichier certificat SSL | `None` |
| `ssl_keyfile` | Fichier clé SSL | `None` |
| `ssl_password` | Mot de passe clé SSL | `None` |

#### Paramètres Kafka Consumer (codés en dur)

Ces paramètres sont configurés dans la méthode `_create_consumer()` et peuvent être modifiés dans le code :

| Paramètre | Description | Valeur |
|-----------|-------------|--------|
| `group.id` | Groupe de consommateurs | Défini via `--consumer-group` |
| `auto.offset.reset` | Position de départ | Défini via `--auto-offset-reset` |
| `enable.auto.commit` | Commit automatique | `True` |
| `session.timeout.ms` | Timeout de session (ms) | `30000` (30s) |
| `heartbeat.interval.ms` | Intervalle de heartbeat (ms) | `3000` (3s) |
| `max.poll.interval.ms` | Intervalle max entre polls (ms) | `300000` (5 min) |
| `fetch.min.bytes` | Nombre min d'octets à récupérer | `1` |
| `fetch.max.wait.ms` | Temps max d'attente pour fetch (ms) | `500` |
| `max.partition.fetch.bytes` | Taille max par partition (octets) | `1048576` (1 MB) |
| `auto.commit.interval.ms` | Intervalle de commit auto (ms) | `1000` (1s) |
| `enable.ssl.certificate.verification` | Vérification certificat SSL | `False` |
| `ssl.ca.location` | Emplacement CA SSL | Défini via `--ssl-cafile` |
| `ssl.certificate.location` | Emplacement certificat SSL | Défini via `--ssl-certfile` |
| `ssl.key.location` | Emplacement clé SSL | Défini via `--ssl-keyfile` |
| `ssl.key.password` | Mot de passe clé SSL | Défini via `--ssl-password` |

#### Paramètres de retry et connexion

| Paramètre | Description | Valeur |
|-----------|-------------|--------|
| `max_retries` | Nombre max de tentatives de connexion | `5` |
| `retry_delay` | Délai initial entre tentatives (secondes) | `3` |
| `consumer_startup_delay` | Délai entre démarrage des consommateurs (secondes) | `1.0` par consumer_id |
| `poll_timeout` | Timeout du poll (secondes) | `1.0` |
| `stats_report_interval` | Intervalle de rapport des stats (secondes) | `10` |

#### Exemples

**Consommation basique**
```bash
python3 kafka_consumer_bomber.py \
  --bootstrap-servers kafka1:9092 \
  --username admin \
  --password secret \
  --duration-minutes 30
```

**Consommation intensive (plusieurs consommateurs)**
```bash
python3 kafka_consumer_bomber.py \
  --bootstrap-servers kafka1:9092,kafka2:9092 \
  --username admin \
  --password secret \
  --topic-prefix production-test \
  --num-topics 20 \
  --consumer-group test-group-1 \
  --num-consumers 3 \
  --duration-minutes 60
```

**Avec certificats SSL personnalisés**
```bash
python3 kafka_consumer_bomber.py \
  --bootstrap-servers kafka1:9092 \
  --username admin \
  --password secret \
  --ssl-cafile /path/to/ca.pem \
  --ssl-certfile /path/to/cert.pem \
  --ssl-keyfile /path/to/key.pem \
  --ssl-password key_password
```

### Traitement des messages

Le script simule un traitement complet des messages :
- **Validation** : Vérifie la structure et le format des messages
- **Transformation** : Normalise et enrichit les données
- **Logique métier** : Traite différemment selon le type de message
- **Délai de traitement** : Simule un temps de traitement réaliste (1-50ms)

#### Paramètres de traitement (MessageProcessor)

| Paramètre | Description | Valeur |
|-----------|-------------|--------|
| `processing_delay_min` | Délai min de traitement (secondes) | `0.001` (1ms) |
| `processing_delay_max` | Délai max de traitement (secondes) | `0.050` (50ms) |
| `required_fields` | Champs requis dans les messages | `["timestamp", "_metadata"]` |
| `stats_report_interval` | Intervalle de rapport des stats (secondes) | `10` |

#### Types de messages traités

Le script traite différemment selon le type de message :

1. **user_activity** : Analyse de comportement utilisateur (login/logout)
2. **system_metrics** : Analyse de performance (seuil d'alerte à 80)
3. **transaction** : Validation de transaction (seuil important à 1000)
4. **log_event** : Analyse de logs (alertes pour ERROR/FATAL)
5. **sensor_data** : Analyse de données IoT (alertes pour qualité "poor")

### Statistiques affichées

Toutes les 10 secondes, le script affiche :
- Nombre de messages consommés
- Nombre de messages échoués
- Taux de messages par seconde (msg/s)
- Débit en MB/s
- Nombre de messages traités
- Taux d'erreur de traitement
- Topics actifs

À la fin de l'exécution, un résumé détaillé est affiché incluant :
- Statistiques globales
- Répartition par type de message
- Répartition par topic

#### Statistiques collectées (ConsumerStats)

| Métrique | Description |
|----------|-------------|
| `messages_consumed` | Nombre total de messages consommés |
| `messages_failed` | Nombre de messages qui ont échoué |
| `bytes_consumed` | Nombre total d'octets consommés |
| `start_time` | Timestamp de début d'exécution |
| `consumer_lag` | Lag par partition (dictionnaire) |

#### Statistiques de traitement (MessageProcessor Stats)

| Métrique | Description |
|----------|-------------|
| `messages_processed` | Nombre de messages traités avec succès |
| `processing_errors` | Nombre d'erreurs de traitement |
| `bytes_processed` | Nombre total d'octets traités |
| `avg_processing_time_ms` | Temps moyen de traitement (ms) |
| `messages_by_type` | Répartition par type de message |
| `messages_by_topic` | Répartition par topic |
| `error_rate` | Taux d'erreur (erreurs / messages traités) |

---

## 🔄 Utilisation combinée

Pour un test complet, vous pouvez lancer les deux scripts simultanément :

**Terminal 1 - Producteur**
```bash
python3 kafka_producer_bomber.py \
  --bootstrap-servers kafka1:9092 \
  --username admin \
  --password secret \
  --messages-per-second 2000 \
  --duration-minutes 60
```

**Terminal 2 - Consommateur**
```bash
python3 kafka_consumer_bomber.py \
  --bootstrap-servers kafka1:9092 \
  --username admin \
  --password secret \
  --num-consumers 2 \
  --duration-minutes 60
```

---

## 🔧 Personnalisation avancée

### Modification des paramètres codés en dur

Pour modifier les paramètres qui ne sont pas exposés via la ligne de commande, vous pouvez éditer directement les scripts :

#### Dans `kafka_producer_bomber.py`

**Modifier les paramètres du producteur Kafka** (ligne ~233-250) :
```python
producer = KafkaProducer(
    # ... autres paramètres ...
    acks='all',                    # Modifier pour '0' ou '1' si besoin
    retries=3,                     # Augmenter pour plus de résilience
    compression_type='gzip',       # Changer en 'snappy' ou 'lz4'
    batch_size=16384,              # Ajuster selon la taille des messages
    linger_ms=10,                  # Augmenter pour plus de batching
    buffer_memory=33554432,        # Augmenter pour plus de throughput
)
```

**Modifier les templates de messages** (ligne ~52-130) :
- Ajouter de nouveaux types de messages dans `_create_message_templates()`
- Modifier les plages de valeurs dans `generate_random_data()`

#### Dans `kafka_consumer_bomber.py`

**Modifier les paramètres du consommateur Kafka** (ligne ~239-257) :
```python
consumer_config = {
    # ... autres paramètres ...
    'max.poll.interval.ms': 300000,      # Augmenter si traitement long
    'fetch.min.bytes': 1,                # Augmenter pour moins de requêtes
    'fetch.max.wait.ms': 500,            # Augmenter pour plus de batching
    'max.partition.fetch.bytes': 1048576, # Augmenter pour plus de données
    'auto.commit.interval.ms': 1000,     # Ajuster selon besoins
}
```

**Modifier la logique de traitement** (ligne ~65-189) :
- Personnaliser `_simulate_processing()` pour votre cas d'usage
- Modifier les seuils d'alerte dans les méthodes `_process_*()`
- Ajuster les délais de traitement dans `_simulate_processing()`

### Variables d'environnement

Les scripts supportent maintenant les variables d'environnement via un fichier `.env` (voir section [Configuration via fichier .env](#configuration-via-fichier-env-recommandé)).

Avantages :
- ✅ Stocker les credentials de manière sécurisée (ajoutez `.env` à `.gitignore`)
- ✅ Configurer les paramètres par défaut
- ✅ Gérer différents environnements (dev, staging, prod) avec différents fichiers `.env`
- ✅ Éviter d'exposer les credentials dans l'historique de commandes

Les paramètres passés en ligne de commande ont toujours priorité sur les variables d'environnement.

## ⚠️ Notes importantes

### Conflits SSL

Le script `kafka_consumer_bomber.py` peut rencontrer des conflits SSL lors de la création de plusieurs consommateurs simultanément. Par défaut, `--num-consumers` est réglé à `1` pour éviter ces problèmes. Si vous devez utiliser plusieurs consommateurs, augmentez progressivement et surveillez les logs.

### Format des topics

Les scripts créent/consomment des topics au format :
```
{prefix}.generated-data-{num:02d}.json
```

Par exemple, avec le préfixe par défaut `test-prometheus` et 10 topics :
- `test-prometheus.generated-data-01.json`
- `test-prometheus.generated-data-02.json`
- ...
- `test-prometheus.generated-data-10.json`

### Arrêt propre

Les scripts gèrent les signaux `SIGINT` (Ctrl+C) et `SIGTERM` pour un arrêt propre. Ils afficheront les statistiques finales avant de se terminer.

### Performance

Pour des tests de performance optimaux :
- Ajustez `--messages-per-second` selon la capacité de votre cluster
- Utilisez `--num-threads` (producteur) pour paralléliser l'envoi
- Utilisez `--num-consumers` (consommateur) avec précaution (voir note SSL)
- Surveillez les métriques Prometheus pendant l'exécution
- Ajustez `batch_size` et `linger_ms` dans le producteur pour optimiser le throughput
- Ajustez `fetch.min.bytes` et `fetch.max.wait.ms` dans le consommateur pour réduire la charge réseau

### Sécurité

**Recommandations importantes** :

1. **Utilisez un fichier `.env`** au lieu de passer les credentials en ligne de commande :
   - Les credentials en ligne de commande sont visibles dans `ps` et l'historique shell
   - Le fichier `.env` peut être protégé avec des permissions restrictives (`chmod 600 .env`)

2. **Ajoutez `.env` à `.gitignore`** :
   ```bash
   echo ".env" >> .gitignore
   ```

3. **Certificats SSL** :
   - Utilisez les certificats SSL pour une sécurité renforcée
   - Le paramètre `enable.ssl.certificate.verification` est désactivé par défaut (à activer en production)

4. **Permissions du fichier .env** :
   ```bash
   chmod 600 .env  # Lecture/écriture uniquement pour le propriétaire
   ```

5. **Variables d'environnement système** :
   - Vous pouvez aussi définir les variables directement dans votre shell :
     ```bash
     export KAFKA_USERNAME=admin
     export KAFKA_PASSWORD=secret
     ```
   - Cela évite même d'avoir un fichier `.env` sur le disque

---

## 🐛 Dépannage

### Erreur de connexion

Vérifiez :
- Les serveurs Kafka sont accessibles
- Les credentials sont corrects
- Le protocole de sécurité correspond à votre configuration Kafka

### Messages non reçus (consommateur)

Vérifiez :
- Les topics existent et contiennent des messages
- Le `--auto-offset-reset` est correct (`earliest` pour lire depuis le début)
- Le groupe de consommateurs n'est pas déjà utilisé ailleurs

### Performance faible

- Augmentez `--num-threads` pour le producteur
- Vérifiez la charge réseau et CPU
- Surveillez les métriques Kafka (lag, throughput)

---

## 📊 Intégration avec Prometheus

Ces scripts sont conçus pour générer du trafic Kafka qui sera monitoré par Prometheus via les exporters JMX. Les métriques suivantes seront particulièrement intéressantes à surveiller :

- **Producteur** : `kafka_producer_*` (taux d'envoi, latence, erreurs)
- **Consommateur** : `kafka_consumer_*` (lag, throughput, commit rate)
- **Broker** : `kafka_server_*` (bytes in/out, requests, partitions)

Les dashboards Grafana fournis dans ce projet visualisent ces métriques.

---

## 🐳 Utilisation avec Docker

### Construction de l'image

```bash
cd kafka-consumer-producer
docker build -t kafka-perf-test:latest .
```

### Utilisation interactive (recommandé)

L'entrée par défaut lance un shell interactif pour que vous puissiez exécuter les commandes manuellement :

```bash
# Créer le fichier .env d'abord
cp env.example .env
# Éditer .env avec vos credentials

# Entrer dans le conteneur interactif
docker run -it --rm \
  -v $(pwd)/.env:/app/.env:ro \
  --network host \
  kafka-perf-test:latest

# Depuis le conteneur, vous pouvez maintenant lancer:
python3 /app/kafka_producer_bomber.py --help
python3 /app/kafka_consumer_bomber.py --help

# Ou utiliser les alias disponibles:
producer-bomber --help
consumer-bomber --help
kafka-producer-perf --help
kafka-consumer-perf --help
```

### Utilisation directe (sans shell interactif)

Vous pouvez aussi lancer directement les commandes :

```bash
# Lancer le producteur directement
docker run --rm \
  -v $(pwd)/.env:/app/.env:ro \
  --network host \
  kafka-perf-test:latest \
  producer-bomber

# Lancer le consommateur directement
docker run --rm \
  -v $(pwd)/.env:/app/.env:ro \
  --network host \
  kafka-perf-test:latest \
  consumer-bomber
```

#### Avec variables d'environnement

```bash
docker run --rm \
  -e KAFKA_BOOTSTRAP_SERVERS=kafka1:9092 \
  -e KAFKA_USERNAME=admin \
  -e KAFKA_PASSWORD=secret \
  --network host \
  kafka-perf-test:latest \
  producer-bomber \
  --messages-per-second 2000 \
  --duration-minutes 30
```

### Utilisation des outils Kafka perf test

#### Producer perf test

```bash
# Avec fichier de configuration (recommandé pour SASL)
docker run --rm \
  -v $(pwd)/config/producer.properties:/app/config/producer.properties:ro \
  --network host \
  kafka-perf-test:latest \
  kafka-producer-perf \
  --topic test-topic \
  --num-records 100000 \
  --record-size 1024 \
  --throughput 10000 \
  --producer-props config-file=/app/config/producer.properties

# Ou avec propriétés inline (moins sécurisé)
docker run --rm \
  --network host \
  kafka-perf-test:latest \
  kafka-producer-perf \
  --topic test-topic \
  --num-records 100000 \
  --record-size 1024 \
  --throughput 10000 \
  --producer-props bootstrap.servers=kafka1:9092,security.protocol=SASL_SSL,sasl.mechanism=PLAIN,sasl.jaas.config="org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"secret\";"
```

#### Consumer perf test

```bash
# Avec fichier de configuration (recommandé pour SASL)
docker run --rm \
  -v $(pwd)/config/consumer.properties:/app/config/consumer.properties:ro \
  --network host \
  kafka-perf-test:latest \
  kafka-consumer-perf \
  --topic test-topic \
  --messages 100000 \
  --consumer.config /app/config/consumer.properties
```

**Note** : Des fichiers d'exemple sont fournis dans `config/consumer.properties.example` et `config/producer.properties.example`. Copiez-les et modifiez-les selon vos besoins.

### Utilisation avec docker-compose

Un fichier `docker-compose.test.yml` est fourni pour faciliter l'utilisation :

```bash
# Construire l'image
docker-compose -f docker-compose.test.yml build

# Entrer dans le conteneur interactif
docker-compose -f docker-compose.test.yml run --rm kafka-perf-test bash

# Ou lancer directement une commande
docker-compose -f docker-compose.test.yml run --rm kafka-perf-test producer-bomber
docker-compose -f docker-compose.test.yml run --rm kafka-perf-test consumer-bomber
docker-compose -f docker-compose.test.yml run --rm kafka-perf-test \
  kafka-producer-perf --topic test --num-records 10000 --record-size 1024 \
  --producer-props bootstrap.servers=kafka1:9092
```

### Commandes disponibles

Dans le conteneur, les alias suivants sont disponibles :

| Alias | Commande réelle | Description |
|-------|----------------|-------------|
| `producer-bomber` | `python3 /app/kafka_producer_bomber.py` | Script bomber producteur Python |
| `consumer-bomber` | `python3 /app/kafka_consumer_bomber.py` | Script bomber consommateur Python |
| `kafka-producer-perf` | `${KAFKA_HOME}/bin/kafka-producer-perf-test.sh` | Outil perf test producteur Kafka officiel |
| `kafka-consumer-perf` | `${KAFKA_HOME}/bin/kafka-consumer-perf-test.sh` | Outil perf test consommateur Kafka officiel |

Vous pouvez aussi utiliser les chemins complets directement :
- `/app/kafka_producer_bomber.py`
- `/app/kafka_consumer_bomber.py`
- `${KAFKA_HOME}/bin/kafka-producer-perf-test.sh`
- `${KAFKA_HOME}/bin/kafka-consumer-perf-test.sh`

### Configuration réseau

Si vos brokers Kafka sont accessibles depuis l'hôte, utilisez `--network host` :

```bash
docker run --rm --network host kafka-perf-test:latest producer-bomber
```

Si vous utilisez un réseau Docker personnalisé, connectez le conteneur au réseau approprié :

```bash
docker run --rm --network monitoring kafka-perf-test:latest producer-bomber
```

### Montage de certificats SSL

Si vous utilisez des certificats SSL personnalisés :

```bash
docker run --rm \
  -v $(pwd)/.env:/app/.env:ro \
  -v $(pwd)/certs:/app/certs:ro \
  --network host \
  kafka-perf-test:latest \
  producer-bomber \
  --ssl-cafile /app/certs/ca.pem \
  --ssl-certfile /app/certs/cert.pem \
  --ssl-keyfile /app/certs/key.pem
```

---

## 📋 Tableau récapitulatif des paramètres

### kafka_producer_bomber.py

| Catégorie | Paramètre | CLI | Valeur par défaut | Modifiable |
|-----------|-----------|-----|-------------------|-----------|
| **Connexion** | `bootstrap_servers` | `--bootstrap-servers` | - | ✅ |
| | `security_protocol` | `--security-protocol` | `SASL_SSL` | ✅ |
| | `sasl_mechanism` | `--sasl-mechanism` | `PLAIN` | ✅ |
| | `sasl_plain_username` | `--username` | - | ✅ |
| | `sasl_plain_password` | `--password` | - | ✅ |
| **Topics** | `topic_prefix` | `--topic-prefix` | `test-prometheus` | ✅ |
| | `num_topics` | `--num-topics` | `10` | ✅ |
| **Performance** | `messages_per_second` | `--messages-per-second` | `1000` | ✅ |
| | `num_threads` | `--num-threads` | `5` | ✅ |
| | `batch_size` | - | `16384` | Code |
| | `linger_ms` | - | `10` | Code |
| | `buffer_memory` | - | `33554432` | Code |
| | `compression_type` | - | `gzip` | Code |
| **Durée** | `duration_minutes` | `--duration-minutes` | `60` | ✅ |
| **Logs** | `verbose` | `--verbose` | `False` | ✅ |

### kafka_consumer_bomber.py

| Catégorie | Paramètre | CLI | Valeur par défaut | Modifiable |
|-----------|-----------|-----|-------------------|-----------|
| **Connexion** | `bootstrap_servers` | `--bootstrap-servers` | - | ✅ |
| | `security_protocol` | `--security-protocol` | `SASL_SSL` | ✅ |
| | `sasl_mechanism` | `--sasl-mechanism` | `PLAIN` | ✅ |
| | `sasl_plain_username` | `--username` | - | ✅ |
| | `sasl_plain_password` | `--password` | - | ✅ |
| **SSL** | `ssl_cafile` | `--ssl-cafile` | `None` | ✅ |
| | `ssl_certfile` | `--ssl-certfile` | `None` | ✅ |
| | `ssl_keyfile` | `--ssl-keyfile` | `None` | ✅ |
| | `ssl_password` | `--ssl-password` | `None` | ✅ |
| **Topics** | `topic_prefix` | `--topic-prefix` | `test-prometheus` | ✅ |
| | `num_topics` | `--num-topics` | `10` | ✅ |
| **Consumer** | `consumer_group` | `--consumer-group` | `prometheus-test-group` | ✅ |
| | `num_consumers` | `--num-consumers` | `1` | ✅ |
| | `auto_offset_reset` | `--auto-offset-reset` | `earliest` | ✅ |
| | `enable_auto_commit` | - | `True` | Code |
| | `max_poll_records` | - | `500` | Code |
| | `session_timeout_ms` | - | `30000` | Code |
| | `heartbeat_interval_ms` | - | `3000` | Code |
| | `max_poll_interval_ms` | - | `300000` | Code |
| | `fetch.min.bytes` | - | `1` | Code |
| | `fetch.max.wait.ms` | - | `500` | Code |
| **Durée** | `duration_minutes` | `--duration-minutes` | `60` | ✅ |
| **Logs** | `verbose` | `--verbose` | `False` | ✅ |

**Légende :**
- ✅ = Modifiable via ligne de commande
- Code = Nécessite modification du code source

---

## 🔍 Limites et contraintes

### Limites connues

1. **Conflits SSL** : Le consommateur peut rencontrer des problèmes avec plusieurs consommateurs simultanés
2. **Taille des messages** : Les messages sont générés avec une taille variable (pas de contrôle strict)
3. **Retry limité** : Maximum 5 tentatives de connexion pour le consommateur
4. **Pas de gestion de partition** : Les scripts ne gèrent pas explicitement les partitions
5. **Pas de gestion d'erreurs avancée** : Les erreurs sont loggées mais pas toutes gérées de manière spécifique

### Recommandations

- **Producteur** : Commencez avec `--num-threads=5` et augmentez progressivement
- **Consommateur** : Utilisez `--num-consumers=1` par défaut pour éviter les conflits SSL
- **Topics** : Créez les topics manuellement si nécessaire avant d'exécuter les scripts
- **Monitoring** : Surveillez les métriques Kafka pendant l'exécution pour détecter les problèmes
