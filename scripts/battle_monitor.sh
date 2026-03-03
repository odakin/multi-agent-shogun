#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# battle_monitor.sh — 「大御所様の執務室」リアルタイム戦況モニター
# ═══════════════════════════════════════════════════════════════
# 4セクション: 🚨裁可待ち / 📋指令 / ⚔稼働状況 / 📜直近
#
# Usage: bash scripts/battle_monitor.sh [--interval N] [--compact]
# ═══════════════════════════════════════════════════════════════

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ─── 排他起動: flock で1インスタンスのみ許可 ───
# 既に動いている場合は起動拒否。右ペインで Ctrl+C してから再実行。
LOCKFILE="$SCRIPT_DIR/.battle_monitor.lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "ERROR: battle_monitor is already running (PID $(cat "$LOCKFILE" 2>/dev/null))." >&2
    echo "Right pane で Ctrl+C してから再実行してください。" >&2
    exit 1
fi
echo $$ > "$LOCKFILE"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"

INTERVAL=1
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="$2"; shift 2 ;;
        --compact)  INTERVAL=2; shift ;;
        --help|-h)  echo "Usage: battle_monitor.sh [--interval N] [--compact]"; exit 0 ;;
        *) shift ;;
    esac
done

C_RESET=$'\033[0m'
C_BOLD=$'\033[1m'
C_DIM=$'\033[2m'
C_GREEN=$'\033[32m'
C_YELLOW=$'\033[33m'
C_CYAN=$'\033[36m'

CELL_W=20  # Grid column visual width (overridden dynamically in render)
NCOLS=3    # Grid column count (overridden dynamically in render)

declare -a ACTIVITY_LOG=()
declare -A PREV_MSG_COUNT=()
MAX_ACTIVITY=100
TRIM_LINE_BUF=""  # _trim_line() 出力バッファ（fork/subshell ゼロ）

setup_terminal() {
    tput civis 2>/dev/null
    tput clear 2>/dev/null
    printf '\033[?7l'  # Disable DECAWM (auto-wrap) as safety net
}

cleanup_terminal() {
    printf '\033[?7h'  # Re-enable DECAWM (auto-wrap)
    tput cnorm 2>/dev/null
}

trap cleanup_terminal EXIT INT TERM

# ─── ANSI-aware line trim (CJK 全角=2 カラム対応) ───
# 出力行をペイン幅 max カラムで切り詰め、ESC シーケンスは幅ゼロで通過させる
trim_ansi_line() {
    local line="$1" max="$2"
    local j=0 w=0 result="" in_esc=0 esc_seq=""
    while [[ $j -lt ${#line} ]]; do
        local c="${line:$j:1}"
        if (( in_esc )); then
            esc_seq+="$c"
            if [[ "$c" =~ [A-Za-z] ]]; then
                result+="$esc_seq"
                in_esc=0
                esc_seq=""
            fi
            (( j++ ))
            continue
        fi
        if [[ "$c" == $'\033' ]]; then
            in_esc=1
            esc_seq="$c"
            (( j++ ))
            continue
        fi
        local cw=1
        if [[ "$c" != [[:ascii:]] ]]; then
            case "$c" in
                ─|┌|┬|┐|│|└|┴|┘) cw=1 ;;  # 罫線: 端末では1幅
                *) cw=2 ;;                   # CJK/絵文字: 2幅
            esac
        fi
        if (( w + cw > max )); then
            printf '%s\033[0m\033[K\n' "$result"
            return
        fi
        result+="$c"
        (( w += cw ))
        (( j++ ))
    done
    printf '%s\033[K\n' "$result"
}

# ─── ANSI-aware line trim — no-fork version (writes to TRIM_LINE_BUF) ───
# trim_ansi_line のfork不要版。出力を global TRIM_LINE_BUF に書く。
_trim_line() {
    local line="$1" max="$2"
    local j=0 w=0 result="" in_esc=0 esc_seq=""
    while [[ $j -lt ${#line} ]]; do
        local c="${line:$j:1}"
        if (( in_esc )); then
            esc_seq+="$c"
            if [[ "$c" =~ [A-Za-z] ]]; then
                result+="$esc_seq"
                in_esc=0
                esc_seq=""
            fi
            (( j++ ))
            continue
        fi
        if [[ "$c" == $'\033' ]]; then
            in_esc=1
            esc_seq="$c"
            (( j++ ))
            continue
        fi
        local cw=1
        if [[ "$c" != [[:ascii:]] ]]; then
            case "$c" in
                ─|┌|┬|┐|│|└|┴|┘) cw=1 ;;
                *) cw=2 ;;
            esac
        fi
        if (( w + cw > max )); then
            TRIM_LINE_BUF="${result}"$'\033[0m\033[K\n'
            return
        fi
        result+="$c"
        (( w += cw ))
        (( j++ ))
    done
    TRIM_LINE_BUF="${result}"$'\033[K\n'
}

# ─── Single Python data fetch (all sections) ───
fetch_all_data() {
    local prev_counts_py="{}"
    if [[ ${#PREV_MSG_COUNT[@]} -gt 0 ]]; then
        local pairs=""
        for k in "${!PREV_MSG_COUNT[@]}"; do
            pairs+="\"$k\":${PREV_MSG_COUNT[$k]},"
        done
        prev_counts_py="{${pairs%,}}"
    fi

    "$PYTHON" - <<PYEOF 2>/dev/null || true
import yaml, glob, unicodedata
from datetime import datetime, timezone

root = '$SCRIPT_DIR'
prev_counts = ${prev_counts_py}
TERM_W = ${term_w}
num_cols = 2 if TERM_W < 60 else 3
border_chars = num_cols + 1  # │ on each side + between cols
CELL_W = max(8, (TERM_W - border_chars) // num_cols)
print(f'grid_meta\t{num_cols}\t{CELL_W}')

agents = ['karo','ashigaru1','ashigaru2','ashigaru3','ashigaru4',
          'ashigaru5','ashigaru6','ashigaru7','gunshi']
all_targets = agents + ['shogun']

def vw(s):
    return sum(2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in str(s))

def pad_to(s, w):
    s = str(s)
    cur = vw(s)
    if cur <= w:
        return s + ' ' * (w - cur)
    out, ow = '', 0
    for c in s:
        cw = 2 if unicodedata.east_asian_width(c) in ('W','F') else 1
        if ow + cw > w - 1:
            out += '…'
            break
        out += c
        ow += cw
    return out + ' ' * max(0, w - vw(out))

# ── 1. Lord pending ──
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
        T = lambda x: str(x).replace('\t', ' ')
        print(f"lord\t{T(item.get('cmd_id','?'))}\t{T(item.get('title','?'))}\t{T(item.get('summary',''))}\t{age}")
except:
    pass

# ── 2. Commands ──
EMOJI = {
    'pending': '⏳', 'in_progress': '🔄', 'done': '✅',
    'qc_pass': '✅', 'failed': '❌', 'deferred': '⏸', 'qc_fail': '❌',
}
try:
    entries = []
    for pat, arch in [
        (f'{root}/queue/cmds/*.yaml', 0),
        (f'{root}/queue/archive/cmd_*.yaml', 1),
    ]:
        for cf in sorted(glob.glob(pat)):
            try:
                with open(cf) as f:
                    c = yaml.safe_load(f) or {}
                if not isinstance(c, dict):
                    continue
                cid = str(c.get('id') or '?')
                purpose = str(c.get('purpose') or c.get('description', '') or '').strip()
                purpose = purpose.replace('\t', ' ').replace('\n', ' ')
                status = str(c.get('status', '?') or '?')
                try:
                    num = int(cid.replace('cmd_', ''))
                except:
                    num = 0
                entries.append((num, cid.replace('cmd_', ''), EMOJI.get(status, status), purpose, str(arch)))
            except:
                pass
    entries.sort(key=lambda x: x[0], reverse=True)
    for _, num_s, emoji, purpose, is_arch in entries[:8]:
        print(f'cmd\t{num_s}\t{emoji}\t{purpose}\t{is_arch}')
except:
    pass

# ── 3. Agent grid ──
FIXED_ICONS = {
    'karo':   ('🏯', '家老', 'karo'),
    'gunshi': ('🧠', '軍師', 'gunshi'),
}
ASHIGARU_NAMES = {
    'ashigaru1': '足軽１', 'ashigaru2': '足軽２', 'ashigaru3': '足軽３',
    'ashigaru4': '足軽４', 'ashigaru5': '足軽５', 'ashigaru6': '足軽６',
    'ashigaru7': '足軽７',
}

# Build dynamic grid: agents in order, split into num_cols columns
AGENTS_FLAT = agents  # ['karo','ashigaru1',...,'ashigaru7','gunshi']
num_rows = (len(AGENTS_FLAT) + num_cols - 1) // num_cols

agent_states = {}
active_c = idle_c = 0
for ag in agents:
    tid, tstat = '---', '---'
    try:
        with open(f'{root}/queue/tasks/{ag}.yaml') as f:
            t = (yaml.safe_load(f) or {}).get('task', {}) or {}
            tid   = str(t.get('task_id', '---') or '---')
            tstat = str(t.get('status',  '---') or '---')
    except:
        pass
    agent_states[ag] = (tid, tstat)
    if ag.startswith('ashigaru'):
        if tstat in ('assigned', 'in_progress'):
            active_c += 1
        else:
            idle_c += 1

print(f'summary\t{active_c}\t{idle_c}')

for ri in range(num_rows):
    for ci in range(num_cols):
        idx = ri * num_cols + ci
        if idx >= len(AGENTS_FLAT):
            # Empty cell (last row padding)
            print(f'cell\t{ri}\t{ci}\t{pad_to("", CELL_W)}\tidle\tempty')
            continue
        ag = AGENTS_FLAT[idx]
        tid, tstat = agent_states.get(ag, ('---', '---'))
        active = tstat in ('assigned', 'in_progress')
        if ag in FIXED_ICONS:
            icon, name, role = FIXED_ICONS[ag]
        else:
            name = ASHIGARU_NAMES.get(ag, ag)
            icon = '⚔' if active else '💤'
            role = 'ashigaru'
        content = f'{icon}{name} {tid}' if active else f'{icon}{name} ---'
        cell = pad_to(content, CELL_W)
        print(f'cell\t{ri}\t{ci}\t{cell}\t{"active" if active else "idle"}\t{role}')

# ── 4. Events + unread ──
new_events, all_seed = [], []
msg_counts = {}
unread_total = 0
first_run = not bool(prev_counts)

for tgt in all_targets:
    try:
        with open(f'{root}/queue/inbox/{tgt}.yaml') as f:
            data = yaml.safe_load(f) or {}
            msgs = data.get('messages', []) or []
    except:
        msgs = []
    msg_counts[tgt] = len(msgs)
    unread_total += sum(1 for m in msgs if not m.get('read', True))
    prev = prev_counts.get(tgt, 0)
    def fmt(m):
        ts = str(m.get('timestamp', ''))
        ts_s = ts[11:16] if len(ts) > 16 else ts[-5:]
        cont = str(m.get('content', ''))[:50].replace('\n', ' ').replace('\t', ' ')
        return f"[{ts_s}] {m.get('from','?')}: {cont}"
    if first_run:
        for m in msgs[-3:]:
            all_seed.append((str(m.get('timestamp', '')), fmt(m)))
    elif len(msgs) > prev:
        for m in msgs[prev:]:
            new_events.append(fmt(m))

if first_run:
    all_seed.sort(key=lambda x: x[0])
    new_events = [m[1] for m in all_seed[-10:]]

print(f'unread\t{unread_total}')
for e in new_events:
    print(f'event\t{e}')
for k, v in msg_counts.items():
    print(f'count\t{k}\t{v}')
PYEOF
}

# ─── Main render ───
render() {
    local term_h term_w
    if read -r term_h term_w < <(stty size 2>/dev/null) && [[ -n "$term_w" && "$term_w" -gt 0 ]]; then
        :
    else
        term_w=$(tput cols 2>/dev/null || echo 80)
        term_h=$(tput lines 2>/dev/null || echo 40)
    fi

    local raw
    raw=$(fetch_all_data)

    declare -a LORD_ITEMS=() CMD_ITEMS=()
    declare -A GRID_CELLS=() GRID_STATUS=() GRID_ROLE=()
    local active_count=0 idle_count=0 unread_count=0
    local GRID_NCOLS=3 GRID_CW=$CELL_W  # defaults; overridden by grid_meta

    while IFS=$'\t' read -r key v1 v2 v3 v4 v5; do
        case "$key" in
            lord)      LORD_ITEMS+=("${v1}	${v2}	${v3}	${v4}") ;;
            cmd)       CMD_ITEMS+=("${v1}	${v2}	${v3}	${v4}") ;;
            summary)   active_count="${v1:-0}"; idle_count="${v2:-0}" ;;
            grid_meta) GRID_NCOLS="${v1:-3}"; GRID_CW="${v2:-$CELL_W}" ;;
            cell)
                GRID_CELLS["${v1},${v2}"]="$v3"
                GRID_STATUS["${v1},${v2}"]="${v4:-idle}"
                GRID_ROLE["${v1},${v2}"]="${v5:-ashigaru}"
                ;;
            unread)  unread_count="${v1:-0}" ;;
            event)   [[ -n "$v1" ]] && ACTIVITY_LOG+=("$v1") ;;
            count)   [[ -n "$v1" && -n "$v2" ]] && PREV_MSG_COUNT["$v1"]="$v2" ;;
        esac
    done <<< "$raw"

    # Bash-side fallback: Python失敗 or grid_meta未受信時に端末幅から列数を計算
    # Python出力が空でもデフォルト(GRID_NCOLS=3)のままにならないよう保護
    if [[ $GRID_NCOLS -eq 3 && $term_w -gt 0 && $term_w -lt 60 ]]; then
        GRID_NCOLS=2
        GRID_CW=$(( (term_w - 3) / 2 ))
        [[ $GRID_CW -lt 8 ]] && GRID_CW=8
    fi

    while [[ ${#ACTIVITY_LOG[@]} -gt $MAX_ACTIVITY ]]; do
        ACTIVITY_LOG=("${ACTIVITY_LOG[@]:1}")
    done

    local lord_count=${#LORD_ITEMS[@]}
    local now
    now=$(date '+%H:%M:%S')

    # Separators (full terminal width)
    local sep thin
    sep=$(printf '%*s' "$term_w" '' | tr ' ' '=')
    thin=$(printf '%*s' "$term_w" '' | tr ' ' '-')

    local buf=""

    # ════ Header ════
    # " 🏯 大御所様の執務室" vw=20: " "(1)+"🏯"(2)+" "(1)+"大御所様の執務室"(16)
    # "HH:MM:SS" vw=8
    local hpad_n=$(( term_w - 20 - 8 ))
    [[ $hpad_n -lt 0 ]] && hpad_n=0
    local hpad
    hpad=$(printf '%*s' "$hpad_n" '')
    buf+=" ${C_BOLD}${C_CYAN}🏯 大御所様の執務室${C_RESET}${hpad}${C_DIM}${now}${C_RESET}\n"
    buf+=" ${C_GREEN}⚔稼働${active_count}${C_RESET}  ${C_DIM}💤待機${idle_count}${C_RESET}  ${C_DIM}📭未読${unread_count}${C_RESET}\n"
    buf+="${C_DIM}${sep}${C_RESET}\n"

    # ════ Section 1: 🚨 裁可待ち ════
    buf+="\n"
    if [[ $lord_count -gt 0 ]]; then
        buf+="${C_YELLOW}${C_BOLD} 🚨 裁可待ち${C_RESET}\n"
        local li
        for li in "${LORD_ITEMS[@]}"; do
            IFS=$'\t' read -r lcmd ltitle lsummary lage <<< "$li"
            local age_str=""
            [[ -n "$lage" ]] && age_str=" ${C_DIM}(${lage})${C_RESET}"
            buf+=" → ${lcmd} ${ltitle}${age_str}\n"
        done
    else
        buf+=" ${C_DIM}🚨 裁可待ち${C_RESET}\n"
        buf+=" ${C_DIM}（なし）${C_RESET}\n"
    fi
    buf+="\n${C_DIM}${thin}${C_RESET}\n"

    # ════ Section 2: 📋 指令 ════
    buf+="\n"
    buf+="${C_BOLD} 📋 指令${C_RESET}\n"
    if [[ ${#CMD_ITEMS[@]} -eq 0 ]]; then
        buf+=" ${C_DIM}（指令なし）${C_RESET}\n"
    else
        local ci
        for ci in "${CMD_ITEMS[@]}"; do
            IFS=$'\t' read -r cnum cemoji cpurpose carch <<< "$ci"
            if [[ "$carch" == "1" ]]; then
                buf+="${C_DIM} ${cemoji} ${cnum} ${cpurpose}${C_RESET}\n"
            else
                buf+=" ${cemoji} ${cnum} ${cpurpose}\n"
            fi
        done
    fi
    buf+="\n${C_DIM}${thin}${C_RESET}\n"

    # ════ Section 3: ⚔ 稼働状況 (dynamic-column grid) ════
    buf+="\n"
    buf+="${C_BOLD} ⚔ 稼働状況${C_RESET}\n"
    local cw=$GRID_CW
    local nc=$GRID_NCOLS

    # Build border strings using ASCII '-' (1-col wide, safe for trim_ansi_line)
    local dashes
    dashes=$(printf '%*s' "$cw" '' | tr ' ' '-')
    # Top border: ┌──┬──┐ (nc columns)
    local top_border="+"
    local mid_border="+"
    local bot_border="+"
    local _ci
    for (( _ci = 0; _ci < nc; _ci++ )); do
        top_border+="${dashes}+"
        mid_border+="${dashes}+"
        bot_border+="${dashes}+"
    done
    buf+="${C_DIM}${top_border}${C_RESET}\n"

    # Determine number of rows: ceil(9 agents / nc)
    local nagents=9
    local grid_rows=$(( (nagents + nc - 1) / nc ))

    local row col
    for (( row = 0; row < grid_rows; row++ )); do
        local rline="${C_DIM}|${C_RESET}"
        for (( col = 0; col < nc; col++ )); do
            local gk="${row},${col}"
            local gcell="${GRID_CELLS[$gk]:-}"
            [[ -z "$gcell" ]] && gcell=$(printf "%-${cw}s" '')
            local gstat="${GRID_STATUS[$gk]:-idle}"
            local grole="${GRID_ROLE[$gk]:-ashigaru}"
            local gcolored
            if [[ "$grole" == "karo" ]]; then
                [[ "$gstat" == "active" ]] \
                    && gcolored="${C_GREEN}${C_BOLD}${gcell}${C_RESET}" \
                    || gcolored="${C_DIM}${gcell}${C_RESET}"
            elif [[ "$grole" == "gunshi" ]]; then
                [[ "$gstat" == "active" ]] \
                    && gcolored="${C_CYAN}${C_BOLD}${gcell}${C_RESET}" \
                    || gcolored="${C_DIM}${gcell}${C_RESET}"
            else
                [[ "$gstat" == "active" ]] \
                    && gcolored="${C_GREEN}${gcell}${C_RESET}" \
                    || gcolored="${C_DIM}${gcell}${C_RESET}"
            fi
            rline+="${gcolored}${C_DIM}|${C_RESET}"
        done
        buf+="${rline}\n"
        # Mid-separator between rows (except after last)
        if (( row < grid_rows - 1 )); then
            buf+="${C_DIM}${mid_border}${C_RESET}\n"
        fi
    done
    buf+="${C_DIM}${bot_border}${C_RESET}\n"
    buf+="\n${C_DIM}${thin}${C_RESET}\n"

    # ════ Section 4: 📜 直近 ════
    buf+="\n"
    buf+="${C_BOLD} 📜 直近${C_RESET}\n"
    local lc=${#ACTIVITY_LOG[@]}
    if [[ $lc -eq 0 ]]; then
        buf+=" ${C_DIM}（通信記録なし）${C_RESET}\n"
    else
        local shown=0 ai
        for ((ai = lc - 1; ai >= 0 && shown < 5; ai--)); do
            buf+=" ${C_DIM}${ACTIVITY_LOG[$ai]}${C_RESET}\n"
            ((shown++))
        done
    fi

    # ── チラツキ根本解消 v4: bash変数でフレーム構築 → printf '%s' 1回 write ──
    # tmpfile/mktemp 廃止。_trim_line が TRIM_LINE_BUF に書き、+=で連結。
    # printf '%s' "$_outframe" = 1回 write(2) → 端末が分割フレームを受け取らない。
    local _outframe=''
    _outframe+=$'\033[?25l\033[H'  # カーソル非表示 + 左上へ
    local _ln
    while IFS= read -r _ln; do
        _trim_line "$_ln" "$term_w"
        _outframe+="$TRIM_LINE_BUF"
    done < <(printf '%b' "$buf")
    _outframe+=$'\033[J'  # カーソル位置から画面末尾まで一括消去
    printf '%s' "$_outframe"  # 1回 write(2): 端末が分割フレームを受け取らない
}

# ─── Main ───
setup_terminal

while true; do
    render 2>/dev/null || true
    sleep "$INTERVAL"
done
