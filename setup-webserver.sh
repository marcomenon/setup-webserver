#!/bin/bash
# ===============================================================
# Script per creare un container LXC Proxmox per un webserver Flask
# con interfaccia avanzata e creazione container ispirata ai community‑scripts
# (Copyright (c) 2021-2025 tteck, MickLesk, michelroegl-brunner)
# License: MIT
# ===============================================================

# Imposta il nome dell'applicazione (influirà anche sull'header e su alcune variabili)
APP="Flask"

# Variabili di default per la creazione del container
var_os="debian"          # Distribuzione predefinita (debian o ubuntu)
var_version="12"         # Per debian: "12" (Bookworm) – per ubuntu potresti usare "24.04" (se supportato)
var_disk="8"             # Dimensione del disco in GB (default 8 GB)
var_cpu="1"              # Numero di core CPU
var_ram="1024"           # RAM in MiB
var_tags="flask"         # Tag associati al container

# --------------------------
# Funzioni di utilità e interfaccia
# --------------------------
# (Qui vengono definite o importate le funzioni prese dal repository community‑scripts)

# Imposta le variabili di base (trasforma APP in minuscolo, genera un UUID, ecc.)
variables() {
  NSAPP=$(echo "${APP,,}" | tr -d ' ')
  var_install="${NSAPP}-install"
  INTEGER='^[0-9]+([.][0-9]+)?$'
  PVEHOST_NAME=$(hostname)
  DIAGNOSTICS="yes"
  METHOD="default"
  RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
}

# Scarica le funzioni API dal repository community‑scripts
source <(curl -s https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

# Funzione per definire colori e simboli per l’interfaccia
color() {
  YW="\033[33m"
  YWB="\033[93m"
  BL="\033[36m"
  RD="\033[01;31m"
  BGN="\033[4;92m"
  GN="\033[1;92m"
  DGN="\033[32m"
  CL="\033[m"
  UL="\033[4m"
  BOLD="\033[1m"
  TAB="  "
  CM="${TAB}✔️${TAB}${CL}"
  CROSS="${TAB}✖️${TAB}${CL}"
  INFO="${TAB}💡${TAB}${CL}"
  OS="${TAB}🖥️${TAB}${CL}"
  OSVERSION="${TAB}🌟${TAB}${CL}"
  CONTAINERTYPE="${TAB}📦${TAB}${CL}"
  DISKSIZE="${TAB}💾${TAB}${CL}"
  CPUCORE="${TAB}🧠${TAB}${CL}"
  RAMSIZE="${TAB}🛠️${TAB}${CL}"
  SEARCH="${TAB}🔍${TAB}${CL}"
  VERIFYPW="${TAB}🔐${TAB}${CL}"
  CONTAINERID="${TAB}🆔${TAB}${CL}"
  HOSTNAME="${TAB}🏠${TAB}${CL}"
  BRIDGE="${TAB}🌉${TAB}${CL}"
  NETWORK="${TAB}📡${TAB}${CL}"
  GATEWAY="${TAB}🌐${TAB}${CL}"
  DISABLEIPV6="${TAB}🚫${TAB}${CL}"
  DEFAULT="${TAB}⚙️${TAB}${CL}"
  MACADDRESS="${TAB}🔗${TAB}${CL}"
  VLANTAG="${TAB}🏷️${TAB}${CL}"
  ROOTSSH="${TAB}🔑${TAB}${CL}"
  CREATING="${TAB}🚀${TAB}${CL}"
  ADVANCED="${TAB}🧩${TAB}${CL}"
}

# Abilita il controllo degli errori
catch_errors() {
  set -Eeuo pipefail
  trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
}

error_handler() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then kill "$SPINNER_PID" >/dev/null; fi
  printf "\e[?25h"
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  exit $exit_code
}

# Funzioni per lo spinner e messaggi di info/errore
start_spinner() {
  local msg="$1"
  local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
  local spin_i=0
  local interval=0.1
  {
    while [ "${SPINNER_ACTIVE:-1}" -eq 1 ]; do
      printf "\r\033[2K${frames[spin_i]} ${YW}%b${CL}" "$msg" >&2
      spin_i=$(((spin_i + 1) % ${#frames[@]}))
      sleep "$interval"
    done
  } &
  SPINNER_PID=$!
}
msg_info() { start_spinner "$1"; }
msg_ok() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then
    kill "$SPINNER_PID" >/dev/null 2>&1
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  printf "\r\033[2K${CM}${GN}%b${CL}\n" "$1" >&2
  SPINNER_ACTIVE=0
}
msg_error() {
  if [ -n "${SPINNER_PID:-}" ] && ps -p "$SPINNER_PID" >/dev/null; then
    kill "$SPINNER_PID" >/dev/null 2>&1
    wait "$SPINNER_PID" 2>/dev/null || true
  fi
  printf "\r\033[2K${CROSS}${RD}%b${CL}\n" "$1" >&2
  SPINNER_ACTIVE=0
}

log_message() {
  local level="$1"
  local message="$2"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  LOGDIR="/usr/local/community-scripts/logs"
  mkdir -p "$LOGDIR"
  LOGFILE="${LOGDIR}/$(date '+%Y-%m-%d')_${NSAPP}.log"
  echo "$timestamp - $level: $message" >>"$LOGFILE"
}

# Controlli preliminari: shell, root, versione PVE, architettura, ecc.
shell_check() {
  if [[ "$(basename "$SHELL")" != "bash" ]]; then
    msg_error "La shell predefinita non è Bash. Passa a Bash per utilizzare questo script."
    exit 1
  fi
}
root_check() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Esegui questo script come root."
    exit 1
  fi
}
pve_check() {
  if ! pveversion | grep -Eq "pve-manager/8\.[1-3]"; then
    msg_error "Versione di Proxmox non supportata. Richiede almeno 8.1."
    exit 1
  fi
}
arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "Questo script funziona solo su architettura amd64."
    exit 1
  fi
}
ssh_check() {
  if [ -n "${SSH_CLIENT:-}" ]; then
    whiptail --backtitle "Proxmox VE Helper Scripts" --title "SSH Rilevato" --msgbox "È consigliato usare la shell di Proxmox e non una sessione SSH." 8 58
  fi
}
maxkeys_check() {
  # (Implementazione semplificata per il controllo delle chiavi kernel)
  true
}
diagnostics_check() {
  # (Implementazione base: se non esiste il file, viene creato con DIAGNOSTICS=yes)
  [ -f "/usr/local/community-scripts/diagnostics" ] || echo "DIAGNOSTICS=yes" > /usr/local/community-scripts/diagnostics
}

# Funzione per mostrare un header ASCII (se disponibile) e pulire lo schermo
header_info() {
  clear
  echo -e "${BOLD}${BL}======== Creazione LXC per ${APP} ========"${CL}
}

# Funzioni per impostare le configurazioni di base e avanzate (usando whiptail)
base_settings() {
  CT_TYPE="1"         # Default: Unprivileged
  DISK_SIZE="$var_disk"
  CORE_COUNT="$var_cpu"
  RAM_SIZE="$var_ram"
  VERB="${1:-no}"
  CT_ID=$(pvesh get /cluster/nextid)
  HN="${NSAPP:-flask}"
  BRG="vmbr0"
  NET="dhcp"
  TAGS="community-script;${var_tags}"
}
echo_default() {
  local CT_TYPE_DESC="Unprivileged"
  if [ "$CT_TYPE" -eq 0 ]; then
    CT_TYPE_DESC="Privileged"
  fi
  echo -e "${OS}${BOLD}OS: ${BGN}${var_os}${CL}"
  echo -e "${OSVERSION}${BOLD}Version: ${BGN}${var_version}${CL}"
  echo -e "${CONTAINERTYPE}${BOLD}Container Type: ${BGN}${CT_TYPE_DESC}${CL}"
  echo -e "${DISKSIZE}${BOLD}Disk: ${BGN}${DISK_SIZE} GB${CL}"
  echo -e "${CPUCORE}${BOLD}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}RAM: ${BGN}${RAM_SIZE} MiB${CL}"
  echo -e "${CONTAINERID}${BOLD}CTID: ${BGN}${CT_ID}${CL}"
  echo -e "${HOSTNAME}${BOLD}Hostname: ${BGN}${HN}${CL}"
  echo -e "${BRIDGE}${BOLD}Bridge: ${BGN}${BRG}${CL}"
}
advanced_settings() {
  # Esempio semplificato: in ambiente reale qui si userebbe whiptail per impostare le opzioni
  var_os=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISTRIBUTION" --radiolist "Scegli distribuzione:" 10 58 2 \
    "debian" "Debian" ON "ubuntu" "Ubuntu" OFF 3>&1 1>&2 2>&3)
  if [ "$var_os" == "debian" ]; then
    var_version=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DEBIAN VERSION" --radiolist "Scegli versione:" 10 58 2 \
      "11" "Bullseye" OFF "12" "Bookworm" ON 3>&1 1>&2 2>&3)
  else
    var_version=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "UBUNTU VERSION" --radiolist "Scegli versione:" 10 58 2 \
      "22.04" "Jammy" ON "24.04" "Noble" OFF 3>&1 1>&2 2>&3)
  fi
  CT_TYPE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "CONTAINER TYPE" --radiolist "Scegli tipo container:" 10 58 2 \
    "1" "Unprivileged" ON "0" "Privileged" OFF 3>&1 1>&2 2>&3)
  HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Imposta Hostname" 8 58 "${NSAPP:-flask}" --title "HOSTNAME" 3>&1 1>&2 2>&3)
  BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Imposta Bridge" 8 58 "vmbr0" --title "BRIDGE" 3>&1 1>&2 2>&3)
}
exit_script() {
  msg_error "Script interrotto dall'utente."
  exit 1
}

# Funzione per creare il container utilizzando il sistema community‑scripts
build_container() {
  # Imposta alcune opzioni aggiuntive
  if [ "$CT_TYPE" == "1" ]; then
    FEATURES="keyctl=1,nesting=1"
  else
    FEATURES="nesting=1"
  fi
  export CTID="$CT_ID"
  export HN
  export PCT_OSTYPE="$var_os"
  export PCT_OSVERSION="$var_version"
  export PCT_DISK_SIZE="$DISK_SIZE"
  export PCT_OPTIONS="-features $FEATURES -hostname $HN -tags $TAGS -net0 name=eth0,bridge=$BRG,ip=$NET -onboot 1 -cores $CORE_COUNT -memory $RAM_SIZE -unprivileged $CT_TYPE"
  # Esegue lo script di creazione LXC preso dal repository community‑scripts
  bash -c "$(wget -qLO - https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/create_lxc.sh)" || exit $?
}

# Imposta controlli preliminari e variabili
variables
color
catch_errors
shell_check
root_check
pve_check
arch_check
ssh_check
maxkeys_check
diagnostics_check

NEXTID=$(pvesh get /cluster/nextid)
timezone=$(cat /etc/timezone)
header_info

# Scegli tra Default o Advanced Settings
CHOICE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --menu "Scegli un'opzione:" 12 50 3 \
  "1" "Default Settings" \
  "2" "Advanced Settings" \
  "3" "Esci" --nocancel --default-item "1" 3>&1 1>&2 2>&3)
case $CHOICE in
  1)
    VERB="no"
    base_settings "$VERB"
    echo_default
    ;;
  2)
    VERB="yes"
    base_settings "$VERB"
    advanced_settings
    echo_default
    ;;
  3)
    exit_script
    ;;
esac

# Costruisce il container LXC
msg_info "Creazione del container in corso..."
build_container
msg_ok "Container creato con successo!"

# -----------------------------------------------------
# Configurazione post-creazione: installa pacchetti e setup app
# -----------------------------------------------------
CTID="$CT_ID"  # ID del container appena creato
sleep 5  # Attesa per garantire che il container sia avviato

msg_info "Installazione dei pacchetti base nel container..."
pct exec "$CTID" -- bash -c "apt update && apt upgrade -y && apt install -y nginx python3 python3-venv openssh-server mariadb-server sqlite3" && msg_ok "Pacchetti installati"

msg_info "Configurazione di nginx per il reverse proxy..."
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

msg_info "Creazione della struttura dell'applicazione..."
pct exec "$CTID" -- bash -c "mkdir -p /opt/webapp/{app,static,templates}" && msg_ok "Struttura creata"

msg_info "Creazione del virtual environment e installazione dei package (uv, flask, uvicorn, ecc.)..."
pct exec "$CTID" -- bash -c "python3 -m venv /opt/webapp/venv && \
  source /opt/webapp/venv/bin/activate && uv init && uv add flask uvicorn valkey flask_sqlalchemy pymysql" && msg_ok "Ambiente Python pronto"

msg_info "Creazione del file .env per la configurazione dell'app..."
pct exec "$CTID" -- bash -c "cat > /opt/webapp/.env <<'EOF'
FLASK_APP=app.py
FLASK_SECRET_KEY=defaultsecret
DB_TYPE=sqlite
EOF" && msg_ok ".env creato"

msg_info "Creazione dell'applicazione Flask..."
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
EOF" && msg_ok "App Flask creata"

msg_info "Creazione del template per la pagina admin..."
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

msg_info "Creazione del servizio systemd per avviare l'app con uvicorn..."
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

# Imposta una descrizione nel container (opzionale)
description() {
  IP=$(pct exec "$CT_ID" ip a s dev eth0 | awk '/inet / {print $2}' | cut -d/ -f1)
  DESCRIPTION="<div align='center'>
    <h2>${APP} LXC</h2>
    <p>Indirizzo IP: ${IP}</p>
  </div>"
  pct set "$CT_ID" -description "$DESCRIPTION"
}
description

echo -e "\n${BOLD}${GN}Configurazione completata. Il webserver Flask e l'interfaccia admin sono pronti!${CL}"
