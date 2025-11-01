# Ente Self-Hosted Setup (Fedora 42)

## Configure client (remote account setup)
- (Assumes server is setup and accessible via local network)
- Download app of choice [here](https://ente.io/download/)
- Figure out <ente-server-ip> value (obtain from server or wifi router)
- Open desktop/mobile app (or web at http://<ente-server-ip>:3000)
- Add server endpoint:
  - Click icon 7 times to enter developer mode
  - Set server endpoint to: `http://<ente-server-ip>:8080`
- Login and use as usual (registering new user requires extra steps below)
- Whenever the server changes (ip address, or restoration), reinstall app (or at least remove cache in desktop)

## Server/Initial Setup

Prerequisites:
- Fedora 42, make SSH connectable
- Podman Compose: `sudo dnf install podman-compose`

### 1. Spin up servers

```bash
# Override if needed
export ENTE_INSTANCE_ROOT_DIR="$(pwd)"
export PODMAN_ENTE_SCRIPT_PATH="$(pwd)/podman-ente.sh"

# Setup
$PODMAN_ENTE_SCRIPT_PATH -y setup $ENTE_INSTANCE_ROOT_DIR
```

### 2. Configure client (account setup)
- Open desktop app (or web at http://localhost:3000)
- Add server endpoint:
  - Desktop: Click icon 7 times to enter developer mode
  - Set server endpoint to: `http://localhost:8080` (or your IP)
- Register user:
  - Get verification code from logs:
    ```bash
    cd $ENTE_INSTANCE_ROOT_DIR/my-ente && \
      podman-compose logs museum 2>&1 | \
      grep -o 'Verification code: [0-9]*' | tail -1 | cut -d' ' -f3
    ```
- Set storage capacity (sets ALL users to 1.5TB):
  ```bash
  podman exec my-ente_postgres_1 psql \
     -U pguser -d ente_db \
     -c "UPDATE subscriptions SET storage = 1649267442000;"
  ```
- Enable desktop features:
  - Settings → Preferences → Streamable videos
  - Settings → Preferences → Machine learning
  - Settings → Preferences → Map

### 3. Autostart (upon boot)

```bash
# Create systemd service file
# NOTE: Replace /storage/my-ente with your actual instance path

# 1. Enable lingering (for SSH logout survival)
sudo loginctl enable-linger e

# 2. Update the system service to ensure it starts at boot
sudo tee /etc/systemd/system/ente.service > /dev/null <<'EOF'
[Unit]
Description=Ente Self-Hosted
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/bin/podman-compose -f /storage/my-ente/compose.yaml up -d
ExecStop=/usr/bin/podman-compose -f /storage/my-ente/compose.yaml down
Restart=on-failure
RestartSec=10
User=e
Group=e
WorkingDirectory=/storage/my-ente
Environment=HOME=/home/e
Environment=USER=e
Environment=XDG_RUNTIME_DIR=/run/user/1000

# Wait for network to be truly ready
ExecStartPre=/bin/sleep 10

[Install]
WantedBy=multi-user.target
EOF

# 3. Enable the service to start at boot
sudo systemctl daemon-reload
sudo systemctl enable ente.service

# 4. Start the service now
sudo systemctl restart ente.service

# 5. Verify it's working
sudo systemctl status ente.service
podman-compose ps

# To disable/remove autostart later:
# sudo systemctl stop ente.service
# sudo systemctl disable ente.service
# sudo rm /etc/systemd/system/ente.service
# systemctl daemon-reload
```

### 4. Prevent Server Sleeping

```
# Create the logind.conf to prevent sleep
sudo mkdir -p /etc/systemd
sudo tee /etc/systemd/logind.conf > /dev/null << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
IdleAction=ignore
PowerKeyIgnoreInhibited=yes
SuspendKeyIgnoreInhibited=yes
HibernateKeyIgnoreInhibited=yes
LidSwitchIgnoreInhibited=yes
EOF

# Restart logind
sudo systemctl restart systemd-logind

# Also mask sleep targets for extra protection
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

### 5. Backup + Restore (ensure autostart removed if moving dir)

```bash
# Setup paths
export PODMAN_ENTE_SCRIPT_PATH="$(pwd)/podman-ente.sh"
export ENTE_BACKUP_DIR="$(pwd)/backup_ente_instance"
export RESTORE_DIR="$(pwd)/restored"

# Backup existing instance
$PODMAN_ENTE_SCRIPT_PATH backup $ENTE_BACKUP_DIR

# Restore to new location (creates / inside target)
$PODMAN_ENTE_SCRIPT_PATH restore $ENTE_BACKUP_DIR $RESTORE_DIR
$PODMAN_ENTE_SCRIPT_PATH -y setup $RESTORE_DIR
```


## Developers/Troubleshooting notes

### Notes:
- Service Endpoints
  - **Photos Web App**: `http://<local-ip-or-localhost>:3000`
  - **Museum API**: `http://<local-ip-or-localhost>:8080`
  - **Public Albums**: `http://<local-ip-or-localhost>:3002`
  - **MinIO Storage**: `http://<local-ip-or-localhost>:3200`
- Advantages of using desktop/mobile app:
  - no file size limitations in thumbnail generation (100 MB, 30s timeout)
  - has ML (facial recognition)
  - has map (geolocation)
- Folder uploads can't handle nested folders (only one level deep)
- No support for HEVC Support (need to tick streamable videos to render mov to mp4 in backend)
- Make sure to enable "stremable videos" in desktop/mobile app (it also takes time to process so wait...)
- Backups include:
  - `postgres-data/` - Database
  - `minio-data/` - Object storage (photos, videos)
  - `data/` - Configuration data
  - `compose.yaml` - Container configuration
  - `museum.yaml` - Museum API configuration

### Future features:
- Add Tagging capability
- Backend stroage "folder" structure (currently its a dump, but indexed by db)
- Bulk download/editting (e.g. property updates)


### Desktop App Setup (Fedora Linux)
- In exploration various codecs libraries were installed
- But later on it seemed like these were not required
- Untested installation notes below (good for file browser preview of media):
  ```bash
  # Enable RPM Fusion repositories
  sudo dnf install https://download1.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm
  sudo dnf install https://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

  # Install GStreamer plugins and HEVC codecs
  sudo dnf install \
      gstreamer1-plugins-bad-freeworld \
      gstreamer1-plugins-ugly \
      gstreamer1-plugins-bad-free \
      gstreamer1-plugins-bad-free-extras \
      gstreamer1-plugin-openh264 \
      mozjs115 \
      libde265 \
      librtmp \
      svt-hevc-libs \
      x264-libs \
      x265-libs
  ```

### Desktop App Troubleshoot
- If Ente linux desktop app freezes:
  ```
  pkill -9 ente
  rm -rf ~/.config/ente
  rm -rf ~/.cache/ente-updater/*
  ```
- If Ente mobile app freezes, uninstall/install app
- Will have to setup the app again
