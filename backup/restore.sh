#!/bin/bash
#
# Restore a .sql.gz dump produced by backup.sh into the local db container.
# Usage: ./restore.sh <dump_file.sql.gz> [database_name]
#
# Note: the dump carries TimescaleDB circular foreign-key constraints. A plain
# psql restore normally handles them, but if it errors on FK ordering, restore
# into a fresh container/volume rather than an in-use database.

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <dump_file.sql.gz> [database_name]"
    echo "database_name defaults to 'postgres'"
    exit 1
fi

DUMP_FILE="$1"
DB_NAME="${2:-postgres}"
CONTAINER_NAME="${CONTAINER_NAME:-db}"
DB_USER="${DB_USER:-postgres}"

if [ ! -f "$DUMP_FILE" ]; then
    echo "Error: dump file $DUMP_FILE not found" >&2
    exit 1
fi

if [[ "$DUMP_FILE" == *.gz ]] && ! gzip -t "$DUMP_FILE" 2>/dev/null; then
    echo "Error: $DUMP_FILE fails gzip integrity check - refusing to restore" >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "Error: container $CONTAINER_NAME is not running" >&2
    exit 1
fi

echo "Restoring $DUMP_FILE into database '$DB_NAME' (container: $CONTAINER_NAME)"

echo "Terminating connections to $DB_NAME..."
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d template1 -c "
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();
"

echo "Dropping and recreating $DB_NAME..."
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d template1 -c "DROP DATABASE IF EXISTS $DB_NAME;"
docker exec "$CONTAINER_NAME" psql -U "$DB_USER" -d template1 -c "CREATE DATABASE $DB_NAME;"

echo "Restoring..."
zcat "$DUMP_FILE" | docker exec -i "$CONTAINER_NAME" psql -U "$DB_USER" -d "$DB_NAME"

echo "Database restore completed."
