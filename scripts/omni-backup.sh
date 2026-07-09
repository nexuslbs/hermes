#!/bin/bash
# Convenience wrapper — calls omni-backup-generic.sh with dest=data
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/omni-backup-generic.sh" "data"
