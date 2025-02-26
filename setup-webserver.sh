#!/usr/bin/env bash
# ===============================================================
# Script per creare un container LXC su Proxmox e configurare
# un webserver Flask con interfaccia admin.
#
# All'avvio l'utente sceglie se usare impostazioni predefinite
# oppure configurare manualmente ogni parametro, inclusi locale,
# timezone e container password.
#
# Autore: (personalizza)
# License: MIT
# ===============================================================

# Abilita exit in caso di errore e imposta il trap per la gestione errori
set -Eeuo pipefail
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR

# -------------------------------------------
# Colorazione, formattazione e icone
# -------------------------------------------
YW="\033[33m"    # Giallo
YWB="\033[93m"   # Giallo chiaro
BL="\033[36m"    # Blu
RD="\033[01;31m" # Rosso
GN="\033[1;92m"  # Verde
CL="\033[m"      # Reset

BOLD="\033[1m"
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"

# -------------------------------------------
# Gestione errori e spinner
# -------------------------------------------
function error_handler() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then
    kill "$SPINNER_PID" >/dev/null
  fi
  printf "\e[?25h"
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  echo -e "\n${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}\n"
  exit 200
}

function spinner() {
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local spin_i=0
  local interval=0.1
  printf "\e[?25l"
  while true; do
    printf "\r${YWB}${frames[spin_i]}${CL}"
    spin_i=$(((spin_i + 1) % ${#frames[@]}))
    sleep "$interval"
  done
}

function msg_info() {
  local msg="$1"
  echo -ne "${TAB}${YW}${msg}...${CL} "
  spinner &
  SPINNER_PID=$!
}

function msg_ok() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then
    kill "$SPINNER_PID" >/dev/null
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  printf "\r${TAB}${CM}${GN}$1${CL}\n"
}

function msg_error() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then
    kill "$SPINNER_PID" >/dev/null
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  printf "\r${TAB}${CROSS}${RD}$1${CL}\n"
}

function msg_warn() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then
    kill "$SPINNER_PID" >/dev/null
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  printf "\r${TAB}${INFO}${YWB}$1${CL}\n"
}

# -------------------------------------------
# Selezione interattiva degli storage
# -------------------------------------------
function select_storage() {
  local content="$1"  # "rootdir" per container, "vztmpl" per template
  local label="$2"
  local storages=()
  while IFS= read -r line; do
    storages+=("$(echo "$line" | awk '{print $1}')")
  done < <(pvesm status -content "$content" | tail -n +2)
  
  if [ "${#storages[@]}" -eq 0 ]; then
    msg_error "Nessuno storage per $label trovato."
    exit 1
  elif [ "${#storages[@]}" -eq 1 ]; then
    echo "${storages[0]}"
  else
    local choices=()
    for s in "${storages[@]}"; do
      choices+=("$s" "" "OFF")
    done
    local selected
    selected=$(whiptail --title "$label Storage" --radiolist \
      "Scegli lo storage per $label:" 15 60 4 "${choices[@]}" 3>&1 1>&2 2>&3) || {
      msg_error "Selezione interrotta."
      exit 202
    }
    echo "$selected"
  fi
}

# -------------------------------------------
# Modalità di configurazione
# -------------------------------------------
MODE=$(whiptail --title "Modalità di Configurazione" --radiolist "Scegli la modalità:" 10 60 2 \
  "DEFAULT" "Usa impostazioni predefinite" ON \
  "MANUALE" "Configura manualmente ogni parametro" OFF 3>&1 1>&2 2>&3)

if [[ "$MODE" == "DEFAULT" ]]; then
  # Impostazioni predefinite (default: Italia)
  CTID=$(pvesh get /cluster/nextid)
  HOSTNAME="flask-container"
  CONTAINER_PASSWORD="password"
  PCT_OSTYPE="debian"
  DESIRED_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
  DISK_SIZE=8
  CORE_COUNT=1
  RAM_SIZE=1024
  DB_TYPE="sqlite"
  ADMIN_USER="admin"
  ADMIN_PASSWORD="admin"
  FLASK_SECRET_KEY="defaultsecret"
  LOCALE="it_IT.UTF-8"
  TIMEZONE="Europe/Rome"
  SUMMARY="CTID: $CTID
Hostname: $HOSTNAME
OS: $PCT_OSTYPE
Template: $DESIRED_TEMPLATE
Disk: ${DISK_SIZE}GB
CPU: ${CORE_COUNT} core(s)
RAM: ${RAM_SIZE} MiB
Locale: $LOCALE
Timezone: $TIMEZONE
Container Password: $CONTAINER_PASSWORD
Database: $DB_TYPE
Admin Username: $ADMIN_USER
Flask Secret: $FLASK_SECRET_KEY"
  whiptail --title "Parametri Predefiniti" --msgbox "Utilizzo i seguenti parametri:\n\n$SUMMARY" 18 60
else
  # Modalità manuale: chiedi ogni parametro tramite whiptail
  CTID=$(whiptail --title "Container ID" --inputbox "Inserisci Container ID (>= 100):" 10 60 "" 3>&1 1>&2 2>&3)
  if ! [[ "$CTID" =~ ^[0-9]+$ ]] || [ "$CTID" -lt 100 ]; then
    msg_error "CTID deve essere un numero intero maggiore o uguale a 100."
    exit 205
  fi

  HOSTNAME=$(whiptail --title "Hostname" --inputbox "Inserisci il nome host del container:" 10 60 "" 3>&1 1>&2 2>&3)
  if [ -z "$HOSTNAME" ]; then
    msg_error "Hostname non può essere vuoto."
    exit 206
  fi

  CONTAINER_PASSWORD=$(whiptail --title "Container Password" --passwordbox "Inserisci la password per il container:" 10 60 "password" 3>&1 1>&2 2>&3)

  PCT_OSTYPE=$(whiptail --title "Sistema Operativo" --radiolist "Scegli il sistema operativo:" 10 60 2 \
    "debian" "Debian" ON \
    "ubuntu" "Ubuntu" OFF 3>&1 1>&2 2>&3)
  if [[ "$PCT_OSTYPE" != "debian" && "$PCT_OSTYPE" != "ubuntu" ]]; then
    msg_error "Sistema operativo non valido. Scegli 'debian' o 'ubuntu'."
    exit 1
  fi
  if [[ "$PCT_OSTYPE" == "debian" ]]; then
    DESIRED_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
  elif [[ "$PCT_OSTYPE" == "ubuntu" ]]; then
    DESIRED_TEMPLATE="ubuntu-24-standard_24.04-2_amd64.tar.zst"
  fi

  DISK_SIZE=$(whiptail --title "Disk Size" --inputbox "Dimensione del disco (in GB):" 10 60 "8" 3>&1 1>&2 2>&3)
  CORE_COUNT=$(whiptail --title "CPU Cores" --inputbox "Numero di core CPU:" 10 60 "1" 3>&1 1>&2 2>&3)
  RAM_SIZE=$(whiptail --title "RAM" --inputbox "Quantità di RAM (in MiB):" 10 60 "1024" 3>&1 1>&2 2>&3)

  DB_TYPE=$(whiptail --title "Database" --radiolist "Scegli il tipo di database per l'applicazione:" 10 60 2 \
    "sqlite" "SQLite (più semplice)" ON \
    "mariadb" "MariaDB (per ambienti più complessi)" OFF 3>&1 1>&2 2>&3)
  if [[ "$DB_TYPE" == "mariadb" ]]; then
    DB_NAME=$(whiptail --title "MariaDB - Nome Database" --inputbox "Inserisci il nome del database:" 10 60 "webapp" 3>&1 1>&2 2>&3)
    DB_USER=$(whiptail --title "MariaDB - Utente" --inputbox "Inserisci il nome utente per il database:" 10 60 "webappuser" 3>&1 1>&2 2>&3)
    DB_PASSWORD=$(whiptail --title "MariaDB - Password" --passwordbox "Inserisci la password per il database:" 10 60 3>&1 1>&2 2>&3)
  fi

  ADMIN_USER=$(whiptail --title "Admin - Username" --inputbox "Inserisci l'username per l'admin di Flask:" 10 60 "admin" 3>&1 1>&2 2>&3)
  ADMIN_PASSWORD=$(whiptail --title "Admin - Password" --passwordbox "Inserisci la password per l'admin di Flask:" 10 60 3>&1 1>&2 2>&3)
  FLASK_SECRET_KEY=$(whiptail --title "Flask - Secret Key" --inputbox "Inserisci la secret key per Flask (lascia vuoto per default 'defaultsecret'):" 10 60 "" 3>&1 1>&2 2>&3)
  if [ -z "$FLASK_SECRET_KEY" ]; then
    FLASK_SECRET_KEY="defaultsecret"
  fi

  LOCALE_CHOICE=$(whiptail --title "Localizzazione" --radiolist "Scegli la localizzazione:" 10 60 2 \
    "Italia" "Imposta locale it_IT.UTF-8 e timezone Europe/Rome" ON \
    "America" "Imposta locale en_US.UTF-8 e timezone America/New_York" OFF 3>&1 1>&2 2>&3)
  if [[ "$LOCALE_CHOICE" == "Italia" ]]; then
    LOCALE="it_IT.UTF-8"
    TIMEZONE="Europe/Rome"
  else
    LOCALE="en_US.UTF-8"
    TIMEZONE="America/New_York"
  fi
fi

# -------------------------------------------
# Selezione degli storage per container e template
# -------------------------------------------
msg_info "Verifica storage"
CONTAINER_STORAGE=$(select_storage rootdir "Container")
msg_ok "Storage container: $CONTAINER_STORAGE"
TEMPLATE_STORAGE=$(select_storage vztmpl "Template")
msg_ok "Storage template: $TEMPLATE_STORAGE"

# -------------------------------------------
# Aggiornamento lista template LXC
# -------------------------------------------
msg_info "Aggiornamento lista template LXC"
pveam update >/dev/null
msg_ok "Lista template aggiornata"

# -------------------------------------------
# Verifica che il template desiderato sia disponibile
# -------------------------------------------
if ! pveam available -section system | grep -qi "$DESIRED_TEMPLATE"; then
  msg_error "Template $DESIRED_TEMPLATE non trovato nella lista dei template disponibili."
  exit 207
fi
TEMPLATE="$DESIRED_TEMPLATE"
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE"
msg_ok "Template individuato: $TEMPLATE"

# -------------------------------------------
# Se il template non esiste o risulta corrotto, ricaricalo (fino a 3 tentativi)
# -------------------------------------------
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE" || \
   ! zstdcat "$TEMPLATE_PATH" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
  msg_warn "Template $TEMPLATE non presente o corrotto. Ricaricamento..."
  [ -f "$TEMPLATE_PATH" ] && rm -f "$TEMPLATE_PATH"
  for attempt in {1..3}; do
    msg_info "Tentativo $attempt: Download del template"
    if timeout 120 pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null; then
      msg_ok "Download template riuscito."
      break
    fi
    if [ "$attempt" -eq 3 ]; then
      msg_error "Tre tentativi falliti. Interruzione."
      exit 208
    fi
    sleep $((attempt * 5))
  done
fi
msg_ok "Template pronto all'uso."

# -------------------------------------------
# Verifica/aggiusta subuid e subgid (per container unprivilegiati)
# -------------------------------------------
grep -q "root:100000:65536" /etc/subuid || echo "root:100000:65536" >> /etc/subuid
grep -q "root:100000:65536" /etc/subgid || echo "root:100000:65536" >> /etc/subgid

# -------------------------------------------
# Definizione delle opzioni per la creazione del container
# -------------------------------------------
PCT_OPTIONS=(
  -features "nesting=1"
  -hostname "$HOSTNAME"
  -net0 "name=eth0,bridge=vmbr0,ip=dhcp"
  -onboot 1
  -cores "$CORE_COUNT"
  -memory "$RAM_SIZE"
  -unprivileged 1
  -rootfs "${CONTAINER_STORAGE}:${DISK_SIZE}"
  --password "$CONTAINER_PASSWORD"
)

# -------------------------------------------
# Creazione del container LXC
# -------------------------------------------
msg_info "Creazione del container LXC"
if ! pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}" &>/dev/null; then
  msg_error "Creazione container fallita."
  if ! zstdcat "$TEMPLATE_PATH" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
    msg_error "Template corrotto. Rimozione e nuovo download..."
    rm -f "$TEMPLATE_PATH"
    if ! timeout 120 pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >/dev/null; then
      msg_error "Download template fallito."
      exit 208
    fi
    msg_ok "Template ricaricato."
    if ! pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}" &>/dev/null; then
      msg_error "Creazione container fallita dopo il nuovo download."
      exit 209
    fi
  else
    exit 209
  fi
fi
msg_ok "Container LXC $CTID creato con successo."

# -------------------------------------------
# Avvio e aggiornamento iniziale del container
# -------------------------------------------
msg_info "Avvio del container LXC"
pct start "$CTID"
sleep 5
msg_ok "Container avviato"

msg_info "Esecuzione di apt update e apt upgrade nel container"
pct exec "$CTID" -- bash -c "apt update && apt upgrade -y"
msg_ok "Container aggiornato"

# -------------------------------------------
# Configurazione locale e timezone all'interno del container
# -------------------------------------------
msg_info "Configurazione locale e timezone"
pct exec "$CTID" -- bash -c "echo '$LOCALE UTF-8' > /etc/locale.gen && locale-gen && update-locale LANG=$LOCALE"
pct exec "$CTID" -- bash -c "echo '$TIMEZONE' > /etc/timezone && dpkg-reconfigure -f noninteractive tzdata"
msg_ok "Locale ($LOCALE) e timezone ($TIMEZONE) configurati"

# -------------------------------------------
# Scelta interattiva del tipo di database
# -------------------------------------------
DB_TYPE=$(whiptail --title "Database" --radiolist "Scegli il tipo di database per l'applicazione:" 10 60 2 \
  "sqlite" "SQLite (più semplice)" ON \
  "mariadb" "MariaDB (per ambienti più complessi)" OFF 3>&1 1>&2 2>&3)
if [[ "$DB_TYPE" != "sqlite" && "$DB_TYPE" != "mariadb" ]]; then
  msg_error "Tipo di database non valido."
  exit 210
fi
msg_ok "Database scelto: $DB_TYPE"

if [[ "$DB_TYPE" == "mariadb" ]]; then
  DB_NAME=$(whiptail --title "MariaDB - Nome Database" --inputbox "Inserisci il nome del database:" 10 60 "webapp" 3>&1 1>&2 2>&3)
  DB_USER=$(whiptail --title "MariaDB - Utente" --inputbox "Inserisci il nome utente per il database:" 10 60 "webappuser" 3>&1 1>&2 2>&3)
  DB_PASSWORD=$(whiptail --title "MariaDB - Password" --passwordbox "Inserisci la password per il database:" 10 60 3>&1 1>&2 2>&3)
fi

# -------------------------------------------
# Inserimento credenziali per amministrazione Flask
# -------------------------------------------
ADMIN_USER=$(whiptail --title "Admin - Username" --inputbox "Inserisci l'username per l'admin di Flask:" 10 60 "admin" 3>&1 1>&2 2>&3)
ADMIN_PASSWORD=$(whiptail --title "Admin - Password" --passwordbox "Inserisci la password per l'admin di Flask:" 10 60 3>&1 1>&2 2>&3)
FLASK_SECRET_KEY=$(whiptail --title "Flask - Secret Key" --inputbox "Inserisci la secret key per Flask (lascia vuoto per default 'defaultsecret'):" 10 60 "" 3>&1 1>&2 2>&3)
if [ -z "$FLASK_SECRET_KEY" ]; then
  FLASK_SECRET_KEY="defaultsecret"
fi

# -------------------------------------------
# Configurazione del server all'interno del container
# -------------------------------------------
msg_info "Installazione pacchetti base nel container"
pct exec "$CTID" -- bash -c "apt update && apt upgrade -y && apt install -y curl nginx python3 python3-venv openssh-server mariadb-server sqlite3" && msg_ok "Pacchetti installati"

msg_info "Installazione di uv"
pct exec "$CTID" -- bash -c "curl -LsSf https://astral.sh/uv/install.sh | sh" && msg_ok "uv installato"

msg_info "Riavvio del container per attivare uv"
pct reboot "$CTID"
sleep 5
msg_ok "Container riavviato"

msg_info "Configurazione di nginx"
pct exec "$CTID" -- bash -c "cat > /etc/nginx/sites-available/webapp <<'EOF'
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
EOF
ln -sf /etc/nginx/sites-available/webapp /etc/nginx/sites-enabled/ && rm -f /etc/nginx/sites-enabled/default && systemctl restart nginx" && msg_ok "Nginx configurato"

msg_info "Creazione struttura dell'applicazione in /opt/webapp"
pct exec "$CTID" -- bash -c "mkdir -p /opt/webapp/{static,templates}" && msg_ok "Struttura creata"

msg_info "Setup ambiente Python e installazione dipendenze"
pct exec "$CTID" -- bash -c "uv init /opt/webapp/ && uv venv /opt/webapp/.venv && source /opt/webapp/.venv/bin/activate && uv pip install flask uvicorn valkey flask_sqlalchemy pymysql" && msg_ok "Ambiente Python pronto"

msg_info "Creazione file .env"
if [[ "$DB_TYPE" == "mariadb" ]]; then
  ENV_CONTENT="FLASK_APP=main.py
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
DB_TYPE=${DB_TYPE}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_NAME=${DB_NAME}"
else
  ENV_CONTENT="FLASK_APP=main.py
FLASK_SECRET_KEY=${FLASK_SECRET_KEY}
DB_TYPE=${DB_TYPE}"
fi
pct exec "$CTID" -- bash -c "echo \"$ENV_CONTENT\" > /opt/webapp/.env" && msg_ok ".env creato"

msg_info "Creazione applicazione Flask (main.py)"
pct exec "$CTID" -- bash -c "cat > /opt/webapp/main.py <<'EOF'
from flask import Flask, render_template, request, redirect, url_for, flash
from flask_sqlalchemy import SQLAlchemy
import os
app = Flask(__name__, template_folder='templates')
app.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'defaultsecret')
if os.environ.get('DB_TYPE') == 'mariadb':
    db_user = os.environ.get('DB_USER', 'webappuser')
    db_password = os.environ.get('DB_PASSWORD', 'password')
    db_name = os.environ.get('DB_NAME', 'webapp')
    app.config['SQLALCHEMY_DATABASE_URI'] = f'mysql+pymysql://{db_user}:{db_password}@localhost/{db_name}'
else:
    app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///webapp.db'
db = SQLAlchemy(app)
class User(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    username = db.Column(db.String(80), unique=True, nullable=False)
    password = db.Column(db.String(120), nullable=False)
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
    return 'Hello, World! Visit /admin to manage users.'
if __name__ == '__main__':
    with app.app_context():
        db.create_all()
    app.run(host='0.0.0.0', port=5000)
EOF" && msg_ok "Applicazione Flask creata"

msg_info "Creazione template admin.html"
pct exec "$CTID" -- bash -c "cat > /opt/webapp/templates/admin.html <<'EOF'
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
  <form method='post'>
    <input type='text' name='username' placeholder='Username' required>
    <input type='password' name='password' placeholder='Password' required>
    <button type='submit'>Aggiungi Utente</button>
  </form>
  <h2>Utenti Esistenti</h2>
  <ul>
    {% for user in users %}
      <li>{{ user.username }}</li>
    {% endfor %}
  </ul>
</body>
</html>
EOF" && msg_ok "Template creato"

msg_info "Creazione servizio systemd per uvicorn"
pct exec "$CTID" -- bash -c "cat > /etc/systemd/system/webapp.service <<'EOF'
[Unit]
Description=Uvicorn instance to serve webapp
After=network.target
[Service]
User=root
Group=www-data
WorkingDirectory=/opt/webapp
EnvironmentFile=/opt/webapp/.env
ExecStart=/opt/webapp/.venv/bin/uvicorn main:app --host 0.0.0.0 --port 5000
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable webapp && systemctl start webapp" && msg_ok "Servizio avviato"

msg_ok "Configurazione completata. Il webserver Flask e l'interfaccia admin sono pronti!"
