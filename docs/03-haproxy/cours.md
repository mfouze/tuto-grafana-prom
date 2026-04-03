# HAProxy — Cours Complet pour Débutants

## 1. C'est quoi HAProxy ?

**HAProxy** (High Availability Proxy) est un **load balancer** et **proxy TCP/HTTP**. Dans notre architecture, il est le **point d'entrée** pour toutes les connexions vers PostgreSQL.

### Analogie
Imagine un réceptionniste dans un hôtel avec 3 réceptionnistes derrière lui. Quand un client arrive, le réceptionniste principal (HAProxy) le dirige vers le bon réceptionniste disponible. Si un réceptionniste fait une pause, le principal envoie les clients vers les autres.

### Rôle dans notre architecture

```
Application → HAProxy → PgBouncer → PostgreSQL
                │
                ├── Port 5000 → Leader (lecture/écriture)
                └── Port 5001 → Replicas (lecture seule)
```

HAProxy fait deux choses essentielles :
1. **Routage** : envoyer les écritures vers le leader et les lectures vers les replicas
2. **Détection de panne** : détecter quand un nœud tombe et arrêter de lui envoyer du trafic

## 2. Concepts clés

### Frontend & Backend

```
                  HAProxy
┌─────────────────────────────────────┐
│                                     │
│  Frontend (écoute)                  │
│  ├── pg-write :5000  ──────────────►│── Backend pg-write
│  │                                  │   ├── patroni-1:5432 (leader)
│  │                                  │   ├── patroni-2:5432
│  │                                  │   └── patroni-3:5432
│  │                                  │
│  └── pg-read :5001   ──────────────►│── Backend pg-read
│                                     │   ├── patroni-1:5432
│                                     │   ├── patroni-2:5432 (replica)
│                                     │   └── patroni-3:5432 (replica)
└─────────────────────────────────────┘
```

- **Frontend** : là où HAProxy écoute les connexions entrantes
- **Backend** : le groupe de serveurs vers lesquels HAProxy redirige le trafic

### Health Checks

HAProxy vérifie régulièrement si chaque backend est vivant. Pour PostgreSQL/Patroni, on utilise l'**API REST Patroni** :

```
HAProxy vérifie : http://patroni-1:8008/primary → 200 = ce nœud est le leader
HAProxy vérifie : http://patroni-1:8008/replica → 200 = ce nœud est un replica
```

Si un nœud ne répond pas ou renvoie une erreur → HAProxy le marque **DOWN** et ne lui envoie plus de trafic.

### États des backends

| État | Couleur (stats) | Signification |
|------|-----------------|---------------|
| UP | Vert | Le serveur répond aux health checks |
| DOWN | Rouge | Le serveur ne répond pas |
| MAINT | Bleu | Le serveur est en maintenance (désactivé manuellement) |
| DRAIN | Gris | Le serveur n'accepte plus de nouvelles connexions |
| NOLB | Jaune | Le serveur est exclu du load balancing |

## 3. Configuration HAProxy pour PostgreSQL/Patroni

```cfg
# /etc/haproxy/haproxy.cfg

global
    log stdout format raw local0
    maxconn 1000
    stats socket /var/run/haproxy.sock mode 660 level admin
    stats timeout 30s

defaults
    log     global
    mode    tcp
    retries 3
    timeout connect 5s
    timeout client  30m
    timeout server  30m
    timeout check   5s

# ===== PAGE DE STATISTIQUES =====
listen stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
    stats show-legends
    stats show-node

# ===== ÉCRITURE → LEADER UNIQUEMENT =====
listen pg-write
    bind *:5000
    mode tcp
    option httpchk GET /primary
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions

    server patroni-1 patroni-1:5432 check port 8008
    server patroni-2 patroni-2:5432 check port 8008
    server patroni-3 patroni-3:5432 check port 8008

# ===== LECTURE → REPLICAS =====
listen pg-read
    bind *:5001
    mode tcp
    balance roundrobin
    option httpchk GET /replica
    http-check expect status 200
    default-server inter 3s fall 3 rise 2 on-marked-down shutdown-sessions

    server patroni-1 patroni-1:5432 check port 8008
    server patroni-2 patroni-2:5432 check port 8008
    server patroni-3 patroni-3:5432 check port 8008
```

### Explication des paramètres importants

| Paramètre | Valeur | Signification |
|-----------|--------|---------------|
| `mode tcp` | - | Mode TCP (pas HTTP) car PostgreSQL parle en TCP |
| `option httpchk` | `GET /primary` | Utilise l'API REST Patroni pour vérifier |
| `check port 8008` | - | Le health check se fait sur le port 8008 (API Patroni) |
| `inter 3s` | 3 secondes | Intervalle entre les health checks |
| `fall 3` | 3 échecs | Nombre d'échecs avant de marquer DOWN |
| `rise 2` | 2 succès | Nombre de succès pour revenir UP |
| `on-marked-down shutdown-sessions` | - | Ferme les connexions existantes quand le backend passe DOWN |
| `balance roundrobin` | - | Distribue les connexions en rotation |
| `maxconn` | 1000 | Nombre max de connexions simultanées |

## 4. Page de statistiques HAProxy

Accessible sur `http://haproxy-host:8404/stats`

C'est une page web qui montre en temps réel :
- L'état de chaque frontend et backend
- Le nombre de connexions actives
- Les taux de requêtes
- Les temps de réponse
- Les erreurs

### Lire les statistiques

Les colonnes importantes :
| Colonne | Signification |
|---------|---------------|
| Status | UP/DOWN/MAINT |
| Cur | Connexions courantes |
| Max | Connexions max atteintes |
| Limit | Limite de connexions |
| Total | Total de connexions depuis le démarrage |
| Bytes In/Out | Volume de données |
| Denied | Connexions refusées |
| Errors | Erreurs de connexion |
| Warnings | Avertissements |
| Server | Nombre de serveurs UP/total |

## 5. Métriques HAProxy pour Prometheus

HAProxy peut exposer ses métriques nativement au format Prometheus (depuis HAProxy 2.0+).

### Activer l'export Prometheus

Ajouter dans la config :
```cfg
frontend prometheus
    bind *:8405
    mode http
    http-request use-service prometheus-exporter if { path /metrics }
    no log
```

### Métriques clés

```promql
# HAProxy est-il vivant ?
haproxy_process_start_time_seconds  # Si absent → HAProxy est down

# État des backends (1=UP, 0=DOWN)
haproxy_server_status{backend="pg-write"}

# Connexions actives par backend
haproxy_server_current_sessions{backend="pg-write"}

# Nombre de serveurs actifs dans un backend
haproxy_backend_active_servers{backend="pg-write"}

# Connexions totales
haproxy_frontend_connections_total{frontend="pg-write"}

# Erreurs de connexion
haproxy_backend_connection_errors_total{backend="pg-write"}

# Temps de réponse (en ms)
haproxy_backend_response_time_average_seconds{backend="pg-write"}

# Sessions max atteintes
haproxy_frontend_current_sessions / haproxy_frontend_limit_sessions
# Si > 0.8 → WARNING (approche de la limite)

# Requêtes refusées
haproxy_frontend_denied_connections_total
```

## 6. Failover des backends

### Scénario : le leader PostgreSQL tombe

```
1. patroni-1 (Leader) tombe
2. HAProxy fait un health check : GET http://patroni-1:8008/primary → timeout
3. Après 3 échecs (fall 3 × inter 3s = ~9 secondes) → patroni-1 marqué DOWN
4. Pendant ce temps, Patroni promeut patroni-2 en Leader
5. HAProxy health check : GET http://patroni-2:8008/primary → 200 OK
6. Après 2 succès (rise 2 × inter 3s = ~6 secondes) → patroni-2 marqué UP pour pg-write
7. Le trafic est redirigé vers patroni-2
```

**Temps total d'indisponibilité** : ~30-60 secondes (Patroni failover) + ~15 secondes (HAProxy détection)

### Scénario : HAProxy lui-même tombe

Si HAProxy tombe → **plus aucune connexion possible** → CRITIQUE

Solutions de haute disponibilité HAProxy :
1. **Keepalived** : VIP (Virtual IP) qui bascule entre 2 HAProxy
2. **Double HAProxy** en actif/passif avec health checks
3. **DNS round-robin** entre plusieurs HAProxy

## 7. Commandes d'administration HAProxy

### Via le socket Unix
```bash
# Se connecter au socket HAProxy
echo "show stat" | socat stdio /var/run/haproxy.sock

# Voir les informations globales
echo "show info" | socat stdio /var/run/haproxy.sock

# Mettre un backend en maintenance
echo "set server pg-write/patroni-1 state maint" | socat stdio /var/run/haproxy.sock

# Remettre un backend en service
echo "set server pg-write/patroni-1 state ready" | socat stdio /var/run/haproxy.sock

# Voir l'état des backends
echo "show servers state" | socat stdio /var/run/haproxy.sock
```

### Via la ligne de commande
```bash
# Vérifier la syntaxe de la configuration
haproxy -c -f /etc/haproxy/haproxy.cfg

# Recharger la configuration sans coupure
systemctl reload haproxy

# Voir les logs
journalctl -u haproxy -f
```

## 8. Problèmes courants

### HAProxy ne démarre pas
```bash
# Vérifier la syntaxe
haproxy -c -f /etc/haproxy/haproxy.cfg
# → Erreur de syntaxe ? Corriger le fichier de config

# Port déjà utilisé ?
ss -tlnp | grep 5000
```

### Tous les backends sont DOWN
```bash
# Vérifier que les health checks fonctionnent
curl -v http://patroni-1:8008/primary
# → 200 ? Le nœud est leader
# → 503 ? Le nœud est un replica
# → Connection refused ? Patroni ne tourne pas

# Vérifier les logs HAProxy
docker logs haproxy 2>&1 | grep -i "down\|error\|fail"
```

### Connexions refusées
```bash
# Vérifier maxconn
echo "show info" | socat stdio /var/run/haproxy.sock | grep -i conn
# CurrConns proche de MaxConn ? → Augmenter maxconn
```
