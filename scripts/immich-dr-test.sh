#!/bin/bash
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
RESTIC_REPO="${RESTIC_REPO:-/mnt/e/backups/immich}"
RESTORE_DIR="${RESTORE_DIR:-$HOME/dr-test/immich}"
SNAPSHOT_ID="${1:-latest}"

# Functions
print_error() {
    echo -e "${RED}ERROR: $1${NC}" >&2
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_info() {
    echo -e "${CYAN}$1${NC}"
}

print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

detect_dump_format() {
    local dump_path="$1"

    # Check if it's a directory (directory format)
    if [ -d "$dump_path" ]; then
        echo "directory"
        return 0
    fi

    # Check magic bytes first (most reliable)
    if head -c 5 "$dump_path" 2>/dev/null | grep -q "PGDMP"; then
        echo "custom"
        return 0
    fi

    # Check file extension as fallback
    case "${dump_path##*.}" in
        sql) echo "plain" ;;
        dump|pgdump) echo "custom" ;;
        *) echo "plain" ;;  # Default to plain
    esac
}

show_help() {
    cat << EOF
${CYAN}Immich Disaster Recovery Test Script${NC}

${GREEN}Usage:${NC}
  $0                    Run full restore and start Immich
  $0 <snapshot-id>      Restore specific snapshot
  $0 cleanup            Stop containers and remove test data
  $0 status             Show container status
  $0 logs               Follow container logs
  $0 help               Show this help message

${GREEN}Environment Variables:${NC}
  RESTIC_REPO           Restic repository path (default: /mnt/e/backups/immich)
  RESTIC_PASSWORD       Restic repository password (will prompt if not set)
  RESTORE_DIR           Directory to restore to (default: \$HOME/dr-test/immich)

${GREEN}Examples:${NC}
  $0                                    # Restore latest snapshot
  $0 abc123ef                           # Restore specific snapshot
  RESTORE_DIR=/tmp/test $0              # Use custom restore directory
  $0 cleanup                            # Clean up test environment

EOF
}

check_dependencies() {
    local missing_deps=()

    for cmd in restic docker; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install the missing dependencies and try again."
        exit 1
    fi
}

check_restic_password() {
    if [ -z "$RESTIC_PASSWORD" ]; then
        print_warning "RESTIC_PASSWORD not set"
        read -s -p "Enter restic repository password: " RESTIC_PASSWORD
        echo
        export RESTIC_PASSWORD
    fi
}

list_snapshots() {
    print_info "Available snapshots with tag 'immich':"
    echo
    restic -r "$RESTIC_REPO" snapshots --tag immich || {
        print_error "Failed to list snapshots. Check repository path and password."
        exit 1
    }
    echo
}

prompt_continue() {
    print_warning "About to restore snapshot: $SNAPSHOT_ID"
    print_warning "Restore directory: $RESTORE_DIR"
    echo
    read -p "Continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Restore cancelled."
        exit 0
    fi
}

restore_snapshot() {
    print_info "Creating restore directory structure..."
    mkdir -p "$RESTORE_DIR"

    print_info "Restoring snapshot $SNAPSHOT_ID to $RESTORE_DIR..."
    restic -r "$RESTIC_REPO" restore "$SNAPSHOT_ID" --target "$RESTORE_DIR" --tag immich || {
        print_error "Failed to restore snapshot"
        exit 1
    }

    print_success "Snapshot restored successfully"
}

detect_paths() {
    print_info "Detecting restored data paths..."

    # Look for photo library
    PHOTO_PATH=""
    for path in "$RESTORE_DIR/library" "$RESTORE_DIR/data/library" "$RESTORE_DIR/upload"; do
        if [ -d "$path" ]; then
            PHOTO_PATH="$path"
            break
        fi
    done

    if [ -z "$PHOTO_PATH" ]; then
        print_error "Could not find photo library in restored data"
        print_info "Searched locations:"
        echo "  - $RESTORE_DIR/library"
        echo "  - $RESTORE_DIR/data/library"
        echo "  - $RESTORE_DIR/upload"
        exit 1
    fi

    # Look for SQL dump - prioritize .dump files (custom format) over .sql (plain format)
    SQL_DUMP=""
    for path in \
        "$RESTORE_DIR/database.dump" \
        "$RESTORE_DIR/db/database.dump" \
        "$RESTORE_DIR/immich.dump" \
        "$RESTORE_DIR/database.pgdump" \
        "$RESTORE_DIR/database.sql" \
        "$RESTORE_DIR/db/database.sql" \
        "$RESTORE_DIR/immich.sql"; do
        if [ -f "$path" ]; then
            SQL_DUMP="$path"
            break
        fi
        # Also check for directory format
        if [ -d "$path" ]; then
            SQL_DUMP="$path"
            break
        fi
    done

    if [ -z "$SQL_DUMP" ]; then
        print_error "Could not find SQL dump in restored data"
        print_info "Searched locations:"
        echo "  - $RESTORE_DIR/database.dump"
        echo "  - $RESTORE_DIR/db/database.dump"
        echo "  - $RESTORE_DIR/immich.dump"
        echo "  - $RESTORE_DIR/database.pgdump"
        echo "  - $RESTORE_DIR/database.sql"
        echo "  - $RESTORE_DIR/db/database.sql"
        echo "  - $RESTORE_DIR/immich.sql"
        exit 1
    fi

    print_success "Photo library found: $PHOTO_PATH"
    print_success "SQL dump found: $SQL_DUMP"
}

generate_env_file() {
    print_info "Generating .env file..."

    cat > "$RESTORE_DIR/.env" << EOF
# Immich DR Test Environment
UPLOAD_LOCATION=$PHOTO_PATH
DB_DATA_LOCATION=$RESTORE_DIR/postgres
REDIS_DATA_LOCATION=$RESTORE_DIR/redis

# Database
DB_HOSTNAME=immich-db
DB_USERNAME=immich
DB_PASSWORD=immich
DB_DATABASE_NAME=immich

# Redis
REDIS_HOSTNAME=immich-redis

# Immich
IMMICH_VERSION=release
IMMICH_MACHINE_LEARNING_ENABLED=false
EOF

    print_success ".env file generated"
}

generate_docker_compose() {
    print_info "Generating docker-compose-dr.yml..."

    mkdir -p "$RESTORE_DIR/postgres"
    mkdir -p "$RESTORE_DIR/redis"

    cat > "$RESTORE_DIR/docker-compose-dr.yml" << 'EOF'
version: "3.8"

services:
  immich-server:
    container_name: immich-server-dr
    image: ghcr.io/immich-app/immich-server:${IMMICH_VERSION:-release}
    command: ["start.sh", "immich"]
    volumes:
      - ${UPLOAD_LOCATION}:/usr/src/app/upload
    env_file:
      - .env
    ports:
      - 2283:3001
    depends_on:
      immich-db:
        condition: service_healthy
      immich-redis:
        condition: service_started
    restart: unless-stopped

  immich-db:
    container_name: immich-db-dr
    image: tensorchord/pgvecto-rs:pg16-v0.2.0
    environment:
      POSTGRES_PASSWORD: ${DB_PASSWORD}
      POSTGRES_USER: ${DB_USERNAME}
      POSTGRES_DB: ${DB_DATABASE_NAME}
    volumes:
      - ${DB_DATA_LOCATION}:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USERNAME} -d ${DB_DATABASE_NAME}"]
      interval: 5s
      timeout: 5s
      retries: 10
    restart: unless-stopped

  immich-redis:
    container_name: immich-redis-dr
    image: redis:7-alpine
    volumes:
      - ${REDIS_DATA_LOCATION}:/data
    restart: unless-stopped
EOF

    print_success "docker-compose-dr.yml generated"
}

start_containers() {
    print_info "Starting containers..."

    cd "$RESTORE_DIR"
    docker compose -f docker-compose-dr.yml up -d

    print_success "Containers started"
}

restore_database() {
    local format=$(detect_dump_format "$SQL_DUMP")
    print_info "Detected dump format: $format"

    print_info "Waiting for database to be ready..."
    sleep 10

    local restore_status=0
    case "$format" in
        plain)
            print_info "Restoring from plain SQL format..."
            docker exec -i immich-db-dr psql -U immich -d immich < "$SQL_DUMP" || restore_status=$?
            ;;
        custom)
            print_info "Restoring from PostgreSQL custom format..."
            docker exec -i immich-db-dr pg_restore -U immich -d immich \
                --clean --if-exists --no-owner --no-privileges < "$SQL_DUMP" || restore_status=$?
            ;;
        directory)
            print_info "Restoring from directory format..."
            docker cp "$SQL_DUMP" immich-db-dr:/tmp/dump_dir
            docker exec immich-db-dr pg_restore -U immich -d immich \
                --clean --if-exists --no-owner --no-privileges /tmp/dump_dir || restore_status=$?
            ;;
    esac

    if [ $restore_status -ne 0 ]; then
        print_error "Failed to restore database"
        print_info "Manual restore commands:"
        echo "  Plain SQL:     docker exec -i immich-db-dr psql -U immich -d immich < $SQL_DUMP"
        echo "  Custom format: docker exec -i immich-db-dr pg_restore -U immich -d immich --clean --if-exists --no-owner --no-privileges < $SQL_DUMP"
        exit 1
    fi

    print_success "Database restored successfully"
}

wait_for_immich() {
    print_info "Waiting for Immich to be ready..."

    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -sf http://localhost:2283/api/server-info/ping > /dev/null 2>&1; then
            print_success "Immich is ready!"
            return 0
        fi

        attempt=$((attempt + 1))
        echo -n "."
        sleep 2
    done

    echo
    print_error "Immich did not become ready in time"
    print_info "Check logs with: $0 logs"
    exit 1
}

show_success_message() {
    echo
    print_success "=========================================="
    print_success "  Immich DR Test Environment Ready!"
    print_success "=========================================="
    echo
    print_info "Access Immich at: ${GREEN}http://localhost:2283${NC}"
    echo
    print_info "Useful commands:"
    echo "  $0 status    - Show container status"
    echo "  $0 logs      - Follow container logs"
    echo "  $0 cleanup   - Stop and remove test environment"
    echo
    print_warning "Note: Machine learning features are disabled in DR test mode"
    echo
}

cleanup() {
    print_warning "Stopping containers and removing test data..."

    if [ -f "$RESTORE_DIR/docker-compose-dr.yml" ]; then
        cd "$RESTORE_DIR"
        docker compose -f docker-compose-dr.yml down -v
        print_success "Containers stopped"
    fi

    if [ -d "$RESTORE_DIR" ]; then
        print_info "Removing restore directory: $RESTORE_DIR"
        rm -rf "$RESTORE_DIR"
        print_success "Test data removed"
    fi

    print_success "Cleanup complete"
}

show_status() {
    if [ -f "$RESTORE_DIR/docker-compose-dr.yml" ]; then
        cd "$RESTORE_DIR"
        docker compose -f docker-compose-dr.yml ps
    else
        print_error "No DR test environment found at $RESTORE_DIR"
        exit 1
    fi
}

show_logs() {
    if [ -f "$RESTORE_DIR/docker-compose-dr.yml" ]; then
        cd "$RESTORE_DIR"
        docker compose -f docker-compose-dr.yml logs -f
    else
        print_error "No DR test environment found at $RESTORE_DIR"
        exit 1
    fi
}

# Main
main() {
    case "${1:-}" in
        help|--help|-h)
            show_help
            exit 0
            ;;
        cleanup)
            cleanup
            exit 0
            ;;
        status)
            show_status
            exit 0
            ;;
        logs)
            show_logs
            exit 0
            ;;
    esac

    print_info "Immich Disaster Recovery Test Script"
    echo

    check_dependencies
    check_restic_password
    list_snapshots
    prompt_continue
    restore_snapshot
    detect_paths
    generate_env_file
    generate_docker_compose
    start_containers
    restore_database
    wait_for_immich
    show_success_message
}

main "$@"
