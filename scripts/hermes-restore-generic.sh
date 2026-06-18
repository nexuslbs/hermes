#!/bin/bash
# Hermes Agent generic restore script - restores /opt/data from S3 under a specified path
# Usage: bash hermes-restore-generic.sh <src-path>
#   src-path examples: "data", "checkpoint/20260609"
# Single source of truth: lives in /opt/hermes-repo/scripts/hermes-restore-generic.sh
set -euo pipefail

SRC="${1:?Usage: $0 <src-path> (e.g. data or checkpoint/20260609)}"

HERMES_HOME="${HERMES_HOME:-/opt/data}"
REPO_DIR="${REPO_DIR:-/opt/hermes-repo}"
RCLONE="${RCLONE:-/usr/local/bin/rclone}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG="/tmp/hermes-restore-${TIMESTAMP}.log"

mkdir -p "$HERMES_HOME/cron/output"

if [ -f "$HERMES_HOME/.env" ]; then
  set -a
  source "$HERMES_HOME/.env"
  set +a
fi

if [ -z "${S3_ACCESS_KEY:-}" ] || [ -z "${S3_SECRET_KEY:-}" ] || \
   [ -z "${S3_ENDPOINT:-}" ] || [ -z "${S3_BUCKET:-}" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] S3 credentials not configured - skipping restore." | tee -a "$LOG"
  echo "Set S3_ACCESS_KEY, S3_SECRET_KEY, S3_ENDPOINT, S3_REGION, S3_BUCKET in $HERMES_HOME/.env" | tee -a "$LOG"
  exit 0
fi

if ! command -v "$RCLONE" &>/dev/null && [ ! -f "$RCLONE" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: rclone not found at $RCLONE. Install it in the container image (see hermes.Dockerfile)." | tee -a "$LOG"
  exit 1
fi

S3_CONF="/tmp/rclone-hermes-restore.conf"
cat > "$S3_CONF" << EOF
[hermes-s3]
type = s3
provider = Other
access_key_id = ${S3_ACCESS_KEY}
secret_access_key = ${S3_SECRET_KEY}
endpoint = ${S3_ENDPOINT}
region = ${S3_REGION:-us-east-005}
EOF

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring from S3 (bucket: ${S3_BUCKET}, src: ${SRC})..." | tee -a "$LOG"

$RCLONE --config "$S3_CONF" sync "hermes-s3:${S3_BUCKET}/${SRC}" "$HERMES_HOME" \
  --delete-excluded \
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
  --log-level ERROR --stats-one-line 2>&1 | tee -a "$LOG"

echo "[$(date +'%Y-%m-%d %H:%M:%S')] S3 sync complete." | tee -a "$LOG"

if [ -f "$HERMES_HOME/backup/state.db" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring consistent state.db from backup..." | tee -a "$LOG"
  mv "$HERMES_HOME/backup/state.db" "$HERMES_HOME/state.db"
  chown 10000:10000 "$HERMES_HOME/state.db"
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] state.db restored." | tee -a "$LOG"
fi

if [ -f "$HERMES_HOME/backup/grafana/grafana.db" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring grafana database..." | tee -a "$LOG"
  docker stop hermes-grafana >> "$LOG" 2>&1 || true
  docker cp "$HERMES_HOME/backup/grafana/grafana.db" hermes-grafana:/var/lib/grafana/grafana.db >> "$LOG" 2>&1
  docker run --rm -v hermes-grafana:/var/lib/grafana alpine chown 472:0 /var/lib/grafana/grafana.db >> "$LOG" 2>&1 || true
  docker run --rm -v hermes-grafana:/var/lib/grafana alpine chmod 640 /var/lib/grafana/grafana.db >> "$LOG" 2>&1 || true
  docker start hermes-grafana >> "$LOG" 2>&1
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Grafana database restored." | tee -a "$LOG"
fi

if [ -d "$HERMES_HOME/backup/vault" ] && [ "$(ls -A $HERMES_HOME/backup/vault 2>/dev/null)" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring vault data..." | tee -a "$LOG"
  docker stop hermes-vault >> "$LOG" 2>&1 || true
  docker run --rm --volumes-from hermes-vault hermes-repo-toolbox bash -c "rm -rf /vault/data/*"
  docker cp "$HERMES_HOME/backup/vault/." hermes-vault:/vault/data/ >> "$LOG" 2>&1
  docker start hermes-vault >> "$LOG" 2>&1
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Vault data restored." | tee -a "$LOG"
fi

# Hindsight restore - stop, run PG from bundled binaries, restore dump from stdin, restart
if [ -f "$HERMES_HOME/backup/hindsight/dump.sql" ]; then
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restoring hindsight database..." | tee -a "$LOG"

  docker stop hermes-hindsight >> "$LOG" 2>&1 || true

  # Pipe the dump into a temp container that starts PG, runs psql from stdin, and stops PG
  docker run --rm -i -v hermes-hindsight:/home/hindsight/.pg0 \
    --entrypoint bash \
    ghcr.io/vectorize-io/hindsight:latest \
    -c '
exec python3 -c "
import json, os, subprocess, sys
info = json.load(open(\"/home/hindsight/.pg0/instances/hindsight/instance.json\"))
os.environ[\"LD_LIBRARY_PATH\"] = \"/home/hindsight/.pg0/installation/18.1.0/lib\"
os.environ[\"PGPASSWORD\"] = info[\"password\"]

PGDATA = \"/home/hindsight/.pg0/instances/hindsight/data\"
PGBIN = \"/home/hindsight/.pg0/installation/18.1.0/bin\"

print(\"Starting PostgreSQL...\", flush=True)
subprocess.run([PGBIN + \"/pg_ctl\", \"-D\", PGDATA, \"-l\", \"/tmp/pg.log\", \"start\"], check=True)

subprocess.run([PGBIN + \"/pg_isready\", \"-h\", \"/tmp\", \"-q\"], check=True)

print(\"Restoring from stdin...\", flush=True)
psql = subprocess.Popen([PGBIN + \"/psql\", \"-h\", \"/tmp\", \"-U\", \"hindsight\", \"-d\", \"hindsight\"], stdin=sys.stdin)
psql.wait()
if psql.returncode != 0:
    raise SystemExit(psql.returncode)

print(\"Stopping PostgreSQL...\", flush=True)
subprocess.run([PGBIN + \"/pg_ctl\", \"-D\", PGDATA, \"stop\"], check=True)
"
' < "$HERMES_HOME/backup/hindsight/dump.sql" >> "$LOG" 2>&1

  rm -f "$HERMES_HOME/backup/hindsight/dump.sql"

  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Starting hindsight..." | tee -a "$LOG"
  docker start hermes-hindsight >> "$LOG" 2>&1

  echo "[$(date +'%Y-%m-%d %H:%M:%S')] Hindsight database restored." | tee -a "$LOG"
else
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] No hindsight backup found - skipping." | tee -a "$LOG"
fi

echo "[$(date +'%Y-%m-%d %H:%M:%S')] Restore complete! (src: ${SRC})" | tee -a "$LOG"
rm -f "$S3_CONF"
