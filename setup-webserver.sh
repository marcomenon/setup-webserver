#!/bin/bash
# Script per creare un CT su Proxmox e configurare un ambiente webserver production-ready
# con gestione amministrativa minima in Flask.

# Se esiste un file .env nella cartella dello script, lo carica; altrimenti richiede i parametri
if [ -f .env ]; then
    echo ".env trovato. Carico i parametri..."
    source .env
else
    # Parametri container
    read -p "Inserisci il Container ID (CTID): " CTID
    read -p "Inserisci il nome del container: " CTNAME
    read -p "Scegli il sistema operativo (debian/ubuntu): " OS_CHOICE
    read -s -p "Inserisci la password per il container: " CT_PASSWORD
    echo ""
    # Parametri database
    read -p "Scegli il tipo di database (mariadb/sqlite): " DB_TYPE
    if [ "$DB_TYPE" = "mariadb" ]; then
         read -p "Nome del database: " DB_NAME
         read -p "Nome utente per il database: " DB_USER
         read -s -p "Password per il database: " DB_PASSWORD
         echo ""
    else
         DB_NAME="webapp.db"
    fi
    # Parametri per l'amministrazione Flask
    read -p "Inserisci l'username admin per Flask: " ADMIN_USER
    read -s -p "Inserisci la password admin per Flask: " ADMIN_PASSWORD
    echo ""
    # Secret key per Flask
    read -p "Inserisci la secret key per Flask (lascia vuoto per default 'defaultsecret'): " FLASK_SECRET_KEY
    if [ -z "$FLASK_SECRET_KEY" ]; then
        FLASK_SECRET_KEY="defaultsecret"
    fi
fi

# Definizione del template in base alla scelta di OS
if [ "$OS_CHOICE" = "debian" ]; then
    TEMPLATE="/var/lib/vz/template/cache/debian-10-standard_10.7-1_amd64.tar.gz"
elif [ "$OS_CHOICE" = "ubuntu" ]; then
    TEMPLATE="/var/lib/vz/template/cache/ubuntu-20.04-standard_20.04-1_amd64.tar.gz"
else
    echo "Scelta del sistema operativo non valida. Esco."
    exit 1
fi

echo "Creazione del container $CTNAME ($CTID) con template $TEMPLATE..."
pct create $CTID $TEMPLATE \
  --hostname "$CTNAME" \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --memory 512 \
  --rootfs local-lvm:8 \
  --password "$CT_PASSWORD"

echo "Avvio del container..."
pct start $CTID
sleep 5  # Attesa per consentire l'avvio

echo "Aggiornamento e installazione dei pacchetti di base..."
# Installazione dei pacchetti base; se si usa MariaDB vengono installati anche i pacchetti relativi
if [ "$DB_TYPE" = "mariadb" ]; then
    pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y nginx python3 python3-venv openssh-server mariadb-server sqlite3"
else
    pct exec $CTID -- bash -c "apt update && apt upgrade -y && apt install -y nginx python3 python3-venv openssh-server sqlite3 mariadb-server"
fi

# Configurazione del database se si usa MariaDB
if [ "$DB_TYPE" = "mariadb" ]; then
    echo "Configurazione di MariaDB..."
    pct exec $CTID -- bash -c "mysql -e \"CREATE DATABASE IF NOT EXISTS ${DB_NAME};\""
    pct exec $CTID -- bash -c "mysql -e \"CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';\""
    pct exec $CTID -- bash -c "mysql -e \"GRANT ALL PRIVILEGES ON ${DB_NAME}.* TO '${DB_USER}'@'localhost';\""
    pct exec $CTID -- bash -c "mysql -e \"FLUSH PRIVILEGES;\""
fi

# Configurazione di nginx: reverse proxy verso uvicorn sulla porta 5000
echo "Configurazione di nginx per il reverse proxy..."
pct exec $CTID -- bash -c "cat > /etc/nginx/sites-available/webapp <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF"
pct exec $CTID -- bash -c "ln -sf /etc/nginx/sites-available/webapp /etc/nginx/sites-enabled/ && rm -f /etc/nginx/sites-enabled/default && systemctl restart nginx"

# Creazione della struttura dell'applicazione
echo "Creazione della struttura dell'applicazione in /opt/webapp..."
pct exec $CTID -- bash -c "mkdir -p /opt/webapp/{app,static,templates}"

# Creazione del virtual environment
echo "Creazione del virtual environment..."
pct exec $CTID -- bash -c "python3 -m venv /opt/webapp/venv"

# Inizializzazione del progetto con uv e installazione dei package necessari:
# vengono installati flask, uvicorn, valkey, flask_sqlalchemy e pymysql per MariaDB
echo "Inizializzazione del progetto con 'uv' e installazione dei package..."
pct exec $CTID -- bash -c "source /opt/webapp/venv/bin/activate && uv init && uv add flask uvicorn valkey flask_sqlalchemy pymysql"

# Creazione del file .env per l'applicazione in /opt/webapp
echo "Creazione del file .env per l'applicazione..."
if [ "$DB_TYPE" = "mariadb" ]; then
    ENV_CONTENT="FLASK_APP=app.py
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
DB_TYPE=${DB_TYPE}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}"
else
    ENV_CONTENT="FLASK_APP=app.py
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
DB_TYPE=${DB_TYPE}"
fi
pct exec $CTID -- bash -c "echo \"$ENV_CONTENT\" > /opt/webapp/.env"

# Creazione del file app.py con gestione minima di amministrazione e tabella utenti
echo "Creazione di /opt/webapp/app/app.py..."
pct exec $CTID -- bash -c "cat > /opt/webapp/app/app.py <<'EOF'
from flask import Flask, render_template, request, redirect, url_for, flash
from flask_sqlalchemy import SQLAlchemy
import os

# Configurazione dell'applicazione
app = Flask(__name__, template_folder='../templates')
app.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'defaultsecret')

db_type = os.environ.get('DB_TYPE', 'sqlite')
if db_type == 'mariadb':
    db_user = os.environ.get('DB_USER', 'webapp')
    db_password = os.environ.get('DB_PASSWORD', 'password')
    db_name = os.environ.get('DB_NAME', 'webapp')
    app.config['SQLALCHEMY_DATABASE_URI'] = f'mysql+pymysql://{db_user}:{db_password}@localhost/{db_name}'
else:
    app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///webapp.db'

db = SQLAlchemy(app)

# Modello per gli utenti
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password = db.Column(db.String(120), nullable=False)

    def __repr__(self):
        return f\"<User {self.username}>\"

# Rotta per la gestione amministrativa
@app.route('/admin', methods=['GET', 'POST'])
def admin():
    if request.method == 'POST':
        username = request.form.get('username')
        password = request.form.get('password')
        if username and password:
            new_user = User(username=username, password=password)
            db.session.add(new_user)
            db.session.commit()
            flash('Utente aggiunto!')
            return redirect(url_for('admin'))
    users = User.query.all()
    return render_template('admin.html', users=users)

@app.route('/')
def index():
    return \"Hello, World! Visit /admin to manage users.\"

if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=5000)
EOF"

# Creazione del template per la pagina admin
echo "Creazione di /opt/webapp/templates/admin.html..."
pct exec $CTID -- bash -c "cat > /opt/webapp/templates/admin.html <<'EOF'
<!doctype html>
<html>
<head>
  <title>Admin - Gestione Utenti</title>
</head>
<body>
  <h1>Gestione Utenti</h1>
  {% with messages = get_flashed_messages() %}
    {% if messages %}
      <ul>
      {% for message in messages %}
        <li>{{ message }}</li>
      {% endfor %}
      </ul>
    {% endif %}
  {% endwith %}
  <form method=\"post\">
    <input type=\"text\" name=\"username\" placeholder=\"Username\" required>
    <input type=\"password\" name=\"password\" placeholder=\"Password\" required>
    <button type=\"submit\">Aggiungi Utente</button>
  </form>
  <h2>Utenti Esistenti</h2>
  <ul>
    {% for user in users %}
      <li>{{ user.username }}</li>
    {% endfor %}
  </ul>
</body>
</html>
EOF"

# Creazione del servizio systemd per avviare l'app con uvicorn
echo "Creazione del servizio systemd per avviare l'app..."
pct exec $CTID -- bash -c "cat > /etc/systemd/system/webapp.service <<'EOF'
[Unit]
Description=Uvicorn instance to serve webapp
After=network.target

[Service]
User=root
Group=www-data
WorkingDirectory=/opt/webapp/app
EnvironmentFile=/opt/webapp/.env
ExecStart=/opt/webapp/venv/bin/uvicorn app:app --host 0.0.0.0 --port 5000

[Install]
WantedBy=multi-user.target
EOF"

# Ricarica systemd e avvio del servizio
echo "Abilitazione e avvio del servizio webapp..."
pct exec $CTID -- bash -c "systemctl daemon-reload && systemctl enable webapp && systemctl start webapp"

echo "Configurazione completata. Il webserver e la gestione admin sono pronti!"
