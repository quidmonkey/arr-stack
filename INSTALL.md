# Installing on Nautilus (Bazzite)

This turns Nautilus (Ryzen 7 5800X3D, RTX 4070 Ti, ASUS TUF Gaming X570-Plus) into the one box for gaming, game streaming and media. It streams games with Steam, Sunshine/Moonlight and Steam Remote Play. It serves the Arr stack behind ProtonVPN, Jellyfin with NVENC, Immich (machine learning on the CPU), Navidrome, Audiobookshelf and Samba. Everything is stored on a TerraMaster D4-320 DAS formatted as btrfs RAID1, and it's reachable from outside the house over Tailscale, with SSH for admin.

AdGuard Home isn't here. It moves to the Firebat (see that repo's `next-steps.md` item 15). Do that before retiring the Intel Mini, because the Mini is the network's DNS until then.

The order: the BIOS is already done; you do the Bazzite install, the clone, and installing Claude. Then you start Claude in this repo and ask it to follow this file. Steps marked **(you)** need a person: a screen, a password, a login in a browser, or a decision. Claude should stop and ask at each one. Everything else is `./install.sh`, which is safe to re-run. `./install.sh check` shows what's done at any point.

## 1. BIOS (done 2026-11-21)

Nothing to do here. These settings are listed so they can be put back if the BIOS is ever reset (press **Del** at boot, then **F7** for Advanced Mode):

- Ai Tweaker > Ai Overclock Tuner: **D.O.C.P.**, DDR4-3200 profile. RAM in slots **A2 and B2** (second and fourth from the CPU) for dual-channel.
- Advanced > APM Configuration > **Restore AC Power Loss: Power On**, so the server comes back by itself after a power cut.
- Advanced > APM Configuration > **ErP Ready: Disabled**, or the power-loss setting doesn't work.
- Boot > Secure Boot can stay on. Bazzite asks you to enroll its key on first boot (next section).

## 2. Install Bazzite (you)

1. On [bazzite.gg](https://bazzite.gg), pick: Desktop, NVIDIA (RTX 16xx and newer), KDE Plasma, and **no** Steam Gaming Mode. You get a normal KDE desktop. The Gaming Mode images boot into a Steam session that the Sunshine Flatpak can't capture. Steam's Big Picture mode is still there whenever you want the couch interface.
2. Write the ISO to a USB stick, boot it, and install to the NVMe (erase the whole disk).
3. With Secure Boot on, the first boot shows a blue MOK screen: **Enroll MOK > Continue > Yes**, password `universalblue`. That's Bazzite's documented default for this screen, not a password you choose.
4. Create your user. Then set the hostname, so `nautilus` works on the LAN and the tailnet: `sudo hostnamectl hostname nautilus`.
5. Router: give Nautilus a fixed IP (LAN > DHCP Server > Manually Assigned IP).
6. **Auto-login:** System Settings > Colors & Themes > Login Screen (SDDM) > Behavior > automatically log in as your user. Sunshine and KDE's remote desktop run inside your desktop session. Without auto-login, nothing can stream after a reboot until someone signs in at the TV.

## 3. Clone, configure, start Claude (you)

```
git clone -b nautilus <this repo's URL> ~/arr-stack
cd ~/arr-stack
cp .env.example .env
```

Fill in `.env` yourself, since it holds secrets: the ProtonVPN WireGuard key, an Immich database password (`openssl rand -hex 24`), and a Samba username and password. Set `PUID`/`PGID` to what `id` prints (1000 for the first user), and set `JELLYFIN_URL` to Nautilus's fixed IP.

Install Claude Code and start it here:

```
curl -fsSL https://claude.ai/install.sh | bash
claude
```

Then ask it to follow INSTALL.md from section 4.

## 4. Host setup

```
./install.sh check
./install.sh host
```

`host` installs `podman-compose` with Homebrew (built into Bazzite) and generates the NVIDIA device spec that lets Jellyfin use the GPU. It also turns off sleep, opens the firewall for Sunshine, Steam Remote Play and SSH, trusts the tailnet interface, and enables `sshd` and `tailscaled`.

**NVIDIA container toolkit.** `host` stops if `nvidia-ctk` is missing. Check with `rpm -q nvidia-container-toolkit nvidia-container-toolkit-base`. If neither is installed, it has to be added to the OS image with `rpm-ostree install`, followed by a reboot. **Ask the user before doing that (you):** a layered package makes every Bazzite update slower, and it can block updates until the package catches up.

**Then (you):**
- `sudo tailscale up --ssh` and open the login link it prints.
- From your other computers: `ssh-copy-id <user>@nautilus`. Then run `./install.sh host` again, which switches SSH to key-only. Until a key is in place it leaves password login on, so you can't lock yourself out.

## 5. The DAS

Plug the D4-320 into the **rear USB-C port**. It's the board's 10 Gbps port. Use CMR drives (WD Red Plus, IronWolf, Exos), not SMR.

Find the disks by their stable names. The model and serial numbers are part of each name:

```
ls -l /dev/disk/by-id/ | grep -v part
```

**(you)** Confirm which disks to format. `das` erases them. Claude must show the list and wait for the user to name the disks. It must never guess, and never pick the NVMe.

```
./install.sh das /dev/disk/by-id/usb-AAA /dev/disk/by-id/usb-BBB [...]
```

It shows the disks again and asks you to type `ERASE`. It formats them as one btrfs RAID1 filesystem (every block on two disks; set `DAS_PROFILE=raid10` for four), mounts it at `/var/mnt/storage`, and sets up a monthly scrub. RAID1 survives one failed disk. It isn't a backup: photos need a second copy somewhere else.

**Soak test before trusting it.** Copy 100 GB or more onto it, then check the kernel log:

```
journalctl -k | grep -iE 'uas|reset|I/O error'
```

A couple of D4-320 owners have seen USB resets with the fast UAS driver. If they show up, the fix is a kernel argument that switches this enclosure to the slower usb-storage driver. Get the ID from `lsusb` and ask the user first, since it costs a lot of speed.

If one disk dies, the filesystem won't mount on its own (btrfs needs the `degraded` option), so the stack won't start. That's deliberate: nothing gets written to the NVMe by mistake. Replace the disk with `btrfs replace`.

## 6. Start the stack

```
./install.sh stack
./install.sh verify
```

`stack` creates the folders, pulls the images, and installs `media-stack.service`, which starts everything on boot once the DAS is mounted. `verify` checks four things: Gluetun is healthy, torrent traffic leaves through the VPN (not the home IP), Jellyfin can see the GPU, and every web UI and Samba answer.

Everything runs as root under Podman. For anything else, use `./install.sh compose ...`, for example `./install.sh compose logs -f gluetun` or `./install.sh compose pull`.

## 7. Moving data over from the Intel Mini

Do this before the Mini is wiped. Run these on Nautilus with the stack stopped (`sudo systemctl stop media-stack`), then start it again.

- **Media and torrents**, keeping hardlinks (`-H`), or every seeding file doubles in size:
  `rsync -aH --info=progress2 <user>@<mini>:/path/to/data/ /var/mnt/storage/data/`
- **App settings:** copy the Mini's `$CONFIG_ROOT` folders for `prowlarr`, `radarr`, `sonarr`, `qbittorrent` and `jellyfin` into `./config/` here. The paths inside the containers (`/data/...`) are the same, so libraries and root folders keep working.
- **Jellyfin:** the Mini used Intel QuickSync. Switch it to NVENC: Dashboard > Playback > Transcoding > Hardware acceleration: **NVIDIA NVENC**.

## 8. First-time app setup (you)

The Arr apps and Jellyfin are covered in README.md. The new apps:

- **Immich** (`:2283`): create the admin account. On phones, install the Immich app with the server `http://nautilus:2283` and turn on backup.
- **Navidrome** (`:4533`): create the admin account. Music goes in `\\nautilus\media\music`. Any Subsonic app works (Symfonium, Substreamer, Feishin).
- **Audiobookshelf** (`:13378`): create the admin account, then add libraries at `/audiobooks` and `/podcasts`. Files go in `\\nautilus\media\audiobooks`.
- **Samba:** `\\nautilus\media` and `\\nautilus\files` on Windows, or `smb://nautilus/media` elsewhere. It works over Tailscale too.

## 9. Streaming (you)

- **Sunshine:** install it from **Bazzite Portal** (the Flatpak), then pair Moonlight on each device through the web UI at `https://localhost:47990`. It captures the KDE desktop through the screen-sharing portal. KDE may ask once for permission to share the screen; allow it and choose to remember the choice.
- **Power use:** in Sunshine's web UI > Configuration > General > Command Preparations, add a command that runs at stream start and one that runs at stream end. Bazzite ships `powerprofilesctl`, so use `powerprofilesctl set performance` to start and `powerprofilesctl set balanced` to end. Check that it exists first with `powerprofilesctl list`.
- **Steam Remote Play / Steam Link:** Steam > Settings > Remote Play > enable. Steam Link apps find it on the LAN. Away from home, Moonlight over Tailscale is better than Steam's own relay.
- **Over Tailscale:** Moonlight is only smooth on a direct connection. If `tailscale ping <phone>` says "via DERP", traffic is going through Tailscale's relay servers, and streaming will stutter.

## Remote access

- **SSH:** `ssh <user>@nautilus` on the LAN. Over the tailnet, Tailscale SSH (`tailscale up --ssh` above) works even if `sshd` is down.
- **Remote desktop:** I'd use Moonlight. It's already set up and gives you the full desktop with low latency. For a plain RDP client (Windows' Remote Desktop app, for instance), KDE has its own RDP server: System Settings > **Remote Desktop**. Set a username and password there and connect to `nautilus:3389`. Not every Fedora-based image ships that settings page. If it's missing, use Moonlight. Both need a logged-in desktop session, which is why section 2 turns on auto-login.

## Updating

- **Bazzite** downloads updates in the background and applies them on the next reboot, which you choose. If an update breaks something, pick the previous version in the boot menu, or run `rpm-ostree rollback`. `nvidia-cdi-generate.service` rebuilds the GPU spec every boot, so new drivers don't break Jellyfin.
- **Containers:** `./install.sh compose pull && sudo systemctl restart media-stack`.
- **Immich** is pinned (`IMMICH_VERSION`). Read the release notes before changing it, and check the release's compose file for changed database or Redis images.
