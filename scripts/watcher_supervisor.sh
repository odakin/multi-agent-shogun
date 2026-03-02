#!/bin/bash
set -euo pipefail

# Keep inbox watchers alive in a persistent tmux-hosted shell.
# This script is designed to run forever.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

mkdir -p logs queue/inbox

ensure_inbox_file() {
    local agent="$1"
    if [ ! -f "queue/inbox/${agent}.yaml" ]; then
        printf 'messages: []\n' > "queue/inbox/${agent}.yaml"
    fi
}

pane_exists() {
    local pane="$1"
    tmux list-panes -a -F "#{session_name}:#{window_name}.#{pane_index}" 2>/dev/null | grep -qx "$pane"
}

start_watcher_if_missing() {
    local agent="$1"
    local pane="$2"
    local log_file="$3"
    local cli

    ensure_inbox_file "$agent"
    if ! pane_exists "$pane"; then
        return 0
    fi

    if pgrep -f "scripts/inbox_watcher.sh ${agent} " >/dev/null 2>&1; then
        return 0
    fi

    cli=$(tmux show-options -p -t "$pane" -v @agent_cli 2>/dev/null || echo "codex")
    nohup bash scripts/inbox_watcher.sh "$agent" "$pane" "$cli" >> "$log_file" 2>&1 &
}

# Read pane-base-index dynamically (matches switch_cli.sh behavior)
get_pane_base() {
    tmux show-options -t multiagent -v @pane_base 2>/dev/null || echo "0"
}

# Read ashigaru_count from settings.yaml (default: 7)
get_ashigaru_count() {
    local count
    count=$(grep "^  ashigaru_count:" "$SCRIPT_DIR/config/settings.yaml" 2>/dev/null \
        | head -1 | sed 's/^  ashigaru_count:[[:space:]]*//' | tr -d '[:space:]')
    if [[ "$count" =~ ^[1-9]$ ]]; then
        echo "$count"
    else
        echo "7"
    fi
}

while true; do
    PANE_BASE=$(get_pane_base)
    ASHIGARU_COUNT=$(get_ashigaru_count)

    start_watcher_if_missing "shogun" "shogun:main.0" "logs/inbox_watcher_shogun.log"
    start_watcher_if_missing "karo" "multiagent:agents.$((PANE_BASE + 0))" "logs/inbox_watcher_karo.log"

    for i in $(seq 1 "$ASHIGARU_COUNT"); do
        start_watcher_if_missing "ashigaru${i}" "multiagent:agents.$((PANE_BASE + i))" "logs/inbox_watcher_ashigaru${i}.log"
    done

    start_watcher_if_missing "gunshi" "multiagent:agents.$((PANE_BASE + ASHIGARU_COUNT + 1))" "logs/inbox_watcher_gunshi.log"
    sleep 5
done
