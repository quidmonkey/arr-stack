# arr-stack

My media stack on Nautilus (Bazzite, rootful Podman): Gluetun (ProtonVPN) + qBittorrent, Prowlarr, FlareSolverr, Radarr, Sonarr, Jellyfin (NVENC), Immich, Navidrome, Audiobookshelf and Samba. It's all one compose file, run with `podman-compose` and started on boot by `media-stack.service`.

To set up a new machine, follow [INSTALL.md](INSTALL.md). `./install.sh check` shows what's done.

AdGuard Home used to live here. It now runs on the Firebat; see that repo's `adguard/` folder and the "AdGuard Home (network DNS)" section of its implementation plan.

| App | Port | Data |
|---|---|---|
| qBittorrent (via Gluetun) | 8080 | `$MEDIA_ROOT/torrents` |
| Prowlarr | 9696 | |
| FlareSolverr | 8191 | |
| Radarr / Sonarr | 7878 / 8989 | `$MEDIA_ROOT` |
| Jellyfin | 8096 | `$MEDIA_ROOT/media` |
| Immich | 2283 | `$IMMICH_UPLOAD_LOCATION` |
| Navidrome | 4533 | `$MEDIA_ROOT/media/music` |
| Audiobookshelf | 13378 | `$MEDIA_ROOT/media/{audiobooks,podcasts}` |
| Samba | 445 | `\\nautilus\media`, `\\nautilus\files` |

## One-time app setup

This is app state, not stored in this repo.

- **Prowlarr** (`:9696`): add indexers, add FlareSolverr as an indexer proxy (`http://flaresolverr:8191/`), and connect Radarr/Sonarr as apps.
- **Radarr/Sonarr** (`:7878` / `:8989`): add root folders under `/data`, and add qBittorrent as a download client (host `gluetun`, port `8080`). On the qBittorrent client, leave **Remove Completed** on (Settings > Download Clients), so finished torrents are cleaned up after import.
- **qBittorrent** (`:8080`): enable "Bypass authentication for clients on localhost" in WebUI settings, so `port-sync.sh` can push the forwarded VPN port automatically. Also set:
  - Options > Downloads: **untick "Keep incomplete torrents in"**, and set Default Save Path to `/data/torrents`. (With the temp path on, removed or stalled torrents leave full-size files stranded in `torrents/incomplete`, where Sonarr/Radarr never import them. This once ate ~240G.)
  - Options > BitTorrent: set a seeding limit (ratio/time) with action **Remove torrent**, so finished torrents don't accumulate.
- **Jellyfin** (`:8096`): run the setup wizard and add `/data/media` as a library. Then Dashboard > Playback > Transcoding > Hardware acceleration: **NVIDIA NVENC**.
- **Immich, Navidrome, Audiobookshelf, Samba:** see INSTALL.md section 8.

## Day to day

- Everything runs as root under Podman, so plain `podman ps` (as your user) shows nothing. Use `./install.sh compose ps`, `./install.sh compose logs -f <service>`, or `sudo podman ...`.
- Start/stop everything: `sudo systemctl start|stop|restart media-stack`.
- Update images: `./install.sh compose pull && sudo systemctl restart media-stack`. Immich is pinned with `IMMICH_VERSION`; bump it on purpose (see INSTALL.md, "Updating").
- `./install.sh verify` checks that torrent traffic leaves through the VPN, that Jellyfin can see the GPU, and that every app answers.

## A couple of things worth knowing

- `config/` and `data/` are gitignored except for `.gitkeep`s and `port-sync.sh`. Everything else in there is per-machine app state (databases, caches, downloaded media), not setup worth versioning.
- `port-sync.sh` is what Gluetun calls whenever ProtonVPN hands out a new forwarded port. It pushes that port into qBittorrent so seeding keeps working after a VPN reconnect.
- Keep `MEDIA_ROOT` on a single filesystem. Sonarr/Radarr import by hardlink from `torrents/` into `media/`, so a seeding file costs no extra space. Splitting them across disks turns every import into a full copy. On Nautilus it's all on the DAS (`/var/mnt/storage`).
- If the DAS fills up, check `du -h --max-depth=2 $MEDIA_ROOT/torrents | sort -rh | head` first. Files with a hardlink count of 1 (`find torrents -type f -links 1`) were never imported.
- `podman-compose`, not `docker-compose`: `docker-compose` talking to Podman silently drops the CDI device that gives Jellyfin the GPU.
- SELinux is enforcing on Bazzite. Bind mounts of our own folders carry `:z` in `docker-compose.yml`. If a new container gets "permission denied" on a mounted folder, a missing `:z` is the first thing to check. Don't add `:z` to system paths like `/etc/localtime`, and don't turn SELinux off.
- If the DAS isn't mounted, `media-stack.service` doesn't start, so nothing gets written to the NVMe by mistake. Check with `mountpoint /var/mnt/storage` and `sudo btrfs device stats /var/mnt/storage`.
- The qBittorrent WebUI is reachable only from the subnets in `LAN_SUBNET` (Gluetun's firewall). It includes the tailnet's `100.64.0.0/10` so it also works over Tailscale.
