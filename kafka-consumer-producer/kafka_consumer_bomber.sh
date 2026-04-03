#!/bin/sh
###############################################################################
# Kafka Consumer Bomber (Shell)
# Consomme des messages JSON depuis Kafka de maniere intensive
# Supporte: PLAINTEXT, SSL, SASL_PLAINTEXT, SASL_SSL
# Mecanismes SASL: PLAIN, SCRAM-SHA-256, SCRAM-SHA-512
###############################################################################

set -e

# ── Valeurs par defaut (surchargeables via .env ou arguments) ────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$SCRIPT_DIR/.env" ] && . "$SCRIPT_DIR/.env"
[ -f ".env" ] && . ".env"

BOOTSTRAP_SERVERS="${KAFKA_BOOTSTRAP_SERVERS:-localhost:9092}"
SECURITY_PROTOCOL="${KAFKA_SECURITY_PROTOCOL:-PLAINTEXT}"
SASL_MECHANISM="${KAFKA_SASL_MECHANISM:-PLAIN}"
SASL_USERNAME="${KAFKA_USERNAME:-}"
SASL_PASSWORD="${KAFKA_PASSWORD:-}"
TOPIC_PREFIX="${KAFKA_TOPIC_PREFIX:-test-prometheus}"
NUM_TOPICS="${KAFKA_NUM_TOPICS:-10}"
CONSUMER_GROUP="${KAFKA_CONSUMER_GROUP:-prometheus-test-group-sh}"
AUTO_OFFSET_RESET="${KAFKA_AUTO_OFFSET_RESET:-earliest}"
DURATION_MINUTES="${KAFKA_DURATION_MINUTES:-60}"
SSL_CAFILE="${KAFKA_SSL_CAFILE:-}"
SSL_CERTFILE="${KAFKA_SSL_CERTFILE:-}"
SSL_KEYFILE="${KAFKA_SSL_KEYFILE:-}"
SSL_TRUSTSTORE="${KAFKA_SSL_TRUSTSTORE:-}"
SSL_TRUSTSTORE_PASSWORD="${KAFKA_SSL_TRUSTSTORE_PASSWORD:-}"
SSL_KEYSTORE="${KAFKA_SSL_KEYSTORE:-}"
SSL_KEYSTORE_PASSWORD="${KAFKA_SSL_KEYSTORE_PASSWORD:-}"
VERBOSE="${KAFKA_VERBOSE:-false}"

KAFKA_HOME="${KAFKA_HOME:-}"
USE_KCAT="${USE_KCAT:-auto}"

# ── Compteurs ────────────────────────────────────────────────────────────────
MESSAGES_CONSUMED=0
MESSAGES_FAILED=0
BYTES_CONSUMED=0
START_TIME=0
RUNNING=1
CONSUMER_PID=""

# Types de messages
COUNT_USER_ACTIVITY=0
COUNT_SYSTEM_METRICS=0
COUNT_TRANSACTION=0
COUNT_LOG_EVENT=0
COUNT_SENSOR_DATA=0
COUNT_UNKNOWN=0

# ── Fichiers temporaires ─────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
PROPS_FILE="$TMP_DIR/consumer.properties"
STATS_FILE="$TMP_DIR/stats.txt"

cleanup() {
    RUNNING=0

    # Arreter le consumer en arriere-plan
    if [ -n "$CONSUMER_PID" ] && kill -0 "$CONSUMER_PID" 2>/dev/null; then
        kill "$CONSUMER_PID" 2>/dev/null
        wait "$CONSUMER_PID" 2>/dev/null
    fi

    elapsed=$(($(date +%s) - START_TIME))
    [ "$elapsed" -le 0 ] && elapsed=1
    rate=$((MESSAGES_CONSUMED / elapsed))

    echo ""
    echo "=== STATISTIQUES FINALES ==="
    echo "Messages consommes:  $MESSAGES_CONSUMED"
    echo "Messages echoues:    $MESSAGES_FAILED"
    echo "Taux moyen:          ${rate} msg/s"
    echo "Duree totale:        ${elapsed}s"
    echo ""
    echo "--- Par type de message ---"
    echo "  user_activity:   $COUNT_USER_ACTIVITY"
    echo "  system_metrics:  $COUNT_SYSTEM_METRICS"
    echo "  transaction:     $COUNT_TRANSACTION"
    echo "  log_event:       $COUNT_LOG_EVENT"
    echo "  sensor_data:     $COUNT_SENSOR_DATA"
    echo "  unknown:         $COUNT_UNKNOWN"

    rm -rf "$TMP_DIR"
    exit 0
}
trap cleanup INT TERM

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: kafka_consumer_bomber.sh [OPTIONS]

Options:
  --bootstrap-servers HOST:PORT   Serveurs Kafka (defaut: localhost:9092)
  --security-protocol PROTO       PLAINTEXT|SSL|SASL_PLAINTEXT|SASL_SSL (defaut: PLAINTEXT)
  --sasl-mechanism MECH           PLAIN|SCRAM-SHA-256|SCRAM-SHA-512 (defaut: PLAIN)
  --username USER                 Utilisateur SASL
  --password PASS                 Mot de passe SASL
  --topic-prefix PREFIX           Prefixe des topics (defaut: test-prometheus)
  --num-topics N                  Nombre de topics (defaut: 10)
  --consumer-group GROUP          Groupe de consommateurs (defaut: prometheus-test-group-sh)
  --auto-offset-reset RESET       earliest|latest (defaut: earliest)
  --duration-minutes N            Duree en minutes (defaut: 60)
  --ssl-cafile PATH               Certificat CA (PEM)
  --ssl-certfile PATH             Certificat client (PEM)
  --ssl-keyfile PATH              Cle privee client (PEM)
  --ssl-truststore PATH           Truststore JKS (pour kafka-console-consumer)
  --ssl-truststore-password PASS  Mot de passe truststore
  --ssl-keystore PATH             Keystore JKS (pour kafka-console-consumer)
  --ssl-keystore-password PASS    Mot de passe keystore
  --kafka-home PATH               Chemin vers l'installation Kafka
  --use-kcat                      Forcer l'utilisation de kcat
  --verbose                       Mode verbeux
  -h, --help                      Afficher l'aide

Variables d'environnement (fichier .env supporte):
  KAFKA_BOOTSTRAP_SERVERS, KAFKA_SECURITY_PROTOCOL, KAFKA_SASL_MECHANISM,
  KAFKA_USERNAME, KAFKA_PASSWORD, KAFKA_TOPIC_PREFIX, KAFKA_NUM_TOPICS,
  KAFKA_CONSUMER_GROUP, KAFKA_AUTO_OFFSET_RESET, KAFKA_DURATION_MINUTES,
  KAFKA_SSL_CAFILE, KAFKA_SSL_CERTFILE, KAFKA_SSL_KEYFILE,
  KAFKA_SSL_TRUSTSTORE, KAFKA_SSL_TRUSTSTORE_PASSWORD,
  KAFKA_SSL_KEYSTORE, KAFKA_SSL_KEYSTORE_PASSWORD,
  KAFKA_HOME, USE_KCAT, KAFKA_VERBOSE
USAGE
    exit 0
}

# ── Parse arguments ──────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --bootstrap-servers)    BOOTSTRAP_SERVERS="$2"; shift 2;;
        --security-protocol)    SECURITY_PROTOCOL="$2"; shift 2;;
        --sasl-mechanism)       SASL_MECHANISM="$2"; shift 2;;
        --username)             SASL_USERNAME="$2"; shift 2;;
        --password)             SASL_PASSWORD="$2"; shift 2;;
        --topic-prefix)         TOPIC_PREFIX="$2"; shift 2;;
        --num-topics)           NUM_TOPICS="$2"; shift 2;;
        --consumer-group)       CONSUMER_GROUP="$2"; shift 2;;
        --auto-offset-reset)    AUTO_OFFSET_RESET="$2"; shift 2;;
        --duration-minutes)     DURATION_MINUTES="$2"; shift 2;;
        --ssl-cafile)           SSL_CAFILE="$2"; shift 2;;
        --ssl-certfile)         SSL_CERTFILE="$2"; shift 2;;
        --ssl-keyfile)          SSL_KEYFILE="$2"; shift 2;;
        --ssl-truststore)       SSL_TRUSTSTORE="$2"; shift 2;;
        --ssl-truststore-password) SSL_TRUSTSTORE_PASSWORD="$2"; shift 2;;
        --ssl-keystore)         SSL_KEYSTORE="$2"; shift 2;;
        --ssl-keystore-password) SSL_KEYSTORE_PASSWORD="$2"; shift 2;;
        --kafka-home)           KAFKA_HOME="$2"; shift 2;;
        --use-kcat)             USE_KCAT="yes"; shift;;
        --verbose)              VERBOSE="true"; shift;;
        -h|--help)              usage;;
        *) echo "Option inconnue: $1"; usage;;
    esac
done

# ── Detecter l'outil disponible ──────────────────────────────────────────────
detect_tool() {
    if [ "$USE_KCAT" = "yes" ]; then
        if command -v kcat >/dev/null 2>&1; then
            CONSUMER_TOOL="kcat"
        elif command -v kafkacat >/dev/null 2>&1; then
            CONSUMER_TOOL="kafkacat"
        else
            echo "ERREUR: kcat/kafkacat non trouve"
            exit 1
        fi
    elif [ "$USE_KCAT" = "auto" ]; then
        if command -v kcat >/dev/null 2>&1; then
            CONSUMER_TOOL="kcat"
        elif command -v kafkacat >/dev/null 2>&1; then
            CONSUMER_TOOL="kafkacat"
        elif [ -n "$KAFKA_HOME" ] && [ -x "$KAFKA_HOME/bin/kafka-console-consumer.sh" ]; then
            CONSUMER_TOOL="kafka-cli"
        elif command -v kafka-console-consumer.sh >/dev/null 2>&1; then
            CONSUMER_TOOL="kafka-cli"
            KAFKA_HOME=""
        else
            echo "ERREUR: Aucun outil Kafka trouve (kcat, kafkacat ou kafka-console-consumer.sh)"
            echo "Installez kcat: brew install kcat / apt install kafkacat"
            echo "Ou definissez KAFKA_HOME vers votre installation Kafka"
            exit 1
        fi
    else
        if [ -n "$KAFKA_HOME" ] && [ -x "$KAFKA_HOME/bin/kafka-console-consumer.sh" ]; then
            CONSUMER_TOOL="kafka-cli"
        elif command -v kafka-console-consumer.sh >/dev/null 2>&1; then
            CONSUMER_TOOL="kafka-cli"
            KAFKA_HOME=""
        else
            echo "ERREUR: kafka-console-consumer.sh non trouve"
            exit 1
        fi
    fi
    echo "[INFO] Outil utilise: $CONSUMER_TOOL"
}

# ── Generer le fichier de proprietes ─────────────────────────────────────────
generate_properties() {
    cat > "$PROPS_FILE" <<EOF
bootstrap.servers=${BOOTSTRAP_SERVERS}
security.protocol=${SECURITY_PROTOCOL}
group.id=${CONSUMER_GROUP}
auto.offset.reset=${AUTO_OFFSET_RESET}
enable.auto.commit=true
auto.commit.interval.ms=1000
session.timeout.ms=30000
heartbeat.interval.ms=3000
max.poll.interval.ms=300000
fetch.min.bytes=1
fetch.max.wait.ms=500
max.partition.fetch.bytes=1048576
EOF

    # SASL
    case "$SECURITY_PROTOCOL" in
        SASL_PLAINTEXT|SASL_SSL)
            if [ -z "$SASL_USERNAME" ] || [ -z "$SASL_PASSWORD" ]; then
                echo "ERREUR: --username et --password requis pour $SECURITY_PROTOCOL"
                exit 1
            fi
            echo "sasl.mechanism=${SASL_MECHANISM}" >> "$PROPS_FILE"

            case "$SASL_MECHANISM" in
                PLAIN)
                    cat >> "$PROPS_FILE" <<EOF
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${SASL_USERNAME}" password="${SASL_PASSWORD}";
EOF
                    ;;
                SCRAM-SHA-256|SCRAM-SHA-512)
                    cat >> "$PROPS_FILE" <<EOF
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="${SASL_USERNAME}" password="${SASL_PASSWORD}";
EOF
                    ;;
                *)
                    echo "ERREUR: Mecanisme SASL non supporte: $SASL_MECHANISM"
                    exit 1
                    ;;
            esac
            ;;
    esac

    # SSL
    case "$SECURITY_PROTOCOL" in
        SSL|SASL_SSL)
            if [ -n "$SSL_TRUSTSTORE" ]; then
                echo "ssl.truststore.location=${SSL_TRUSTSTORE}" >> "$PROPS_FILE"
                [ -n "$SSL_TRUSTSTORE_PASSWORD" ] && echo "ssl.truststore.password=${SSL_TRUSTSTORE_PASSWORD}" >> "$PROPS_FILE"
            fi
            if [ -n "$SSL_KEYSTORE" ]; then
                echo "ssl.keystore.location=${SSL_KEYSTORE}" >> "$PROPS_FILE"
                [ -n "$SSL_KEYSTORE_PASSWORD" ] && echo "ssl.keystore.password=${SSL_KEYSTORE_PASSWORD}" >> "$PROPS_FILE"
            fi
            if [ -z "$SSL_TRUSTSTORE" ] && [ -z "$SSL_CAFILE" ]; then
                echo "ssl.endpoint.identification.algorithm=" >> "$PROPS_FILE"
            fi
            ;;
    esac

    [ "$VERBOSE" = "true" ] && echo "[DEBUG] Fichier properties:" && cat "$PROPS_FILE"
}

# ── Construire la liste des topics ───────────────────────────────────────────
build_topics_list() {
    topics=""
    i=1
    while [ "$i" -le "$NUM_TOPICS" ]; do
        t=$(printf "%s.generated-data-%02d.json" "$TOPIC_PREFIX" "$i")
        if [ -z "$topics" ]; then
            topics="$t"
        else
            topics="${topics},${t}"
        fi
        i=$((i + 1))
    done
    echo "$topics"
}

# ── Traiter une ligne de message ─────────────────────────────────────────────
process_message() {
    line="$1"

    # Verifier que c'est du JSON
    case "$line" in
        "{"*)
            MESSAGES_CONSUMED=$((MESSAGES_CONSUMED + 1))
            BYTES_CONSUMED=$((BYTES_CONSUMED + ${#line}))

            # Extraire le type de message (parsing leger sans jq)
            msg_type=""
            if command -v jq >/dev/null 2>&1; then
                msg_type=$(echo "$line" | jq -r '.type // "unknown"' 2>/dev/null)
            else
                # Fallback: extraction basique avec sed
                msg_type=$(echo "$line" | sed -n 's/.*"type"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            fi

            case "$msg_type" in
                user_activity)   COUNT_USER_ACTIVITY=$((COUNT_USER_ACTIVITY + 1));;
                system_metrics)  COUNT_SYSTEM_METRICS=$((COUNT_SYSTEM_METRICS + 1));;
                transaction)     COUNT_TRANSACTION=$((COUNT_TRANSACTION + 1));;
                log_event)       COUNT_LOG_EVENT=$((COUNT_LOG_EVENT + 1));;
                sensor_data)     COUNT_SENSOR_DATA=$((COUNT_SENSOR_DATA + 1));;
                *)               COUNT_UNKNOWN=$((COUNT_UNKNOWN + 1));;
            esac

            [ "$VERBOSE" = "true" ] && echo "[RECV] type=${msg_type} $(echo "$line" | cut -c1-80)..."

            # Reporter toutes les 100 messages
            if [ $((MESSAGES_CONSUMED % 100)) -eq 0 ]; then
                now=$(date +%s)
                elapsed=$((now - START_TIME))
                [ "$elapsed" -le 0 ] && elapsed=1
                rate=$((MESSAGES_CONSUMED / elapsed))
                echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Messages: ${MESSAGES_CONSUMED} (+${MESSAGES_FAILED} failed), Rate: ${rate} msg/s"
            fi
            ;;
        "")
            # Ligne vide, ignorer
            ;;
        *)
            # Pas du JSON valide
            MESSAGES_FAILED=$((MESSAGES_FAILED + 1))
            [ "$VERBOSE" = "true" ] && echo "[SKIP] Non-JSON: $(echo "$line" | cut -c1-60)"
            ;;
    esac
}

# ── Lancer le consumer kcat ─────────────────────────────────────────────────
start_consumer_kcat() {
    topics_list="$1"

    kcat_args="-C -b $BOOTSTRAP_SERVERS -G $CONSUMER_GROUP"

    # Ajouter chaque topic separement (kcat -G attend les topics comme arguments)
    i=1
    while [ "$i" -le "$NUM_TOPICS" ]; do
        t=$(printf "%s.generated-data-%02d.json" "$TOPIC_PREFIX" "$i")
        kcat_args="$kcat_args $t"
        i=$((i + 1))
    done

    kcat_args="$kcat_args -X security.protocol=$SECURITY_PROTOCOL"
    kcat_args="$kcat_args -X auto.offset.reset=$AUTO_OFFSET_RESET"

    case "$SECURITY_PROTOCOL" in
        SASL_PLAINTEXT|SASL_SSL)
            kcat_args="$kcat_args -X sasl.mechanism=$SASL_MECHANISM"
            kcat_args="$kcat_args -X sasl.username=$SASL_USERNAME"
            kcat_args="$kcat_args -X sasl.password=$SASL_PASSWORD"
            ;;
    esac

    case "$SECURITY_PROTOCOL" in
        SSL|SASL_SSL)
            [ -n "$SSL_CAFILE" ] && kcat_args="$kcat_args -X ssl.ca.location=$SSL_CAFILE"
            [ -n "$SSL_CERTFILE" ] && kcat_args="$kcat_args -X ssl.certificate.location=$SSL_CERTFILE"
            [ -n "$SSL_KEYFILE" ] && kcat_args="$kcat_args -X ssl.key.location=$SSL_KEYFILE"
            if [ -z "$SSL_CAFILE" ]; then
                kcat_args="$kcat_args -X enable.ssl.certificate.verification=false"
            fi
            ;;
    esac

    echo "[INFO] Lancement: $CONSUMER_TOOL $kcat_args"
    $CONSUMER_TOOL $kcat_args 2>/dev/null &
    CONSUMER_PID=$!
}

# ── Lancer le consumer kafka-cli ─────────────────────────────────────────────
start_consumer_cli() {
    topics_list="$1"

    if [ -n "$KAFKA_HOME" ]; then
        consumer_cmd="$KAFKA_HOME/bin/kafka-console-consumer.sh"
    else
        consumer_cmd="kafka-console-consumer.sh"
    fi

    # Construire la whitelist (regex) pour plusieurs topics
    whitelist=$(printf "%s\\.generated-data-[0-9]+\\.json" "$TOPIC_PREFIX")

    echo "[INFO] Lancement: $consumer_cmd --whitelist '$whitelist'"
    $consumer_cmd \
        --bootstrap-server "$BOOTSTRAP_SERVERS" \
        --whitelist "$whitelist" \
        --consumer.config "$PROPS_FILE" \
        --from-beginning \
        2>/dev/null &
    CONSUMER_PID=$!
}

# ── Boucle principale ────────────────────────────────────────────────────────
main() {
    echo "=== Kafka Consumer Bomber (Shell) ==="
    echo "Bootstrap:  $BOOTSTRAP_SERVERS"
    echo "Protocol:   $SECURITY_PROTOCOL"
    echo "SASL:       $SASL_MECHANISM"
    echo "Group:      $CONSUMER_GROUP"
    echo "Topics:     $NUM_TOPICS (prefix: $TOPIC_PREFIX)"
    echo "Offset:     $AUTO_OFFSET_RESET"
    echo "Duree:      $DURATION_MINUTES min"
    echo ""

    detect_tool

    topics_list=$(build_topics_list)
    echo "[INFO] Topics: $topics_list"

    if [ "$CONSUMER_TOOL" = "kafka-cli" ]; then
        generate_properties
    fi

    START_TIME=$(date +%s)
    END_TIME=$((START_TIME + DURATION_MINUTES * 60))

    echo "[INFO] Demarrage de la consommation..."
    echo ""

    # Lancer le consumer et traiter le flux ligne par ligne
    case "$CONSUMER_TOOL" in
        kcat|kafkacat)
            # kcat en mode consumer group
            kcat_args="-C -b $BOOTSTRAP_SERVERS -G $CONSUMER_GROUP"

            i=1
            while [ "$i" -le "$NUM_TOPICS" ]; do
                t=$(printf "%s.generated-data-%02d.json" "$TOPIC_PREFIX" "$i")
                kcat_args="$kcat_args $t"
                i=$((i + 1))
            done

            kcat_args="$kcat_args -X security.protocol=$SECURITY_PROTOCOL"
            kcat_args="$kcat_args -X auto.offset.reset=$AUTO_OFFSET_RESET"

            case "$SECURITY_PROTOCOL" in
                SASL_PLAINTEXT|SASL_SSL)
                    kcat_args="$kcat_args -X sasl.mechanism=$SASL_MECHANISM"
                    kcat_args="$kcat_args -X sasl.username=$SASL_USERNAME"
                    kcat_args="$kcat_args -X sasl.password=$SASL_PASSWORD"
                    ;;
            esac

            case "$SECURITY_PROTOCOL" in
                SSL|SASL_SSL)
                    [ -n "$SSL_CAFILE" ] && kcat_args="$kcat_args -X ssl.ca.location=$SSL_CAFILE"
                    [ -n "$SSL_CERTFILE" ] && kcat_args="$kcat_args -X ssl.certificate.location=$SSL_CERTFILE"
                    [ -n "$SSL_KEYFILE" ] && kcat_args="$kcat_args -X ssl.key.location=$SSL_KEYFILE"
                    if [ -z "$SSL_CAFILE" ]; then
                        kcat_args="$kcat_args -X enable.ssl.certificate.verification=false"
                    fi
                    ;;
            esac

            # Pipe le flux dans le processeur
            $CONSUMER_TOOL $kcat_args 2>/dev/null | while IFS= read -r line; do
                [ "$(date +%s)" -ge "$END_TIME" ] && break
                process_message "$line"
            done
            ;;

        kafka-cli)
            if [ -n "$KAFKA_HOME" ]; then
                consumer_cmd="$KAFKA_HOME/bin/kafka-console-consumer.sh"
            else
                consumer_cmd="kafka-console-consumer.sh"
            fi

            whitelist=$(printf "%s\\.generated-data-[0-9]+\\.json" "$TOPIC_PREFIX")

            $consumer_cmd \
                --bootstrap-server "$BOOTSTRAP_SERVERS" \
                --whitelist "$whitelist" \
                --consumer.config "$PROPS_FILE" \
                --from-beginning \
                2>/dev/null | while IFS= read -r line; do
                    [ "$(date +%s)" -ge "$END_TIME" ] && break
                    process_message "$line"
                done
            ;;
    esac

    cleanup
}

main
