curl -sL https://raw.githubusercontent.com/marcomenon/setup-webserver/refs/heads/main/setup-webserver.sh

curl -sL https://raw.githubusercontent.com/marcomenon/setup-webserver/refs/heads/main/setup-webserver.sh -o setup-webserver.sh
less setup-webserver.sh

rm setup-webserver.sh
curl -sL https://raw.githubusercontent.com/marcomenon/setup-webserver/refs/heads/main/setup-webserver.sh -o setup-webserver.sh
chmod +x setup-webserver.sh
./setup-webserver.sh


wget https://raw.githubusercontent.com/marcomenon/setup-webserver/main/setup_lxc.sh -O setup_lxc.sh
chmod +x setup_lxc.sh
sudo bash setup_lxc.sh
