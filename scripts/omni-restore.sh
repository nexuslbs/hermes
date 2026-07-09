#!/bin/bash
# Convenience wrapper — calls omni-restore-generic.sh with src=data
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/omni-restore-generic.sh" "data"
