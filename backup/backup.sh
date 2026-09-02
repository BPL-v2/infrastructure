#!/bin/bash
#
# Postgres logical backup with hourly -> daily -> weekly promotion.
# See backup/README.md for the strategy, retention, and cron setup.

set -euo pipefail

# Where the backup tiers live. Kept outside the repo by default so the dumps
# are never accidentally committed. Override with BACKUP_DIR=/path in the
# environment (or the cron line) if needed.
BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"

CONTAINER_NAME="${CONTAINER_NAME:-db}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"

# Retention per tier.
KEEP_HOURLY="${KEEP_HOURLY:-24}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-12}"

# A new backup smaller than this fraction of the previous one in the same tier
# is treated as truncated/corrupt and rejected.
MIN_SIZE_RATIO_PERCENT="${MIN_SIZE_RATIO_PERCENT:-50}"

# Use pigz (parallel gzip) if present, otherwise gzip. Output is identical.
if command -v pigz >/dev/null 2>&1; then
    COMPRESSOR="pigz"
else
    COMPRESSOR="gzip"
fi

mkdir -p "$BACKUP_DIR"/{hourly,daily,weekly}

# Size in bytes of $1, or 0 if it does not exist.
file_size() {
    if [ -f "$1" ]; then stat -c %s "$1"; else echo 0; fi
}

# Newest existing backup in tier dir $1 matching glob $2 (empty if none).
latest_backup() {
    find "$1" -name "$2" -type f -size +0 | sort | tail -1
}

# Verify a gzip file is intact and not implausibly small versus $2 (a reference
# file from the same tier, may be missing). Deletes the file and exits on failure.
validate_backup() {
    local file="$1" reference="${2:-}"

    if [ ! -s "$file" ]; then
        echo "Error: backup file $file is missing or empty" >&2
        rm -f "$file"; exit 1
    fi

    if ! gzip -t "$file" 2>/dev/null; then
        echo "Error: backup file $file fails gzip integrity check" >&2
        rm -f "$file"; exit 1
    fi

    if [ -n "$reference" ] && [ -f "$reference" ]; then
        local new_size ref_size threshold
        new_size=$(file_size "$file")
        ref_size=$(file_size "$reference")
        threshold=$(( ref_size * MIN_SIZE_RATIO_PERCENT / 100 ))
        if [ "$new_size" -lt "$threshold" ]; then
            echo "Error: $file ($new_size bytes) is under ${MIN_SIZE_RATIO_PERCENT}% of previous $reference ($ref_size bytes) - assuming truncated" >&2
            rm -f "$file"; exit 1
        fi
    fi
}

hourly_backup() {
    local timestamp backup_file prev
    timestamp=$(date +"%Y%m%d_%H")
    backup_file="$BACKUP_DIR/hourly/backup_hourly_$timestamp.sql.gz"
    prev=$(latest_backup "$BACKUP_DIR/hourly" "backup_hourly_*.sql.gz" || true)

    echo "Creating hourly backup: $backup_file"

    # pipefail plus an explicit PIPESTATUS check so a mid-stream pg_dump failure
    # can never be masked by a successful compressor exit.
    set +e
    docker exec "$CONTAINER_NAME" pg_dump -U "$DB_USER" -d "$DB_NAME" | "$COMPRESSOR" > "$backup_file"
    local pipe_status=("${PIPESTATUS[@]}")
    set -e

    if [ "${pipe_status[0]}" -ne 0 ] || [ "${pipe_status[1]}" -ne 0 ]; then
        echo "Error: backup pipeline failed (pg_dump=${pipe_status[0]}, ${COMPRESSOR}=${pipe_status[1]})" >&2
        rm -f "$backup_file"; exit 1
    fi

    validate_backup "$backup_file" "$prev"
    echo "Hourly backup created successfully: $backup_file ($(du -h "$backup_file" | cut -f1))"

    find "$BACKUP_DIR/hourly" -name "backup_hourly_*.sql.gz" -type f | sort | head -n -"$KEEP_HOURLY" | xargs -r rm -f
}

# Promote the newest backup from one tier to the next.
#   $1 src dir  $2 dst dir  $3 src glob  $4 dst prefix  $5 keep count
promote_backup() {
    local src_dir="$1" dst_dir="$2" src_glob="$3" dst_prefix="$4" keep="$5"
    local latest timestamp dst_file prev

    latest=$(latest_backup "$src_dir" "$src_glob" || true)
    if [ -z "$latest" ] || [ ! -s "$latest" ]; then
        echo "Error: no valid backup in $src_dir to promote to $dst_dir" >&2
        exit 1
    fi
    if ! gzip -t "$latest" 2>/dev/null; then
        echo "Error: source backup $latest fails gzip integrity check - not promoting" >&2
        exit 1
    fi

    timestamp=$(date +"%Y%m%d")
    dst_file="$dst_dir/${dst_prefix}_${timestamp}.sql.gz"
    prev=$(latest_backup "$dst_dir" "${dst_prefix}_*.sql.gz" || true)

    echo "Promoting $latest -> $dst_file"
    cp "$latest" "$dst_file"
    validate_backup "$dst_file" "$prev"
    echo "Backup promoted successfully: $dst_file ($(du -h "$dst_file" | cut -f1))"

    find "$dst_dir" -name "${dst_prefix}_*.sql.gz" -type f | sort | head -n -"$keep" | xargs -r rm -f
}

case "${1:-}" in
    hourly)
        hourly_backup
        ;;
    daily)
        promote_backup "$BACKUP_DIR/hourly" "$BACKUP_DIR/daily" "backup_hourly_*.sql.gz" "backup_daily" "$KEEP_DAILY"
        ;;
    weekly)
        promote_backup "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "backup_daily_*.sql.gz" "backup_weekly" "$KEEP_WEEKLY"
        ;;
    *)
        echo "Usage: $0 {hourly|daily|weekly}"
        exit 1
        ;;
esac
