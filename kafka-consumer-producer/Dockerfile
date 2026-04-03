# Dockerfile pour Kafka Performance Tests et Scripts Bomber
FROM openjdk:11-jdk-slim

# Installer Python 3 et dépendances système
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-venv \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# Installer les outils Kafka (version Apache Kafka)
ARG KAFKA_VERSION=3.6.1
ARG SCALA_VERSION=2.13
ENV KAFKA_HOME=/opt/kafka
ENV PATH="${KAFKA_HOME}/bin:${PATH}"

RUN mkdir -p ${KAFKA_HOME} && \
    cd /tmp && \
    wget -q "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" && \
    tar -xzf "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" -C ${KAFKA_HOME} --strip-components=1 && \
    rm -f "kafka_${SCALA_VERSION}-${KAFKA_VERSION}.tgz" && \
    chmod +x ${KAFKA_HOME}/bin/*.sh

# Créer le répertoire de travail
WORKDIR /app

# Copier les fichiers requirements et installer les dépendances Python
COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

# Copier les scripts Python
COPY kafka_producer_bomber.py .
COPY kafka_consumer_bomber.py .

# Créer un script d'entrée pour faciliter l'utilisation
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Créer un répertoire pour les fichiers de configuration
RUN mkdir -p /app/config

# Variables d'environnement par défaut
ENV KAFKA_BOOTSTRAP_SERVERS=""
ENV KAFKA_USERNAME=""
ENV KAFKA_PASSWORD=""
ENV KAFKA_SECURITY_PROTOCOL="SASL_SSL"
ENV KAFKA_SASL_MECHANISM="PLAIN"

# Point d'entrée (peut être surchargé)
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD []
