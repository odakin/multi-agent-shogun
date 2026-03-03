#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# battle_monitor.sh — 「大殿様の執務室」リアルタイム戦況モニター
# ═══════════════════════════════════════════════════════════════
# 設計思想: 大殿様が2秒で状況を把握できること
#   アクション必要 → 画面が叫ぶ（🚨裁可待ちセクション）
#   アクション不要 → 画面は静か
#   情報は4階層: 要アクション → 指令状況 → 稼働状況 → 履歴
#
# 4セクション構成:
#   1. 🚨 裁可待ち  — lord_pending.yaml (awaiting_lord)
#   2. 📋 指令      — queue/cmds/ + archive (直近8件)
#   3. ⚔  稼働状況  — 3列グリッド (モニタ配置準拠)
#   4. 📜 直近      — 最新イベント5行
#
# Usage:
#   bash scripts/battle_monitor.sh [--interval N] [--compact]
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

# ─── Args ───
INTERVAL=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --compact)  INTERVAL=2; shift ;;
        --help|-h)  echo "Usage: battle_monitor.sh [--interval N] [--compact]"; exit 0 ;;
        *) shift ;;
    esac
done

# ─── Colors ───
C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'

# ─── 3-Column grid layout (row-major order) ───
#   左列:  karo,      ashigaru1, ashigaru2
#   中列:  ashigaru3, ashigaru4, ashigaru5
#   右列:  ashigaru6, ashigaru7, gunshi
GRID=(
    karo      ashigaru3 ashigaru6
    ashigaru1 ashigaru4 ashigaru7
    ashigaru2 ashigaru5 gunshi
)

# ─── Activity feed ring buffer ───
declare -a ACTIVITY_LOG=()
declare -A PREV_MSG_COUNT=()
MAX_ACTIVITY=100

# ─── Terminal setup / cleanup ───
setup_terminal() {
    tput smcup 2>/dev/null
    tput civis 2>/dev/null
    tput clear 2>/dev/null
}

cleanup_terminal() {
    tput cnorm 2>/dev/null
    tput rmcup 2>/dev/null
}

trap cleanup_terminal EXIT INT TERM

# ─── CJK-aware string truncation ───
# ASCII = width 1, non-ASCII (CJK/emoji) = width 2
truncate_str() {
    local str="$1" max="$2" i=0 w=0 last_fit_i=0
    while [[ $i -lt ${#str} ]]; do
        local c="${str:$i:1}"
        local cw=1
        [[ "$c" == [[:ascii:]] ]] || cw=2
        if (( w + cw > max )); then
            # Adding this char would overflow; truncate at last safe cut point.
            echo "${str:0:$last_fit_i}…"
            return
        fi
        (( w += cw ))
        (( i++ ))
        # Track largest cut point where str[0:i] + '…' fits within max columns.
        (( w <= max - 1 )) && last_fit_i=$i
    done
    echo "$str"
}

# ─── Agent status check ───
is_active() {
    case "$1" in assigned|in_progress) return 0 ;; *) return 1 ;; esac
}

# ─── Single Python data fetch (all sections in one subprocess) ───
# Output format (tab-separated):
#   lord\tcmd_id\ttitle\tsummary\tage
#   cmd\tcmd_id\temoji\tpurpose\tarchived(0|1)
#   agent\tname\ttask_id\tstatus
#   event\tcontent
#   count\tagent\tN
fetch_all_data() {
    # Build PREV_MSG_COUNT as Python dict literal
    local prev_counts_py="{}"
    if [[ ${#PREV_MSG_COUNT[@]} -gt 0 ]]; then
        local pairs=""
        for k in "${!PREV_MSG_COUNT[@]}"; do
            pairs+="\"$k\":${PREV_MSG_COUNT[$k]},"
        done
        prev_counts_py="{${pairs%,}}"
    fi

    "$PYTHON" - <<PYEOF 2>/dev/null || true
import yaml, os, glob
from datetime import datetime, timezone

root = '$SCRIPT_DIR'
prev_counts = ${prev_counts_py}
agents = ['karo','ashigaru1','ashigaru2','ashigaru3','ashigaru4',
          'ashigaru5','ashigaru6','ashigaru7','gunshi']
all_targets = agents + ['shogun']

# ── Section 1: Lord pending ──
try:
    with open(f'{root}/queue/lord_pending.yaml') as f:
        lp = yaml.safe_load(f) or {}
    now_dt = datetime.now(timezone.utc)
    for item in (lp.get('pending_decisions') or []):
        if item.get('status') != 'awaiting_lord':
            continue
        age = ''
        try:
            ra = str(item.get('reported_at', ''))
            dt = datetime.fromisoformat(ra.replace('Z', '+00:00'))
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            h = int((now_dt - dt).total_seconds() // 3600)
            age = f'{h}時間前' if h < 24 else f'{h//24}日前'
        except:
            pass
        cmd_id  = str(item.get('cmd_id',  '?')).replace('\t', ' ')
        title   = str(item.get('title',   '?')).replace('\t', ' ')
        summary = str(item.get('summary', '')).replace('\t', ' ')
        print(f'lord\t{cmd_id}\t{title}\t{summary}\t{age}')
except:
    pass

# ── Section 2: Commands (newest first, active before archived, max 8) ──
EMOJI = {
    'pending': '⏳', 'in_progress': '🔄', 'done': '✅',
    'qc_pass': '✅', 'failed': '❌', 'deferred': '⏸', 'qc_fail': '❌',
}
try:
    entries = []
    for pattern, is_arch in [
        (f'{root}/queue/cmds/*.yaml', False),
        (f'{root}/queue/archive/cmd_*.yaml', True),
    ]:
        for cf in sorted(glob.glob(pattern)):
            try:
                with open(cf) as f:
                    c = yaml.safe_load(f) or {}
                if not isinstance(c, dict):
                    continue
                cid     = str(c.get('id') or '?')
                purpose = str(c.get('purpose') or c.get('description', '') or '').strip()[:38]
                purpose = purpose.replace('\t', ' ').replace('\n', ' ')
                status  = str(c.get('status', '?') or '?')
                try:
                    num = int(cid.replace('cmd_', ''))
                except:
                    num = 0
                entries.append((num, cid, EMOJI.get(status, status), purpose, '1' if is_arch else '0'))
            except:
                pass
    entries.sort(key=lambda x: x[0], reverse=True)
    for _, cid, emoji, purpose, arch in entries[:8]:
        print(f'cmd\t{cid}\t{emoji}\t{purpose}\t{arch}')
except:
    pass

# ── Section 3: Agent task states ──
for agent in agents:
    task_id, task_status = '---', '---'
    try:
        with open(f'{root}/queue/tasks/{agent}.yaml') as f:
            t = (yaml.safe_load(f) or {}).get('task', {}) or {}
            task_id     = str(t.get('task_id',  '---') or '---')
            task_status = str(t.get('status',   '---') or '---')
    except:
        pass
    print(f'agent\t{agent}\t{task_id}\t{task_status}')

# ── Section 4: Activity events ──
new_events = []
msg_counts = {}
first_run  = not bool(prev_counts)
all_seed   = []

for target in all_targets:
    try:
        with open(f'{root}/queue/inbox/{target}.yaml') as f:
            msgs = (yaml.safe_load(f) or {}).get('messages', []) or []
    except:
        msgs = []
    msg_counts[target] = len(msgs)
    prev = prev_counts.get(target, 0)
    if first_run:
        for m in msgs[-3:]:
            ts   = str(m.get('timestamp', ''))
            ts_s = ts[11:16] if len(ts) > 16 else ts[-5:]
            frm  = str(m.get('from', '?'))
            cont = str(m.get('content', ''))[:50].replace('\n', ' ').replace('\t', ' ')
            all_seed.append((ts, f'[{ts_s}] {frm}: {cont}'))
    elif len(msgs) > prev:
        for m in msgs[prev:]:
            ts   = str(m.get('timestamp', ''))
            ts_s = ts[11:16] if len(ts) > 16 else ts[-5:]
            frm  = str(m.get('from', '?'))
            cont = str(m.get('content', ''))[:50].replace('\n', ' ').replace('\t', ' ')
            new_events.append(f'[{ts_s}] {frm}: {cont}')

if first_run:
    all_seed.sort(key=lambda x: x[0])
    new_events = [m[1] for m in all_seed[-10:]]

for e in new_events:
    print(f'event\t{e}')
for k, v in msg_counts.items():
    print(f'count\t{k}\t{v}')
PYEOF
}

# ─── Main render function ───
render() {
    # Terminal dimensions — stty size 優先、失敗時は tput、最終フォールバック 40x80
    local term_h term_w
    if read -r term_h term_w < <(stty size 2>/dev/null) && [[ -n "$term_w" && "$term_w" -gt 0 ]]; then
        :  # stty size 成功
    else
        term_w=$(tput cols 2>/dev/null || echo 80)
        term_h=$(tput lines 2>/dev/null || echo 40)
    fi

    # Fetch all data (single Python call)
    local raw
    raw=$(fetch_all_data)

    # Fetch model names from tmux @model_name pane option
    declare -A AGENT_MODEL=()
    while IFS=' ' read -r ag_id ag_model; do
        [[ -n "$ag_id" && -n "$ag_model" ]] && AGENT_MODEL["$ag_id"]="${ag_model,,}"
    done < <(tmux list-panes -a -F '#{@agent_id} #{@model_name}' 2>/dev/null)

    # Parse output
    declare -a LORD_ITEMS=() CMD_ITEMS=()
    declare -A AGENT_TASK_ID=() AGENT_TASK_STATUS=()

    while IFS=$'\t' read -r key v1 v2 v3 v4; do
        case "$key" in
            lord)  LORD_ITEMS+=("${v1}	${v2}	${v3}	${v4}") ;;
            cmd)   CMD_ITEMS+=("${v1}	${v2}	${v3}	${v4}") ;;
            agent)
                AGENT_TASK_ID["$v1"]="$v2"
                AGENT_TASK_STATUS["$v1"]="$v3"
                ;;
            event) [[ -n "$v1" ]] && ACTIVITY_LOG+=("$v1") ;;
            count) [[ -n "$v1" && -n "$v2" ]] && PREV_MSG_COUNT["$v1"]="$v2" ;;
        esac
    done <<< "$raw"

    # Trim activity log
    while [[ ${#ACTIVITY_LOG[@]} -gt $MAX_ACTIVITY ]]; do
        ACTIVITY_LOG=("${ACTIVITY_LOG[@]:1}")
    done

    # Count active / idle ashigaru
    local active_count=0 idle_count=0
    local ag
    for ag in ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7; do
        is_active "${AGENT_TASK_STATUS[$ag]:----}" && ((active_count++)) || ((idle_count++))
    done

    local lord_count=${#LORD_ITEMS[@]}
    local now
    now=$(date '+%H:%M:%S')

    # Separators
    local sep thin
    sep=$(printf  '═%.0s' $(seq 1 "$term_w") 2>/dev/null || printf '=%.0s' $(seq 1 "$term_w"))
    thin=$(printf '─%.0s' $(seq 1 "$term_w") 2>/dev/null || printf '-%.0s' $(seq 1 "$term_w"))

    local buf=""

    # ════════════════════════════════════════════
    # HEADER
    # ════════════════════════════════════════════
    local lord_badge=""
    [[ $lord_count -gt 0 ]] && lord_badge="  ${C_YELLOW}${C_BOLD}🚨裁可待ち${lord_count}件${C_RESET}"
    buf+="${C_BOLD}${C_CYAN} 🏯 大殿様の執務室${C_RESET}${lord_badge}  ${C_DIM}${now}${C_RESET}\n"
    buf+=" ${C_GREEN}⚔稼働${active_count}${C_RESET}  ${C_DIM}💤待機${idle_count}${C_RESET}\n"
    buf+="${C_DIM}${sep}${C_RESET}\n"

    # ════════════════════════════════════════════
    # SECTION 1: 🚨 裁可待ち
    # ════════════════════════════════════════════
    if [[ $lord_count -gt 0 ]]; then
        buf+="${C_YELLOW}${C_BOLD} 🚨 裁可待ち — ご決裁をお待ちしております${C_RESET}\n"
        local lord_item
        for lord_item in "${LORD_ITEMS[@]}"; do
            IFS=$'\t' read -r lcmd ltitle lsummary lage <<< "$lord_item"
            local age_str=""
            [[ -n "$lage" ]] && age_str="${C_DIM}  (${lage})${C_RESET}"
            local line
            line=$(truncate_str "   📋 ${lcmd}  ${ltitle}" $((term_w - 24)))
            buf+="${C_YELLOW}${C_BOLD}${line}${C_RESET}${age_str}\n"
            if [[ -n "$lsummary" ]]; then
                local sline
                sline=$(truncate_str "      └ ${lsummary}" $((term_w - 4)))
                buf+="  ${C_DIM}${sline}${C_RESET}\n"
            fi
        done
    else
        buf+=" ${C_DIM}🚨 裁可待ち: （なし）${C_RESET}\n"
    fi
    buf+="${C_DIM}${thin}${C_RESET}\n"

    # ════════════════════════════════════════════
    # SECTION 2: 📋 指令
    # ════════════════════════════════════════════
    buf+="${C_BOLD} 📋 指令${C_RESET}\n"
    if [[ ${#CMD_ITEMS[@]} -eq 0 ]]; then
        buf+="  ${C_DIM}（指令なし）${C_RESET}\n"
    else
        local cmd_item
        for cmd_item in "${CMD_ITEMS[@]}"; do
            IFS=$'\t' read -r cid cemoji cpurpose carch <<< "$cmd_item"
            local dim_style=""
            [[ "$carch" == "1" ]] && dim_style="${C_DIM}"
            local cline
            cline=$(truncate_str "  ${cid} ${cemoji}  ${cpurpose}" $((term_w - 2)))
            buf+="${dim_style}${cline}${C_RESET}\n"
        done
    fi
    buf+="${C_DIM}${thin}${C_RESET}\n"

    # ════════════════════════════════════════════
    # SECTION 3: ⚔ 稼働状況 (3列グリッド)
    # ════════════════════════════════════════════
    buf+="${C_BOLD} ⚔  稼働状況${C_RESET}\n"
    local col_w=$(( (term_w - 6) / 3 ))
    [[ $col_w -lt 20 ]] && col_w=20

    local grid_row grid_col
    for grid_row in 0 1 2; do
        local row_str=""
        for grid_col in 0 1 2; do
            local idx=$(( grid_row * 3 + grid_col ))
            local g_agent="${GRID[$idx]}"
            local g_tid="${AGENT_TASK_ID[$g_agent]:----}"
            local g_tstat="${AGENT_TASK_STATUS[$g_agent]:----}"
            local g_active=false
            is_active "$g_tstat" && g_active=true

            # Icon + display name
            local g_icon g_name
            case "$g_agent" in
                karo)      g_icon="🏯"; g_name="家老" ;;
                gunshi)    g_icon="🧠"; g_name="軍師" ;;
                ashigaru1) [[ "${AGENT_MODEL[ashigaru1]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽１" ;;
                ashigaru2) [[ "${AGENT_MODEL[ashigaru2]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽２" ;;
                ashigaru3) [[ "${AGENT_MODEL[ashigaru3]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽３" ;;
                ashigaru4) [[ "${AGENT_MODEL[ashigaru4]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽４" ;;
                ashigaru5) [[ "${AGENT_MODEL[ashigaru5]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽５" ;;
                ashigaru6) [[ "${AGENT_MODEL[ashigaru6]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽６" ;;
                ashigaru7) [[ "${AGENT_MODEL[ashigaru7]:-}" == opus* ]] && { $g_active && g_icon="⚡" || g_icon="💤"; } || { $g_active && g_icon="⚔" || g_icon="💤"; }; g_name="足軽７" ;;
                *)         g_icon="?";  g_name="$g_agent" ;;
            esac

            # Cell plain text
            local g_plain
            if $g_active; then
                g_plain="${g_icon}${g_name} ${g_tid}"
            else
                g_plain="${g_icon}${g_name}"
            fi

            # Truncate to fit column
            local g_display
            g_display=$(truncate_str "$g_plain" $(( col_w - 2 )))

            # Compute visual width for padding
            local g_vw=0 g_i=0
            while [[ $g_i -lt ${#g_display} ]]; do
                [[ "${g_display:$g_i:1}" == [[:ascii:]] ]] && ((g_vw++)) || ((g_vw+=2))
                ((g_i++))
            done
            local g_pad=$(( col_w - 1 - g_vw ))
            [[ $g_pad -lt 0 ]] && g_pad=0

            # Apply color
            local g_colored
            if [[ "$g_agent" == "karo" ]]; then
                $g_active \
                    && g_colored="${C_GREEN}${C_BOLD}${g_display}${C_RESET}" \
                    || g_colored="${C_DIM}${g_display}${C_RESET}"
            elif [[ "$g_agent" == "gunshi" ]]; then
                $g_active \
                    && g_colored="${C_CYAN}${C_BOLD}${g_display}${C_RESET}" \
                    || g_colored="${C_DIM}${g_display}${C_RESET}"
            else
                if $g_active; then
                    if [[ "${AGENT_MODEL[$g_agent]:-}" == opus* ]]; then
                        g_colored="${C_YELLOW}${C_BOLD}${g_display}${C_RESET}"
                    else
                        g_colored="${C_GREEN}${g_display}${C_RESET}"
                    fi
                else
                    g_colored="${C_DIM}${g_display}${C_RESET}"
                fi
            fi

            row_str+=" ${g_colored}"
            local p
            for ((p = 0; p < g_pad; p++)); do row_str+=" "; done
            [[ $grid_col -lt 2 ]] && row_str+="${C_DIM}│${C_RESET}"
        done
        buf+="${row_str}\n"
    done

    # Grid summary line
    local karo_icon="🏯待機"
    is_active "${AGENT_TASK_STATUS[karo]:----}" && karo_icon="🏯稼働"
    local gunshi_icon="🧠待機"
    is_active "${AGENT_TASK_STATUS[gunshi]:----}" && gunshi_icon="🧠稼働"
    buf+="  ${C_DIM}${karo_icon}  ⚔${active_count}  💤${idle_count}  ${gunshi_icon}${C_RESET}\n"
    buf+="${C_DIM}${thin}${C_RESET}\n"

    # ════════════════════════════════════════════
    # SECTION 4: 📜 直近
    # ════════════════════════════════════════════
    buf+="${C_BOLD} 📜 直近${C_RESET}\n"
    local log_count=${#ACTIVITY_LOG[@]}
    if [[ $log_count -eq 0 ]]; then
        buf+="  ${C_DIM}（通信記録なし）${C_RESET}\n"
    else
        local shown=0 i
        for ((i = log_count - 1; i >= 0 && shown < 5; i--)); do
            local e_short
            e_short=$(truncate_str "${ACTIVITY_LOG[$i]}" $((term_w - 4)))
            buf+="  ${C_DIM}${e_short}${C_RESET}\n"
            ((shown++))
        done
    fi

    # Output frame — 毎サイクル完全消去 + 行末消去で残像ゼロ
    printf '\033[2J\033[H'
    local _line
    while IFS= read -r _line; do
        printf '%s\033[K\n' "$_line"
    done < <(printf '%b' "$buf")
}

# ─── Main ───
setup_terminal

while true; do
    render 2>/dev/null || true
    sleep "$INTERVAL"
done
