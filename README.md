curl -sL https://raw.githubusercontent.com/marcomenon/setup-webserver/refs/heads/main/setup-webserver.sh

curl -sL https://raw.githubusercontent.com/marcomenon/setup-webserver/refs/heads/main/setup-webserver.sh -o setup-webserver.sh
less setup-webserver.sh

rm setup-webserver.sh
curl -sL https://raw.githubusercontent.com/marcomenon/setup-webserver/refs/heads/main/setup-webserver.sh -o setup-webserver.sh
chmod +x setup-webserver.sh
./setup-webserver.sh
