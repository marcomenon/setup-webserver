#!/bin/bash

# ========================
# 📌 VARIABILI CONFIGURABILI
# ========================
PROJ_NAME="mio_progetto"  # Nome del progetto
ADMIN_USER="admin_$PROJ_NAME"  # Nome utente amministrativo
DB_NAME="mariadb_$PROJ_NAME"
DB_USER="user_$PROJ_NAME"
DB_PASS="password_$PROJ_NAME"
REDIS_PORT="6379"
NGINX_CONF="/etc/nginx/sites-available/$PROJ_NAME"
UFW_PORTS=(80 3306 6379)  # 3306 per MariaDB, 6379 per Redis, 80 per HTTP
PROJ_HOME="/home/$PROJ_NAME"
WWW_DIR="/var/www/$PROJ_NAME"

echo "==============================="
echo "⚙️  Configurazione per: $PROJ_NAME"
echo "👤 Utente: $ADMIN_USER"
echo "📂 Home directory: $PROJ_HOME"
echo "🛢️  Database: $DB_NAME (utente: $DB_USER)"
echo "📦 Redis in ascolto su: $REDIS_PORT"
echo "🌐 Nginx configurato per servire $PROJ_NAME"
echo "==============================="

# ========================
# 🔹 1️⃣ Creazione Utente e Cartelle
# ========================
echo "🔹 Creazione dell'utente e impostazione della password..."
useradd -m -s /bin/bash -G sudo,www-data "$ADMIN_USER"
echo "$ADMIN_USER:$PROJ_NAME" | chpasswd

echo "🔹 Creazione delle cartelle di progetto..."
mkdir -p "$PROJ_HOME"
mkdir -p "$WWW_DIR/static" "$WWW_DIR/media"

chown -R "$ADMIN_USER:www-data" "$PROJ_HOME"
chown -R www-data:www-data "$WWW_DIR"

chmod -R g+rw "$WWW_DIR"

find "$WWW_DIR" -type d -exec chmod g+s {} \;

# ========================
# 🔹 2️⃣ Installazione di Pacchetti Necessari
# ========================
echo "🔹 Installazione di pacchetti..."
apt update && apt install -y build-essential  pkg-config nginx mariadb-server default-libmysqlclient-dev redis python3-pip python3-venv python3-dev

# ========================
# 🔹 3️⃣ Configurazione Database MariaDB
# ========================
echo "🔹 Configurazione di MariaDB..."
mysql -e "CREATE DATABASE $DB_NAME;"
mysql -e "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
mysql -e "GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$DB_USER'@'localhost';"
mysql -e "FLUSH PRIVILEGES;"

# ========================
# 🔹 4️⃣ Configurazione Redis
# ========================
echo "🔹 Configurazione di Redis..."
sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf
systemctl restart redis

# ========================
# 🔹 5️⃣ Creazione del Virtual Environment e Installazione Gunicorn + uv
# ========================
echo "🔹 Creazione del virtual environment e installazione Gunicorn + uv..."
sudo -u "$ADMIN_USER" bash -c "cd $PROJ_HOME && python3 -m venv .venv"
sudo -u "$ADMIN_USER" bash -c "source $PROJ_HOME/.venv/bin/activate && pip install --upgrade pip uv gunicorn"

# ========================
# 🔹 6️⃣ Creazione del file .env con variabili d'ambiente
# ========================
echo "🔹 Creazione del file .env..."
cat > "$PROJ_HOME/.env" <<EOF
# Configurazione ambiente per $PROJ_NAME
DJANGO_SECRET_KEY=$(openssl rand -hex 32)
DEBUG=True
MAINTENANCE_MODE=True
ALLOWED_MAINTENANCE_HOSTS=localhost
ALLOWED_MAINTENANCE_IPS=192.168.151.22
ALLOWED_HOSTS_DOMAIN=example.com
ALLOWED_HOSTS_IP=127.0.0.1

# Email
EMAIL_BACKEND=django.core.mail.backends.smtp.EmailBackend
EMAIL_HOST=smtp.gmail.com
EMAIL_PORT=587
EMAIL_HOST_USER=your_email@gmail.com
EMAIL_HOST_PASSWORD=your_email_password
EMAIL_USE_TLS=true
EMAIL_TIMEOUT=10
DEFAULT_FROM_EMAIL=your_email@gmail.com

# Database
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
DB_HOST=localhost
DB_PORT=3306

# Redis
REDIS_HOST=localhost
REDIS_PORT=$REDIS_PORT

# Internazionalizzazione
LANGUAGE_CODE=it-IT
TIME_ZONE=Europe/Rome

# Static e Media
STATIC_ROOT=$WWW_DIR/static
MEDIA_ROOT=$WWW_DIR/media

# Allauth
ACCOUNT_EMAIL_VERIFICATION=none
ACCOUNT_LOGIN_METHODS=username
ACCOUNT_EMAIL_REQUIRED=false
ACCOUNT_USERNAME_REQUIRED=true
EOF

chown "$ADMIN_USER:$ADMIN_USER" "$PROJ_HOME/.env"
chmod 600 "$PROJ_HOME/.env"

# ========================
# 🔹 7️⃣ Configurazione Nginx (senza env_file e rimozione default)
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
rm -f /etc/nginx/sites-enabled/default  # 🔥 Rimuove il file di default
nginx -t && systemctl restart nginx

# ========================
# 🔹 8️⃣ Configurazione UFW (Firewall)
# ========================
echo "🔹 Configurazione di UFW..."
ufw allow OpenSSH
for port in "${UFW_PORTS[@]}"; do
    ufw allow "$port"
done
ufw --force enable

# ========================
# 🔹 9️⃣ Creazione del servizio systemd per Gunicorn
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

echo "✅ Configurazione completata con successo!"
echo "📂 Il file .env è stato creato in: $PROJ_HOME/.env"
echo "📦 Virtual environment: $PROJ_HOME/.venv"
echo "🐍 Gunicorn e uv installati in: $PROJ_HOME/.venv"
echo "🌐 Puoi accedere ai file statici e media in: $WWW_DIR"
