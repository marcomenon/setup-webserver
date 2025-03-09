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
WWW_DIR="/var/www/$PROJ_NAME"
NGINX_CONF="/etc/nginx/sites-available/$PROJ_NAME"
PROJ_HOME="/home/$PROJ_NAME"
DB_NAME="postgres_$PROJ_NAME"
DB_USER="user_$PROJ_NAME"
DB_PASS="password_$PROJ_NAME"
DB_APPR="approle_$PROJ_NAME"
REDIS_PORT="6379"
UFW_PORTS=(80 5432 6379)  # 5432 per PostgreSQL, 6379 per Redis, 80 per HTTP

# Ottiene l'indirizzo IP della macchina
MACHINE_IP=$(hostname -I | awk '{print $1}')

# Variabili per il file .env
DJANGO_SECRET_KEY=$(openssl rand -hex 32)
DEBUG="True"
MAINTENANCE_MODE="True"
ALLOWED_MAINTENANCE_HOSTS="localhost"
ALLOWED_MAINTENANCE_IPS="$MACHINE_IP"
ALLOWED_HOSTS_DOMAIN="*.$PROJ_NAME.$PROJ_DOMAIN"
ALLOWED_HOSTS_IP="127.0.0.1"
EMAIL_BACKEND="django.core.mail.backends.smtp.EmailBackend"
EMAIL_HOST="smtp.gmail.com"
EMAIL_PORT="587"
EMAIL_HOST_USER="your_email@gmail.com"
EMAIL_HOST_PASSWORD="your_email_password"
EMAIL_USE_TLS="true"
EMAIL_TIMEOUT="10"
DEFAULT_FROM_EMAIL="$EMAIL_HOST_USER"
LANGUAGE_CODE="it-IT"
TIME_ZONE="Europe/Rome"
STATIC_ROOT="$WWW_DIR/static"
MEDIA_ROOT="$WWW_DIR/media"
ACCOUNT_EMAIL_VERIFICATION="none"
ACCOUNT_LOGIN_METHODS="username"
ACCOUNT_EMAIL_REQUIRED="false"
ACCOUNT_USERNAME_REQUIRED="true"

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
# 🔹 Installazione di Pacchetti Necessari
# ========================
echo "🔹 Installazione di pacchetti..."
apt update && apt install -y build-essential pkg-config nginx postgresql postgresql-contrib redis python3-pip python3-venv python3-dev libpq-dev python3-dev gcc git

# ========================
# 🔹 Creazione Utente e Cartelle
# ========================
echo "🔹 Creazione dell'utente e impostazione della password..."
useradd -m -s /bin/bash -G sudo,www-data "$ADMIN_USER"
echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd

echo "🔹 Creazione delle cartelle di progetto..."
mkdir -p "$WWW_DIR/static" "$WWW_DIR/media"
chown -R www-data:www-data "$WWW_DIR"
chmod -R g+rw "$WWW_DIR"
find "$WWW_DIR" -type d -exec chmod g+s {} \;

# ========================
# 🔹 Configurazione Database PostgreSQL
# ========================
echo "🔹 Configurazione di PostgreSQL..."
set -e  # Se un comando fallisce, lo script si interrompe

# Creazione database e utente
sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;" || echo "⚠️ Il database $DB_NAME esiste già!"
sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';" || echo "⚠️ L'utente $DB_USER esiste già!"
sudo -u postgres psql -c "ALTER DATABASE $DB_NAME OWNER TO $DB_USER;"

# Configurazione del ruolo
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET client_encoding TO 'utf8';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';"
sudo -u postgres psql -c "ALTER ROLE $DB_USER SET timezone TO 'Europe/Rome';"

# Permessi database
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;"
sudo -u postgres psql -c "ALTER USER $DB_USER WITH CREATEDB;"

# Permessi sullo schema public
sudo -u postgres psql -c "GRANT USAGE, CREATE ON SCHEMA public TO $DB_USER;"
sudo -u postgres psql -c "GRANT ALL ON SCHEMA public TO $DB_USER;"
sudo -u postgres psql -c "ALTER SCHEMA public OWNER TO $DB_USER;"

# Permessi di default per il futuro (bisogna specificare il ruolo)
sudo -u postgres psql -c "ALTER DEFAULT PRIVILEGES FOR ROLE $DB_USER IN SCHEMA public GRANT ALL ON TABLES TO $DB_USER;"
sudo -u postgres psql -c "ALTER DEFAULT PRIVILEGES FOR ROLE $DB_USER IN SCHEMA public GRANT ALL ON SEQUENCES TO $DB_USER;"
sudo -u postgres psql -c "ALTER DEFAULT PRIVILEGES FOR ROLE $DB_USER IN SCHEMA public GRANT ALL ON FUNCTIONS TO $DB_USER;"

# Creazione di un ruolo applicativo (se necessario)
sudo -u postgres psql -c "CREATE ROLE $DB_APPR;" || echo "⚠️ Il ruolo $DB_APPR esiste già!"
sudo -u postgres psql -c "GRANT $DB_APPR TO $DB_USER;"

systemctl restart postgresql

# ========================
# 🔹 Configurazione Redis
# ========================
echo "🔹 Configurazione di Redis..."
sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
systemctl restart redis

# ========================
# 🔹 Clonazione della repository Django
# ========================
echo "🔹 Clonazione della repository..."
git clone $GIT_REPO $PROJ_HOME

if [ ! -d "$PROJ_HOME" ]; then
    echo "❌ Errore: La clonazione della repository non è riuscita!"
    exit 1
fi

# ========================
# 🔹 Modifica del file pyproject.toml
# ========================
echo "🔹 Aggiornamento del nome del progetto in pyproject.toml..."
sed -i -E 's/^name\s*=\s*".*"/name = "'"$PROJ_NAME"'"/' "$PROJ_HOME/pyproject.toml"
chown -R "$ADMIN_USER:www-data" "$PROJ_HOME"

# ========================
# 🔹 Creazione del Virtual Environment e Installazione Gunicorn + uv
# ========================
echo "🔹 Creazione del virtual environment e installazione Gunicorn + uv..."
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && python3 -m venv .venv"
sudo -u "$ADMIN_USER" bash -c "source $PROJ_HOME/.venv/bin/activate && pip install --upgrade pip uv"
sudo -u "$ADMIN_USER" "$PROJ_HOME/.venv/bin/uv" sync

# ========================
# 🔹 Creazione del file .env con variabili d'ambiente
# ========================
echo "🔹 Creazione del file .env..."
cat > "$PROJ_HOME/.env" <<EOF
# Configurazione ambiente per $PROJ_NAME
DJANGO_SECRET_KEY=$DJANGO_SECRET_KEY
DEBUG=$DEBUG
MAINTENANCE_MODE=$MAINTENANCE_MODE
ALLOWED_MAINTENANCE_HOSTS=$ALLOWED_MAINTENANCE_HOSTS
ALLOWED_MAINTENANCE_IPS=$ALLOWED_MAINTENANCE_IPS
ALLOWED_HOSTS_DOMAIN=$ALLOWED_HOSTS_DOMAIN
ALLOWED_HOSTS_IP=$ALLOWED_HOSTS_IP

# Email
EMAIL_BACKEND=$EMAIL_BACKEND
EMAIL_HOST=$EMAIL_HOST
EMAIL_PORT=$EMAIL_PORT
EMAIL_HOST_USER=$EMAIL_HOST_USER
EMAIL_HOST_PASSWORD=$EMAIL_HOST_PASSWORD
EMAIL_USE_TLS=$EMAIL_USE_TLS
EMAIL_TIMEOUT=$EMAIL_TIMEOUT
DEFAULT_FROM_EMAIL=$DEFAULT_FROM_EMAIL

# Database
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_APPR=$DB_APPR
DB_ENGINE=django.db.backends.postgresql
DB_HOST=localhost
DB_PORT=5432

# Redis
REDIS_HOST=localhost
REDIS_PORT=$REDIS_PORT

# Internazionalizzazione
LANGUAGE_CODE=$LANGUAGE_CODE
TIME_ZONE=$TIME_ZONE

# Static e Media
STATIC_ROOT=$STATIC_ROOT
MEDIA_ROOT=$MEDIA_ROOT

# Allauth
ACCOUNT_EMAIL_VERIFICATION=$ACCOUNT_EMAIL_VERIFICATION
ACCOUNT_LOGIN_METHODS=$ACCOUNT_LOGIN_METHODS
ACCOUNT_EMAIL_REQUIRED=$ACCOUNT_EMAIL_REQUIRED
ACCOUNT_USERNAME_REQUIRED=$ACCOUNT_USERNAME_REQUIRED
EOF

chown "$ADMIN_USER:$ADMIN_USER" "$PROJ_HOME/.env"
chmod 600 "$PROJ_HOME/.env"

# ========================
# 🔹 Creazione del Virtual Environment e Installazione Gunicorn + uv + dipendenze
# ========================
echo "🔹 Creazione del virtual environment e installazione Gunicorn + uv..."
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && python3 -m venv .venv"
sudo -u "$ADMIN_USER" bash -c "source $PROJ_HOME/.venv/bin/activate && pip install --upgrade pip uv gunicorn && uv sync && deactivate"

# ========================
# 🔹 Configurazione Nginx (senza env_file e rimozione default)
# ========================
echo "🔹 Creazione configurazione Nginx..."
cat > "$NGINX_CONF" <<EOF
server {
    listen 80;
    server_name _;

    location /static/ {
        alias $WWW_DIR/static/;
    }

    location /media/ {
        alias $WWW_DIR/media/;
    }

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

ln -s "$NGINX_CONF" /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default  
nginx -t && systemctl restart nginx

# ========================
# 🔹 Configurazione UFW (Firewall)
# ========================
echo "🔹 Configurazione di UFW..."
ufw allow OpenSSH
for port in "${UFW_PORTS[@]}"; do
    ufw allow "$port"
done
ufw --force enable

# ========================
# 🔹 Creazione del servizio systemd per Gunicorn
# ========================
echo "🔹 Creazione del servizio per Gunicorn..."
cat > "/etc/systemd/system/gunicorn_$PROJ_NAME.service" <<EOF
[Unit]
Description=Gunicorn instance per $PROJ_NAME
After=network.target

[Service]
User=$ADMIN_USER
Group=www-data
WorkingDirectory=$PROJ_HOME
EnvironmentFile=$PROJ_HOME/.env
ExecStart=$PROJ_HOME/.venv/bin/gunicorn --workers 3 --bind 127.0.0.1:8000 core.wsgi:application

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gunicorn_$PROJ_NAME
systemctl start gunicorn_$PROJ_NAME

# ========================
# ✅ Configurazione completata
# ========================
echo "✅ Configurazione completata con successo!"
echo "📌 Repository clonata in: $PROJ_HOME"
echo "📂 Il file .env è stato creato in: $PROJ_HOME/.env"
echo "📦 Virtual environment: $PROJ_HOME/.venv"
echo "🐍 Gunicorn e uv installati in: $PROJ_HOME/.venv"
echo "🌐 Puoi accedere ai file statici e media in: $WWW_DIR"