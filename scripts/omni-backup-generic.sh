#!/bin/bash
# OmniStack backup script - syncs OMNI_DIR/data to S3 under omni/data/
# Usage: bash omni-backup-generic.sh <dest-path>
#   dest-path examples: "data", "checkpoint/20260609"
# Lives in /opt/hermes-repo/scripts/omni-backup-generic.sh
set -uo pipefail  # NO errexit — continue if one DB fails

DEST="${1:?Usage: $0 <dest-path> (e.g. data or checkpoint/20260609)}"

OMNI_DIR="${OMNI_DIR:-/opt/workspace/omni-stack}"
HERMES_HOME="${HERMES_HOME:-/opt/data}"
RCLONE="${RCLONE:-/usr/local/bin/rclone}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="$HERMES_HOME/cron/output/omni_backup_${TIMESTAMP}.log"

mkdir -p "$OMNI_DIR/data/backup/postgres" "$OMNI_DIR/data/credentials" "$HERMES_HOME/cron/output"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === OmniStack Backup Start (dest: ${DEST}) ===" >> "$LOG"

# ── Load env vars (including COMPOSE_PROFILES for service detection) ──
if [ -f "$OMNI_DIR/.env" ]; then
  set -a
  source "$OMNI_DIR/.env"
  set +a
fi

# ── Determine which services are enabled from COMPOSE_PROFILES ──
# "full" or "all" means everything enabled
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
MATTERMOST_ENABLED=false
if echo "$COMPOSE_PROFILES" | grep -qiE '(^|,)mattermost(,|$| )' || \
   echo "$COMPOSE_PROFILES" | grep -qiE '(^|,)all(,|$| )' || \
   echo "$COMPOSE_PROFILES" | grep -qiE '(^|,)full(,|$| )'; then
  MATTERMOST_ENABLED=true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] COMPOSE_PROFILES=${COMPOSE_PROFILES}, MATTERMOST_ENABLED=${MATTERMOST_ENABLED}" >> "$LOG"

# ── 1. Copy .env to credentials/ ──
if [ -f "$OMNI_DIR/.env" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Copying .env to data/credentials/.env..." >> "$LOG"
  cp "$OMNI_DIR/.env" "$OMNI_DIR/data/credentials/.env"
  chmod 600 "$OMNI_DIR/data/credentials/.env"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] .env copied." >> "$LOG"
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $OMNI_DIR/.env not found." >> "$LOG"
fi

# ── 2. Backup OmniAgent PostgreSQL ──
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backing up OmniAgent PostgreSQL..." >> "$LOG"
if docker inspect omni-postgres-1 &>/dev/null; then
  if docker exec omni-postgres-1 pg_dump -U omniagent -d omniagent \
    --no-owner --no-acl --clean --if-exists \
    > "$OMNI_DIR/data/backup/postgres/omniagent-dump.sql" 2>> "$LOG"; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] OmniAgent PG dump succeeded." >> "$LOG"
  else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: OmniAgent PG dump failed (continuing)." >> "$LOG"
  fi
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] omni-postgres-1 container not found - skipping." >> "$LOG"
fi

# ── 3. Backup Mattermost PostgreSQL (if enabled) ──
if [ "$MATTERMOST_ENABLED" = true ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backing up Mattermost PostgreSQL..." >> "$LOG"
  if docker inspect omni-mattermost-db-1 &>/dev/null; then
    if docker exec omni-mattermost-db-1 pg_dump -U mmuser -d mattermost \
      --no-owner --no-acl --clean --if-exists \
      > "$OMNI_DIR/data/backup/postgres/mattermost-dump.sql" 2>> "$LOG"; then
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] Mattermost PG dump succeeded." >> "$LOG"
    else
      echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Mattermost PG dump failed (continuing)." >> "$LOG"
    fi
  else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] omni-mattermost-db-1 container not found - skipping." >> "$LOG"
  fi
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Mattermost not enabled in COMPOSE_PROFILES - skipping." >> "$LOG"
fi

# ── Already loaded env vars above for COMPOSE_PROFILES detection.
# S3 credentials should be available from that source call.
# Fallback to HERMES_HOME .env if omni .env doesn't have S3 vars.
if [ -z "${S3_ACCESS_KEY:-}" ] && [ -f "$HERMES_HOME/.env" ]; then
  set -a
  source "$HERMES_HOME/.env"
  set +a
fi

if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ] || \
   [ -z "${S3_ENDPOINT:-}" ] || [ -z "${S3_BUCKET:-}" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: S3 credentials not configured." | tee -a "$LOG"
  exit 1
fi

S3_CONF="/tmp/rclone-omni-backup.conf"
cat > "$S3_CONF" << EOF
[omni-s3]
type = s3
provider = Other
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION:-us-east-005}
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Syncing $OMNI_DIR/data to s3://${S3_BUCKET}/omni/${DEST}..." >> "$LOG"

$RCLONE --config "$S3_CONF" sync "$OMNI_DIR/data" "omni-s3:${S3_BUCKET}/omni/${DEST}" \
  --delete-excluded \
  --exclude ".cache/**" \
  --exclude "cache/**" \
  --exclude "backup/vector/**" \
  --log-level INFO >> "$LOG" 2>&1

echo "[$(date +'%Y-%m-%d %H:%M:%S')] OmniStack backup complete! (dest: ${DEST})" >> "$LOG"
echo "OmniStack backup complete. Dest: ${DEST}. Log: $LOG"
rm -f "$S3_CONF"
