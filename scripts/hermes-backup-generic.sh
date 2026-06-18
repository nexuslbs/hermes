#!/bin/bash
# Hermes Agent generic backup script - syncs /opt/data to S3 under a specified path
# Usage: bash hermes-backup-generic.sh <dest-path>
#   dest-path examples: "data", "checkpoint/20260609"
# Single source of truth: lives in /opt/hermes-repo/scripts/hermes-backup-generic.sh
set -euo pipefail

DEST="${1:?Usage: $0 <dest-path> (e.g. data or checkpoint/20260609)}"

HERMES_HOME="${HERMES_HOME:-/opt/data}"
REPO_DIR="${REPO_DIR:-/opt/hermes-repo}"
RCLONE="${RCLONE:-/usr/local/bin/rclone}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="$HERMES_HOME/cron/output/backup_${TIMESTAMP}.log"

mkdir -p "$HERMES_HOME/cron/output" "$HERMES_HOME/backup/grafana" "$HERMES_HOME/backup/vault" "$HERMES_HOME/backup/hindsight"

if [ -f "$HERMES_HOME/state.db" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Creating consistent sqlite3 backup of state.db..." >> "$LOG"
  sqlite3 "$HERMES_HOME/state.db" ".backup '${HERMES_HOME}/backup/state.db'" >> "$LOG" 2>&1
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] state.db not found - skipping sqlite backup." >> "$LOG"
fi

if docker inspect hermes-grafana &>/dev/null; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Stopping grafana for consistent db backup..." >> "$LOG"
  docker stop hermes-grafana >> "$LOG" 2>&1
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Copying grafana.db..." >> "$LOG"
  docker cp hermes-grafana:/var/lib/grafana/grafana.db "$HERMES_HOME/backup/grafana/grafana.db"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting grafana..." >> "$LOG"
  docker start hermes-grafana >> "$LOG" 2>&1
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] hermes-grafana container not found - skipping." >> "$LOG"
fi

if docker inspect hermes-vault &>/dev/null; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Stopping vault for consistent data backup..." >> "$LOG"
  docker stop hermes-vault >> "$LOG" 2>&1
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Copying vault data..." >> "$LOG"
  rm -rf "$HERMES_HOME/backup/vault/" && mkdir -p "$HERMES_HOME/backup/vault/"
  docker cp hermes-vault:/vault/data/. "$HERMES_HOME/backup/vault/" >> "$LOG" 2>&1
  chown -R 10000:10000 "$HERMES_HOME/backup/vault/" >> "$LOG" 2>&1
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting vault..." >> "$LOG"
  docker start hermes-vault >> "$LOG" 2>&1
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] hermes-vault container not found - skipping." >> "$LOG"
fi

# Hindsight backup - pg_dump via unix socket, no stop required
if docker inspect hermes-hindsight &>/dev/null; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backing up hindsight database (pg_dump via unix socket)..." >> "$LOG"
  mkdir -p "$HERMES_HOME/backup/hindsight"

  docker exec hermes-hindsight python3 -c "
import json, os, subprocess
info = json.load(open('/home/hindsight/.pg0/instances/hindsight/instance.json'))
os.environ['LD_LIBRARY_PATH'] = '/home/hindsight/.pg0/installation/18.1.0/lib'
os.environ['PGPASSWORD'] = info['password']
subprocess.run([
    '/home/hindsight/.pg0/installation/18.1.0/bin/pg_dump',
    '-h', '/tmp', '-p', '5432', '-U', 'hindsight', '-d', 'hindsight',
    '--no-owner', '--no-acl', '--clean', '--if-exists'
])
" > "$HERMES_HOME/backup/hindsight/dump.sql" 2>> "$LOG"

  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Hindsight database dumped to backup/hindsight/dump.sql" >> "$LOG"
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] hermes-hindsight container not found - skipping hindsight backup." >> "$LOG"
fi

set -a
source "$HERMES_HOME/.env"
set +a

S3_CONF="/tmp/rclone-hermes-backup.conf"
cat > "$S3_CONF" << EOF
[hermes-s3]
type = s3
provider = Other
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION}
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting Hermes backup to S3 (bucket: ${S3_BUCKET}, dest: ${DEST})..." >> "$LOG"

$RCLONE --config "$S3_CONF" sync "$HERMES_HOME" "hermes-s3:${S3_BUCKET}/${DEST}" \
  --delete-excluded --fast-list \
  --exclude ".cache/**" \
  --exclude "cache/**" \
  --exclude ".npm/**" \
  --exclude "home/.npm/**" \
  --exclude "home/.local/**" \
  --exclude "home/.rustup/**" \
  --exclude "home/.cargo/**" \
  --exclude "bin/rclone" \
  --exclude "bin/tirith" \
  --exclude "home/hermes-backup-*.zip" \
  --exclude ".npm/_npx/**" \
  --exclude "audio_cache/**" \
  --exclude "image_cache/**" \
  --exclude "logs/**" \
  --exclude "cron/output/**" \
  --exclude "sandboxes/**" \
  --exclude "sessions/**" \
  --exclude ".local/share/tirith/**" \
  --exclude ".skills_prompt_snapshot.json" \
  --exclude "models_dev_cache.json" \
  --exclude "ollama_cloud_models_cache.json" \
  --exclude "/state.db" \
  --exclude "state.db-wal" \
  --exclude "state.db-shm" \
  --exclude "lsp/**" \
  --exclude "backup/vector/**" \
  --log-level INFO >> "$LOG" 2>&1

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Backup complete! (dest: ${DEST})" >> "$LOG"
echo "Backup complete. Dest: ${DEST}. Log: $LOG"
rm -f "$S3_CONF"
