#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# health_checker.sh — 全エージェント巡回ヘルスチェック（案A）
#
# inbox_watcher.sh (10プロセス) + watcher_supervisor.sh を
# 1つのプロセスに統合。30秒間隔で全エージェントを巡回する。
#
# 設計思想:
#   メッセージ配達の一次手段 = inbox_write.sh の nudge (push型)
#   メッセージ配達の二次手段 = Stop hook (turn間チェック)
#   本スクリプトの役割 = 保険 (stuck検出 + 未読リトライ + compact復旧)
#
# Usage: bash scripts/health_checker.sh [interval_sec]
# Default interval: 30 seconds
# ═══════════════════════════════════════════════════════════════

set -uo pipefail
# NOTE: set -e は意図的に使わない。1エージェントの検査失敗で全体を止めない。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INTERVAL="${1:-30}"
LOG_PREFIX="[health_checker]"

# Source shared libraries
source "$SCRIPT_DIR/lib/agent_status.sh" 2>/dev/null || true

log() { echo "[$(date '+%H:%M:%S')] $LOG_PREFIX $*" >&2; }

# ─── Agent discovery ───
# tmux @agent_id から全エージェントのpane_id を動的に取得
get_agent_panes() {
    tmux list-panes -a -F '#{pane_id} #{@agent_id}' 2>/dev/null | \
        while IFS=' ' read -r pane_id agent_id; do
            [ -n "$agent_id" ] && echo "$agent_id $pane_id"
        done
}

# ─── Unread count (lightweight) ───
count_unread() {
    local agent="$1"
    local inbox="$SCRIPT_DIR/queue/inbox/${agent}.yaml"
    [ -f "$inbox" ] || { echo 0; return; }
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
with open('$inbox') as f:
    data = yaml.safe_load(f) or {}
msgs = data.get('messages', []) or []
print(sum(1 for m in msgs if not m.get('read', False)))
" 2>/dev/null || echo 0
}

# ─── Task status check ───
# Returns: assigned, done, idle, none
get_task_status() {
    local agent="$1"
    local task_file="$SCRIPT_DIR/queue/tasks/${agent}.yaml"
    [ -f "$task_file" ] || { echo "none"; return; }
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
with open('$task_file') as f:
    data = yaml.safe_load(f) or {}
task = data.get('task', {}) or {}
print(task.get('status', 'none') or 'none')
" 2>/dev/null || echo "none"
}

# ─── Send nudge ───
send_nudge() {
    local agent="$1"
    local pane="$2"
    local message="$3"

    # Check if busy — don't nudge during active processing
    if type agent_is_busy_check &>/dev/null; then
        if agent_is_busy_check "$pane"; then
            return 0  # busy, skip
        fi
    fi

    # Transcript view detection: escape first, then nudge
    local pane_tail
    pane_tail=$(timeout 2 tmux capture-pane -t "$pane" -p 2>/dev/null | tail -15)
    if echo "$pane_tail" | grep -qiE "Showing detailed transcript|ctrl.o to toggle"; then
        log "TRANSCRIPT-ESCAPE $agent: exiting transcript view before nudge"
        timeout 2 tmux send-keys -t "$pane" Escape 2>/dev/null || return 0
        sleep 0.5
        timeout 2 tmux send-keys -t "$pane" Escape 2>/dev/null || return 0
        sleep 1
    fi

    # Send nudge text + Enter (separated for Codex TUI compatibility)
    timeout 5 tmux send-keys -t "$pane" "$message" 2>/dev/null || return 0
    sleep 0.3
    timeout 5 tmux send-keys -t "$pane" Enter 2>/dev/null || return 0
    log "NUDGE $agent: $message"
}

# ─── Check one agent ───
check_agent() {
    local agent="$1"
    local pane="$2"

    # 1. Stuck detection (feedback prompts, session end dialogs, etc.)
    if type agent_stuck_check &>/dev/null; then
        if agent_stuck_check "$pane" "$agent"; then
            log "STUCK-RECOVERED $agent"
            # Notify karo (unless this IS karo/shogun)
            if [ "$agent" != "karo" ] && [ "$agent" != "shogun" ]; then
                bash "$SCRIPT_DIR/scripts/inbox_write.sh" karo \
                    "${agent}がスタックしていたため自動復旧（health_checker）。タスク状態を確認せよ。" \
                    stuck_recovery health_checker 2>/dev/null || true
            fi
            return 0
        fi
    fi

    # 2. Unread inbox messages → nudge if agent is idle
    local unread
    unread=$(count_unread "$agent")
    if [ "$unread" -gt 0 ]; then
        send_nudge "$agent" "$pane" "inbox${unread}"
        return 0
    fi

    # 3. Post-compact recovery: assigned task but idle with no unread
    #    (agent compact'd, lost context, sitting at prompt with nothing to do)
    #    Skip for shogun (human-controlled)
    if [ "$agent" = "shogun" ]; then
        return 0
    fi

    # === Karo special case (BEFORE busy check) ===
    # Karo's "task" is in shogun_to_karo.yaml (not queue/tasks/karo.yaml).
    # If cmd is in_progress → send_nudge (which internally skips if truly busy).
    # Must run before generic busy check because old "thinking" text in pane
    # history causes false-busy detection for karo after compaction.
    if [ "$agent" = "karo" ]; then
        local has_active_cmd
        has_active_cmd=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
with open('$SCRIPT_DIR/queue/shogun_to_karo.yaml') as f:
    data = yaml.safe_load(f) or []
cmds = data if isinstance(data, list) else [data]
print('yes' if any(c.get('status') == 'in_progress' for c in cmds if isinstance(c, dict)) else 'no')
" 2>/dev/null || echo "no")
        if [ "$has_active_cmd" = "yes" ]; then
            # send_nudge internally calls agent_is_busy_check — skips if truly busy
            send_nudge "$agent" "$pane" "compact-recovery: cmd in_progress あり。queue/shogun_to_karo.yaml を読んで指揮を再開せよ"
        fi
        return 0
    fi

    # Check if agent is actually idle (not busy processing)
    if type agent_is_busy_check &>/dev/null; then
        if agent_is_busy_check "$pane"; then
            return 0  # busy = working on it, all good
        fi
    fi

    # === Ashigaru / Gunshi ===
    local task_status
    task_status=$(get_task_status "$agent")
    if [ "$task_status" = "assigned" ] || [ "$task_status" = "in_progress" ]; then
        # Agent is idle + has assigned/in_progress task = likely post-compact
        send_nudge "$agent" "$pane" "compact-recovery: queue/tasks/${agent}.yaml を読んでタスクを再開せよ"
    fi
}

# ─── Main loop ───
log "started (interval=${INTERVAL}s)"

while true; do
    # Discover all agent panes dynamically
    while IFS=' ' read -r agent pane; do
        check_agent "$agent" "$pane" || true
    done < <(get_agent_panes)

    sleep "$INTERVAL"
done
