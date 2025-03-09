#!/bin/bash

# ========================
# 📌 INPUT VARIABILI CONFIGURABILI
# ========================
read -p "Inserisci il nome del progetto: " PROJ_NAME
read -p "Inserisci il dominio del progetto: " PROJ_DOMAIN
read -p "Inserisci il nome utente amministrativo: " ADMIN_USER
read -s -p "Inserisci la password amministrativa: " ADMIN_PASS

echo -e "\nConfigurazione in corso per il progetto: $PROJ_NAME ($PROJ_DOMAIN) con utente $ADMIN_USER"

# ==============================
# 📌 CONFIGURAZIONE VARIABILI
# ==============================

GIT_REPO="https://github.com/marcomenon/djangoproject.git"
PROJ_HOME="/home/$ADMIN_USER/$PROJ_NAME"
WWW_DIR="/var/www/$PROJ_NAME"

DB_NAME="postgres_$PROJ_NAME"
DB_USER="user_$PROJ_NAME"
DB_PASS="password_$PROJ_NAME"
DB_HOST="localhost"
DB_PORT="5432"

REDIS_HOST="localhost"
REDIS_PORT="6379"

PG_VERSION="17"
PG_HBA_CONF="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
NGINX_CONF="/etc/nginx/conf.d/$PROJ_NAME.conf"
UFW_PORTS=(80 5432 6379)

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

# ==============================
# 📌 INSTALLAZIONE PACCHETTI
# ==============================
echo "🔹 Installazione pacchetti base..."
apt update && apt install -y lsb-release curl gpg gnupg2 ca-certificates ubuntu-keyring git \
    python3-pip python3-venv python3-dev libpq-dev gcc gettext
echo "🔹 Installazione Nginx, Redis e Postgresql "
curl https://nginx.org/keys/nginx_signing.key | gpg --dearmor \
| tee /usr/share/keyrings/nginx-archive-keyring.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] \
http://nginx.org/packages/ubuntu `lsb_release -cs` nginx" \
    | tee /etc/apt/sources.list.d/nginx.list
echo -e "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    | tee /etc/apt/preferences.d/99nginx
curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
chmod 644 /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/redis.list
install -d /usr/share/postgresql-common/pgdg
curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
apt update && apt install -y nginx redis postgresql

# ==============================
# 📌 CONFIGURAZIONE UTENTE
# ==============================
echo "🔹 Creazione utente Django..."
if ! id "$ADMIN_USER" &>/dev/null; then
    useradd -m -s /bin/bash -G sudo,www-data "$ADMIN_USER"
    echo "$ADMIN_USER:$ADMIN_PASS" | chpasswd
    echo "✅ Utente creato: $ADMIN_USER"
fi

echo "🔹 Creazione cartelle di progetto..."
mkdir -p "$WWW_DIR/static" "$WWW_DIR/media"
chown -R www-data:www-data "$WWW_DIR"
chmod -R g+rw "$WWW_DIR"
find "$WWW_DIR" -type d -exec chmod g+s {} \;

# ==============================
# 📌 CONFIGURAZIONE POSTGRESQL
# ==============================
echo "🔹 Modifica di $PG_HBA_CONF per consentire l'accesso..."
sed -i 's/local   all             postgres                            peer/local   all             postgres                            trust/' "$PG_HBA_CONF"
sed -i 's/local   all             all                                     peer/local   all             all                                     password/' "$PG_HBA_CONF"

echo "🔹 Riavvio di PostgreSQL..."
systemctl restart postgresql

echo "🔹 Configurazione PostgreSQL..."
sudo -u postgres psql <<EOF
CREATE DATABASE $DB_NAME;
CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';
ALTER ROLE $DB_USER SET client_encoding TO 'utf8';
ALTER ROLE $DB_USER SET default_transaction_isolation TO 'read committed';
ALTER ROLE $DB_USER SET timezone TO 'Europe/Rome';
GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;
ALTER DATABASE $DB_NAME OWNER TO $DB_USER;
GRANT USAGE, CREATE ON SCHEMA public TO $DB_USER;
GRANT ALL PRIVILEGES ON SCHEMA public TO $DB_USER;
EOF

# ==============================
# 📌 CONFIGURAZIONE REDIS
# ==============================
echo "🔹 Configurazione Redis..."
systemctl enable redis-server
systemctl start redis-server

# ==============================
# 📌 CONFIGURAZIONE DJANGO
# ==============================
echo "🔹 Clonazione repository Django..."
sudo -u "$ADMIN_USER" git clone "$GIT_REPO" "$PROJ_HOME" || echo "⚠️ Il repository esiste già!"

echo "🔹 Aggiornamento del nome del progetto in pyproject.toml..."
sed -i -E 's/^name\s*=\s*".*"/name = "'"$PROJ_NAME"'"/' "$PROJ_HOME/pyproject.toml"
chown -R "$ADMIN_USER:www-data" "$PROJ_HOME"

echo "🔹 Creazione ambiente virtuale..."
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && python3 -m venv .venv"
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && source $PROJ_HOME/.venv/bin/activate && pip install --upgrade pip uv"
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && $PROJ_HOME/.venv/bin/uv sync"

echo "🔹 Creazione file .env..."
cat > "$PROJ_HOME/.env" <<EOF
# ========================
# 🔹 Configurazione ambiente per $PROJ_NAME
# ========================
PROJECT_NAME=$PROJ_NAME
DJANGO_SECRET_KEY="$(openssl rand -hex 32)"
DEBUG=true
MAINTENANCE_MODE=true

# ========================
# 🔹 Configurazione degli Host
# ========================
ALLOWED_MAINTENANCE_HOSTS="localhost"
ALLOWED_MAINTENANCE_IPS="$(hostname -I | awk '{print $1}')"
ALLOWED_HOSTS_DOMAIN="$PROJ_NAME.$PROJ_DOMAIN"
ALLOWED_HOSTS_IP="127.0.0.1"

# ========================
# 🔹 Configurazione Email
# ========================
EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_HOST_USER=your_email@gmail.com
EMAIL_HOST_PASSWORD=your_email_password
EMAIL_USE_TLS=true
EMAIL_TIMEOUT=10
DEFAULT_FROM_EMAIL=your_email@gmail.com

# ========================
# 🔹 Configurazione Database PostgreSQL
# ========================
DB_ENGINE=django.db.backends.postgresql
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_HOST=$DB_HOST
DB_PORT=$DB_PORT

# ========================
# 🔹 Configurazione Redis
# ========================
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT

# ========================
# 🔹 Configurazione Internazionalizzazione
# ========================
LANGUAGE_CODE="it-IT"
TIME_ZONE="Europe/Rome"

# ========================
# 🔹 Configurazione File Statici & Media
# ========================
STATIC_ROOT=$WWW_DIR/static
MEDIA_ROOT=$WWW_DIR/media

# ========================
# 🔹 Configurazione Django Allauth
# ========================
ACCOUNT_EMAIL_VERIFICATION=none
ACCOUNT_LOGIN_METHODS=username
ACCOUNT_EMAIL_REQUIRED=false
ACCOUNT_USERNAME_REQUIRED=true
EOF

chown "$ADMIN_USER:$ADMIN_USER" "$PROJ_HOME/.env"
chmod 600 "$PROJ_HOME/.env"

# ==============================
# 📌 CONFIGURAZIONE GUNICORN
# ==============================
echo "🔹 Configurazione Gunicorn..."
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

# ==============================
# 📌 CONFIGURAZIONE NGINX
# ==============================
echo "🔹 Configurazione Nginx..."
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

rm -f /etc/nginx/conf.d/default.conf
nginx -t && systemctl restart nginx

# ==============================
# 📌 CONFIGURAZIONE FIREWALL (UFW)
# ==============================
echo "🔹 Configurazione di UFW..."
ufw allow OpenSSH
for port in "${UFW_PORTS[@]}"; do
    ufw allow "$port"
done
ufw --force enable

# ==============================
# ✅ FINE INSTALLAZIONE
# ==============================
echo "✅ Installazione completata con successo!"
echo "📌 Django disponibile su: http://$(hostname -I | awk '{print $1}')"
echo "📦 Gunicorn è attivo: systemctl status gunicorn_$PROJ_NAME"
echo "🌐 Nginx configurato: systemctl status nginx"
echo "🛢️ PostgreSQL e Redis sono attivi!"
