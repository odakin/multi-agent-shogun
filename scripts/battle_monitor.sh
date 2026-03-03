#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# battle_monitor.sh — 全画面リアルタイム戦況モニター
# ═══════════════════════════════════════════════════════════════
# 全エージェントのペイン出力を1画面に集約してリアルタイム表示。
# 稼働中エージェントは出力を最大N行表示、待機中は1行に圧縮。
#
# Usage:
#   bash scripts/battle_monitor.sh              # デフォルト (1秒更新)
#   bash scripts/battle_monitor.sh --interval 2 # 2秒更新
#   bash scripts/battle_monitor.sh --lines 8    # 稼働中8行表示
#   bash scripts/battle_monitor.sh --compact    # 稼働中3行
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── Defaults ───
INTERVAL=1
BUSY_LINES=6
COMPACT=false

# ─── Parse args ───
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --lines)    BUSY_LINES="$2"; shift 2 ;;
        --compact)  COMPACT=true; BUSY_LINES=3; shift ;;
        --help|-h)
            echo "Usage: battle_monitor.sh [--interval N] [--lines N] [--compact]"
            exit 0
            ;;
        *) shift ;;
    esac
done

# ─── Load shared library ───
source "$SCRIPT_DIR/lib/agent_status.sh" 2>/dev/null || true

# ─── Python path ───
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

# ─── Agent list ───
AGENTS=("karo" "ashigaru1" "ashigaru2" "ashigaru3" "ashigaru4" "ashigaru5" "ashigaru6" "ashigaru7" "gunshi")

# ─── Color codes ───
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_RED=$'\033[31m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'
C_WHITE=$'\033[37m'
C_BG_NONE=$'\033[49m'

# ─── Activity feed state ───
declare -a ACTIVITY_LOG=()       # ring buffer of "[HH:MM] from: content"
declare -A PREV_MSG_COUNT=()     # per-agent inbox message count tracker
MAX_ACTIVITY=200                 # max entries to keep
FEED_INITIALIZED=false           # skip existing msgs on first run, load last N

# ─── Terminal setup ───
setup_terminal() {
    tput smcup 2>/dev/null   # alternate screen
    tput civis 2>/dev/null   # hide cursor
    # Clear alternate screen once
    tput clear 2>/dev/null
}

cleanup_terminal() {
    tput cnorm 2>/dev/null   # show cursor
    tput rmcup 2>/dev/null   # restore screen
}

trap cleanup_terminal EXIT INT TERM

# ─── Agent → Pane mapping ───
# Returns associative-array-like lines: "agent pane_id"
declare -A AGENT_PANES
refresh_pane_map() {
    AGENT_PANES=()
    while IFS=' ' read -r pane_id agent_id; do
        [[ -n "$agent_id" && "$agent_id" != "..." ]] && AGENT_PANES["$agent_id"]="$pane_id"
    done < <(tmux list-panes -a -F '#{pane_id} #{@agent_id}' 2>/dev/null)
}

# ─── Get agent state ───
# Returns: "busy" / "idle" / "absent"
get_agent_state() {
    local agent="$1"
    local pane="${AGENT_PANES[$agent]:-}"
    [[ -z "$pane" ]] && { echo "absent"; return; }

    agent_is_busy_check "$pane" 2>/dev/null
    local rc=$?
    case $rc in
        0) echo "busy" ;;
        1) echo "idle" ;;
        2) echo "absent" ;;
        *) echo "idle" ;;
    esac
}

# ─── Capture pane output (last N lines, non-empty) ───
capture_pane_tail() {
    local pane="$1" lines="$2"
    tmux capture-pane -t "$pane" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -"$lines"
}

# ─── Python bulk data fetch ───
# Returns JSON with task_id, status, unread per agent + _cmd + _new_events + _msg_counts
fetch_yaml_data() {
    # Serialize prev msg counts as Python dict
    local prev_counts_py="{"
    local _first=true
    for _agent in "${!PREV_MSG_COUNT[@]}"; do
        $_first || prev_counts_py+=","
        prev_counts_py+="\"$_agent\":${PREV_MSG_COUNT[$_agent]}"
        _first=false
    done
    prev_counts_py+="}"

    "$PYTHON" -c "
import yaml, json, os, sys

root = '$SCRIPT_DIR'
agents = $( printf "'%s'," "${AGENTS[@]}" | sed 's/,$//' | sed 's/^/[/;s/$/]/' )
prev_counts = ${prev_counts_py}
result = {}

for agent in agents:
    tid, status, unread = '---', '---', 0
    try:
        with open(f'{root}/queue/tasks/{agent}.yaml') as f:
            t = (yaml.safe_load(f) or {}).get('task', {}) or {}
            tid = t.get('task_id', '---') or '---'
            status = t.get('status', '---') or '---'
    except: pass
    try:
        with open(f'{root}/queue/inbox/{agent}.yaml') as f:
            msgs = (yaml.safe_load(f) or {}).get('messages', []) or []
            unread = sum(1 for m in msgs if not m.get('read', False))
    except: pass
    result[agent] = {'task_id': str(tid), 'status': str(status), 'unread': unread}

# Current cmd (per-cmd files + recent archive)
try:
    import glob
    all_cmds = []
    for cf in sorted(glob.glob(f'{root}/queue/cmds/*.yaml')):
        with open(cf) as f:
            cmd = yaml.safe_load(f) or {}
        if isinstance(cmd, dict):
            cid = cmd.get('id') or '?'
            purpose = cmd.get('purpose') or cmd.get('description', '?') or '?'
            if isinstance(purpose, str): purpose = purpose.strip().replace('\n', ' ')
            status = cmd.get('status', '?') or '?'
            all_cmds.append({'id': cid, 'status': status, 'purpose': purpose, 'archived': False})
    for cf in sorted(glob.glob(f'{root}/queue/archive/cmd_*.yaml')):
        with open(cf) as f:
            cmd = yaml.safe_load(f) or {}
        if isinstance(cmd, dict):
            cid = cmd.get('id') or '?'
            purpose = cmd.get('purpose') or cmd.get('description', '?') or '?'
            if isinstance(purpose, str): purpose = purpose.strip().replace('\n', ' ')
            status = cmd.get('status', '?') or '?'
            all_cmds.append({'id': cid, 'status': status, 'purpose': purpose, 'archived': True})
    def cmd_num(c):
        try: return int(c['id'].replace('cmd_',''))
        except: return 0
    all_cmds.sort(key=cmd_num, reverse=True)
    result['_cmds'] = all_cmds[:10]
    active_parts = [f"{c['id']}: {c['purpose'][:40]}" for c in all_cmds if not c['archived']]
    result['_cmd'] = ' / '.join(active_parts) if active_parts else '(指令なし)'
except:
    result['_cmd'] = '(指令なし)'
    result['_cmds'] = []

# Collect inbox events from ALL agents + shogun
new_events = []
msg_counts = {}
first_run = not bool(prev_counts)  # empty dict = first run
all_targets = agents + ['shogun']

# On first run: collect last N messages across all inboxes for initial context
all_msgs_for_seed = []
for target in all_targets:
    try:
        with open(f'{root}/queue/inbox/{target}.yaml') as f:
            msgs = (yaml.safe_load(f) or {}).get('messages', []) or []
    except:
        msgs = []
    msg_counts[target] = len(msgs)
    prev = prev_counts.get(target, 0)
    if first_run:
        # Seed: collect last 3 messages per inbox for initial display
        for m in msgs[-3:]:
            ts = str(m.get('timestamp', ''))
            ts_short = ts[11:16] if len(ts) > 16 else ts[-5:]
            frm = str(m.get('from', '?'))
            content = str(m.get('content', ''))[:40].replace(chr(10), ' ')
            all_msgs_for_seed.append((ts, f'[{ts_short}] {frm}: {content}'))
    elif len(msgs) > prev:
        for m in msgs[prev:]:
            ts = str(m.get('timestamp', ''))
            ts_short = ts[11:16] if len(ts) > 16 else ts[-5:]
            frm = str(m.get('from', '?'))
            content = str(m.get('content', ''))[:40].replace(chr(10), ' ')
            new_events.append(f'[{ts_short}] {frm}: {content}')

if first_run:
    # Sort seed messages by timestamp, take last 20
    all_msgs_for_seed.sort(key=lambda x: x[0])
    new_events = [m[1] for m in all_msgs_for_seed[-20:]]

result['_new_events'] = new_events
result['_msg_counts'] = msg_counts

# Lord pending decisions (awaiting_lord only) — P1: awk廃止しPythonで堅牢パース
lord_pending = []
try:
    from datetime import datetime, timezone
    with open(f'{root}/queue/lord_pending.yaml') as f:
        lp_data = yaml.safe_load(f) or {}
    now_dt = datetime.now(timezone.utc)
    for item in (lp_data.get('pending_decisions') or []):
        if item.get('status') == 'awaiting_lord':
            reported_at = str(item.get('reported_at', ''))
            age = ''
            try:
                dt = datetime.fromisoformat(reported_at.replace('Z', '+00:00'))
                if dt.tzinfo is None:
                    dt = dt.replace(tzinfo=timezone.utc)
                hours = int((now_dt - dt).total_seconds() // 3600)
                age = f'{hours}時間前' if hours < 24 else f'{hours // 24}日前'
            except: pass
            lord_pending.append({
                'cmd_id': str(item.get('cmd_id', '?')),
                'title': str(item.get('title', '?')),
                'summary': str(item.get('summary', '')),
                'age': age,
            })
except: pass
result['_lord_pending'] = lord_pending

json.dump(result, sys.stdout, ensure_ascii=False)
" 2>/dev/null || echo '{}'
}

# ─── Task status icon ───
task_icon() {
    local status="$1"
    case "$status" in
        assigned|in_progress) echo "🔥" ;;
        completed|done)       echo "✅" ;;
        blocked)              echo "🚫" ;;
        *)                    echo "  " ;;
    esac
}

# ─── State icon ───
state_icon() {
    local state="$1"
    case "$state" in
        busy)   echo "${C_GREEN}🟢稼働${C_RESET}" ;;
        idle)   echo "${C_DIM}⚪待機${C_RESET}" ;;
        absent) echo "${C_RED}🔴不在${C_RESET}" ;;
    esac
}

# ─── Truncate string to fit terminal width ───
# Accounts for CJK double-width characters
truncate_str() {
    local str="$1" max="$2"
    local i=0 w=0 c
    while [[ $i -lt ${#str} ]]; do
        c="${str:$i:1}"
        # ASCII = width 1, non-ASCII (CJK etc.) = width 2 (approximation)
        if [[ "$c" == [[:ascii:]] ]]; then
            ((w++))
        else
            ((w+=2))
        fi
        if [[ $w -ge $max ]]; then
            echo "${str:0:$i}…"
            return
        fi
        ((i++))
    done
    echo "$str"
}

# ─── Render one cycle ───
render() {
    local term_width term_height
    # stty size is more reliable than tput inside tmux split panes
    read -r term_height term_width < <(stty size 2>/dev/null || echo "40 80")

    # Fetch all data
    refresh_pane_map
    local yaml_json
    yaml_json=$(fetch_yaml_data)

    # Parse JSON (lightweight — use Python to extract)
    local parsed
    parsed=$("$PYTHON" -c "
import json, sys
data = json.loads(sys.stdin.read())
agents = $( printf "'%s'," "${AGENTS[@]}" | sed 's/,$//' | sed 's/^/[/;s/$/]/' )
for a in agents:
    d = data.get(a, {})
    print(f\"{a}\t{d.get('task_id','---')}\t{d.get('status','---')}\t{d.get('unread',0)}\")
print(f\"_cmd\t{data.get('_cmd','')}\")
# New events (one per line)
for e in data.get('_new_events', []):
    print(f'_event\t{e}')
# Message counts (agent\tcount)
for k, v in data.get('_msg_counts', {}).items():
    print(f'_count\t{k}\t{v}')
# Lord pending items
for item in data.get('_lord_pending', []):
    print(f\"_lord\t{item['cmd_id']}\t{item['title']}\t{item['summary']}\t{item['age']}\")
# Cmd table items
_STATUS_EMOJI = {'pending': '⏳', 'in_progress': '🔄', 'done': '✅', 'qc_pass': '✅', 'failed': '❌', 'deferred': '⏸'}
for c in data.get('_cmds', []):
    cid = str(c.get('id', '?'))
    cstat = str(c.get('status', '?'))
    cpurp = str(c.get('purpose', '?'))[:25]
    emoji = _STATUS_EMOJI.get(cstat, cstat)
    print(f'_cmds\t{cid}\t{emoji}\t{cpurp}')
" <<< "$yaml_json" 2>/dev/null)

    # Parse into arrays
    declare -A TASK_ID TASK_STATUS UNREAD
    declare -a LORD_ITEMS=()
    declare -a CMD_ITEMS=()
    local CMD_LINE=""
    while IFS=$'\t' read -r key v1 v2 v3 v4; do
        case "$key" in
            _cmd)   CMD_LINE="$v1" ;;
            _event) [[ -n "$v1" ]] && ACTIVITY_LOG+=("$v1") ;;
            _count) [[ -n "$v1" && -n "$v2" ]] && PREV_MSG_COUNT["$v1"]="$v2" ;;
            _lord)  [[ -n "$v1" ]] && LORD_ITEMS+=("${v1}	${v2}	${v3}	${v4}") ;;
            _cmds)  [[ -n "$v1" ]] && CMD_ITEMS+=("${v1}	${v2}	${v3}") ;;
            *)
                TASK_ID["$key"]="$v1"
                TASK_STATUS["$key"]="$v2"
                UNREAD["$key"]="$v3"
                ;;
        esac
    done <<< "$parsed"
    local lord_count=${#LORD_ITEMS[@]}
    local cmd_count=${#CMD_ITEMS[@]}
    local cmd_table_lines=0
    [[ $cmd_count -gt 0 ]] && cmd_table_lines=$(( cmd_count + 2 ))

    # Trim activity log to max
    while [[ ${#ACTIVITY_LOG[@]} -gt $MAX_ACTIVITY ]]; do
        ACTIVITY_LOG=("${ACTIVITY_LOG[@]:1}")
    done

    # Classify agents
    local busy_agents=() idle_agents=()
    declare -A AGENT_STATE
    for agent in "${AGENTS[@]}"; do
        local state
        state=$(get_agent_state "$agent")
        AGENT_STATE["$agent"]="$state"
        if [[ "$state" == "busy" ]]; then
            busy_agents+=("$agent")
        else
            idle_agents+=("$agent")
        fi
    done

    # Calculate lines available for busy agents
    local busy_count=${#busy_agents[@]}
    local idle_count=${#idle_agents[@]}
    # Fixed lines: header(2) + separator(1) + idle section(~ceil(idle_count/3)+1) + footer(2) + separators(busy_count)
    local idle_rows=$(( (idle_count + 2) / 3 ))  # 3 agents per row
    [[ $idle_count -gt 0 ]] && idle_rows=$((idle_rows + 1))  # +1 for separator
    local fixed_lines=$((2 + 1 + cmd_table_lines + idle_rows + 2 + busy_count))
    local avail_for_busy=$((term_height - fixed_lines))
    local lines_per_busy=$BUSY_LINES
    if [[ $busy_count -gt 0 ]]; then
        local max_per=$((avail_for_busy / busy_count))
        [[ $max_per -lt 2 ]] && max_per=2
        [[ $lines_per_busy -gt $max_per ]] && lines_per_busy=$max_per
    fi

    # ─── Build output buffer ───
    local buf=""
    local sep_line
    sep_line=$(printf '=%.0s' $(seq 1 "$term_width"))
    local thin_sep
    thin_sep=$(printf -- '-%.0s' $(seq 1 "$term_width"))
    local now
    now=$(date '+%H:%M:%S')

    # Header
    local cmd_short
    cmd_short=$(truncate_str "$CMD_LINE" $((term_width - 30)))
    buf+="${C_BOLD}${C_CYAN} 🏯 ${cmd_short}${C_RESET}\n"
    local lord_badge=""
    [[ ${lord_count:-0} -gt 0 ]] && lord_badge=" │ ${C_YELLOW}${C_BOLD}🚨裁可待ち${lord_count}${C_RESET}"
    buf+=" ${C_GREEN}稼働${busy_count}${C_RESET} │ ${C_DIM}待機${idle_count}${C_RESET} │ 未読$(( $(for a in "${AGENTS[@]}"; do echo "${UNREAD[$a]:-0}"; done | paste -sd+ | bc 2>/dev/null || echo 0) ))${lord_badge}  ${C_DIM}${now}${C_RESET}\n"
    buf+="${C_DIM}${sep_line}${C_RESET}\n"

    # Cmd table (OPT-A: sep_line直後、lord_pending前)
    if [[ $cmd_count -gt 0 ]]; then
        buf+=" ${C_BOLD}📋 cmd一覧${C_RESET}\n"
        for cmd_item in "${CMD_ITEMS[@]}"; do
            IFS=$'\t' read -r cid cemoji cpurpose <<< "$cmd_item"
            local cpurp_short
            cpurp_short=$(truncate_str "$cpurpose" $((term_width - 16)))
            buf+="  ${C_BOLD}${cid}${C_RESET} ${cemoji}  ${C_DIM}${cpurp_short}${C_RESET}\n"
        done
        buf+="${C_DIM}${thin_sep}${C_RESET}\n"
    fi

    # Lord pending (裁可待ち) section — P1:awk廃止 P2:視認性強化 P4:経過時間 P5:summary表示 P6:幅制限
    if [[ ${lord_count:-0} -gt 0 ]]; then
        buf+="${C_YELLOW}${C_BOLD}▶▶ 🚨 裁可待ち ${lord_count}件 — ご決裁をお待ちしております ◀◀${C_RESET}\n"
        for lord_item in "${LORD_ITEMS[@]}"; do
            IFS=$'\t' read -r lcmd ltitle lsummary lage <<< "$lord_item"
            local age_str=""
            [[ -n "$lage" ]] && age_str=" (${lage})"
            local item_line
            item_line=$(truncate_str "  📋 ${lcmd}  ${ltitle}${age_str}" $((term_width - 2)))
            buf+="${C_YELLOW}${C_BOLD}${item_line}${C_RESET}\n"
            if [[ -n "$lsummary" ]]; then
                local sum_short
                sum_short=$(truncate_str "     └ ${lsummary}" $((term_width - 2)))
                buf+="  ${C_DIM}${sum_short}${C_RESET}\n"
            fi
        done
        buf+="${C_YELLOW}${C_DIM}${thin_sep}${C_RESET}\n"
    fi

    # Busy agents (expanded)
    for agent in "${busy_agents[@]}"; do
        local pane="${AGENT_PANES[$agent]:-}"
        local tid="${TASK_ID[$agent]:----}"
        local tstat="${TASK_STATUS[$agent]:----}"
        local unread="${UNREAD[$agent]:-0}"
        local icon
        icon=$(task_icon "$tstat")

        # Header line
        local short_name="$agent"
        [[ "$agent" =~ ^ashigaru ]] && short_name="ash${agent#ashigaru}"
        local tid_short
        tid_short=$(truncate_str "$tid" $((term_width - 22)))
        buf+="${C_BOLD}▶ ${short_name}${C_RESET} $(state_icon busy) ${icon}${tid_short} │ inbox:${unread}\n"

        # Pane content
        if [[ -n "$pane" ]]; then
            local content
            content=$(capture_pane_tail "$pane" "$lines_per_busy")
            while IFS= read -r line; do
                local trimmed
                trimmed=$(truncate_str "$line" $((term_width - 4)))
                buf+="  ${C_DIM}${trimmed}${C_RESET}\n"
            done <<< "$content"
        fi
        buf+="${C_DIM}${thin_sep}${C_RESET}\n"
    done

    # Idle agents (1 per line, clean format)
    if [[ ${#idle_agents[@]} -gt 0 ]]; then
        buf+="\n"
        local max_tid_len=$((term_width - 16))
        [[ $max_tid_len -lt 6 ]] && max_tid_len=6
        for agent in "${idle_agents[@]}"; do
            local tid="${TASK_ID[$agent]:----}"
            local tstat="${TASK_STATUS[$agent]:----}"
            local unread="${UNREAD[$agent]:-0}"
            local icon
            icon=$(task_icon "$tstat")
            local short_name="$agent"
            [[ "$agent" =~ ^ashigaru ]] && short_name="ash${agent#ashigaru}"

            local tid_short
            tid_short=$(truncate_str "$tid" "$max_tid_len")

            local unread_mark=""
            [[ "$unread" -gt 0 ]] && unread_mark=" ${C_YELLOW}✉${unread}${C_RESET}"

            buf+="  ${C_DIM}⚪${short_name}${C_RESET} ${icon}${C_DIM}${tid_short}${C_RESET}${unread_mark}\n"
        done
    fi

    # ─── Activity feed ───
    buf+="${C_DIM}${sep_line}${C_RESET}\n"
    local line_count=0
    # Count lines used so far (count \n in buf)
    local tmp="${buf//[!\\]/}"
    # Approximate: header(3) + busy(busy_count*(lines_per_busy+2)) + idle(1+idle_count) + separator(1)
    local used_lines=$((3 + cmd_table_lines + busy_count * (lines_per_busy + 2) + idle_count + 2))
    [[ ${#idle_agents[@]} -gt 0 ]] && used_lines=$((used_lines + 1))  # blank line before idle
    local feed_lines=$((term_height - used_lines))
    [[ $feed_lines -lt 1 ]] && feed_lines=1
    [[ $feed_lines -gt 30 ]] && feed_lines=30  # cap at 30

    local log_count=${#ACTIVITY_LOG[@]}
    if [[ $log_count -eq 0 ]]; then
        buf+=" ${C_DIM}(通信記録なし)${C_RESET}\n"
    else
        # Newest first (reverse order), fill available lines
        local start_idx=$((log_count - 1))
        local shown=0
        for ((i=start_idx; i>=0 && shown<feed_lines; i--)); do
            local entry="${ACTIVITY_LOG[$i]}"
            local entry_short
            entry_short=$(truncate_str "$entry" $((term_width - 2)))
            buf+=" ${C_DIM}${entry_short}${C_RESET}\n"
            ((shown++))
        done
    fi

    # Output: cursor home + buffer + clear remaining
    tput home 2>/dev/null
    printf '%b' "$buf"
    tput ed 2>/dev/null
}

# ─── Main ───
setup_terminal

while true; do
    render 2>/dev/null || true
    sleep "$INTERVAL"
done
