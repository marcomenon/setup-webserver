#!/bin/bash

# ========================
# 📌 INPUT VARIABILI CONFIGURABILI
# ========================
read -p "Inserisci il nome del progetto: " PROJ_NAME
read -p "Inserisci il dominio del progetto: " PROJ_DOMAIN
read -p "Inserisci il nome utente amministrativo: " ADMIN_USER
read -s -p "Inserisci la password amministrativa: " ADMIN_PASS

echo -e "\nConfigurazione in corso per il progetto: $PROJ_NAME ($PROJ_DOMAIN) con utente $ADMIN_USER"

GIT_REPO="https://github.com/marcomenon/djangoproject.git"
PROJ_HOME="/home/$ADMIN_USER/$PROJ_NAME"
DB_NAME="postgres_$PROJ_NAME"
DB_USER="user_$PROJ_NAME"
DB_PASS="password_$PROJ_NAME"
DB_HOST="postgres"
DB_PORT="5432"
REDIS_HOST="redis"
REDIS_PORT="6379"
NGINX_CONF="./nginx/nginx.conf"
NGINX_PORT="80"
STATIC_ROOT="$PROJ_HOME/static"
MEDIA_ROOT="$PROJ_HOME/media"
UFW_PORTS=($NGINX_CONF)

# Stampa delle informazioni
echo "==============================="
echo "⚙️ Configurazione per: $PROJ_NAME"
echo "👤 Utente: $ADMIN_USER"
echo "📂 Home directory: $PROJ_HOME"
echo "📥 Repository Git: $GIT_REPO"
echo "🛢️ Database: $DB_NAME (utente: $DB_USER)"
echo "📦 Redis in ascolto su: $REDIS_PORT"
echo "🌐 Nginx configurato per servire $PROJ_NAME"
echo "🌍 Dominio configurato: $ALLOWED_HOSTS_DOMAIN"
echo "==============================="

# ========================
# 📌 INSTALLAZIONE PACCHETTI NECESSARI
# ========================
echo "🔹 Installazione pacchetti richiesti..."
apt update && apt install -y docker.io docker-compose nginx python3-pip python3-venv git libpq-dev python3-dev gcc

# ========================
# 📌 CREAZIONE UTENTE E PERMESSI
# ========================
echo "🔹 Creazione dell'utente amministrativo..."
if id "$ADMIN_USER" &>/dev/null; then
    echo "⚠️ L'utente $ADMIN_USER esiste già."
else
    useradd -m -s /bin/bash -G sudo,www-data "$ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
    echo "✅ Utente creato: $ADMIN_USER"
fi

# ========================
# 📌 CLONAZIONE DELLA REPOSITORY
# ========================
echo "🔹 Clonazione della repository Django..."
sudo -u "$ADMIN_USER" git clone "$GIT_REPO" "$PROJ_HOME" || echo "⚠️ Il repository esiste già!"

# ========================
# 📌 CONFIGURAZIONE PYPROJECT.TOML
# ========================
echo "🔹 Aggiornamento del nome del progetto in pyproject.toml..."
sed -i -E 's/^name\s*=\s*".*"/name = "'"$PROJ_NAME"'"/' "$PROJ_HOME/pyproject.toml"
chown -R "$ADMIN_USER:www-data" "$PROJ_HOME"

# ========================
# 📌 Creazione del Virtual Environment e Installazione Gunicorn + uv
# ========================
echo "🔹 Creazione del virtual environment e installazione Gunicorn + uv..."
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && python3 -m venv .venv"
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && source $PROJ_HOME/.venv/bin/activate && pip install --upgrade pip uv"
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && $PROJ_HOME/.venv/bin/uv sync"

# ========================
# 📌 CONFIGURAZIONE .ENV
# ========================
echo "🔹 Creazione del file .env..."
cat > "$PROJ_HOME/.env" <<EOF
# Configurazione ambiente per $PROJ_NAME
DJANGO_SECRET_KEY="$(openssl rand -hex 32)"
DEBUG="True"
MAINTENANCE_MODE="True"
ALLOWED_MAINTENANCE_HOSTS="localhost"
ALLOWED_MAINTENANCE_IPS="$(hostname -I | awk '{print $1}')"
ALLOWED_HOSTS_DOMAIN="*.$PROJ_NAME.$PROJ_DOMAIN"
ALLOWED_HOSTS_IP="127.0.0.1"

# Email
EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST="smtp.gmail.com"
EMAIL_PORT="587"
EMAIL_HOST_USER="your_email@gmail.com"
EMAIL_HOST_PASSWORD="your_email_password"
EMAIL_USE_TLS="true"
EMAIL_TIMEOUT="10"
DEFAULT_FROM_EMAIL="your_email@gmail.com"

# Database
DB_ENGINE=django.db.backends.postgresql
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT

# Redis
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT

# Internazionalizzazione
LANGUAGE_CODE="it-IT"
TIME_ZONE="Europe/Rome"

# Static e Media
STATIC_ROOT=$STATIC_ROOT
MEDIA_ROOT=$MEDIA_ROOT

# Allauth
ACCOUNT_EMAIL_VERIFICATION="none"
ACCOUNT_LOGIN_METHODS="username"
ACCOUNT_EMAIL_REQUIRED="false"
ACCOUNT_USERNAME_REQUIRED="true"
EOF

chown "$ADMIN_USER:$ADMIN_USER" "$PROJ_HOME/.env"
chmod 600 "$PROJ_HOME/.env"

# ========================
# 📌 CREAZIONE DOCKER COMPOSE
# ========================
echo "🔹 Creazione di Docker Compose..."
cd "$PROJ_HOME"

# Creiamo il file docker-compose.yml
cat > "$PROJ_HOME/docker-compose.yml" <<EOF
version: '3.9'

services:
  django:
    build: .
    container_name: ${PROJ_NAME}_django
    restart: always
    env_file: .env
    depends_on:
      - postgres
      - redis
    networks:
      - backend

  postgres:
    image: postgres:16
    container_name: ${PROJ_NAME}_postgres
    restart: always
    environment:
      POSTGRES_DB: $DB_NAME
      POSTGRES_USER: $DB_USER
      POSTGRES_PASSWORD: $DB_PASS
    volumes:
      - postgres_data:/var/lib/postgresql/data
    networks:
      - backend

  redis:
    image: redis:7
    container_name: ${PROJ_NAME}_redis
    restart: always
    networks:
      - backend

  nginx:
    image: nginx:latest
    container_name: ${PROJ_NAME}_nginx
    restart: always
    depends_on:
      - django
    ports:
      - "$NGINX_CONF:80"
    volumes:
      - $NGINX_CONF:/etc/nginx/nginx.conf:ro
      - $STATIC_ROOT:/app/static
      - $MEDIA_ROOT:/app/media
    networks:
      - backend

networks:
  backend:
    driver: bridge

volumes:
  postgres_data:

EOF

# ========================
# 📌 AVVIO CONTAINER DOCKER
# ========================
echo "🔹 Avvio di Docker Compose..."
cd "$PROJ_HOME"
docker-compose up -d --build

# ========================
# 📌 CONFIGURAZIONE UFW (Firewall)
# ========================
echo "🔹 Configurazione di UFW..."
ufw allow OpenSSH
for port in "${UFW_PORTS[@]}"; do
    ufw allow "$port"
done
ufw --force enable

# ========================
# ✅ Configurazione completata
# ========================
echo "✅ Configurazione completata con successo!"
echo "📌 Repository clonata in: $PROJ_HOME"
echo "📂 Il file .env è stato creato in: $PROJ_HOME/.env"
echo "📦 Virtual environment: $PROJ_HOME/.venv"
echo "🐍 Gunicorn e uv installati in: $PROJ_HOME/.venv"
echo "🌐 Puoi accedere all'indirizzo: $(hostname -I | awk '{print $1}')"