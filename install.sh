#!/usr/bin/env bash
# Installer for Nautilus (Bazzite NVIDIA). See INSTALL.md for the full runbook.
#
# Run from the repo as your normal user (Homebrew refuses root); it calls sudo
# where needed. Subcommands, in install order:
#   check            show what's done and what's missing (safe, changes nothing)
#   host             podman-compose, NVIDIA CDI, no sleep, firewall, SSH, Tailscale
#   das DISK DISK..  format the DAS as btrfs RAID1 and mount it (ERASES DISKS)
#   stack            create folders, install the boot service, start everything
#   verify           check VPN, GPU and every service answers
#   compose ARGS..   run podman-compose as root, e.g. `compose logs -f jellyfin`
set -euo pipefail

REPO_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$REPO_DIR"

if [ -f .env ]; then
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
fi
STORAGE_ROOT=${STORAGE_ROOT:-/var/mnt/storage}
CONFIG_ROOT=${CONFIG_ROOT:-./config}
PUID=${PUID:-1000}
PGID=${PGID:-1000}

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }
report() {
  local label=$1; shift
  if "$@" >/dev/null 2>&1; then echo "  [ok] $label"; else echo "  [--] $label"; fi
}

# True when both values are set and not equal.
differs() { [ -n "$1" ] && [ -n "$2" ] && [ "$1" != "$2" ]; }

podman_compose_ok() {
  local v
  v=$(podman-compose --version 2>/dev/null | sed -n 's/.*podman-compose version \([0-9.]*\).*/\1/p')
  [ -n "$v" ] && printf '1.3.0\n%s\n' "$v" | sort -V -C
}

# Copy a unit from systemd/ into /etc/systemd/system, filling in placeholders.
install_unit() {
  sed -e "s|@REPO_DIR@|$REPO_DIR|g" \
      -e "s|@STORAGE_ROOT@|$STORAGE_ROOT|g" \
      -e "s|@PODMAN_COMPOSE@|$(command -v podman-compose || true)|g" \
      "systemd/$1" | sudo tee "/etc/systemd/system/$1" >/dev/null
}

cmd_check() {
  report "Bazzite NVIDIA image" grep -qi nvidia /usr/share/ublue-os/image-info.json
  report "NVIDIA driver loaded (nvidia-smi)" nvidia-smi
  report "nvidia-ctk (NVIDIA container toolkit)" command -v nvidia-ctk
  report "podman" command -v podman
  report "podman-compose >= 1.3" podman_compose_ok
  report "sleep disabled" test "$(systemctl is-enabled sleep.target 2>/dev/null)" = masked
  report "sshd running" systemctl is-active --quiet sshd
  report "SSH key-only login" test -f /etc/ssh/sshd_config.d/10-key-only.conf
  report "firewalld running" systemctl is-active --quiet firewalld
  report "tailscale logged in" tailscale status
  report ".env present" test -f .env
  report "DAS mounted at $STORAGE_ROOT" mountpoint -q "$STORAGE_ROOT"
  report "DAS scrub timer enabled" systemctl is-enabled --quiet btrfs-scrub-storage.timer
  report "media-stack.service enabled" systemctl is-enabled --quiet media-stack.service
}

cmd_host() {
  [ "$(id -u)" -ne 0 ] || die "run as your normal user, not root"

  info "podman-compose (Homebrew)"
  command -v podman-compose >/dev/null || brew install podman-compose
  podman_compose_ok || die "podman-compose must be >= 1.3 (needs depends_on health conditions): brew upgrade podman-compose"

  info "NVIDIA CDI spec"
  command -v nvidia-ctk >/dev/null || die "nvidia-ctk not found. See INSTALL.md, 'NVIDIA container toolkit'."
  install_unit nvidia-cdi-generate.service
  sudo systemctl daemon-reload
  sudo systemctl enable nvidia-cdi-generate.service
  sudo systemctl restart nvidia-cdi-generate.service
  nvidia-ctk cdi list 2>/dev/null | grep -q 'nvidia.com/gpu=all' || die "CDI spec has no nvidia.com/gpu=all device"

  info "Disabling sleep (this PC is a 24/7 server)"
  sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target

  if systemctl is-active --quiet firewalld; then
    info "Firewall: Sunshine, Steam Remote Play, and trust the tailnet"
    local port
    for port in 47984-47990/tcp 48010/tcp 47998-48000/udp 27031-27036/udp 27036-27037/tcp; do
      sudo firewall-cmd --permanent --add-port="$port" >/dev/null
    done
    sudo firewall-cmd --permanent --add-service=ssh >/dev/null
    sudo firewall-cmd --permanent --zone=trusted --query-interface=tailscale0 >/dev/null 2>&1 ||
      sudo firewall-cmd --permanent --zone=trusted --add-interface=tailscale0 >/dev/null
    sudo firewall-cmd --reload >/dev/null
  fi

  info "SSH"
  sudo systemctl enable --now sshd
  # Key-only login, but only once a key is in place, so this can't lock you out.
  if [ -s "$HOME/.ssh/authorized_keys" ]; then
    printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\nPermitRootLogin no\n' |
      sudo tee /etc/ssh/sshd_config.d/10-key-only.conf >/dev/null
    sudo systemctl reload sshd
  else
    echo "  Passwords still allowed: no key in ~/.ssh/authorized_keys yet."
    echo "  From your PC: ssh-copy-id $(id -un)@$(hostname), then run ./install.sh host again."
  fi

  info "Tailscale"
  sudo systemctl enable --now tailscaled
  tailscale status >/dev/null 2>&1 || echo "  Not logged in yet. Run: sudo tailscale up --ssh"
}

cmd_das() {
  [ $# -ge 2 ] || die "usage: ./install.sh das /dev/disk/by-id/<disk> /dev/disk/by-id/<disk> [...]"
  local disk
  for disk in "$@"; do [ -b "$disk" ] || die "$disk is not a block device"; done
  ! mountpoint -q "$STORAGE_ROOT" || die "$STORAGE_ROOT is already mounted"

  local profile=${DAS_PROFILE:-raid1}
  lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,MOUNTPOINTS "$@"
  echo
  echo "This formats the disks above as one btrfs $profile filesystem."
  echo "EVERYTHING ON THEM WILL BE ERASED."
  local answer
  read -r -p "Type ERASE to continue: " answer
  [ "$answer" = ERASE ] || die "aborted"

  info "Formatting"
  sudo mkfs.btrfs -f -L storage -d "$profile" -m raid1 "$@"
  sudo udevadm settle

  info "Mounting at $STORAGE_ROOT"
  local uuid
  uuid=$(sudo blkid -s UUID -o value "$1")
  [ -n "$uuid" ] || die "no filesystem UUID on $1"
  sudo mkdir -p "$STORAGE_ROOT"
  # nofail: boot doesn't hang if the DAS is off. media-stack.service won't
  # start without the mount (RequiresMountsFor), so nothing writes to the NVMe.
  grep -q "UUID=$uuid" /etc/fstab ||
    echo "UUID=$uuid $STORAGE_ROOT btrfs noatime,nofail,x-systemd.device-timeout=60s 0 0" |
    sudo tee -a /etc/fstab >/dev/null
  sudo systemctl daemon-reload
  sudo mount "$STORAGE_ROOT"

  info "Monthly scrub"
  install_unit btrfs-scrub-storage.service
  install_unit btrfs-scrub-storage.timer
  sudo systemctl daemon-reload
  sudo systemctl enable --now btrfs-scrub-storage.timer

  sudo btrfs filesystem usage -T "$STORAGE_ROOT"
}

cmd_stack() {
  [ -f .env ] || die ".env missing: cp .env.example .env and fill it in"
  local var
  for var in WIREGUARD_PRIVATE_KEY IMMICH_DB_PASSWORD SAMBA_USER SAMBA_PASSWORD MEDIA_ROOT IMMICH_UPLOAD_LOCATION FILES_ROOT; do
    [ -n "${!var:-}" ] || die "$var is empty in .env"
  done
  mountpoint -q "$STORAGE_ROOT" || die "DAS not mounted at $STORAGE_ROOT: run ./install.sh das first"
  for var in MEDIA_ROOT IMMICH_UPLOAD_LOCATION FILES_ROOT; do
    case ${!var} in
      "$STORAGE_ROOT"/*) ;;
      *) die "$var=${!var} is not on the DAS ($STORAGE_ROOT/...)" ;;
    esac
  done
  command -v podman-compose >/dev/null || die "podman-compose missing: run ./install.sh host first"

  info "Creating folders"
  # Podman won't create missing bind-mount sources, unlike Docker.
  install -d "$CONFIG_ROOT"/{gluetun,qbittorrent,prowlarr,radarr,sonarr,jellyfin,navidrome} \
    "$CONFIG_ROOT"/immich/postgres "$CONFIG_ROOT"/audiobookshelf/{config,metadata}
  sudo install -d -o "$PUID" -g "$PGID" \
    "$MEDIA_ROOT"/torrents "$MEDIA_ROOT"/media/{movies,tv,music,audiobooks,podcasts} \
    "$IMMICH_UPLOAD_LOCATION" "$FILES_ROOT"

  info "Pulling images"
  cmd_compose pull

  info "Boot service"
  install_unit media-stack.service
  sudo systemctl daemon-reload
  sudo systemctl enable media-stack.service
  sudo systemctl restart media-stack.service

  local host
  host=$(hostname)
  cat <<EOF

Started. First-time setup for each app is in README.md. Addresses:
  qBittorrent     http://$host:8080
  Prowlarr        http://$host:9696
  Radarr          http://$host:7878
  Sonarr          http://$host:8989
  Jellyfin        http://$host:8096
  Immich          http://$host:2283
  Navidrome       http://$host:4533
  Audiobookshelf  http://$host:13378
  Samba           \\\\$host\\media and \\\\$host\\files
Next: ./install.sh verify
EOF
}

cmd_verify() {
  sudo podman ps --format '{{.Names}}\t{{.Status}}'
  echo
  report "Gluetun healthy" sh -c "sudo podman inspect -f '{{.State.Health.Status}}' gluetun | grep -qx healthy"

  local vpn_ip home_ip
  vpn_ip=$(sudo podman exec gluetun wget -qO- https://ipinfo.io/ip 2>/dev/null || true)
  home_ip=$(curl -fsS --max-time 10 https://ipinfo.io/ip 2>/dev/null || true)
  report "torrent traffic leaves via the VPN ($vpn_ip, home is $home_ip)" \
    differs "$vpn_ip" "$home_ip"

  report "Jellyfin can see the GPU" sudo podman exec jellyfin nvidia-smi

  local name port
  while read -r name port; do
    report "$name answers on :$port" curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$port/"
  done <<'EOF'
qBittorrent 8080
FlareSolverr 8191
Prowlarr 9696
Radarr 7878
Sonarr 8989
Jellyfin 8096
Immich 2283
Navidrome 4533
Audiobookshelf 13378
EOF
  report "Samba listening on :445" timeout 3 bash -c '</dev/tcp/127.0.0.1/445'
}

cmd_compose() {
  local pc
  pc=$(command -v podman-compose) || die "podman-compose missing: run ./install.sh host first"
  sudo "$pc" "$@"
}

[ $# -ge 1 ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d'; exit 1; }
sub=$1; shift
case $sub in
  check|host|das|stack|verify|compose) "cmd_$sub" "$@" ;;
  *) die "unknown subcommand: $sub (try: check host das stack verify compose)" ;;
esac
