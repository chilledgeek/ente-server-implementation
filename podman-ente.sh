#!/bin/sh
#
# Ente self-host helper script (Podman version).
#
# Usage:
#   ./podman-ente.sh setup [target-dir]                    # Create new instance
#   ./podman-ente.sh -y setup [target-dir]                 # Non-interactive setup (skip prompts)
#   ./podman-ente.sh backup <absolute-backup-path>        # Backup existing instance
#   ./podman-ente.sh restore <absolute-backup-path> [target-dir] # Restore from backup
#   ./podman-ente.sh create-buckets                        # Create MinIO buckets for existing instance

set -e

# =============================================================================
# CONFIGURATION BLOCK - Customize these settings as needed
# =============================================================================

# Instance configuration
INSTANCE_NAME="my-ente"                    # Directory name for the instance
BACKUP_PREFIX="ente-backup"                # Prefix for backup directories

# Port configuration
API_PORT="8080"                            # Museum API port
WEB_PORT_PHOTOS="3000"                     # Photos web app port
WEB_PORT_ALBUMS="3002"                     # Public albums port
MINIO_PORT="3200"                          # MinIO API port
MINIO_CONSOLE_PORT="3201"                  # MinIO Web UI port (optional)

# Database configuration
POSTGRES_USER="pguser"                     # PostgreSQL username
POSTGRES_DB="ente_db"                      # PostgreSQL database name

# MinIO configuration
MINIO_USER_PREFIX="minio-user"              # Prefix for MinIO username
MINIO_REGION="eu-central-2"                # MinIO region

# Security settings
PASSWORD_LENGTH="21"                       # Length for generated passwords
KEY_LENGTH="32"                            # Length for encryption keys
HASH_LENGTH="64"                           # Length for hash keys
USER_SUFFIX_LENGTH="6"                     # Length for user suffixes

# Directory permissions
DIR_PERMISSIONS="755"                      # Permissions for data directories

# CORS configuration
ENABLE_CORS="true"                         # Enable CORS headers
CORS_ALLOWED_ORIGINS="*"                   # Allowed origins (* for all, or comma-separated list)
CORS_ALLOWED_METHODS="GET,POST,PUT,DELETE,OPTIONS"  # Allowed HTTP methods
CORS_ALLOWED_HEADERS="Content-Type,Authorization,X-Requested-With"  # Allowed headers
# Note: For production, consider restricting CORS_ALLOWED_ORIGINS to specific domains
# Example: CORS_ALLOWED_ORIGINS="https://yourdomain.com,https://app.yourdomain.com"

# Network configuration
EXPOSE_TO_NETWORK="true"                   # Expose services to local network (not just localhost)
NETWORK_INTERFACE="0.0.0.0"               # Network interface to bind to (0.0.0.0 for all interfaces)
MINIO_ENDPOINT_AUTO="true"                # Automatically detect MinIO endpoint for network access
# Note: When EXPOSE_TO_NETWORK=true, services will be accessible from other devices on your network
# Example: http://192.168.1.100:3000 (replace with your machine's IP)
# When MINIO_ENDPOINT_AUTO=true, MinIO endpoint will be set to detected network IP for mobile app access

# Container image configuration (with locked versions)
MUSEUM_IMAGE="ghcr.io/ente-io/server:latest"      # Ente Museum API server (update manually)
WEB_IMAGE="ghcr.io/ente-io/web:latest"            # Ente Web frontend (update manually)
POSTGRES_IMAGE="docker.io/library/postgres:15"    # PostgreSQL database (major.minor)
MINIO_IMAGE="docker.io/minio/minio:latest"         # MinIO object storage (update manually)
SOCAT_IMAGE="docker.io/alpine/socat:latest"       # Socat for networking (update manually)
# Note: Locked versions prevent breaking changes from automatic updates
# For Ente images, check https://github.com/ente-io/ente/releases for specific versions
# For infrastructure images, use major.minor versions for security updates

# =============================================================================
# END CONFIGURATION BLOCK
# =============================================================================

# Helper function to validate absolute paths
validate_absolute_path() {
    local path="$1"
    local purpose="$2"
    
    if [ -z "$path" ]; then
        echo "ERROR: $purpose path is required."
        exit 1
    fi
    
    if [ "${path#/}" = "$path" ]; then
        echo "ERROR: $purpose path must be absolute (start with /)."
        echo "Provided: $path"
        echo "Example: /home/user/backups/ente-backup"
        exit 1
    fi
}

# Helper function to get target directory
get_target_dir() {
    local target_dir="$1"
    if [ -n "$target_dir" ]; then
        echo "$target_dir"
    else
        echo "$(pwd)"
    fi
}

# Helper function to get network binding
get_network_binding() {
    if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        echo "$NETWORK_INTERFACE"
    else
        echo "127.0.0.1"
    fi
}

# Helper function to get MinIO endpoint
get_minio_endpoint() {
    if [ "$MINIO_ENDPOINT_AUTO" = "true" ] && [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        # Try to get the actual IP address
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$ip" ]; then
            echo "$ip:$MINIO_PORT"
        else
            echo "localhost:$MINIO_PORT"
        fi
    else
        echo "localhost:$MINIO_PORT"
    fi
}

# Helper function to get network URLs
get_network_urls() {
    local binding=$(get_network_binding)
    if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        # Try to get the actual IP address
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$ip" ]; then
            echo "  Local access: http://localhost:$WEB_PORT_PHOTOS"
            echo "  Network access: http://$ip:$WEB_PORT_PHOTOS"
            echo "  Albums: http://$ip:$WEB_PORT_ALBUMS"
            echo "  API: http://$ip:$API_PORT"
        else
            echo "  Local access: http://localhost:$WEB_PORT_PHOTOS"
            echo "  Network access: http://$binding:$WEB_PORT_PHOTOS (check your machine's IP)"
        fi
    else
        echo "  Local access: http://localhost:$WEB_PORT_PHOTOS"
        echo "  Albums: http://localhost:$WEB_PORT_ALBUMS"
        echo "  API: http://localhost:$API_PORT"
    fi
}

# Helper function to wait for MinIO to be ready
wait_for_minio() {
    echo "Waiting for MinIO to be ready..."
    local max_attempts=60  # Increased to 2 minutes
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        # Check if MinIO API is responding by trying to set an alias with root credentials
        if podman compose exec minio mc alias set local http://localhost:3200 "${minio_user}" "${minio_pass}" >/dev/null 2>&1; then
            echo " ✓ MinIO is ready"
            return 0
        fi
        
        # Show progress every 5 attempts
        if [ $((attempt % 5)) -eq 0 ]; then
            echo "Attempt $attempt/$max_attempts: MinIO not ready yet, waiting..."
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "ERROR: MinIO failed to become ready after $max_attempts attempts (2 minutes)"
    echo "You can try running: ./podman-ente.sh create-buckets"
    return 1
}

# Helper function to wait for Museum API to be ready
wait_for_museum_api() {
    echo "Waiting for Museum API to be ready..."
    local max_attempts=60  # 2 minutes
    local attempt=1
    local api_url="http://localhost:${API_PORT}/ping"
    
    while [ $attempt -le $max_attempts ]; do
        # Check if Museum API is responding
        if curl -s -f "$api_url" >/dev/null 2>&1; then
            echo " ✓ Museum API is ready"
            return 0
        fi
        
        # Show progress every 5 attempts
        if [ $((attempt % 5)) -eq 0 ]; then
            echo "Attempt $attempt/$max_attempts: Museum API not ready yet, waiting..."
        fi
        sleep 2
        attempt=$((attempt + 1))
    done
    
    echo "ERROR: Museum API failed to become ready after $max_attempts attempts (2 minutes)"
    return 1
}

# Helper function to create MinIO buckets
create_minio_buckets() {
    echo "Creating MinIO buckets..."
    
    # Wait for MinIO to be ready
    if ! wait_for_minio; then
        echo "ERROR: Cannot create buckets - MinIO is not ready"
        return 1
    fi
    
    # Use internal container network for bucket creation (localhost:3200)
    echo "Setting up MinIO client..."
    podman compose exec minio mc alias set local http://localhost:3200 "${minio_user}" "${minio_pass}" || {
        echo "ERROR: Failed to set MinIO alias. Check MinIO credentials."
        return 1
    }
    
    # Create buckets with better error handling
    echo "Creating bucket: b2-eu-cen"
    podman compose exec minio mc mb local/b2-eu-cen || echo "Bucket b2-eu-cen may already exist"
    
    echo "Creating bucket: wasabi-eu-central-2-v3"
    podman compose exec minio mc mb local/wasabi-eu-central-2-v3 || echo "Bucket wasabi-eu-central-2-v3 may already exist"
    
    echo "Creating bucket: scw-eu-fr-v3"
    podman compose exec minio mc mb local/scw-eu-fr-v3 || echo "Bucket scw-eu-fr-v3 may already exist"
    
    # Verify buckets were created
    echo "Verifying buckets..."
    podman compose exec minio mc ls local/ || echo "Warning: Could not list buckets"
    
    echo " ✓ Created MinIO buckets for upload functionality"
}

# Handle create-buckets command
if [ "$1" = "create-buckets" ]; then
    if [ ! -d "$INSTANCE_NAME" ]; then
        echo "ERROR: No '$INSTANCE_NAME' directory found."
        echo "Run './podman-ente.sh setup' first to create an instance."
        exit 1
    fi
    
    cd "$INSTANCE_NAME"
    
    if [ ! -f "compose.yaml" ]; then
        echo "ERROR: No compose.yaml found in '$INSTANCE_NAME' directory."
        exit 1
    fi
    
    echo "Creating MinIO buckets for existing instance..."
    create_minio_buckets
    
    echo ""
    echo "You can now try uploading files again."
    exit 0
fi

# Handle backup/restore commands
if [ "$1" = "backup" ]; then
    if [ ! -d "$INSTANCE_NAME" ]; then
        echo "ERROR: No '$INSTANCE_NAME' directory found to backup."
        exit 1
    fi
    
    if [ -z "$2" ]; then
        echo "ERROR: Backup path is required."
        echo "Usage: $0 backup <absolute-backup-path>"
        echo "Example: $0 backup /home/user/backups/ente-backup-2024-12"
        exit 1
    fi
    
    validate_absolute_path "$2" "Backup"
    backup_name="$2"
    
    echo "Creating backup: $backup_name"
    
    # Stop services to ensure consistent data
    cd "$INSTANCE_NAME"
    echo "Stopping services for consistent backup..."
    podman compose down 2>/dev/null || true
    
    # Create backup directory (works with both relative and absolute paths)
    cd ..
    mkdir -p "$backup_name"
    
    # Backup essential data and config
    echo "Backing up data directories and config files..."
    # Use sudo for postgres-data as it requires elevated permissions
    sudo rsync -av "$INSTANCE_NAME/postgres-data/" "$backup_name/postgres-data/"
    rsync -av "$INSTANCE_NAME/minio-data/" "$backup_name/minio-data/"
    rsync -av "$INSTANCE_NAME/data/" "$backup_name/data/" 2>/dev/null || true
    cp "$INSTANCE_NAME/compose.yaml" "$backup_name/"
    cp "$INSTANCE_NAME/museum.yaml" "$backup_name/"
    
    echo " ✓ Backup created: $backup_name"
    echo " ✓ Backup includes: postgres-data, minio-data, data, compose.yaml, museum.yaml"
    echo " ✓ Full backup path: $(realpath "$backup_name")"
    exit 0
fi

if [ "$1" = "restore" ]; then
    if [ -z "$2" ]; then
        echo "ERROR: Please specify backup path."
        echo "Usage: $0 restore <absolute-backup-path> [target-dir]"
        echo "Example: $0 restore /home/user/backups/ente-backup-2024-12"
        echo "Example: $0 restore /home/user/backups/ente-backup-2024-12 /opt/ente"
        exit 1
    fi
    
    validate_absolute_path "$2" "Backup"
    backup_path="$2"
    
    if [ ! -d "$backup_path" ]; then
        echo "ERROR: Backup path '$backup_path' does not exist."
        echo "Full path checked: $(realpath "$backup_path" 2>/dev/null || echo "$backup_path")"
        exit 1
    fi
    
    # Get target directory (defaults to current directory)
    target_dir=$(get_target_dir "$3")
    instance_path="$target_dir/$INSTANCE_NAME"
    
    if [ -d "$instance_path" ]; then
        echo "ERROR: '$instance_path' directory already exists."
        echo "To restore, please remove the existing directory first:"
        echo "  rm -rf '$instance_path'"
        echo "Then run the restore command again."
        exit 1
    fi
    
    echo "Restoring from backup: $backup_path"
    echo "Full backup path: $(realpath "$backup_path")"
    echo "Target directory: $target_dir"
    echo "Instance will be created at: $instance_path"
    mkdir -p "$target_dir"
    cd "$target_dir"
    mkdir "$INSTANCE_NAME"
    cd "$INSTANCE_NAME"
    
    # Restore data directories
    echo "Restoring data directories..."
    mkdir -p postgres-data minio-data data
    # Use sudo for postgres-data as it requires elevated permissions
    sudo rsync -av "$backup_path/postgres-data/" postgres-data/
    rsync -av "$backup_path/minio-data/" minio-data/
    rsync -av "$backup_path/data/" data/ 2>/dev/null || true
    
    # Restore config files
    echo "Restoring config files..."
    cp "$backup_path/compose.yaml" .
    cp "$backup_path/museum.yaml" .
    
    # Set correct permissions (use sudo for postgres-data)
    sudo chmod "$DIR_PERMISSIONS" postgres-data 2>/dev/null || true
    chmod "$DIR_PERMISSIONS" minio-data data
    
    # Fix SELinux contexts for Podman/Fedora if applicable
    if command -v chcon >/dev/null 2>&1; then
        echo "Setting SELinux context for restored files..."
        sudo chcon -Rt svirt_sandbox_file_t postgres-data 2>/dev/null || true
        sudo chcon -Rt svirt_sandbox_file_t minio-data 2>/dev/null || true
        sudo chcon -Rt svirt_sandbox_file_t data 2>/dev/null || true
        sudo chcon -Rt svirt_sandbox_file_t compose.yaml 2>/dev/null || true
        sudo chcon -Rt svirt_sandbox_file_t museum.yaml 2>/dev/null || true
        echo " ✓ SELinux contexts set"
    fi
    
    echo " ✓ Restore completed"
    echo ""
    echo "Service endpoints (will be available after starting):"
    get_network_urls
    echo ""
    echo "📱 Mobile App Server Endpoint:"
    if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$ip" ]; then
            echo "  http://$ip:$API_PORT"
        else
            echo "  http://$NETWORK_INTERFACE:$API_PORT"
        fi
    else
        echo "  http://localhost:$API_PORT"
    fi
    
    echo ""
    echo "🗄️ MinIO Storage Endpoint:"
    minio_endpoint=$(get_minio_endpoint)
    echo "  http://$minio_endpoint (for mobile app file access)"
    echo ""
    echo "To start services:"
    echo "  cd $instance_path"
    echo "  podman compose up -d"
    exit 0
fi

# Check if podman compose is available
if ! podman compose version >/dev/null 2>&1; then
    echo "ERROR: Please install Podman Compose before running this script."
    exit 1
fi

# Check if base64 is available
if ! command -v base64 >/dev/null; then
    echo "ERROR: base64 command not found. It is needed to autogenerate credentials."
    exit 1
fi

# Check if directory already exists (only for setup command)
if [ "$1" != "setup" ] && [ "$1" != "backup" ] && [ "$1" != "restore" ] && [ -d "$INSTANCE_NAME" ]; then
    echo "The '$INSTANCE_NAME' directory already exists. Starting existing instance..."
    cd "$INSTANCE_NAME"
    podman compose up -d
    echo "✓ Services started. Use 'podman compose logs -f' to view logs."
    echo ""
    echo "Service endpoints:"
    get_network_urls
    echo ""
    echo "📱 Mobile App Server Endpoint:"
    if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$ip" ]; then
            echo "  http://$ip:$API_PORT"
        else
            echo "  http://$NETWORK_INTERFACE:$API_PORT"
        fi
    else
        echo "  http://localhost:$API_PORT"
    fi
    
    echo ""
    echo "🗄️ MinIO Storage Endpoint:"
    minio_endpoint=$(get_minio_endpoint)
    echo "  http://$minio_endpoint (for mobile app file access)"
    exit 0
fi

# Check for -y flag (skip prompts)
SKIP_PROMPTS="false"
if [ "$1" = "-y" ]; then
    SKIP_PROMPTS="true"
    shift  # Remove -y from args
fi

# Handle setup command
if [ "$1" = "setup" ] || [ -z "$1" ]; then
    # Get target directory (defaults to current directory)
    target_dir=$(get_target_dir "$2")
    instance_path="$target_dir/$INSTANCE_NAME"
    
    if [ -d "$instance_path" ]; then
        echo "WARNING: '$instance_path' directory already exists."
        echo "Starting existing instance instead of creating new one..."
        cd "$instance_path"
        podman compose up -d
        echo "✓ Services started. Use 'podman compose logs -f' to view logs."
        echo ""
        echo "Service endpoints:"
        get_network_urls
        echo ""
        echo "📱 Mobile App Server Endpoint:"
        if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
            ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
            if [ -n "$ip" ]; then
                echo "  http://$ip:$API_PORT"
            else
                echo "  http://$NETWORK_INTERFACE:$API_PORT"
            fi
        else
            echo "  http://localhost:$API_PORT"
        fi
        
        echo ""
        echo "🗄️ MinIO Storage Endpoint:"
        minio_endpoint=$(get_minio_endpoint)
        echo "  http://$minio_endpoint (for mobile app file access)"
        exit 0
    fi
    
    echo "Setting up Ente instance in: $target_dir"
    echo "Instance will be created at: $instance_path"
    # Continue with setup process below
else
    echo "ERROR: Unknown command '$1'"
    echo "Usage: $0 [-y] [setup [target-dir]|backup <absolute-backup-path>|restore <absolute-backup-path> [target-dir]]"
    echo "  -y  Skip prompts (non-interactive mode)"
    exit 1
fi

echo ""
echo " - H E L L O - E N T E -"
echo ""

# Simplified random string generator using configuration variables
gen_random() {
    local length=$1
    local variant=${2:-""}
    local result=$(head -c $length /dev/urandom | base64 | tr -d '\n')
    if [ "$variant" = "urlsafe" ]; then
        result=$(echo "$result" | tr '+/' '-_')
    fi
    echo "$result"
}

# Generate all credentials using configuration variables
pg_pass=$(gen_random "$PASSWORD_LENGTH")
minio_user="$MINIO_USER_PREFIX-$(gen_random "$USER_SUFFIX_LENGTH")"
minio_pass=$(gen_random "$PASSWORD_LENGTH")
museum_key=$(gen_random "$KEY_LENGTH")
museum_hash=$(gen_random "$HASH_LENGTH")
museum_jwt_secret=$(gen_random "$KEY_LENGTH" "urlsafe")

# Create directory and files
mkdir -p "$target_dir"
cd "$target_dir"
mkdir "$INSTANCE_NAME" && cd "$INSTANCE_NAME"
echo " ✓ Created directory $instance_path"

# Create persistent data directories with correct permissions
# Using configuration variables for permissions
mkdir -p data postgres-data minio-data
chmod "$DIR_PERMISSIONS" data postgres-data minio-data

# Fix SELinux context for Podman containers (Fedora/RHEL)
if command -v setsebool >/dev/null 2>&1; then
    echo "Setting up SELinux for Podman containers..."
    sudo setsebool -P container_manage_cgroup on 2>/dev/null || true
fi


# Let containers handle their own ownership by using tmpfs for initialization
echo "Setting up container-friendly permissions..."
# Only create directories if they don't exist (preserve existing data)
if [ ! -d "postgres-data" ]; then
    mkdir -p postgres-data
    chmod 755 postgres-data  # Read/write for owner, read for others
fi
if [ ! -d "minio-data" ]; then
    mkdir -p minio-data
    chmod 755 minio-data  # Read/write for owner, read for others
fi

echo " ✓ Created persistent data directories with correct permissions"

# Create compose.yaml
network_binding=$(get_network_binding)
cat > compose.yaml <<EOF
services:
  museum:
    image: ${MUSEUM_IMAGE}
    ports:
      - ${network_binding}:${API_PORT}:8080
    depends_on:
      postgres:
        condition: service_healthy
    volumes:
      - ./museum.yaml:/museum.yaml:ro
      - ./data:/data:ro
    environment:
      # CORS configuration
      ENABLE_CORS: "${ENABLE_CORS}"
      CORS_ALLOWED_ORIGINS: "${CORS_ALLOWED_ORIGINS}"
      CORS_ALLOWED_METHODS: "${CORS_ALLOWED_METHODS}"
      CORS_ALLOWED_HEADERS: "${CORS_ALLOWED_HEADERS}"
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:8080/ping >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

  socat:
    image: ${SOCAT_IMAGE}
    network_mode: service:museum
    depends_on: [museum]
    command: "TCP-LISTEN:3200,fork,reuseaddr TCP:minio:${MINIO_PORT}"

  web:
    image: ${WEB_IMAGE}
    ports:
      - ${network_binding}:${WEB_PORT_PHOTOS}:3000
      - ${network_binding}:${WEB_PORT_ALBUMS}:3002
    environment:
      ENTE_API_ORIGIN: "http://localhost:${API_PORT}"
      ENTE_ALBUMS_ORIGIN: "https://localhost:${WEB_PORT_ALBUMS}"
      # CORS configuration
      ENABLE_CORS: "${ENABLE_CORS}"
      CORS_ALLOWED_ORIGINS: "${CORS_ALLOWED_ORIGINS}"
      CORS_ALLOWED_METHODS: "${CORS_ALLOWED_METHODS}"
      CORS_ALLOWED_HEADERS: "${CORS_ALLOWED_HEADERS}"

  postgres:
    image: ${POSTGRES_IMAGE}
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${pg_pass}
      POSTGRES_DB: ${POSTGRES_DB}
    healthcheck:
      test: pg_isready -q -d ${POSTGRES_DB} -U ${POSTGRES_USER}
      start_period: 40s
      start_interval: 1s
    volumes:
      - ./postgres-data:/var/lib/postgresql/data

  minio:
    image: ${MINIO_IMAGE}
    ports:
      - ${network_binding}:${MINIO_PORT}:${MINIO_PORT}
    environment:
      MINIO_ROOT_USER: ${minio_user}
      MINIO_ROOT_PASSWORD: ${minio_pass}
    command: server /data --address ":${MINIO_PORT}" --console-address ":${MINIO_CONSOLE_PORT}"
    volumes:
      - ./minio-data:/data
    post_start:
      - command: |
          sh -c '
          while ! mc alias set h0 http://minio:${MINIO_PORT} ${minio_user} ${minio_pass} 2>/dev/null; do
            echo "Waiting for minio..."
            sleep 0.5
          done
          cd /data
          mc mb -p b2-eu-cen
          mc mb -p wasabi-eu-central-2-v3
          mc mb -p scw-eu-fr-v3
          '

EOF

echo " ✓ Created compose.yaml"

# Create museum.yaml
minio_endpoint=$(get_minio_endpoint)
cat > museum.yaml <<EOF
db:
  host: postgres
  port: 5432
  name: ${POSTGRES_DB}
  user: ${POSTGRES_USER}
  password: ${pg_pass}

s3:
  are_local_buckets: true
  use_path_style_urls: true

  b2-eu-cen:
    key: ${minio_user}
    secret: ${minio_pass}
    endpoint: ${minio_endpoint}
    region: ${MINIO_REGION}
    bucket: b2-eu-cen

  wasabi-eu-central-2-v3:
    key: ${minio_user}
    secret: ${minio_pass}
    endpoint: ${minio_endpoint}
    region: ${MINIO_REGION}
    bucket: wasabi-eu-central-2-v3
    compliance: false

  scw-eu-fr-v3:
    key: ${minio_user}
    secret: ${minio_pass}
    endpoint: ${minio_endpoint}
    region: ${MINIO_REGION}
    bucket: scw-eu-fr-v3

apps:
  public-albums: http://${network_binding}:${WEB_PORT_ALBUMS}
  cast: http://${network_binding}:3004
  accounts: http://${network_binding}:3001

# CORS configuration
cors:
  enabled: "${ENABLE_CORS}"
  allowed_origins: "${CORS_ALLOWED_ORIGINS}"
  allowed_methods: "${CORS_ALLOWED_METHODS}"
  allowed_headers: "${CORS_ALLOWED_HEADERS}"
  allow_credentials: true

# Admin whitelist
admin:
  whitelist:
    - admin@localhosting.com

key:
  encryption: ${museum_key}
  hash: ${museum_hash}
  jwt:
    secret: ${museum_jwt_secret}
EOF

echo " ✓ Created museum.yaml"

       # Set SELinux context for all container files (after they're created)
       if command -v chcon >/dev/null 2>&1; then
           echo "Setting SELinux context for all container files..."
           # Data directories
           sudo chcon -Rt svirt_sandbox_file_t ./postgres-data 2>/dev/null || true
           sudo chcon -Rt svirt_sandbox_file_t ./minio-data 2>/dev/null || true
           sudo chcon -Rt svirt_sandbox_file_t ./data 2>/dev/null || true
           # Config files
           sudo chcon -Rt svirt_sandbox_file_t ./compose.yaml 2>/dev/null || true
           sudo chcon -Rt svirt_sandbox_file_t ./museum.yaml 2>/dev/null || true
       fi

       # Note: MinIO buckets will be created after containers are started

echo ""

# Ask if user wants to start
if [ "$SKIP_PROMPTS" = "true" ]; then
    choice="y"
    echo "Automatically starting Ente (non-interactive mode)..."
else
    read -p "Do you want to start Ente? (y/n) [n]: " choice
fi

if [[ "$choice" =~ ^[Yy]$ ]]; then
    echo ""
    echo "Starting podman compose in background..."
    echo ""
    echo "After the cluster has started, you can access Ente at:"
    get_network_urls
    echo ""
    echo "Starting services in background (detached mode)..."
    echo "To view logs: podman compose logs -f"
    echo "To stop services: podman compose down"
    echo ""
    podman compose up -d > /dev/null 2>&1 &
    sleep 5  # Give services more time to start
    
    # Wait for services to be ready and create buckets
    echo "Waiting for services to be ready..."
    if create_minio_buckets; then
        echo "✓ MinIO buckets created"
    else
        echo "⚠️  MinIO bucket creation failed"
        echo "   You can try running: ./podman-ente.sh create-buckets"
    fi
    
    # Wait for Museum API to be ready
    if wait_for_museum_api; then
        echo "✓ All services are ready and responding"
    else
        echo "⚠️  Museum API not ready, but services are running"
        echo "   You can check logs with: podman compose logs -f"
    fi
    echo "✓ Check logs with: podman compose logs -f"
    echo "✓ Stop with: podman compose down"
    echo ""
    echo "📱 Mobile App Server Endpoint:"
    if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$ip" ]; then
            echo "  http://$ip:$API_PORT"
        else
            echo "  http://$NETWORK_INTERFACE:$API_PORT"
        fi
    else
        echo "  http://localhost:$API_PORT"
    fi
    
    echo ""
    echo "🗄️ MinIO Storage Endpoint:"
    minio_endpoint=$(get_minio_endpoint)
    echo "  http://$minio_endpoint (for mobile app file access)"
    
    echo ""
    echo "🔍 To get verification codes:"
    echo "  cd $INSTANCE_NAME"
    echo "  podman compose logs museum 2>&1 | grep 'Verification code'"
    echo "  # Or follow logs in real-time:"
    echo "  podman compose logs -f museum"
    echo ""
    echo "💡 Quick verification code extraction:"
    echo "  cd $INSTANCE_NAME && podman compose logs museum 2>&1 | grep -o 'Verification code: [0-9]*' | tail -1 | cut -d' ' -f3"
else
    echo ""
    echo "To start the cluster:"
    echo "  cd $INSTANCE_NAME"
    echo "  podman compose up -d    # Start in background"
    echo "  podman compose logs -f  # View logs"
    echo "  podman compose down     # Stop services"
    echo ""
    echo "After the cluster has started, you can access Ente at:"
    get_network_urls
    echo ""
    echo "✓ Services will run in background"
    echo "✓ Use 'podman compose logs -f' to view logs"
    echo ""
    echo "📱 Mobile App Server Endpoint:"
    if [ "$EXPOSE_TO_NETWORK" = "true" ]; then
        ip=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1)
        if [ -n "$ip" ]; then
            echo "  http://$ip:$API_PORT"
        else
            echo "  http://$NETWORK_INTERFACE:$API_PORT"
        fi
    else
        echo "  http://localhost:$API_PORT"
    fi
    
    echo ""
    echo "🗄️ MinIO Storage Endpoint:"
    minio_endpoint=$(get_minio_endpoint)
    echo "  http://$minio_endpoint (for mobile app file access)"
fi
