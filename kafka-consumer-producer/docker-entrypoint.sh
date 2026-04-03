#!/bin/bash
set -e

# Fonction d'aide
show_help() {
    cat << EOF
=== Kafka Performance Test Container ===

Ce conteneur contient:
  - Scripts bomber Python (kafka_producer_bomber.py, kafka_consumer_bomber.py)
  - Outils Kafka perf test officiels (kafka-producer-perf-test.sh, kafka-consumer-perf-test.sh)

Commandes disponibles:
  producer-bomber          Lancer kafka_producer_bomber.py
  consumer-bomber          Lancer kafka_consumer_bomber.py
  kafka-producer-perf      Lancer kafka-producer-perf-test.sh
  kafka-consumer-perf      Lancer kafka-consumer-perf-test.sh
  help                     Afficher cette aide

Exemples d'utilisation:

  # Entrer dans le conteneur interactif
  docker run -it --rm -v \$(pwd)/.env:/app/.env --network host kafka-perf-test:latest bash

  # Depuis le conteneur, vous pouvez lancer:
  python3 /app/kafka_producer_bomber.py --help
  python3 /app/kafka_consumer_bomber.py --help
  ${KAFKA_HOME}/bin/kafka-producer-perf-test.sh --help
  ${KAFKA_HOME}/bin/kafka-consumer-perf-test.sh --help

  # Ou utiliser les alias:
  producer-bomber --help
  consumer-bomber --help
  kafka-producer-perf --help
  kafka-consumer-perf --help

Variables d'environnement:
  KAFKA_BOOTSTRAP_SERVERS  Serveurs Kafka (pour scripts bomber)
  KAFKA_USERNAME           Nom d'utilisateur SASL
  KAFKA_PASSWORD           Mot de passe SASL
  KAFKA_SECURITY_PROTOCOL  Protocole de sécurité (défaut: SASL_SSL)
  KAFKA_SASL_MECHANISM     Mécanisme SASL (défaut: PLAIN)

Répertoires:
  /app                     Répertoire de travail (contient les scripts)
  /app/config              Répertoire pour fichiers de configuration
  ${KAFKA_HOME}/bin        Outils Kafka perf test

EOF
}

# Vérifier si un fichier .env existe
if [ -f /app/.env ]; then
    export $(cat /app/.env | grep -v '^#' | xargs)
fi

# Créer des alias pour faciliter l'utilisation
alias producer-bomber='python3 /app/kafka_producer_bomber.py'
alias consumer-bomber='python3 /app/kafka_consumer_bomber.py'
alias kafka-producer-perf='${KAFKA_HOME}/bin/kafka-producer-perf-test.sh'
alias kafka-consumer-perf='${KAFKA_HOME}/bin/kafka-consumer-perf-test.sh'

# Si une commande est fournie, l'exécuter directement
if [ $# -gt 0 ]; then
    COMMAND=$1
    shift
    
    case "$COMMAND" in
        producer-bomber)
            exec python3 /app/kafka_producer_bomber.py "$@"
            ;;
        
        consumer-bomber)
            exec python3 /app/kafka_consumer_bomber.py "$@"
            ;;
        
        kafka-producer-perf)
            exec ${KAFKA_HOME}/bin/kafka-producer-perf-test.sh "$@"
            ;;
        
        kafka-consumer-perf)
            exec ${KAFKA_HOME}/bin/kafka-consumer-perf-test.sh "$@"
            ;;
        
        help|--help|-h)
            show_help
            exit 0
            ;;
        
        *)
            # Si ce n'est pas une commande reconnue, l'exécuter directement
            exec "$COMMAND" "$@"
            ;;
    esac
fi

# Si aucune commande n'est fournie, afficher l'aide et lancer un shell interactif
show_help
echo ""
echo "Vous êtes dans un shell interactif. Utilisez les commandes ci-dessus ou lancez vos propres commandes."
echo "Tapez 'exit' pour quitter."
echo ""

# Lancer un shell interactif
exec /bin/bash
