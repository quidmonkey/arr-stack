# arr-stack

My media stack: Gluetun (ProtonVPN) + qBittorrent, Prowlarr, FlareSolverr, Radarr, Sonarr, Jellyfin, and AdGuard Home, all wired together with Compose.

## Bringing it up on a new machine

1. Install Docker + the Compose plugin.
2. `cp .env.example .env` and fill it in:
   - `WIREGUARD_PRIVATE_KEY` — ProtonVPN account > Downloads > WireGuard configuration.
   - `LAN_SUBNET` — your local subnet, so the qBittorrent WebUI only stays reachable from LAN.
   - `MEDIA_ROOT` — where movies/shows/torrents live. Point this at an existing library if you have one; otherwise `./data` works fine.
   - `JELLYFIN_URL` — the LAN address clients will use to reach Jellyfin.
3. `docker compose up -d`
4. One-time setup per machine (this is app state, not stored in this repo):
   - **Prowlarr** (`:9696`) — add indexers, add FlareSolverr as an indexer proxy (`http://flaresolverr:8191/`), connect Radarr/Sonarr as apps.
   - **Radarr/Sonarr** (`:7878` / `:8989`) — add root folders under `/data`, add qBittorrent as a download client (host `gluetun`, port `8080`).
   - **qBittorrent** (`:8080`) — enable "Bypass authentication for clients on localhost" in WebUI settings, so `port-sync.sh` can push the forwarded VPN port automatically.
   - **Jellyfin** (`:8096`) — run the setup wizard, add `/data/media` as a library.
   - **AdGuard Home** — setup wizard on `:3000`, admin UI after that on `:8081`. Needs port 53 free on the host (stop `systemd-resolved`'s stub listener if it's holding it).

## A couple of things worth knowing

- `config/` and `data/` are gitignored except for `.gitkeep`s and `port-sync.sh` — everything else in there is per-machine app state (databases, caches, downloaded media), not setup worth versioning.
- `port-sync.sh` is what Gluetun calls whenever ProtonVPN hands out a new forwarded port; it pushes that port into qBittorrent so seeding keeps working after a VPN reconnect.
- Jellyfin mounts `/dev/dri` for hardware transcoding, assuming an Intel/AMD iGPU. Drop that line from `docker-compose.yml` on a machine without one.

## Running it as a systemd service (optional)

`docker-compose-app.service.example` is what I use to bring the stack up on boot. Copy it to `/etc/systemd/system/docker-compose-app.service`, fix `WorkingDirectory` and `User`/`Group` for the new machine, then:

```
sudo systemctl daemon-reload
sudo systemctl enable --now docker-compose-app.service
```
