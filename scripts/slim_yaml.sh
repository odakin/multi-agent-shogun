#!/bin/bash
#
# slim_yaml.sh - YAML slimming wrapper with file locking
#
# Usage: bash slim_yaml.sh <agent_id>
#
# This script acquires an exclusive lock before calling the Python slimmer,
# ensuring no concurrent modifications to YAML files (same pattern as inbox_write.sh).
#

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="${SCRIPT_DIR}/queue/.slim_yaml.lock"
LOCK_TIMEOUT=10

# Acquire global slim lock
exec 200>"$LOCK_FILE"
if ! flock -w "$LOCK_TIMEOUT" 200; then
    echo "Error: Failed to acquire slim lock within $LOCK_TIMEOUT seconds" >&2
    exit 1
fi

# Also acquire inbox-specific lock (same lock as inbox_write.sh) to prevent race condition:
# inbox_write.sh uses queue/inbox/<agent>.yaml.lock as its lock file.
# Without this, slim_yaml.py can read-modify-write the inbox while inbox_write.sh
# is mid-write, causing the newly added message to be silently dropped (messages:[]).
AGENT_ID="${1:-}"
if [ -n "$AGENT_ID" ]; then
    INBOX_LOCK="${SCRIPT_DIR}/queue/inbox/${AGENT_ID}.yaml.lock"
    exec 201>"$INBOX_LOCK"
    if ! flock -w "$LOCK_TIMEOUT" 201; then
        echo "Error: Failed to acquire inbox lock for $AGENT_ID within $LOCK_TIMEOUT seconds" >&2
        exit 1
    fi
fi

# Call the Python implementation (.venv to ensure PyYAML is available)
"$SCRIPT_DIR/.venv/bin/python3" "$SCRIPT_DIR/scripts/slim_yaml.py" "$@"
exit_code=$?

# Lock is automatically released when file descriptor is closed
exit "$exit_code"
