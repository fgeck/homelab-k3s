#!/bin/bash
set -euo pipefail

# Migration script for consolidating default-postgres-cnpg into postgresql-vecto
# This script will dump all databases from default-postgres-cnpg and restore them to postgresql-vecto

echo "=========================================="
echo "PostgreSQL Migration Script"
echo "From: default-postgres-cnpg"
echo "To: postgresql-vecto (with vectorchord)"
echo "=========================================="
echo ""

# Configuration
SOURCE_CLUSTER="default-postgres-cnpg-cluster"
TARGET_CLUSTER="postgresql-vecto-cluster"
NAMESPACE="default"
BACKUP_DIR="./postgres-migration-$(date +%Y%m%d-%H%M%S)"

# Databases to migrate
DATABASES=("paperless" "radarr_main" "radarr_log" "sonarr_main" "sonarr_log")

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}Step 1: Pre-flight checks${NC}"
echo "----------------------------------------"

# Check if source cluster exists
if ! kubectl get cluster -n ${NAMESPACE} ${SOURCE_CLUSTER} &>/dev/null; then
    echo -e "${RED}ERROR: Source cluster ${SOURCE_CLUSTER} not found in namespace ${NAMESPACE}${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Source cluster ${SOURCE_CLUSTER} exists"

# Check if target cluster exists
if ! kubectl get cluster -n ${NAMESPACE} ${TARGET_CLUSTER} &>/dev/null; then
    echo -e "${RED}ERROR: Target cluster ${TARGET_CLUSTER} not found in namespace ${NAMESPACE}${NC}"
    echo "Please deploy postgresql-vecto first using Flux"
    exit 1
fi
echo -e "${GREEN}✓${NC} Target cluster ${TARGET_CLUSTER} exists"

# Get superuser passwords from secrets
echo "Retrieving PostgreSQL superuser passwords..."
SOURCE_SUPERUSER_PASSWORD=$(kubectl get secret -n ${NAMESPACE} ${SOURCE_CLUSTER}-superuser -o jsonpath='{.data.password}' | base64 -d)
TARGET_SUPERUSER_PASSWORD=$(kubectl get secret -n ${NAMESPACE} ${TARGET_CLUSTER}-superuser -o jsonpath='{.data.password}' | base64 -d)

if [ -z "$SOURCE_SUPERUSER_PASSWORD" ] || [ -z "$TARGET_SUPERUSER_PASSWORD" ]; then
    echo -e "${RED}ERROR: Could not retrieve superuser passwords from secrets${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Retrieved superuser passwords"

# Create backup directory
mkdir -p "${BACKUP_DIR}"
echo -e "${GREEN}✓${NC} Created backup directory: ${BACKUP_DIR}"

echo ""
echo -e "${YELLOW}Step 2: Dump databases from ${SOURCE_CLUSTER}${NC}"
echo "----------------------------------------"

for db in "${DATABASES[@]}"; do
    echo "Dumping database: ${db}"

    # Get the read-write service
    SOURCE_SERVICE="${SOURCE_CLUSTER}-rw.${NAMESPACE}.svc.cluster.local"

    # Dump database using pg_dump via kubectl exec (with password)
    kubectl exec -n ${NAMESPACE} ${SOURCE_CLUSTER}-1 -- \
        env PGPASSWORD="${SOURCE_SUPERUSER_PASSWORD}" pg_dump -U postgres -d ${db} --clean --if-exists --no-owner --no-acl \
        > "${BACKUP_DIR}/${db}.sql"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Successfully dumped ${db} ($(du -h "${BACKUP_DIR}/${db}.sql" | cut -f1))"
    else
        echo -e "${RED}✗${NC} Failed to dump ${db}"
        exit 1
    fi
done

echo ""
echo -e "${YELLOW}Step 3: Restore databases to ${TARGET_CLUSTER}${NC}"
echo "----------------------------------------"

for db in "${DATABASES[@]}"; do
    echo "Restoring database: ${db}"

    # Restore database using psql via kubectl exec (with password)
    kubectl exec -i -n ${NAMESPACE} ${TARGET_CLUSTER}-1 -- \
        env PGPASSWORD="${TARGET_SUPERUSER_PASSWORD}" psql -U postgres -d ${db} < "${BACKUP_DIR}/${db}.sql"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} Successfully restored ${db}"
    else
        echo -e "${RED}✗${NC} Failed to restore ${db}"
        echo "You can manually restore using: kubectl exec -i -n ${NAMESPACE} ${TARGET_CLUSTER}-1 -- psql -U postgres -d ${db} < ${BACKUP_DIR}/${db}.sql"
        exit 1
    fi
done

echo ""
echo -e "${YELLOW}Step 4: Verify data${NC}"
echo "----------------------------------------"

for db in "${DATABASES[@]}"; do
    echo "Checking row counts for: ${db}"

    # Get table count from source (with password)
    SOURCE_TABLES=$(kubectl exec -n ${NAMESPACE} ${SOURCE_CLUSTER}-1 -- \
        env PGPASSWORD="${SOURCE_SUPERUSER_PASSWORD}" psql -U postgres -d ${db} -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")

    # Get table count from target (with password)
    TARGET_TABLES=$(kubectl exec -n ${NAMESPACE} ${TARGET_CLUSTER}-1 -- \
        env PGPASSWORD="${TARGET_SUPERUSER_PASSWORD}" psql -U postgres -d ${db} -tAc "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")

    if [ "${SOURCE_TABLES}" == "${TARGET_TABLES}" ]; then
        echo -e "${GREEN}✓${NC} ${db}: ${TARGET_TABLES} tables migrated successfully"
    else
        echo -e "${YELLOW}⚠${NC} ${db}: Source has ${SOURCE_TABLES} tables, target has ${TARGET_TABLES} tables"
    fi
done

echo ""
echo -e "${GREEN}=========================================="
echo "Migration completed successfully!"
echo "==========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Update application configurations to point to:"
echo "   postgresql-vecto-rw.${NAMESPACE}.svc.cluster.local:5432"
echo ""
echo "2. Test each application:"
echo "   - Paperless-NGX"
echo "   - Radarr"
echo "   - Sonarr"
echo ""
echo "3. Once verified, you can scale down default-postgres-cnpg:"
echo "   kubectl patch cluster -n ${NAMESPACE} ${SOURCE_CLUSTER} --type=merge -p '{\"spec\":{\"instances\":0}}'"
echo ""
echo "4. After confirming stability, delete the old cluster:"
echo "   kubectl delete cluster -n ${NAMESPACE} ${SOURCE_CLUSTER}"
echo ""
echo "Backup files are stored in: ${BACKUP_DIR}"
echo ""
