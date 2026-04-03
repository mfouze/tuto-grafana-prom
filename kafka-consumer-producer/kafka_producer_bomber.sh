#!/bin/sh
###############################################################################
# Kafka Producer Bomber (Shell)
# Envoie des messages JSON aleatoires dans Kafka
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
MESSAGES_PER_SECOND="${KAFKA_MESSAGES_PER_SECOND:-10}"
DURATION_MINUTES="${KAFKA_DURATION_MINUTES:-60}"
SSL_CAFILE="${KAFKA_SSL_CAFILE:-}"
SSL_CERTFILE="${KAFKA_SSL_CERTFILE:-}"
SSL_KEYFILE="${KAFKA_SSL_KEYFILE:-}"
SSL_KEYSTORE="${KAFKA_SSL_KEYSTORE:-}"
SSL_KEYSTORE_PASSWORD="${KAFKA_SSL_KEYSTORE_PASSWORD:-}"
SSL_TRUSTSTORE="${KAFKA_SSL_TRUSTSTORE:-}"
SSL_TRUSTSTORE_PASSWORD="${KAFKA_SSL_TRUSTSTORE_PASSWORD:-}"
VERBOSE="${KAFKA_VERBOSE:-false}"

# Outil a utiliser: kcat ou kafka-console-producer
KAFKA_HOME="${KAFKA_HOME:-}"
USE_KCAT="${USE_KCAT:-auto}"

# ── Compteurs ────────────────────────────────────────────────────────────────
MESSAGES_SENT=0
MESSAGES_FAILED=0
BYTES_SENT=0
START_TIME=0
RUNNING=1

# ── Fichiers temporaires ─────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d)
PROPS_FILE="$TMP_DIR/producer.properties"
JAAS_FILE="$TMP_DIR/jaas.conf"

cleanup() {
    RUNNING=0
    elapsed=$(($(date +%s) - START_TIME))
    [ "$elapsed" -le 0 ] && elapsed=1
    rate=$((MESSAGES_SENT / elapsed))
    echo ""
    echo "=== STATISTIQUES FINALES ==="
    echo "Messages envoyes:  $MESSAGES_SENT"
    echo "Messages echoues:  $MESSAGES_FAILED"
    echo "Taux moyen:        ${rate} msg/s"
    echo "Duree totale:      ${elapsed}s"
    rm -rf "$TMP_DIR"
    exit 0
}
trap cleanup INT TERM

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
    cat <<'USAGE'
Usage: kafka_producer_bomber.sh [OPTIONS]

Options:
  --bootstrap-servers HOST:PORT   Serveurs Kafka (defaut: localhost:9092)
  --security-protocol PROTO       PLAINTEXT|SSL|SASL_PLAINTEXT|SASL_SSL (defaut: PLAINTEXT)
  --sasl-mechanism MECH           PLAIN|SCRAM-SHA-256|SCRAM-SHA-512 (defaut: PLAIN)
  --username USER                 Utilisateur SASL
  --password PASS                 Mot de passe SASL
  --topic-prefix PREFIX           Prefixe des topics (defaut: test-prometheus)
  --num-topics N                  Nombre de topics (defaut: 10)
  --messages-per-second N         Messages/sec (defaut: 10)
  --duration-minutes N            Duree en minutes (defaut: 60)
  --ssl-cafile PATH               Certificat CA (PEM)
  --ssl-certfile PATH             Certificat client (PEM)
  --ssl-keyfile PATH              Cle privee client (PEM)
  --ssl-truststore PATH           Truststore JKS (pour kafka-console-producer)
  --ssl-truststore-password PASS  Mot de passe truststore
  --ssl-keystore PATH             Keystore JKS (pour kafka-console-producer)
  --ssl-keystore-password PASS    Mot de passe keystore
  --kafka-home PATH               Chemin vers l'installation Kafka
  --use-kcat                      Forcer l'utilisation de kcat
  --verbose                       Mode verbeux
  -h, --help                      Afficher l'aide

Variables d'environnement (fichier .env supporte):
  KAFKA_BOOTSTRAP_SERVERS, KAFKA_SECURITY_PROTOCOL, KAFKA_SASL_MECHANISM,
  KAFKA_USERNAME, KAFKA_PASSWORD, KAFKA_TOPIC_PREFIX, KAFKA_NUM_TOPICS,
  KAFKA_MESSAGES_PER_SECOND, KAFKA_DURATION_MINUTES, KAFKA_SSL_CAFILE,
  KAFKA_SSL_CERTFILE, KAFKA_SSL_KEYFILE, KAFKA_SSL_TRUSTSTORE,
  KAFKA_SSL_TRUSTSTORE_PASSWORD, KAFKA_SSL_KEYSTORE, KAFKA_SSL_KEYSTORE_PASSWORD,
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
        --messages-per-second)  MESSAGES_PER_SECOND="$2"; shift 2;;
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
            PRODUCER_TOOL="kcat"
        elif command -v kafkacat >/dev/null 2>&1; then
            PRODUCER_TOOL="kafkacat"
        else
            echo "ERREUR: kcat/kafkacat non trouve"
            exit 1
        fi
    elif [ "$USE_KCAT" = "auto" ]; then
        if command -v kcat >/dev/null 2>&1; then
            PRODUCER_TOOL="kcat"
        elif command -v kafkacat >/dev/null 2>&1; then
            PRODUCER_TOOL="kafkacat"
        elif [ -n "$KAFKA_HOME" ] && [ -x "$KAFKA_HOME/bin/kafka-console-producer.sh" ]; then
            PRODUCER_TOOL="kafka-cli"
        elif command -v kafka-console-producer.sh >/dev/null 2>&1; then
            PRODUCER_TOOL="kafka-cli"
            KAFKA_HOME=""
        else
            echo "ERREUR: Aucun outil Kafka trouve (kcat, kafkacat ou kafka-console-producer.sh)"
            echo "Installez kcat: brew install kcat / apt install kafkacat"
            echo "Ou definissez KAFKA_HOME vers votre installation Kafka"
            exit 1
        fi
    else
        if [ -n "$KAFKA_HOME" ] && [ -x "$KAFKA_HOME/bin/kafka-console-producer.sh" ]; then
            PRODUCER_TOOL="kafka-cli"
        elif command -v kafka-console-producer.sh >/dev/null 2>&1; then
            PRODUCER_TOOL="kafka-cli"
            KAFKA_HOME=""
        else
            echo "ERREUR: kafka-console-producer.sh non trouve"
            exit 1
        fi
    fi
    echo "[INFO] Outil utilise: $PRODUCER_TOOL"
}

# ── Generer le fichier de proprietes (pour kafka-console-producer) ───────────
generate_properties() {
    cat > "$PROPS_FILE" <<EOF
bootstrap.servers=${BOOTSTRAP_SERVERS}
security.protocol=${SECURITY_PROTOCOL}
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
            # Pour les endpoints sans verification (test)
            if [ -z "$SSL_TRUSTSTORE" ] && [ -z "$SSL_CAFILE" ]; then
                echo "ssl.endpoint.identification.algorithm=" >> "$PROPS_FILE"
            fi
            ;;
    esac

    # Optimisations producer
    cat >> "$PROPS_FILE" <<EOF
acks=all
retries=3
compression.type=gzip
batch.size=16384
linger.ms=10
buffer.memory=33554432
EOF

    [ "$VERBOSE" = "true" ] && echo "[DEBUG] Fichier properties:" && cat "$PROPS_FILE"
}

# ── Generateurs de donnees aleatoires ────────────────────────────────────────
rand_int() {
    # $1=min $2=max
    awk -v min="$1" -v max="$2" 'BEGIN{srand(); print int(min+rand()*(max-min+1))}'
}

rand_choice() {
    # Choisit un element aleatoire parmi les arguments
    n=$#
    idx=$(rand_int 1 "$n")
    shift $((idx - 1))
    echo "$1"
}

rand_ip() {
    echo "$(rand_int 1 255).$(rand_int 1 255).$(rand_int 1 255).$(rand_int 1 255)"
}

rand_float() {
    awk -v min="$1" -v max="$2" 'BEGIN{srand(); printf "%.2f", min+rand()*(max-min)}'
}

rand_coord_lat() {
    awk 'BEGIN{srand(); printf "%.6f", -90+rand()*180}'
}

rand_coord_lon() {
    awk 'BEGIN{srand(); printf "%.6f", -180+rand()*360}'
}

# ── Generateur de messages JSON ──────────────────────────────────────────────
generate_user_activity() {
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    uid=$(rand_int 1 100000)
    action=$(rand_choice login logout view click purchase search navigate)
    sid=$(rand_int 100000 999999)
    ip=$(rand_ip)
    page="/page_$(rand_int 1 100)"
    duration=$(rand_int 1 3600)
    device=$(rand_choice desktop mobile tablet)
    mid=$(rand_int 1000000 9999999)

    cat <<EOF
{"type":"user_activity","user_id":"user_${uid}","action":"${action}","timestamp":"${ts}","session_id":"session_${sid}","ip_address":"${ip}","metadata":{"page":"${page}","duration":${duration},"device_type":"${device}"},"_metadata":{"generated_at":"${ts}","message_id":"msg_${mid}","version":"1.0","source":"kafka_producer_bomber_sh"}}
EOF
}

generate_system_metrics() {
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    srv=$(rand_int 1 100)
    metric=$(rand_choice cpu_usage memory_usage disk_usage network_io response_time)
    value=$(rand_float 0 100)
    env=$(rand_choice production staging development)
    region=$(rand_choice us-east-1 us-west-2 eu-west-1 ap-southeast-1)
    svc=$(rand_choice api web database cache queue)
    mid=$(rand_int 1000000 9999999)

    cat <<EOF
{"type":"system_metrics","server_id":"server_${srv}","metric_name":"${metric}","value":${value},"timestamp":"${ts}","tags":{"environment":"${env}","region":"${region}","service":"${svc}"},"_metadata":{"generated_at":"${ts}","message_id":"msg_${mid}","version":"1.0","source":"kafka_producer_bomber_sh"}}
EOF
}

generate_transaction() {
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    txn=$(rand_int 1000000 9999999)
    amount=$(rand_float 1 10000)
    currency=$(rand_choice USD EUR GBP JPY)
    uid=$(rand_int 1 100000)
    merchant="merchant_$(rand_int 1 1000)"
    status=$(rand_choice success pending failed cancelled)
    method=$(rand_choice credit_card debit_card paypal bank_transfer)
    mid=$(rand_int 1000000 9999999)

    cat <<EOF
{"type":"transaction","transaction_id":"txn_${txn}","amount":${amount},"currency":"${currency}","timestamp":"${ts}","user_id":"user_${uid}","merchant":"${merchant}","status":"${status}","payment_method":"${method}","_metadata":{"generated_at":"${ts}","message_id":"msg_${mid}","version":"1.0","source":"kafka_producer_bomber_sh"}}
EOF
}

generate_log_event() {
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    level=$(rand_choice DEBUG INFO WARN ERROR FATAL)
    msg=$(rand_choice "User authentication successful" "Database connection established" "Cache miss occurred" "API request processed" "Background job completed")
    svc=$(rand_choice api web database cache queue)
    trace="trace_$(rand_int 100000 999999)"
    span="span_$(rand_int 10000 99999)"
    file="app_$(rand_int 1 10).py"
    line=$(rand_int 1 1000)
    func=$(rand_choice process_request validate_input save_data send_notification)
    mid=$(rand_int 1000000 9999999)

    cat <<EOF
{"type":"log_event","level":"${level}","message":"${msg}","timestamp":"${ts}","service":"${svc}","trace_id":"${trace}","span_id":"${span}","metadata":{"file":"${file}","line":${line},"function":"${func}"},"_metadata":{"generated_at":"${ts}","message_id":"msg_${mid}","version":"1.0","source":"kafka_producer_bomber_sh"}}
EOF
}

generate_sensor_data() {
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    sid=$(rand_int 1 1000)
    stype=$(rand_choice temperature humidity pressure motion light)
    value=$(rand_float 0 100)
    unit=$(rand_choice celsius fahrenheit percent pascal lux)
    lat=$(rand_coord_lat)
    lon=$(rand_coord_lon)
    alt=$(rand_float 0 5000)
    quality=$(rand_choice excellent good fair poor)
    mid=$(rand_int 1000000 9999999)

    cat <<EOF
{"type":"sensor_data","sensor_id":"sensor_${sid}","sensor_type":"${stype}","value":${value},"unit":"${unit}","timestamp":"${ts}","location":{"latitude":${lat},"longitude":${lon},"altitude":${alt}},"quality":"${quality}","_metadata":{"generated_at":"${ts}","message_id":"msg_${mid}","version":"1.0","source":"kafka_producer_bomber_sh"}}
EOF
}

generate_random_message() {
    msg_type=$(rand_int 1 5)
    case "$msg_type" in
        1) generate_user_activity;;
        2) generate_system_metrics;;
        3) generate_transaction;;
        4) generate_log_event;;
        5) generate_sensor_data;;
    esac
}

# ── Choisir un topic aleatoire ───────────────────────────────────────────────
random_topic() {
    num=$(rand_int 1 "$NUM_TOPICS")
    printf "%s.generated-data-%02d.json" "$TOPIC_PREFIX" "$num"
}

# ── Envoyer un message ──────────────────────────────────────────────────────
send_message_kcat() {
    topic="$1"
    message="$2"
    key="key_$(rand_int 1 1000)"

    kcat_args="-P -b $BOOTSTRAP_SERVERS -t $topic -K : -X security.protocol=$SECURITY_PROTOCOL"

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

    echo "${key}:${message}" | $PRODUCER_TOOL $kcat_args 2>/dev/null
    return $?
}

send_message_cli() {
    topic="$1"
    message="$2"

    if [ -n "$KAFKA_HOME" ]; then
        producer_cmd="$KAFKA_HOME/bin/kafka-console-producer.sh"
    else
        producer_cmd="kafka-console-producer.sh"
    fi

    echo "$message" | $producer_cmd \
        --bootstrap-server "$BOOTSTRAP_SERVERS" \
        --topic "$topic" \
        --producer.config "$PROPS_FILE" \
        2>/dev/null
    return $?
}

send_message() {
    topic="$1"
    message="$2"

    case "$PRODUCER_TOOL" in
        kcat|kafkacat) send_message_kcat "$topic" "$message";;
        kafka-cli)     send_message_cli "$topic" "$message";;
    esac
}

# ── Reporter les stats ──────────────────────────────────────────────────────
report_stats() {
    now=$(date +%s)
    elapsed=$((now - START_TIME))
    [ "$elapsed" -le 0 ] && elapsed=1
    rate=$((MESSAGES_SENT / elapsed))
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') - Messages: ${MESSAGES_SENT} (+${MESSAGES_FAILED} failed), Rate: ${rate} msg/s, Duree: ${elapsed}s"
}

# ── Boucle principale ────────────────────────────────────────────────────────
main() {
    echo "=== Kafka Producer Bomber (Shell) ==="
    echo "Bootstrap:  $BOOTSTRAP_SERVERS"
    echo "Protocol:   $SECURITY_PROTOCOL"
    echo "SASL:       $SASL_MECHANISM"
    echo "Topics:     $NUM_TOPICS (prefix: $TOPIC_PREFIX)"
    echo "Rate:       $MESSAGES_PER_SECOND msg/s"
    echo "Duree:      $DURATION_MINUTES min"
    echo ""

    detect_tool

    if [ "$PRODUCER_TOOL" = "kafka-cli" ]; then
        generate_properties
    fi

    START_TIME=$(date +%s)
    END_TIME=$((START_TIME + DURATION_MINUTES * 60))

    # Calcul du delai entre messages (en secondes)
    if [ "$MESSAGES_PER_SECOND" -gt 0 ]; then
        # Utilise awk pour le calcul flottant
        SLEEP_INTERVAL=$(awk -v mps="$MESSAGES_PER_SECOND" 'BEGIN{printf "%.4f", 1/mps}')
    else
        SLEEP_INTERVAL=1
    fi

    echo "[INFO] Demarrage du bombardement... (sleep interval: ${SLEEP_INTERVAL}s)"
    echo ""

    last_report=$START_TIME

    while [ "$(date +%s)" -lt "$END_TIME" ] && [ "$RUNNING" -eq 1 ]; do
        topic=$(random_topic)
        message=$(generate_random_message)

        if send_message "$topic" "$message"; then
            MESSAGES_SENT=$((MESSAGES_SENT + 1))
            [ "$VERBOSE" = "true" ] && echo "[SENT] $topic -> $(echo "$message" | cut -c1-80)..."
        else
            MESSAGES_FAILED=$((MESSAGES_FAILED + 1))
            [ "$VERBOSE" = "true" ] && echo "[FAIL] $topic"
        fi

        # Reporter les stats toutes les 10 secondes
        now=$(date +%s)
        if [ $((now - last_report)) -ge 10 ]; then
            report_stats
            last_report=$now
        fi

        # Throttle
        if command -v perl >/dev/null 2>&1; then
            perl -e "select(undef,undef,undef,$SLEEP_INTERVAL)" 2>/dev/null
        elif command -v python3 >/dev/null 2>&1; then
            python3 -c "import time; time.sleep($SLEEP_INTERVAL)" 2>/dev/null
        else
            # Fallback: sleep 0 (le plus rapide possible) si < 1s
            sleep_secs=$(echo "$SLEEP_INTERVAL" | cut -d. -f1)
            [ -z "$sleep_secs" ] || [ "$sleep_secs" -eq 0 ] && sleep_secs=0
            [ "$sleep_secs" -gt 0 ] && sleep "$sleep_secs"
        fi
    done

    cleanup
}

main
