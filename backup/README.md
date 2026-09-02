# Database backups

Logical (`pg_dump`) backups of the Postgres/TimescaleDB container, with a
three-tier hourly -> daily -> weekly rotation.

## Scripts

| Script       | Purpose                                                        |
| ------------ | ------------------------------------------------------------- |
| `backup.sh`  | Create/promote backups. `backup.sh {hourly\|daily\|weekly}`  |
| `restore.sh` | Restore a dump: `restore.sh <file.sql.gz> [db_name]`         |

`backup.sh hourly` runs `pg_dump | gzip` (uses `pigz` if installed).
`daily` and `weekly` don't re-dump — they promote (copy) the newest backup
from the tier below.

## Tiers & retention

| Tier   | Schedule            | Kept | Source        |
| ------ | ------------------- | ---- | ------------- |
| hourly | every hour          | 24   | fresh pg_dump |
| daily  | 00:00               | 7    | newest hourly |
| weekly | Sundays 00:05       | 12   | newest daily  |

Overridable via env: `BACKUP_DIR`, `KEEP_HOURLY`, `KEEP_DAILY`, `KEEP_WEEKLY`,
`CONTAINER_NAME`, `DB_USER`, `DB_NAME`, `MIN_SIZE_RATIO_PERCENT`.

## Storage location

Backups are written to `$BACKUP_DIR` (default `$HOME/backups`), **outside this
repo** so dumps are never committed. A second server pulls the dump directory
periodically for off-box retention — the box itself holds no long-term copy.

## Integrity checks

Every backup is validated before it is kept or promoted:

- `pg_dump` exit status is checked explicitly via `PIPESTATUS` (a failed dump
  can't be masked by a successful `gzip`).
- `gzip -t` must pass.
- The new file must be at least `MIN_SIZE_RATIO_PERCENT` (default 50%) of the
  previous file in the same tier, else it's treated as truncated and rejected.

A failed check deletes the bad file and exits non-zero, so a broken dump can't
propagate up the tiers (this previously happened — a 6 MB truncated dump was
promoted hourly -> daily -> weekly).

## Cron

```cron
0 * * * * /home/liberatorist/deployment-server/backup/backup.sh hourly
0 0 * * * /home/liberatorist/deployment-server/backup/backup.sh daily
5 0 * * 0 /home/liberatorist/deployment-server/backup/backup.sh weekly
```

Weekly is offset to 00:05 so the day's `daily` promotion finishes first.

## Restore notes

The dump contains TimescaleDB circular foreign-key constraints. A plain `psql`
restore normally handles them; if it errors on FK ordering, restore into a
fresh container + volume rather than an in-use database.
