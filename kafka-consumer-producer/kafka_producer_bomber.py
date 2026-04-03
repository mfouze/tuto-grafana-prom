#!/usr/bin/env python3
"""
Kafka Producer Bomber - Script de test pour Prometheus
Génère des messages JSON de manière aléatoire pour bombarder le cluster Kafka
Support SASL_SSL avec PLAIN pour l'authentification
"""

import json
import random
import time
import threading
import logging
import os
from datetime import datetime, timezone
from typing import Dict, Any, List
from dataclasses import dataclass
from kafka import KafkaProducer
from kafka.errors import KafkaError
import argparse
import signal
import sys
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
class ProducerConfig:
    """Configuration du producteur Kafka"""
    bootstrap_servers: List[str]
    security_protocol: str = "SASL_SSL"
    sasl_mechanism: str = "PLAIN"
    sasl_plain_username: str = ""
    sasl_plain_password: str = ""
    topic_prefix: str = "test-prometheus"
    num_topics: int = 10
    messages_per_second: int = 1000
    message_size_kb: int = 1
    num_threads: int = 5
    duration_minutes: int = 60

class MessageGenerator:
    """Générateur de messages JSON aléatoires"""

    def __init__(self, config: ProducerConfig):
        self.config = config
        self.message_templates = self._create_message_templates()
        self.running = True

    def _create_message_templates(self) -> List[Dict[str, Any]]:
        """Crée des templates de messages pour différents types de données"""
        return [
            {
                "type": "user_activity",
                "template": {
                    "user_id": "{user_id}",
                    "action": "{action}",
                    "timestamp": "{timestamp}",
                    "session_id": "{session_id}",
                    "ip_address": "{ip_address}",
                    "user_agent": "{user_agent}",
                    "metadata": {
                        "page": "{page}",
                        "duration": "{duration}",
                        "device_type": "{device_type}"
                    }
                }
            },
            {
                "type": "system_metrics",
                "template": {
                    "server_id": "{server_id}",
                    "metric_name": "{metric_name}",
                    "value": "{value}",
                    "timestamp": "{timestamp}",
                    "tags": {
                        "environment": "{environment}",
                        "region": "{region}",
                        "service": "{service}"
                    }
                }
            },
            {
                "type": "transaction",
                "template": {
                    "transaction_id": "{transaction_id}",
                    "amount": "{amount}",
                    "currency": "{currency}",
                    "timestamp": "{timestamp}",
                    "user_id": "{user_id}",
                    "merchant": "{merchant}",
                    "status": "{status}",
                    "payment_method": "{payment_method}"
                }
            },
            {
                "type": "log_event",
                "template": {
                    "level": "{level}",
                    "message": "{message}",
                    "timestamp": "{timestamp}",
                    "service": "{service}",
                    "trace_id": "{trace_id}",
                    "span_id": "{span_id}",
                    "metadata": {
                        "file": "{file}",
                        "line": "{line}",
                        "function": "{function}"
                    }
                }
            },
            {
                "type": "sensor_data",
                "template": {
                    "sensor_id": "{sensor_id}",
                    "sensor_type": "{sensor_type}",
                    "value": "{value}",
                    "unit": "{unit}",
                    "timestamp": "{timestamp}",
                    "location": {
                        "latitude": "{latitude}",
                        "longitude": "{longitude}",
                        "altitude": "{altitude}"
                    },
                    "quality": "{quality}"
                }
            }
        ]

    def generate_random_data(self) -> Dict[str, Any]:
        """Génère des données aléatoires pour remplir les templates"""
        return {
            "user_id": f"user_{random.randint(1, 100000)}",
            "action": random.choice(["login", "logout", "view", "click", "purchase", "search", "navigate"]),
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "session_id": f"session_{random.randint(100000, 999999)}",
            "ip_address": f"{random.randint(1, 255)}.{random.randint(1, 255)}.{random.randint(1, 255)}.{random.randint(1, 255)}",
            "user_agent": random.choice([
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
            ]),
            "page": f"/page_{random.randint(1, 100)}",
            "duration": random.randint(1, 3600),
            "device_type": random.choice(["desktop", "mobile", "tablet"]),
            "server_id": f"server_{random.randint(1, 100)}",
            "metric_name": random.choice(["cpu_usage", "memory_usage", "disk_usage", "network_io", "response_time"]),
            "value": round(random.uniform(0, 100), 2),
            "environment": random.choice(["production", "staging", "development"]),
            "region": random.choice(["us-east-1", "us-west-2", "eu-west-1", "ap-southeast-1"]),
            "service": random.choice(["api", "web", "database", "cache", "queue"]),
            "transaction_id": f"txn_{random.randint(1000000, 9999999)}",
            "amount": round(random.uniform(1, 10000), 2),
            "currency": random.choice(["USD", "EUR", "GBP", "JPY"]),
            "merchant": f"merchant_{random.randint(1, 1000)}",
            "status": random.choice(["success", "pending", "failed", "cancelled"]),
            "payment_method": random.choice(["credit_card", "debit_card", "paypal", "bank_transfer"]),
            "level": random.choice(["DEBUG", "INFO", "WARN", "ERROR", "FATAL"]),
            "message": random.choice([
                "User authentication successful",
                "Database connection established",
                "Cache miss occurred",
                "API request processed",
                "Background job completed"
            ]),
            "trace_id": f"trace_{random.randint(100000, 999999)}",
            "span_id": f"span_{random.randint(10000, 99999)}",
            "file": f"app_{random.randint(1, 10)}.py",
            "line": random.randint(1, 1000),
            "function": random.choice(["process_request", "validate_input", "save_data", "send_notification"]),
            "sensor_id": f"sensor_{random.randint(1, 1000)}",
            "sensor_type": random.choice(["temperature", "humidity", "pressure", "motion", "light"]),
            "unit": random.choice(["celsius", "fahrenheit", "percent", "pascal", "lux"]),
            "latitude": round(random.uniform(-90, 90), 6),
            "longitude": round(random.uniform(-180, 180), 6),
            "altitude": round(random.uniform(0, 5000), 2),
            "quality": random.choice(["excellent", "good", "fair", "poor"])
        }

    def generate_message(self) -> Dict[str, Any]:
        """Génère un message JSON aléatoire"""
        template_info = random.choice(self.message_templates)
        data = self.generate_random_data()

        # Remplir le template avec les données aléatoires
        message = {}
        for key, value in template_info["template"].items():
            if isinstance(value, str) and value.startswith("{") and value.endswith("}"):
                field_name = value[1:-1]
                message[key] = data.get(field_name, value)
            elif isinstance(value, dict):
                message[key] = {}
                for sub_key, sub_value in value.items():
                    if isinstance(sub_value, str) and sub_value.startswith("{") and sub_value.endswith("}"):
                        field_name = sub_value[1:-1]
                        message[key][sub_key] = data.get(field_name, sub_value)
                    else:
                        message[key][sub_key] = sub_value
            else:
                message[key] = value

        # Ajouter des métadonnées
        message["_metadata"] = {
            "generated_at": datetime.now(timezone.utc).isoformat(),
            "message_id": f"msg_{random.randint(1000000, 9999999)}",
            "version": "1.0",
            "source": "kafka_producer_bomber"
        }

        return message

class KafkaProducerBomber:
    """Bombardeur Kafka pour tester Prometheus"""

    def __init__(self, config: ProducerConfig):
        self.config = config
        self.message_generator = MessageGenerator(config)
        self.producer = None
        self.running = False
        self.stats = {
            "messages_sent": 0,
            "messages_failed": 0,
            "bytes_sent": 0,
            "start_time": None,
            "topics_created": set()
        }

    def _create_producer(self) -> KafkaProducer:
        """Crée le producteur Kafka avec configuration SASL_SSL/PLAIN"""
        try:
            producer = KafkaProducer(
                bootstrap_servers=self.config.bootstrap_servers,
                security_protocol=self.config.security_protocol,
                sasl_mechanism=self.config.sasl_mechanism,
                sasl_plain_username=self.config.sasl_plain_username,
                sasl_plain_password=self.config.sasl_plain_password,
                value_serializer=lambda v: json.dumps(v).encode('utf-8'),
                key_serializer=lambda k: k.encode('utf-8') if k else None,
                acks='all',  # Attendre confirmation de tous les replicas
                retries=3,
                retry_backoff_ms=100,
                request_timeout_ms=30000,
                max_block_ms=10000,
                compression_type='gzip',  # Compression pour économiser la bande passante
                batch_size=16384,  # Taille de batch optimisée
                linger_ms=10,  # Attendre 10ms avant d'envoyer le batch
                buffer_memory=33554432,  # 32MB de buffer
                max_request_size=1048576,  # 1MB max par requête
            )
            logger.info("Producteur Kafka créé avec succès")
            return producer
        except Exception as e:
            logger.error(f"Erreur lors de la création du producteur: {e}")
            raise

    def _get_random_topic(self) -> str:
        """Retourne un topic aléatoire"""
        topic_num = random.randint(1, self.config.num_topics)
        topic = f"{self.config.topic_prefix}.generated-data-{topic_num:02d}.json"
        self.stats["topics_created"].add(topic)
        return topic

    def _get_random_key(self) -> str:
        """Retourne une clé aléatoire pour le partitionnement"""
        return f"key_{random.randint(1, 1000)}"

    def _send_message(self, topic: str, key: str, message: Dict[str, Any]) -> bool:
        """Envoie un message au topic Kafka"""
        try:
            future = self.producer.send(
                topic=topic,
                key=key,
                value=message
            )

            # Attendre la confirmation (optionnel, pour les tests on peut être asynchrone)
            # record_metadata = future.get(timeout=10)

            self.stats["messages_sent"] += 1
            self.stats["bytes_sent"] += len(json.dumps(message).encode('utf-8'))
            return True

        except KafkaError as e:
            logger.error(f"Erreur Kafka lors de l'envoi: {e}")
            self.stats["messages_failed"] += 1
            return False
        except Exception as e:
            logger.error(f"Erreur inattendue lors de l'envoi: {e}")
            self.stats["messages_failed"] += 1
            return False

    def _producer_worker(self, worker_id: int):
        """Worker thread pour envoyer des messages"""
        logger.info(f"Worker {worker_id} démarré")

        messages_per_worker = self.config.messages_per_second // self.config.num_threads
        sleep_interval = 1.0 / messages_per_worker if messages_per_worker > 0 else 1.0

        while self.running:
            try:
                # Générer et envoyer un message
                message = self.message_generator.generate_message()
                topic = self._get_random_topic()
                key = self._get_random_key()

                self._send_message(topic, key, message)

                # Attendre avant le prochain message
                time.sleep(sleep_interval)

            except Exception as e:
                logger.error(f"Erreur dans le worker {worker_id}: {e}")
                time.sleep(1)

    def _stats_reporter(self):
        """Thread pour reporter les statistiques"""
        while self.running:
            time.sleep(10)  # Reporter toutes les 10 secondes

            if self.stats["start_time"]:
                elapsed = time.time() - self.stats["start_time"]
                rate = self.stats["messages_sent"] / elapsed if elapsed > 0 else 0
                throughput = self.stats["bytes_sent"] / elapsed / 1024 / 1024 if elapsed > 0 else 0

                logger.info(
                    f"Stats - Messages: {self.stats['messages_sent']} "
                    f"(+{self.stats['messages_failed']} failed), "
                    f"Rate: {rate:.1f} msg/s, "
                    f"Throughput: {throughput:.2f} MB/s, "
                    f"Topics: {len(self.stats['topics_created'])}"
                )

    def start(self):
        """Démarre le bombardement"""
        logger.info("Démarrage du bombardeur Kafka...")

        try:
            # Créer le producteur
            self.producer = self._create_producer()

            # Démarrer les workers
            self.running = True
            self.stats["start_time"] = time.time()

            workers = []
            for i in range(self.config.num_threads):
                worker = threading.Thread(target=self._producer_worker, args=(i,))
                worker.daemon = True
                worker.start()
                workers.append(worker)

            # Démarrer le reporter de stats
            stats_thread = threading.Thread(target=self._stats_reporter)
            stats_thread.daemon = True
            stats_thread.start()

            logger.info(f"Bombardement démarré avec {self.config.num_threads} workers")
            logger.info(f"Configuration: {self.config.messages_per_second} msg/s, {self.config.num_topics} topics")

            # Attendre la durée spécifiée
            time.sleep(self.config.duration_minutes * 60)

        except KeyboardInterrupt:
            logger.info("Arrêt demandé par l'utilisateur")
        except Exception as e:
            logger.error(f"Erreur lors du démarrage: {e}")
        finally:
            self.stop()

    def stop(self):
        """Arrête le bombardement"""
        logger.info("Arrêt du bombardeur...")
        self.running = False

        if self.producer:
            self.producer.flush()  # Attendre que tous les messages soient envoyés
            self.producer.close()

        # Afficher les stats finales
        if self.stats["start_time"]:
            elapsed = time.time() - self.stats["start_time"]
            rate = self.stats["messages_sent"] / elapsed if elapsed > 0 else 0
            throughput = self.stats["bytes_sent"] / elapsed / 1024 / 1024 if elapsed > 0 else 0

            logger.info("=== STATISTIQUES FINALES ===")
            logger.info(f"Messages envoyés: {self.stats['messages_sent']}")
            logger.info(f"Messages échoués: {self.stats['messages_failed']}")
            logger.info(f"Taux moyen: {rate:.1f} msg/s")
            logger.info(f"Débit moyen: {throughput:.2f} MB/s")
            logger.info(f"Topics utilisés: {len(self.stats['topics_created'])}")
            logger.info(f"Durée totale: {elapsed:.1f} secondes")

def signal_handler(sig, frame):
    """Gestionnaire de signal pour arrêt propre"""
    logger.info("Signal d'arrêt reçu")
    sys.exit(0)

def main():
    """Fonction principale"""
    parser = argparse.ArgumentParser(description="Kafka Producer Bomber pour tester Prometheus")
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
                       help="Nombre de topics à utiliser. Peut être défini via KAFKA_NUM_TOPICS dans .env")
    parser.add_argument("--messages-per-second", 
                       type=int, 
                       default=int(os.getenv('KAFKA_MESSAGES_PER_SECOND', '1000')),
                       help="Messages par seconde. Peut être défini via KAFKA_MESSAGES_PER_SECOND dans .env")
    parser.add_argument("--num-threads", 
                       type=int, 
                       default=int(os.getenv('KAFKA_NUM_THREADS', '5')),
                       help="Nombre de threads producteurs. Peut être défini via KAFKA_NUM_THREADS dans .env")
    parser.add_argument("--duration-minutes", 
                       type=int, 
                       default=int(os.getenv('KAFKA_DURATION_MINUTES', '60')),
                       help="Durée en minutes. Peut être défini via KAFKA_DURATION_MINUTES dans .env")
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
    config = ProducerConfig(
        bootstrap_servers=args.bootstrap_servers.split(','),
        security_protocol=args.security_protocol,
        sasl_mechanism=args.sasl_mechanism,
        sasl_plain_username=args.username,
        sasl_plain_password=args.password,
        topic_prefix=args.topic_prefix,
        num_topics=args.num_topics,
        messages_per_second=args.messages_per_second,
        num_threads=args.num_threads,
        duration_minutes=args.duration_minutes
    )

    # Créer et démarrer le bombardeur
    bomber = KafkaProducerBomber(config)
    bomber.start()

if __name__ == "__main__":
    main()
