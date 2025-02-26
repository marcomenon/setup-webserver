#!/usr/bin/env bash
# ===============================================================
# Script semplificato per creare un container LXC su Proxmox
# e configurare un webserver Flask con interfaccia admin.
#
# Autore: Menon Marco
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
# Input interattivo per impostazioni base
# -------------------------------------------
read -p "Inserisci Container ID (>= 100): " CTID
if ! [[ "$CTID" =~ ^[0-9]+$ ]] || [ "$CTID" -lt 100 ]; then
  msg_error "CTID deve essere un numero intero maggiore o uguale a 100."
  exit 205
fi

read -p "Inserisci Hostname del container: " HOSTNAME

# Chiede solo il tipo di sistema operativo (debian o ubuntu)
read -p "Scegli sistema operativo (debian/ubuntu): " PCT_OSTYPE

# Imposta il template in base alla scelta (non si chiede la versione)
if [[ "$PCT_OSTYPE" == "debian" ]]; then
  DESIRED_TEMPLATE="debian-12-standard_12.7-1_amd64.tar.gz"
elif [[ "$PCT_OSTYPE" == "ubuntu" ]]; then
  DESIRED_TEMPLATE="ubuntu-24-standard_24.04-2_amd64.tar.gz"
else
  msg_error "Sistema operativo non valido. Scegli 'debian' o 'ubuntu'."
  exit 1
fi

# Impostazioni predefinite per container
DISK_SIZE=8     # in GB
CORE_COUNT=1
RAM_SIZE=1024   # in MiB

# -------------------------------------------
# Verifica se l'ID è già in uso
# -------------------------------------------
if pct status "$CTID" &>/dev/null || qm status "$CTID" &>/dev/null; then
  msg_error "CTID '$CTID' è già in uso."
  exit 206
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
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE" || ! zstdcat "$TEMPLATE_PATH" 2>/dev/null | tar -tf - >/dev/null 2>&1; then
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
# Verifica/aggiusta subuid e subgid (necessari per container unprivilegiati)
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
)

# -------------------------------------------
# Creazione del container LXC
# -------------------------------------------
msg_info "Creazione del container LXC"
if ! pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${PCT_OPTIONS[@]}" &>/dev/null; then
  msg_error "Creazione container fallita."
  # Se il template è sospetto di corruzione, riprova a ricaricarlo
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
# Configurazione del server all'interno del container
# -------------------------------------------
sleep 5  # Attesa per garantire che il container sia avviato

# 1. Installazione pacchetti base
msg_info "Installazione pacchetti base nel container"
pct exec "$CTID" -- bash -c "apt update && apt upgrade -y && apt install -y nginx python3 python3-venv openssh-server mariadb-server sqlite3" && msg_ok "Pacchetti installati"

# 2. Configurazione di nginx come reverse proxy
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

# 3. Creazione della struttura dell'applicazione
msg_info "Creazione struttura dell'applicazione in /opt/webapp"
pct exec "$CTID" -- bash -c "mkdir -p /opt/webapp/{app,static,templates}" && msg_ok "Struttura creata"

# 4. Creazione del virtual environment ed installazione delle dipendenze
msg_info "Setup ambiente Python e installazione dipendenze"
pct exec "$CTID" -- bash -c "python3 -m venv /opt/webapp/venv && \
  source /opt/webapp/venv/bin/activate && uv init && uv add flask uvicorn valkey flask_sqlalchemy pymysql" && msg_ok "Ambiente Python pronto"

# 5. Creazione del file .env per l'applicazione
msg_info "Creazione file .env"
pct exec "$CTID" -- bash -c "cat > /opt/webapp/.env <<'EOF'
FLASK_APP=app.py
FLASK_SECRET_KEY=defaultsecret
DB_TYPE=sqlite
EOF" && msg_ok ".env creato"

# 6. Creazione dell'applicazione Flask (app.py)
msg_info "Creazione applicazione Flask (app.py)"
pct exec "$CTID" -- bash -c "cat > /opt/webapp/app/app.py <<'EOF'
from flask import Flask, render_template, request, redirect, url_for, flash
from flask_sqlalchemy import SQLAlchemy
import os
app = Flask(__name__, template_folder='../templates')
app.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'defaultsecret')
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

# 7. Creazione del template HTML per la pagina admin
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

# 8. Creazione del servizio systemd per avviare l'app con uvicorn
msg_info "Creazione servizio systemd per uvicorn"
pct exec "$CTID" -- bash -c "cat > /etc/systemd/system/webapp.service <<'EOF'
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
EOF
systemctl daemon-reload && systemctl enable webapp && systemctl start webapp" && msg_ok "Servizio avviato"

msg_ok "Configurazione completata. Il webserver Flask e l'interfaccia admin sono pronti!"
