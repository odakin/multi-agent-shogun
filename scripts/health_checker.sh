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

# ─── Nudge cooldown (prevent repeated nudges to same agent) ───
declare -A LAST_NUDGE_TIME=()
NUDGE_COOLDOWN=90  # seconds — don't re-nudge same agent within 90s

# ─── Stale task detection (nudged but YAML unchanged) ───
declare -A NUDGE_COUNT=()         # per-agent nudge count for same stale task
declare -A NUDGE_TASK_ID=()       # task_id at first nudge
STALE_TASK_NUDGE_LIMIT=3          # after N nudges with no status change → auto-fix

is_nudge_cooled_down() {
    local agent="$1"
    local now
    now=$(date +%s)
    local last="${LAST_NUDGE_TIME[$agent]:-0}"
    if (( now - last < NUDGE_COOLDOWN )); then
        return 1  # still cooling down
    fi
    LAST_NUDGE_TIME[$agent]=$now
    return 0  # OK to nudge
}

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

# ─── Task ID check ───
get_task_id() {
    local agent="$1"
    local task_file="$SCRIPT_DIR/queue/tasks/${agent}.yaml"
    [ -f "$task_file" ] || { echo ""; return; }
    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
with open('$task_file') as f:
    data = yaml.safe_load(f) or {}
task = data.get('task', {}) or {}
print(task.get('task_id', '') or '')
" 2>/dev/null || echo ""
}

# ─── Auto-fix stale task YAML ───
# If agent was nudged N times for same assigned task but status never changed,
# the agent likely completed it but forgot to update YAML.
# Safety net: update status to done + log.
auto_fix_stale_task() {
    local agent="$1"
    local task_file="$SCRIPT_DIR/queue/tasks/${agent}.yaml"
    [ -f "$task_file" ] || return 1

    "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml, datetime
with open('$task_file') as f:
    data = yaml.safe_load(f) or {}
task = data.get('task', {}) or {}
if task.get('status') in ('assigned', 'in_progress'):
    task['status'] = 'done'
    task['auto_closed_by'] = 'health_checker'
    task['auto_closed_at'] = datetime.datetime.now().strftime('%Y-%m-%dT%H:%M:%S')
    task['auto_closed_reason'] = 'Agent idle after ${STALE_TASK_NUDGE_LIMIT} recovery nudges — status likely stale'
    data['task'] = task
    with open('$task_file', 'w') as f:
        yaml.dump(data, f, allow_unicode=True, default_flow_style=False)
    print('fixed')
else:
    print('skip')
" 2>/dev/null || echo "error"
}

# ─── Send nudge ───
send_nudge() {
    local agent="$1"
    local pane="$2"
    local message="$3"

    # Cooldown check — don't re-nudge same agent within 5 minutes
    if ! is_nudge_cooled_down "$agent"; then
        return 0  # recently nudged, skip
    fi

    # Check if busy — don't nudge during active processing
    if type agent_is_busy_check &>/dev/null; then
        if agent_is_busy_check "$pane"; then
            LAST_NUDGE_TIME[$agent]=0  # reset cooldown — wasn't actually nudged
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
    # Karo's "task" is in queue/cmds/ (per-cmd files).
    # If any cmd is in_progress → send_nudge (which internally skips if truly busy).
    # Must run before generic busy check because old "thinking" text in pane
    # history causes false-busy detection for karo after compaction.
    if [ "$agent" = "karo" ]; then
        local has_active_cmd
        has_active_cmd=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml, glob
found = False
for f in glob.glob('$SCRIPT_DIR/queue/cmds/*.yaml'):
    with open(f) as fh:
        data = yaml.safe_load(fh) or {}
    if isinstance(data, dict) and data.get('status') == 'in_progress':
        found = True; break
print('yes' if found else 'no')
" 2>/dev/null || echo "no")
        if [ "$has_active_cmd" = "yes" ]; then
            # send_nudge internally calls agent_is_busy_check — skips if truly busy
            send_nudge "$agent" "$pane" "compact-recovery: cmd in_progress あり。queue/cmds/ を読んで指揮を再開せよ"
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
        # Track stale nudge count per task
        local current_task_id
        current_task_id=$(get_task_id "$agent")
        local prev_task="${NUDGE_TASK_ID[$agent]:-}"

        if [ "$current_task_id" != "$prev_task" ]; then
            # New task or first time — reset counter
            NUDGE_COUNT[$agent]=0
            NUDGE_TASK_ID[$agent]="$current_task_id"
        fi

        local count="${NUDGE_COUNT[$agent]:-0}"
        count=$((count + 1))
        NUDGE_COUNT[$agent]=$count

        if (( count > STALE_TASK_NUDGE_LIMIT )); then
            # Agent was nudged N+ times but YAML never updated → auto-fix
            local result
            result=$(auto_fix_stale_task "$agent")
            if [ "$result" = "fixed" ]; then
                log "STALE-AUTO-FIX $agent: task $current_task_id status → done (after $count nudges)"
                NUDGE_COUNT[$agent]=0
                NUDGE_TASK_ID[$agent]=""
            fi
        else
            # Normal compact-recovery nudge
            send_nudge "$agent" "$pane" "compact-recovery: queue/tasks/${agent}.yaml を読んでタスクを再開せよ。完了済みなら status を done に更新せよ。"
        fi
    else
        # Task is done/none — reset stale counter
        NUDGE_COUNT[$agent]=0
        NUDGE_TASK_ID[$agent]=""
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
