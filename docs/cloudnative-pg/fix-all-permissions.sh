#!/bin/bash

# Fix permissions for all users on existing tables after migration
# This script should be run once after migrating databases from separate PostgreSQL instances
# to the consolidated postgresql-vecto cluster

set -e

echo "=== Fixing permissions for all application users on existing tables ==="

# Get the PostgreSQL superuser password from the secret
PGPASSWORD=$(kubectl get secret -n default postgresql-vecto-cluster-superuser -o jsonpath='{.data.password}' | base64 -d)
export PGPASSWORD

PGHOST="localhost"
PGUSER="postgres"

echo "Starting port-forward to PostgreSQL..."

# Port-forward to access the database
kubectl port-forward -n default svc/postgresql-vecto-cluster-rw 5432:5432 &
PF_PID=$!

# Wait for port-forward to be ready
sleep 3

# Function to fix permissions for a database and user
fix_permissions() {
    local DBNAME=$1
    local USERNAME=$2

    echo ""
    echo "--- Processing database: $DBNAME for user: $USERNAME ---"

    psql -h "$PGHOST" -U "$PGUSER" -d "$DBNAME" <<EOF
-- Grant permissions on all existing tables
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$USERNAME";

-- Grant permissions on all existing sequences
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$USERNAME";

-- Grant permissions on all existing functions
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO "$USERNAME";

-- Ensure schema permissions
GRANT USAGE, CREATE ON SCHEMA public TO "$USERNAME";

-- Display table count for verification
SELECT COUNT(*) as table_count FROM information_schema.tables WHERE table_schema = 'public';
EOF

    echo "✓ Permissions fixed for $USERNAME on $DBNAME"
}

# Fix permissions for Paperless
# fix_permissions "paperless" "paperless"

# Fix permissions for Radarr
# fix_permissions "radarr_main" "radarr"
# fix_permissions "radarr_log" "radarr"

# Fix permissions for Sonarr
# fix_permissions "sonarr_main" "sonarr"
fix_permissions "sonarr_log" "sonarr"

echo ""
echo "=== All permissions fixed successfully! ==="

# Kill port-forward
kill $PF_PID 2>/dev/null || true

echo "Done."
