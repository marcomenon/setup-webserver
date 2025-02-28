#!/bin/bash

# Imposta i parametri iniziali
GITHUB_REPO="https://github.com/tuo-username/tuo-repo.git"
DEFAULT_PROJECT_NAME="djangoproject"
DEFAULT_PYTHON_VERSION="3.10"
PROJECT_GROUP="www-data"

# Controlla se lo script è eseguito come root
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ Lo script deve essere eseguito come root! Usa sudo."
    exit 1
fi

echo "🔽 Clonazione del repository da GitHub..."
# Clona il progetto se non esiste già
if [ ! -d "$DEFAULT_PROJECT_NAME" ]; then
    git clone "$GITHUB_REPO" "$DEFAULT_PROJECT_NAME"
else
    echo "📂 La cartella del progetto esiste già, aggiornamento..."
    cd "$DEFAULT_PROJECT_NAME" && git pull origin main
fi

# Cambiamo directory nel progetto clonato
cd "$DEFAULT_PROJECT_NAME" || { echo "❌ Errore: impossibile accedere alla directory del progetto."; exit 1; }

# Funzione per leggere una chiave da un file TOML
get_toml_value() {
    local key=$1
    local file=$2
    grep -oP "(?<=^$key = \")[^\"]+" "$file" 2>/dev/null || echo ""
}

# Legge il nome del progetto da pyproject.toml
PYPROJECT_FILE="pyproject.toml"
if [ -f "$PYPROJECT_FILE" ]; then
    PROJECT_NAME=$(get_toml_value "name" "$PYPROJECT_FILE")
else
    PROJECT_NAME="$DEFAULT_PROJECT_NAME"
fi

# Se PROJECT_NAME è vuoto, assegna il valore di default
PROJECT_NAME="${PROJECT_NAME:-$DEFAULT_PROJECT_NAME}"

# Crea PROJECT_USER basandosi su PROJECT_NAME
if [[ "$PROJECT_NAME" == *project ]]; then
    PROJECT_USER="${PROJECT_NAME%project}user"
else
    PROJECT_USER="${PROJECT_NAME}user"
fi

# Legge la versione di Python da .python-version (se esiste)
PYTHON_VERSION_FILE=".python-version"
if [ -f "$PYTHON_VERSION_FILE" ]; then
    PYTHON_VERSION=$(cat "$PYTHON_VERSION_FILE" | tr -d '[:space:]')
else
    PYTHON_VERSION="$DEFAULT_PYTHON_VERSION"
fi

# Impostazioni finali
BASE_DIR="/home/$PROJECT_USER/$PROJECT_NAME"

echo "🛠 Configurazione del server per il progetto Django:"
echo "- Nome progetto: $PROJECT_NAME"
echo "- Utente progetto: $PROJECT_USER"
echo "- Versione Python: $PYTHON_VERSION"

# Aggiorna i pacchetti e installa le dipendenze di sistema
apt update && apt upgrade -y
apt install -y nginx python${PYTHON_VERSION} python${PYTHON_VERSION}-venv python${PYTHON_VERSION}-dev python3-pip git curl ufw

# Crea l'utente Django se non esiste
if id "$PROJECT_USER" &>/dev/null; then
    echo "✅ Utente $PROJECT_USER già esistente"
else
    echo "👤 Creazione dell'utente $PROJECT_USER..."
    adduser --system --group --home "/home/$PROJECT_USER" $PROJECT_USER
    echo "✅ Utente $PROJECT_USER creato con successo!"
fi

# Sposta il progetto clonato nella home dell'utente
mv "$PWD" "/home/$PROJECT_USER/$PROJECT_NAME"
chown -R $PROJECT_USER:$PROJECT_GROUP "/home/$PROJECT_USER/$PROJECT_NAME"

# Cambia directory nella home dell'utente per continuare l'installazione
cd "/home/$PROJECT_USER/$PROJECT_NAME" || { echo "❌ Errore: impossibile accedere alla directory del progetto."; exit 1; }

# Crea ed attiva un ambiente virtuale Python
echo "🐍 Creazione dell'ambiente virtuale Python..."
sudo -u $PROJECT_USER python${PYTHON_VERSION} -m venv "venv"
source "venv/bin/activate"

# Installa le dipendenze da pyproject.toml
if [ -f "pyproject.toml" ]; then
    echo "📦 Installazione dei pacchetti da pyproject.toml..."
    pip install --upgrade pip
    pip install .
else
    echo "⚠️ Nessun file pyproject.toml trovato, installazione manuale necessaria."
fi

# Esegue il setup automatico dello script che abbiamo creato
echo "⚙️ Esecuzione dello script di setup Django..."
bash "scripts/setup_django_server.sh"

# Configura UFW (Firewall) per consentire il traffico HTTP e HTTPS
echo "🛡️ Configurazione del firewall UFW..."
ufw allow OpenSSH
ufw allow 'Nginx Full'
ufw --force enable

# Riavvia nginx per applicare le configurazioni
echo "🔄 Riavvio di nginx..."
systemctl restart nginx

echo "✅ Installazione completata con successo!"
echo "🌍 Il server Django è ora disponibile su http://$SITE_DOMAIN"
