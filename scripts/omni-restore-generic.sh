#!/bin/bash
# OmniStack restore script - restores OMNI_DIR/data from S3 under omni/<src>/
# Usage: bash omni-restore-generic.sh <src-path>
#   src-path examples: "data", "checkpoint/20260609"
# Lives in /opt/hermes-repo/scripts/omni-restore-generic.sh
set -uo pipefail

SRC="${1:?Usage: $0 <src-path> (e.g. data or checkpoint/20260609)}"

OMNI_DIR="${OMNI_DIR:-/opt/workspace/omni-stack}"
HERMES_HOME="${HERMES_HOME:-/opt/data}"
RCLONE="${RCLONE:-/usr/local/bin/rclone}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="/tmp/omni-restore-${TIMESTAMP}.log"

# ── Load S3 credentials ──
if [ -f "$OMNI_DIR/.env" ]; then
  set -a
  source "$OMNI_DIR/.env"
  set +a
elif [ -f "$HERMES_HOME/.env" ]; then
  set -a
  source "$HERMES_HOME/.env"
  set +a
fi

if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ] || \
   [ -z "${S3_ENDPOINT:-}" ] || [ -z "${S3_BUCKET:-}" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: S3 credentials not configured." | tee -a "$LOG"
  echo "Set S3_ACCESS_KEY, S3_SECRET_KEY, S3_ENDPOINT, S3_REGION, S3_BUCKET" | tee -a "$LOG"
  exit 1
fi

if ! command -v "$RCLONE" &>/dev/null && [ ! -f "$RCLONE" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: rclone not found at $RCLONE." | tee -a "$LOG"
  exit 1
fi

# ── Determine Mattermost enablement ──
COMPOSE_PROFILES="${COMPOSE_PROFILES:-}"
MATTERMOST_ENABLED=false
if echo "$COMPOSE_PROFILES" | grep -qiE '(^|,)mattermost(,|$| )' || \
   echo "$COMPOSE_PROFILES" | grep -qiE '(^|,)all(,|$| )' || \
   echo "$COMPOSE_PROFILES" | grep -qiE '(^|,)full(,|$| )'; then
  MATTERMOST_ENABLED=true
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] === OmniStack Restore Start (src: ${SRC}) ===" | tee -a "$LOG"
echo "[$(date +'%Y-%m-%d %H:%M:%S')] MATTERMOST_ENABLED=${MATTERMOST_ENABLED}" | tee -a "$LOG"

# ── Stop services ──
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Stopping omni-omniagent-1..." | tee -a "$LOG"
docker stop omni-omniagent-1 >> "$LOG" 2>&1 || echo "  (not running, continuing)" | tee -a "$LOG"

if [ "$MATTERMOST_ENABLED" = true ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Stopping omni-mattermost-1..." | tee -a "$LOG"
  docker stop omni-mattermost-1 >> "$LOG" 2>&1 || echo "  (not running, continuing)" | tee -a "$LOG"
fi

# ── Sync from S3 ──
S3_CONF="/tmp/rclone-omni-restore.conf"
cat > "$S3_CONF" << EOF
[omni-s3]
type = s3
provider = Other
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION:-us-east-005}
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Syncing from s3://${S3_BUCKET}/omni/${SRC} to $OMNI_DIR/data..." | tee -a "$LOG"

$RCLONE --config "$S3_CONF" sync "omni-s3:${S3_BUCKET}/omni/${SRC}" "$OMNI_DIR/data" \
  --delete-excluded \
  --exclude ".cache/**" \
  --exclude "cache/**" \
  --exclude "backup/vector/**" \
  --log-level ERROR --stats-one-line 2>&1 | tee -a "$LOG"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] S3 sync complete." | tee -a "$LOG"

# ── Restore .env from credentials/ ──
if [ -f "$OMNI_DIR/data/credentials/.env" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring .env from data/credentials/.env..." | tee -a "$LOG"
  cp "$OMNI_DIR/data/credentials/.env" "$OMNI_DIR/.env"
  chmod 600 "$OMNI_DIR/.env"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] .env restored." | tee -a "$LOG"
fi

# ── Restore OmniAgent PostgreSQL ──
if [ -f "$OMNI_DIR/data/backup/postgres/omniagent-dump.sql" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring OmniAgent PostgreSQL..." | tee -a "$LOG"

  # Terminate active connections and drop/recreate database
  docker start omni-postgres-1 >> "$LOG" 2>&1 || true
  sleep 2

  docker exec omni-postgres-1 psql -U omniagent -d postgres <<'EOSQL' >> "$LOG" 2>&1 || true
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'omniagent' AND pid <> pg_backend_pid();
    DROP DATABASE IF EXISTS omniagent;
    CREATE DATABASE omniagent;
EOSQL

  if docker exec -i omni-postgres-1 psql -U omniagent -d omniagent \
    < "$OMNI_DIR/data/backup/postgres/omniagent-dump.sql" >> "$LOG" 2>&1; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] OmniAgent PG restore succeeded." | tee -a "$LOG"
  else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: OmniAgent PG restore failed." | tee -a "$LOG"
  fi
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] No omniagent-dump.sql found - skipping PG restore." | tee -a "$LOG"
fi

# ── Restore Mattermost PostgreSQL (if enabled and backup exists) ──
if [ "$MATTERMOST_ENABLED" = true ] && [ -f "$OMNI_DIR/data/backup/postgres/mattermost-dump.sql" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring Mattermost PostgreSQL..." | tee -a "$LOG"

  docker start omni-mattermost-db-1 >> "$LOG" 2>&1 || true
  sleep 2

  docker exec omni-mattermost-db-1 psql -U mmuser -d postgres <<'EOSQL' >> "$LOG" 2>&1 || true
    SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity
    WHERE datname = 'mattermost' AND pid <> pg_backend_pid();
    DROP DATABASE IF EXISTS mattermost;
    CREATE DATABASE mattermost;
EOSQL

  if docker exec -i omni-mattermost-db-1 psql -U mmuser -d mattermost \
    < "$OMNI_DIR/data/backup/postgres/mattermost-dump.sql" >> "$LOG" 2>&1; then
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] Mattermost PG restore succeeded." | tee -a "$LOG"
  else
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: Mattermost PG restore failed." | tee -a "$LOG"
  fi
fi

# ── Restart services ──
echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting omni-omniagent-1..." | tee -a "$LOG"
docker start omni-omniagent-1 >> "$LOG" 2>&1 || echo "  (failed to start)" | tee -a "$LOG"

if [ "$MATTERMOST_ENABLED" = true ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting omni-mattermost-1..." | tee -a "$LOG"
  docker start omni-mattermost-1 >> "$LOG" 2>&1 || echo "  (failed to start)" | tee -a "$LOG"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] OmniStack restore complete! (src: ${SRC})" | tee -a "$LOG"
rm -f "$S3_CONF"
