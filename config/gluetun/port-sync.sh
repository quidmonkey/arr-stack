#!/bin/sh
# Called by gluetun's VPN_PORT_FORWARDING_UP_COMMAND whenever the forwarded
# port is assigned or changes. Pushes it into qBittorrent's listen_port via
# qBittorrent's WebUI API (reachable at 127.0.0.1 since qbittorrent shares
# gluetun's network namespace, and localhost auth bypass is enabled there).
PORT="$1"
wget -qO- --post-data="json={\"listen_port\":${PORT}}" http://127.0.0.1:8080/api/v2/app/setPreferences
