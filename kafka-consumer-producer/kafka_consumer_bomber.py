#!/usr/bin/env python3
"""
Kafka Consumer Bomber - Script de test pour Prometheus
Consomme des messages JSON de manière intensive pour bombarder le cluster Kafka
Support SASL_SSL avec PLAIN pour l'authentification
"""

import json
import time
import threading
import logging
import os
from datetime import datetime, timezone
from typing import Dict, Any, List, Optional
from dataclasses import dataclass
from confluent_kafka import Consumer, KafkaError
import argparse
import signal
import sys
from collections import defaultdict, Counter
from dotenv import load_dotenv

# Charger les variables d'environnement depuis .env
load_dotenv()

# Configuration du logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

@dataclass
class ConsumerConfig:
    """Configuration du consommateur Kafka"""
    bootstrap_servers: List[str]
    security_protocol: str = "SASL_SSL"
    sasl_mechanism: str = "PLAIN"
    sasl_plain_username: str = ""
    sasl_plain_password: str = ""
    topic_prefix: str = "test-prometheus"
    num_topics: int = 10
    consumer_group: str = "prometheus-test-group"
    num_consumers: int = 5
    duration_minutes: int = 60
    auto_offset_reset: str = "earliest"
    enable_auto_commit: bool = True
    max_poll_records: int = 500
    session_timeout_ms: int = 30000
    heartbeat_interval_ms: int = 3000
    # Configuration SSL optionnelle
    ssl_cafile: Optional[str] = None
    ssl_certfile: Optional[str] = None
    ssl_keyfile: Optional[str] = None
    ssl_password: Optional[str] = None

class MessageProcessor:
    """Processeur de messages pour simulation de traitement"""

    def __init__(self):
        self.stats = {
            "messages_processed": 0,
            "messages_by_type": Counter(),
            "messages_by_topic": Counter(),
            "processing_errors": 0,
            "processing_times": [],
            "bytes_processed": 0
        }

    def process_message(self, message: Dict[str, Any], topic: str) -> bool:
        """Traite un message reçu"""
        start_time = time.time()

        try:
            # Simuler un traitement de message
            self._simulate_processing(message)

            # Mettre à jour les statistiques
            processing_time = time.time() - start_time
            self.stats["messages_processed"] += 1
            self.stats["messages_by_topic"][topic] += 1
            self.stats["processing_times"].append(processing_time)
            self.stats["bytes_processed"] += len(json.dumps(message).encode('utf-8'))

            # Identifier le type de message
            message_type = message.get("type", "unknown")
            self.stats["messages_by_type"][message_type] += 1

            return True

        except Exception as e:
            logger.error(f"Erreur lors du traitement du message: {e}")
            self.stats["processing_errors"] += 1
            return False

    def _simulate_processing(self, message: Dict[str, Any]):
        """Simule un traitement de message (validation, transformation, etc.)"""
        # Simuler une validation
        if not self._validate_message(message):
            raise ValueError("Message invalide")

        # Simuler une transformation
        self._transform_message(message)

        # Simuler un traitement métier
        self._business_logic(message)

        # Simuler un délai de traitement (1-50ms)
        processing_delay = 0.001 + (0.049 * (hash(str(message)) % 100) / 100)
        time.sleep(processing_delay)

    def _validate_message(self, message: Dict[str, Any]) -> bool:
        """Valide la structure du message"""
        required_fields = ["timestamp", "_metadata"]

        for field in required_fields:
            if field not in message:
                return False

        # Vérifier le format du timestamp
        try:
            datetime.fromisoformat(message["timestamp"].replace('Z', '+00:00'))
        except (ValueError, AttributeError):
            return False

        return True

    def _transform_message(self, message: Dict[str, Any]):
        """Transforme le message (ajout de métadonnées, normalisation)"""
        # Ajouter un timestamp de traitement
        message["_processed_at"] = datetime.now(timezone.utc).isoformat()

        # Normaliser certains champs
        if "user_id" in message:
            message["user_id"] = str(message["user_id"]).lower()

        if "action" in message:
            message["action"] = str(message["action"]).upper()

    def _business_logic(self, message: Dict[str, Any]):
        """Simule une logique métier"""
        message_type = message.get("type", "unknown")

        if message_type == "user_activity":
            self._process_user_activity(message)
        elif message_type == "system_metrics":
            self._process_system_metrics(message)
        elif message_type == "transaction":
            self._process_transaction(message)
        elif message_type == "log_event":
            self._process_log_event(message)
        elif message_type == "sensor_data":
            self._process_sensor_data(message)

    def _process_user_activity(self, message: Dict[str, Any]):
        """Traite les messages d'activité utilisateur"""
        # Simuler une analyse de comportement
        action = message.get("action", "")
        if action in ["login", "logout"]:
            # Logique spéciale pour les connexions/déconnexions
            pass

    def _process_system_metrics(self, message: Dict[str, Any]):
        """Traite les métriques système"""
        # Simuler une analyse de performance
        value = message.get("value", 0)
        if value > 80:  # Seuil d'alerte
            # Simuler une alerte
            pass

    def _process_transaction(self, message: Dict[str, Any]):
        """Traite les transactions"""
        # Simuler une validation de transaction
        amount = message.get("amount", 0)
        if amount > 1000:  # Transaction importante
            # Simuler une validation renforcée
            pass

    def _process_log_event(self, message: Dict[str, Any]):
        """Traite les événements de log"""
        # Simuler une analyse de logs
        level = message.get("level", "INFO")
        if level in ["ERROR", "FATAL"]:
            # Simuler une alerte d'erreur
            pass

    def _process_sensor_data(self, message: Dict[str, Any]):
        """Traite les données de capteurs"""
        # Simuler une analyse de données IoT
        value = message.get("value", 0)
        quality = message.get("quality", "good")
        if quality == "poor":
            # Simuler une alerte de qualité
            pass

    def get_stats(self) -> Dict[str, Any]:
        """Retourne les statistiques de traitement"""
        avg_processing_time = (
            sum(self.stats["processing_times"]) / len(self.stats["processing_times"])
            if self.stats["processing_times"] else 0
        )

        return {
            "messages_processed": self.stats["messages_processed"],
            "processing_errors": self.stats["processing_errors"],
            "bytes_processed": self.stats["bytes_processed"],
            "avg_processing_time_ms": avg_processing_time * 1000,
            "messages_by_type": dict(self.stats["messages_by_type"]),
            "messages_by_topic": dict(self.stats["messages_by_topic"]),
            "error_rate": (
                self.stats["processing_errors"] / self.stats["messages_processed"]
                if self.stats["messages_processed"] > 0 else 0
            )
        }

class KafkaConsumerBomber:
    """Bombardeur consommateur Kafka pour tester Prometheus"""

    def __init__(self, config: ConsumerConfig):
        self.config = config
        self.message_processor = MessageProcessor()
        self.consumers = []
        self.running = False
        self.stats = {
            "messages_consumed": 0,
            "messages_failed": 0,
            "bytes_consumed": 0,
            "start_time": None,
            "consumer_lag": defaultdict(int)
        }

    def _create_consumer(self, consumer_id: int) -> Consumer:
        """Crée un consommateur Kafka avec configuration SASL_SSL/PLAIN"""
        max_retries = 5
        retry_delay = 3

        for attempt in range(max_retries):
            try:
                # Délai progressif plus long pour éviter les conflits SSL
                if attempt > 0:
                    time.sleep(retry_delay * (attempt + 1))

                # Configuration confluent_kafka (version récente)
                consumer_config = {
                    'bootstrap.servers': ','.join(self.config.bootstrap_servers),
                    'security.protocol': self.config.security_protocol,
                    'sasl.mechanism': self.config.sasl_mechanism,
                    'sasl.username': self.config.sasl_plain_username,
                    'sasl.password': self.config.sasl_plain_password,
                    'group.id': self.config.consumer_group,  # Utiliser le groupe tel quel
                    'auto.offset.reset': self.config.auto_offset_reset,
                    'enable.auto.commit': self.config.enable_auto_commit,
                    'session.timeout.ms': self.config.session_timeout_ms,
                    'heartbeat.interval.ms': self.config.heartbeat_interval_ms,
                    'max.poll.interval.ms': 300000,  # 5 minutes
                    'fetch.min.bytes': 1,
                    'fetch.max.wait.ms': 500,
                    'max.partition.fetch.bytes': 1048576,  # 1MB
                    'auto.commit.interval.ms': 1000,
                    # Configuration SSL correcte pour confluent_kafka
                    'enable.ssl.certificate.verification': False,
                }

                # Ajouter la configuration SSL si fournie
                if self.config.ssl_cafile:
                    consumer_config['ssl.ca.location'] = self.config.ssl_cafile
                if self.config.ssl_certfile:
                    consumer_config['ssl.certificate.location'] = self.config.ssl_certfile
                if self.config.ssl_keyfile:
                    consumer_config['ssl.key.location'] = self.config.ssl_keyfile
                if self.config.ssl_password:
                    consumer_config['ssl.key.password'] = self.config.ssl_password

                consumer = Consumer(consumer_config)

                # Test de connexion immédiat - utiliser list_topics() au lieu de topics()
                try:
                    metadata = consumer.list_topics(timeout=10)
                    logger.debug(f"Connexion testée avec succès, {len(metadata.topics)} topics disponibles")
                except Exception as e:
                    logger.warning(f"Test de connexion échoué: {e}")
                    # On continue quand même, le consumer peut fonctionner

                logger.info(f"Consommateur {consumer_id} créé avec succès (tentative {attempt + 1})")
                return consumer

            except Exception as e:
                error_msg = str(e)
                logger.warning(f"Tentative {attempt + 1} échouée pour le consommateur {consumer_id}: {error_msg}")

                # Si c'est l'erreur SSL connue, on attend plus longtemps
                if "already-connected SSLSocket" in error_msg or "SSL" in error_msg:
                    logger.info(f"Erreur SSL détectée, attente plus longue pour le consumer {consumer_id}")
                    time.sleep(5 + (attempt * 2))

                if attempt == max_retries - 1:
                    logger.error(f"Erreur fatale lors de la création du consommateur {consumer_id} après {max_retries} tentatives: {e}")
                    raise

    def _get_topics(self) -> List[str]:
        """Retourne la liste des topics à consommer"""
        topics = []
        for i in range(1, self.config.num_topics + 1):
            topics.append(f"{self.config.topic_prefix}.generated-data-{i:02d}.json")
        return topics

    def _consumer_worker(self, consumer_id: int):
        """Worker thread pour consommer des messages"""
        logger.info(f"Consumer worker {consumer_id} démarré")

        try:
            # Délai initial plus long pour éviter les conflits de connexion SSL
            time.sleep(consumer_id * 1.0)

            consumer = self._create_consumer(consumer_id)
            topics = self._get_topics()
            consumer.subscribe(topics)

            logger.info(f"Consumer {consumer_id} abonné aux topics: {topics}")
            logger.info(f"Consumer {consumer_id} - Premier topic: {topics[0] if topics else 'Aucun'}")

            while self.running:
                try:
                    # Poller les messages (confluent_kafka style)
                    msg = consumer.poll(timeout=1.0)

                    if msg is None:
                        continue

                    if msg.error():
                        if msg.error().code() == KafkaError._PARTITION_EOF:
                            # Fin de partition, continuer
                            continue
                        else:
                            logger.error(f"Erreur Kafka: {msg.error()}")
                            continue

                    # Récupérer le topic et traiter le message
                    topic = msg.topic()

                    try:
                        # Afficher le topic du message
                        logger.debug(f"Message reçu du topic: {topic}")

                        # Décoder le message
                        message_data = json.loads(msg.value().decode('utf-8'))

                        # Traiter le message
                        success = self.message_processor.process_message(
                            message_data, topic
                        )

                        if success:
                            self.stats["messages_consumed"] += 1
                            self.stats["bytes_consumed"] += len(msg.value())
                            # Afficher le topic toutes les 100 messages pour le suivi
                            if self.stats["messages_consumed"] % 100 == 0:
                                logger.info(f"Topic actuel: {topic} - Messages traités: {self.stats['messages_consumed']}")
                        else:
                            self.stats["messages_failed"] += 1

                    except Exception as e:
                        logger.error(f"Erreur lors du traitement du message du topic {topic}: {e}")
                        self.stats["messages_failed"] += 1

                except KafkaError as e:
                    logger.error(f"Erreur Kafka dans le consumer {consumer_id}: {e}")
                    time.sleep(1)
                except Exception as e:
                    logger.error(f"Erreur inattendue dans le consumer {consumer_id}: {e}")
                    time.sleep(1)

        except Exception as e:
            logger.error(f"Erreur fatale dans le consumer {consumer_id}: {e}")
        finally:
            if 'consumer' in locals():
                consumer.close()
            logger.info(f"Consumer worker {consumer_id} arrêté")

    def _stats_reporter(self):
        """Thread pour reporter les statistiques"""
        while self.running:
            time.sleep(10)  # Reporter toutes les 10 secondes

            if self.stats["start_time"]:
                elapsed = time.time() - self.stats["start_time"]
                rate = self.stats["messages_consumed"] / elapsed if elapsed > 0 else 0
                throughput = self.stats["bytes_consumed"] / elapsed / 1024 / 1024 if elapsed > 0 else 0

                # Stats du processeur
                processor_stats = self.message_processor.get_stats()

                # Afficher les topics actifs
                active_topics = list(processor_stats['messages_by_topic'].keys())
                topics_info = ", ".join(active_topics[:3])  # Afficher les 3 premiers topics
                if len(active_topics) > 3:
                    topics_info += f" (+{len(active_topics)-3} autres)"

                logger.info(
                    f"Stats - Messages: {self.stats['messages_consumed']} "
                    f"(+{self.stats['messages_failed']} failed), "
                    f"Rate: {rate:.1f} msg/s, "
                    f"Throughput: {throughput:.2f} MB/s, "
                    f"Processed: {processor_stats['messages_processed']}, "
                    f"Errors: {processor_stats['error_rate']:.2%}, "
                    f"Topics: {topics_info}"
                )

    def start(self):
        """Démarre la consommation"""
        logger.info("Démarrage du consommateur Kafka...")

        try:
            # Démarrer les workers
            self.running = True
            self.stats["start_time"] = time.time()

            workers = []
            for i in range(self.config.num_consumers):
                worker = threading.Thread(target=self._consumer_worker, args=(i,))
                worker.daemon = True
                worker.start()
                workers.append(worker)
                # Délai plus long entre les démarrages pour éviter les conflits SSL
                time.sleep(2.0)

            # Démarrer le reporter de stats
            stats_thread = threading.Thread(target=self._stats_reporter)
            stats_thread.daemon = True
            stats_thread.start()

            logger.info(f"Consommation démarrée avec {self.config.num_consumers} consumers")
            logger.info(f"Topics: {self._get_topics()}")

            # Attendre la durée spécifiée
            time.sleep(self.config.duration_minutes * 60)

        except KeyboardInterrupt:
            logger.info("Arrêt demandé par l'utilisateur")
        except Exception as e:
            logger.error(f"Erreur lors du démarrage: {e}")
        finally:
            self.stop()

    def stop(self):
        """Arrête la consommation"""
        logger.info("Arrêt du consommateur...")
        self.running = False

        # Afficher les stats finales
        if self.stats["start_time"]:
            elapsed = time.time() - self.stats["start_time"]
            rate = self.stats["messages_consumed"] / elapsed if elapsed > 0 else 0
            throughput = self.stats["bytes_consumed"] / elapsed / 1024 / 1024 if elapsed > 0 else 0

            processor_stats = self.message_processor.get_stats()

            logger.info("=== STATISTIQUES FINALES ===")
            logger.info(f"Messages consommés: {self.stats['messages_consumed']}")
            logger.info(f"Messages échoués: {self.stats['messages_failed']}")
            logger.info(f"Messages traités: {processor_stats['messages_processed']}")
            logger.info(f"Taux moyen: {rate:.1f} msg/s")
            logger.info(f"Débit moyen: {throughput:.2f} MB/s")
            logger.info(f"Temps de traitement moyen: {processor_stats['avg_processing_time_ms']:.2f} ms")
            logger.info(f"Taux d'erreur: {processor_stats['error_rate']:.2%}")
            logger.info(f"Durée totale: {elapsed:.1f} secondes")

            # Détail par type de message
            logger.info("Messages par type:")
            for msg_type, count in processor_stats['messages_by_type'].items():
                logger.info(f"  {msg_type}: {count}")

            # Détail par topic
            logger.info("Messages par topic:")
            for topic, count in processor_stats['messages_by_topic'].items():
                logger.info(f"  {topic}: {count}")

def signal_handler(sig, frame):
    """Gestionnaire de signal pour arrêt propre"""
    logger.info("Signal d'arrêt reçu")
    sys.exit(0)

def main():
    """Fonction principale"""
    parser = argparse.ArgumentParser(description="Kafka Consumer Bomber pour tester Prometheus")
    parser.add_argument("--bootstrap-servers", 
                       default=os.getenv('KAFKA_BOOTSTRAP_SERVERS'),
                       help="Serveurs Kafka (ex: kafka1:9092,kafka2:9092). Peut être défini via KAFKA_BOOTSTRAP_SERVERS dans .env")
    parser.add_argument("--username", 
                       default=os.getenv('KAFKA_USERNAME'),
                       help="Nom d'utilisateur SASL PLAIN. Peut être défini via KAFKA_USERNAME dans .env")
    parser.add_argument("--password", 
                       default=os.getenv('KAFKA_PASSWORD'),
                       help="Mot de passe SASL PLAIN. Peut être défini via KAFKA_PASSWORD dans .env")
    parser.add_argument("--security-protocol",
                       default=os.getenv('KAFKA_SECURITY_PROTOCOL', 'SASL_SSL'),
                       help="Protocole de sécurité (SASL_SSL, SASL_PLAINTEXT, SSL, PLAINTEXT). Peut être défini via KAFKA_SECURITY_PROTOCOL dans .env")
    parser.add_argument("--sasl-mechanism",
                       default=os.getenv('KAFKA_SASL_MECHANISM', 'PLAIN'),
                       help="Mécanisme SASL (PLAIN, SCRAM-SHA-256, SCRAM-SHA-512, etc.). Peut être défini via KAFKA_SASL_MECHANISM dans .env")
    parser.add_argument("--topic-prefix", 
                       default=os.getenv('KAFKA_TOPIC_PREFIX', 'test-prometheus'),
                       help="Préfixe des topics. Peut être défini via KAFKA_TOPIC_PREFIX dans .env")
    parser.add_argument("--num-topics", 
                       type=int, 
                       default=int(os.getenv('KAFKA_NUM_TOPICS', '10')),
                       help="Nombre de topics à consommer. Peut être défini via KAFKA_NUM_TOPICS dans .env")
    parser.add_argument("--consumer-group", 
                       default=os.getenv('KAFKA_CONSUMER_GROUP', 'prometheus-test-group'),
                       help="Groupe de consommateurs. Peut être défini via KAFKA_CONSUMER_GROUP dans .env")
    parser.add_argument("--num-consumers", 
                       type=int, 
                       default=int(os.getenv('KAFKA_NUM_CONSUMERS', '1')),
                       help="Nombre de consommateurs (recommandé: 1 pour éviter les conflits SSL). Peut être défini via KAFKA_NUM_CONSUMERS dans .env")
    parser.add_argument("--duration-minutes", 
                       type=int, 
                       default=int(os.getenv('KAFKA_DURATION_MINUTES', '60')),
                       help="Durée en minutes. Peut être défini via KAFKA_DURATION_MINUTES dans .env")
    parser.add_argument("--auto-offset-reset", 
                       default=os.getenv('KAFKA_AUTO_OFFSET_RESET', 'earliest'),
                       choices=["earliest", "latest"],
                       help="Position de départ. Peut être défini via KAFKA_AUTO_OFFSET_RESET dans .env")
    parser.add_argument("--ssl-cafile", 
                       default=os.getenv('KAFKA_SSL_CAFILE'),
                       help="Chemin vers le fichier CA SSL (optionnel). Peut être défini via KAFKA_SSL_CAFILE dans .env")
    parser.add_argument("--ssl-certfile", 
                       default=os.getenv('KAFKA_SSL_CERTFILE'),
                       help="Chemin vers le fichier certificat SSL (optionnel). Peut être défini via KAFKA_SSL_CERTFILE dans .env")
    parser.add_argument("--ssl-keyfile", 
                       default=os.getenv('KAFKA_SSL_KEYFILE'),
                       help="Chemin vers le fichier clé SSL (optionnel). Peut être défini via KAFKA_SSL_KEYFILE dans .env")
    parser.add_argument("--ssl-password", 
                       default=os.getenv('KAFKA_SSL_PASSWORD'),
                       help="Mot de passe pour la clé SSL (optionnel). Peut être défini via KAFKA_SSL_PASSWORD dans .env")
    parser.add_argument("--verbose", 
                       action="store_true",
                       default=os.getenv('KAFKA_VERBOSE', 'false').lower() == 'true',
                       help="Mode verbeux. Peut être défini via KAFKA_VERBOSE=true dans .env")

    args = parser.parse_args()

    # Vérifier les paramètres requis
    if not args.bootstrap_servers:
        parser.error("--bootstrap-servers est requis ou doit être défini via KAFKA_BOOTSTRAP_SERVERS dans .env")
    if not args.username:
        parser.error("--username est requis ou doit être défini via KAFKA_USERNAME dans .env")
    if not args.password:
        parser.error("--password est requis ou doit être défini via KAFKA_PASSWORD dans .env")

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    # Configuration du signal handler
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    # Créer la configuration
    config = ConsumerConfig(
        bootstrap_servers=args.bootstrap_servers.split(','),
        security_protocol=args.security_protocol,
        sasl_mechanism=args.sasl_mechanism,
        sasl_plain_username=args.username,
        sasl_plain_password=args.password,
        topic_prefix=args.topic_prefix,
        num_topics=args.num_topics,
        consumer_group=args.consumer_group,
        num_consumers=args.num_consumers,
        duration_minutes=args.duration_minutes,
        auto_offset_reset=args.auto_offset_reset,
        ssl_cafile=args.ssl_cafile,
        ssl_certfile=args.ssl_certfile,
        ssl_keyfile=args.ssl_keyfile,
        ssl_password=args.ssl_password
    )

    # Créer et démarrer le consommateur
    consumer = KafkaConsumerBomber(config)
    consumer.start()

if __name__ == "__main__":
    main()
