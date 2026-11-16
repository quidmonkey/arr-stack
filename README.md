# arr-stack

My media stack: Gluetun (ProtonVPN) + qBittorrent, Prowlarr, FlareSolverr, Radarr, Sonarr, Jellyfin, and AdGuard Home, all wired together with Compose.

## Bringing it up on a new machine

1. Install Docker + the Compose plugin.
2. `cp .env.example .env` and fill it in:
   - `WIREGUARD_PRIVATE_KEY` — ProtonVPN account > Downloads > WireGuard configuration.
   - `LAN_SUBNET` — your local subnet, so the qBittorrent WebUI only stays reachable from LAN.
   - `MEDIA_ROOT` — where movies/shows/torrents live. Point this at an existing library if you have one; otherwise `./data` works fine.
   - `CONFIG_ROOT` — where per-app state lives (databases, `AdGuardHome.yaml`, ...). Defaults to `./config`. On the current mini PC it's `/home/quidmonkey/config`, outside the repo.
   - `JELLYFIN_URL` — the LAN address clients will use to reach Jellyfin.
3. `docker compose up -d`
4. One-time setup per machine (this is app state, not stored in this repo):
   - **Prowlarr** (`:9696`) — add indexers, add FlareSolverr as an indexer proxy (`http://flaresolverr:8191/`), connect Radarr/Sonarr as apps.
   - **Radarr/Sonarr** (`:7878` / `:8989`) — add root folders under `/data`, add qBittorrent as a download client (host `gluetun`, port `8080`). On the qBittorrent client, leave **Remove Completed** on (Settings > Download Clients), so finished torrents are cleaned up after import.
   - **qBittorrent** (`:8080`) — enable "Bypass authentication for clients on localhost" in WebUI settings, so `port-sync.sh` can push the forwarded VPN port automatically. Also set:
     - Options > Downloads: **untick "Keep incomplete torrents in"**, and set Default Save Path to `/data/torrents`. (With the temp path on, removed or stalled torrents leave full-size files stranded in `torrents/incomplete`, where Sonarr/Radarr never import them. This once ate ~240G.)
     - Options > BitTorrent: set a seeding limit (ratio/time) with action **Remove torrent**, so finished torrents don't accumulate.
   - **Jellyfin** (`:8096`) — run the setup wizard, add `/data/media` as a library.
   - **AdGuard Home** — setup wizard on `:3000`, admin UI after that on `:8081`. Needs port 53 free on the host (stop `systemd-resolved`'s stub listener if it's holding it).

## A couple of things worth knowing

- `config/` and `data/` are gitignored except for `.gitkeep`s and `port-sync.sh` — everything else in there is per-machine app state (databases, caches, downloaded media), not setup worth versioning.
- `port-sync.sh` is what Gluetun calls whenever ProtonVPN hands out a new forwarded port; it pushes that port into qBittorrent so seeding keeps working after a VPN reconnect.
- Keep `MEDIA_ROOT` on a single filesystem. Sonarr/Radarr import by hardlink from `torrents/` into `media/`, so a seeding file costs no extra space. Splitting them across disks turns every import into a full copy.
- If the disk fills up, check `du -h --max-depth=2 $MEDIA_ROOT/torrents | sort -rh | head` first. Files with a hardlink count of 1 (`find torrents -type f -links 1`) were never imported.
- Jellyfin mounts `/dev/dri` for hardware transcoding, assuming an Intel/AMD iGPU. Drop that line from `docker-compose.yml` on a machine without one.

## AdGuard Home as the network's DNS

AdGuard's settings live in `$CONFIG_ROOT/adguard/conf/AdGuardHome.yaml`, which is not committed (it holds the admin password hash). What it's set to, so it can be rebuilt:

- **Upstream DNS:** `https://dns10.quad9.net/dns-query`, bootstrap `9.9.9.10` / `149.112.112.10`.
- **Blocklists** (Filters > DNS blocklists): AdGuard DNS filter, and HaGeZi's Pro Blocklist (`https://adguardteam.github.io/HostlistsRegistry/assets/filter_48.txt`). No custom rules.
- **Updating:** `docker compose pull adguardhome && docker compose up -d adguardhome`. `latest` is not re-pulled on its own. DNS for the whole network is down for ~10s while it restarts.
- **Editing the yaml by hand:** stop the container first, and write to a new file and check it before swapping it in. AdGuard treats an empty or unreadable config as a fresh install, comes up in the setup wizard, and stops answering DNS.

Router setup (ASUS):

- Give the AdGuard host a fixed IP: LAN > DHCP Server > Manually Assigned IP.
- Hand AdGuard out to clients directly: LAN > DHCP Server > **DNS Server 1** = AdGuard host IP, **DNS Server 2** blank, "Advertise router's IP in addition to user-specified DNS" = No. Clients then show up individually in AdGuard instead of all as the router.
- Don't list a public resolver next to AdGuard anywhere clients can see it. Routers and clients treat multiple DNS servers as interchangeable, so after any AdGuard restart traffic drifts to the public one and quietly stops being filtered. (In Sept 2026 this cut the block rate from ~20% to ~1% for two months.)
- If you use LAN > DNS Director to force clients onto AdGuard, add the AdGuard host's MAC as a "No Redirection" exception first. Otherwise its own upstream lookups get redirected back to itself and DNS breaks for the whole network.

What DNS blocking can't do:

- iPhones with iCloud Private Relay skip local DNS in Safari. Turn off Settings > Wi-Fi > (i) > **Limit IP Address Tracking** for the home network.
- Ads a site serves from its own domain or from shared CDNs (e.g. NeoGAF's banners) can't be blocked by domain. Use an in-browser blocker for those: DuckDuckGo browser, or a Safari content blocker (AdGuard, Wipr, 1Blocker).

## Running it as a systemd service (optional)

`docker-compose-app.service.example` is what I use to bring the stack up on boot. Copy it to `/etc/systemd/system/docker-compose-app.service`, set `WorkingDirectory` to this repo's directory and fix `User`/`Group` for the new machine, then:

```
sudo systemctl daemon-reload
sudo systemctl enable --now docker-compose-app.service
```
