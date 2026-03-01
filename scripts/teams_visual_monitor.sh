#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# teams_visual_monitor.sh — Agent Teams 版ビジュアルモニター
# ═══════════════════════════════════════════════════════════════════════════════
# Agent Teams が自動作成する tmux ペインを監視し、視覚装飾を適用するデーモン。
# shutsujin_teams.sh の exec 前にバックグラウンドで起動される。
#
# 機能:
#   - 新規ペインを検出し @agent_id, @model_name, @current_task をセット
#   - pane-border-format を適用（エージェント名+モデル名+タスクID常時表示）
#   - 3x3 グリッドレイアウトを自動適用（9ペイン時）
#   - tiledレイアウトを自動適用（4ペイン以上）
#   - ペイン背景色の適用（家老=暗赤、軍師=暗金、将軍/足軽=白デフォルト）
#   - エージェント識別: (1) 自己登録, (2) ペイン内容スキャン
#   - 無反応ペイン検出 + /clear 送信（復旧）
#
# 使用方法:
#   nohup bash scripts/teams_visual_monitor.sh <session_name> <script_dir> &
# ═══════════════════════════════════════════════════════════════════════════════

set -u

SESSION_NAME="${1:-}"
SCRIPT_DIR="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/teams_visual_monitor.log"
TEAM_CONFIG_DIR="$HOME/.claude/teams"
POLL_INTERVAL=3
LAYOUT_APPLIED=false
BORDER_APPLIED=false

# /clear recovery settings
UNRESPONSIVE_THRESHOLD=240   # 4分間無反応で /clear 送信
CLEAR_COOLDOWN=300           # /clear は5分に1回まで

# claude-swarm tmux サーバー検出用
TMUX_SOCKET=""               # -L オプションの値（空なら デフォルトサーバー）

mkdir -p "$LOG_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# ログ関数
# ═══════════════════════════════════════════════════════════════════════════════
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# tmux ラッパー: claude-swarm サーバー対応
# ═══════════════════════════════════════════════════════════════════════════════
_tmux() {
    if [ -n "$TMUX_SOCKET" ]; then
        tmux -L "$TMUX_SOCKET" "$@"
    else
        tmux "$@"
    fi
}

# Source shared library for busy/idle detection (used by dynamic_resize_panes)
if [ -f "$SCRIPT_DIR/lib/agent_status.sh" ]; then
    source "$SCRIPT_DIR/lib/agent_status.sh"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# tmux カスタムレイアウト — 列ファースト構造で列ごと独立リサイズ
# ═══════════════════════════════════════════════════════════════════════════════
# tiled レイアウトは行境界が列をまたいで共有されるため、1列の resize-pane -y
# が他列に波及する。カスタムレイアウト文字列を {col[rows]} 構造で構築し
# select-layout で一括適用すれば各列の行高さが完全独立になる。
# ═══════════════════════════════════════════════════════════════════════════════

# tmux レイアウトチェックサム（tmux ソース互換 CRC-16）
tmux_layout_checksum() {
    local layout="$1"
    local csum=0 i c
    for (( i=0; i<${#layout}; i++ )); do
        printf -v c '%d' "'${layout:$i:1}"
        csum=$(( ((csum >> 1) + ((csum & 1) << 15) + c) & 0xFFFF ))
    done
    printf '%04x' "$csum"
}

# 列ファーストの 3x3 レイアウト文字列を構築
# 引数: win_width win_height  pane_num[0..8]  height[0..8]
# pane_num は tmux pane_id の数値部分（%N → N）
build_column_first_layout() {
    local W="$1" H="$2"
    shift 2
    local -a pid=() ht=()
    local i
    for i in {0..8}; do pid+=("$1"); shift; done
    for i in {0..8}; do ht+=("$1"); shift; done

    # 列幅（3等分、ボーダー2本分を引いた残りを分割）
    local uw=$((W - 2))
    local cw0=$((uw / 3))
    local cw1=$((uw / 3))
    local cw2=$((uw - cw0 - cw1))
    local x1=$((cw0 + 1))
    local x2=$((x1 + cw1 + 1))

    local layout="${W}x${H},0,0{"
    local y1 y2

    # 列0 (pane 0,1,2)
    y1=$((ht[0] + 1)); y2=$((y1 + ht[1] + 1))
    layout+="${cw0}x${H},0,0"
    layout+="[${cw0}x${ht[0]},0,0,${pid[0]}"
    layout+=",${cw0}x${ht[1]},0,${y1},${pid[1]}"
    layout+=",${cw0}x${ht[2]},0,${y2},${pid[2]}]"

    # 列1 (pane 3,4,5)
    y1=$((ht[3] + 1)); y2=$((y1 + ht[4] + 1))
    layout+=",${cw1}x${H},${x1},0"
    layout+="[${cw1}x${ht[3]},${x1},0,${pid[3]}"
    layout+=",${cw1}x${ht[4]},${x1},${y1},${pid[4]}"
    layout+=",${cw1}x${ht[5]},${x1},${y2},${pid[5]}]"

    # 列2 (pane 6,7,8)
    y1=$((ht[6] + 1)); y2=$((y1 + ht[7] + 1))
    layout+=",${cw2}x${H},${x2},0"
    layout+="[${cw2}x${ht[6]},${x2},0,${pid[6]}"
    layout+=",${cw2}x${ht[7]},${x2},${y1},${pid[7]}"
    layout+=",${cw2}x${ht[8]},${x2},${y2},${pid[8]}]"

    layout+="}"

    local cksum
    cksum=$(tmux_layout_checksum "$layout")
    echo "${cksum},${layout}"
}

log "=== ビジュアルモニター起動 ==="
log "SESSION_NAME=$SESSION_NAME"
log "SCRIPT_DIR=$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# claude-swarm tmux サーバーを検出
# --teammate-mode tmux は tmux -L claude-swarm-{PID} でサーバーを作る
# ═══════════════════════════════════════════════════════════════════════════════
detect_swarm_socket() {
    # claude-swarm-* の tmux ソケットを探す
    # macOS: ソケットは /tmp/tmux-{uid}/ に作られる（/tmp 直下ではない）
    local uid
    uid=$(id -u)
    for dir in "/tmp/tmux-${uid}" "${TMPDIR:-/tmp}" "/tmp"; do
        [ -d "$dir" ] || continue
        local found
        found=$(ls -t "$dir"/claude-swarm-* 2>/dev/null | head -1)
        if [ -n "$found" ] && [ -S "$found" ]; then
            local socket_name
            socket_name=$(basename "$found")
            # tmux サーバーが生きているか確認
            if tmux -L "$socket_name" list-sessions >/dev/null 2>&1; then
                echo "$socket_name"
                return
            fi
        fi
    done

    # ps から claude-swarm の tmux プロセスを探す
    local swarm_pid
    swarm_pid=$(ps aux 2>/dev/null | grep "tmux -L claude-swarm-" | grep -v grep | head -1 | awk '{print $NF}' | grep -o 'claude-swarm-[0-9]*')
    if [ -n "$swarm_pid" ]; then
        echo "$swarm_pid"
        return
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# セッション名の自動検出
# ═══════════════════════════════════════════════════════════════════════════════
detect_session() {
    if [ -n "$SESSION_NAME" ]; then
        echo "$SESSION_NAME"
        return
    fi

    # まず claude-swarm サーバーを探す（Agent Teams --teammate-mode tmux 用）
    local swarm_socket
    swarm_socket=$(detect_swarm_socket)
    if [ -n "$swarm_socket" ]; then
        TMUX_SOCKET="$swarm_socket"
        local swarm_session
        swarm_session=$(_tmux list-sessions -F '#{session_name}' 2>/dev/null | head -1)
        if [ -n "$swarm_session" ]; then
            log "claude-swarm detected: socket=$TMUX_SOCKET session=$swarm_session"
            echo "$swarm_session"
            return
        fi
    fi

    # フォールバック: デフォルト tmux サーバーで探す
    TMUX_SOCKET=""
    local sessions
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    for s in $sessions; do
        local pane_ids
        pane_ids=$(tmux list-panes -t "$s" -F '#{pane_index}' 2>/dev/null)
        for p in $pane_ids; do
            local pane_content
            pane_content=$(tmux capture-pane -t "$s:0.$p" -p 2>/dev/null)
            if echo "$pane_content" | grep -q "Claude Code\|claude-code\|multi-agent-shogun\|@anthropic-ai\|teammate-mode"; then
                echo "$s"
                return
            fi
            local agent_id
            agent_id=$(tmux show-options -p -t "$s:0.$p" -v @agent_id 2>/dev/null)
            if [ -n "$agent_id" ]; then
                echo "$s"
                return
            fi
        done
    done

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# エージェント名とモデルのマッピング
# ═══════════════════════════════════════════════════════════════════════════════
get_model_for_agent() {
    local agent="$1"
    local kessen="${KESSEN_MODE:-false}"

    case "$agent" in
        shogun|team-lead)
            echo "Opus"
            ;;
        karo)
            if [ "$kessen" = "true" ]; then
                echo "Opus"
            else
                echo "Sonnet"
            fi
            ;;
        gunshi)
            echo "Opus"
            ;;
        ashigaru*)
            if [ "$kessen" = "true" ]; then
                echo "Opus"
            else
                echo "Sonnet"
            fi
            ;;
        *)
            echo "Sonnet"
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# エージェント名に基づくペインスタイル（fg + bg）
# fg を明示指定しないとライトモードのデフォルト黒文字が暗背景で読めなくなる
# ═══════════════════════════════════════════════════════════════════════════════
get_bg_color_for_agent() {
    local agent="$1"
    case "$agent" in
        shogun|team-lead)
            echo ""                          # 白背景（デフォルト）
            ;;
        karo)
            echo "fg=#d0d0d0,bg=#6b2020"    # 赤（家老）+ 明文字
            ;;
        gunshi)
            echo "fg=#d0d0d0,bg=#6b6b10"    # 金/黄（軍師）+ 明文字
            ;;
        ashigaru*)
            echo ""                          # 白背景（デフォルト）
            ;;
        *)
            echo ""                          # 白背景（デフォルト）
            ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# ペインからエージェント名を検出
# ═══════════════════════════════════════════════════════════════════════════════
detect_agent_from_pane() {
    local pane_id="$1"

    # 方法1: 既に @agent_id が自己登録されている場合（最優先）
    local existing_id
    existing_id=$(_tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
    if [ -n "$existing_id" ] && [ "$existing_id" != "" ] && [ "$existing_id" != "..." ]; then
        echo "$existing_id"
        return
    fi

    # 方法2: ペイン内容をスキャンしてエージェント名を検出
    local content
    content=$(_tmux capture-pane -t "$pane_id" -p 2>/dev/null | head -30)

    # spawn prompt の set-option パターンから検出
    local set_id
    set_id=$(echo "$content" | grep -o "@agent_id ['\"]\\?[a-z]*[0-9]*['\"]\\?" | head -1 | grep -o "[a-z]*[0-9]*$" | head -1)
    if [ -n "$set_id" ]; then
        echo "$set_id"
        return
    fi

    # instructions ファイルの読み込みパターンから検出
    if echo "$content" | grep -q "instructions/shogun.md\|将軍として"; then
        echo "shogun"
        return
    elif echo "$content" | grep -q "instructions/karo.md\|家老なり\|汝は家老"; then
        echo "karo"
        return
    elif echo "$content" | grep -q "instructions/gunshi.md\|軍師なり\|汝は軍師"; then
        echo "gunshi"
        return
    fi

    # 足軽の番号を検出
    local ashi_num
    ashi_num=$(echo "$content" | grep -o "ashigaru[0-9]\|足軽[0-9]\|足軽[0-9]号" | head -1 | grep -o "[0-9]")
    if [ -n "$ashi_num" ]; then
        echo "ashigaru${ashi_num}"
        return
    fi

    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# ペインにスタイルを適用
# ═══════════════════════════════════════════════════════════════════════════════
style_pane() {
    local pane_id="$1"
    local agent_name="$2"
    local model

    model=$(get_model_for_agent "$agent_name")

    # @agent_id が既に自己登録で正しく設定されていればそのまま維持
    local current_id
    current_id=$(_tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
    if [ "$current_id" != "$agent_name" ]; then
        _tmux set-option -p -t "$pane_id" @agent_id "$agent_name" 2>/dev/null
    fi

    # @model_name も自己登録を尊重（spawn prompt で設定済みの場合がある）
    local current_model
    current_model=$(_tmux show-options -p -t "$pane_id" -v @model_name 2>/dev/null)
    if [ -z "$current_model" ] || [ "$current_model" = "..." ]; then
        _tmux set-option -p -t "$pane_id" @model_name "$model" 2>/dev/null
    fi

    # @current_task が未設定の場合のみ初期化
    local current_task
    current_task=$(_tmux show-options -p -t "$pane_id" -v @current_task 2>/dev/null)
    if [ -z "$current_task" ]; then
        _tmux set-option -p -t "$pane_id" @current_task "" 2>/dev/null
    fi

    # 背景色の適用（空なら白デフォルトにリセット）
    local bg_color
    bg_color=$(get_bg_color_for_agent "$agent_name")
    if [ -n "$bg_color" ]; then
        _tmux select-pane -t "$pane_id" -P "$bg_color" 2>/dev/null
    else
        _tmux select-pane -t "$pane_id" -P 'default' 2>/dev/null
    fi

    log "Styled pane $pane_id as $agent_name ($model) ${bg_color:+[$bg_color]}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# pane-border-format を適用
# ═══════════════════════════════════════════════════════════════════════════════
apply_border_format() {
    local session="$1"

    # 全ウィンドウに適用
    local windows
    windows=$(_tmux list-windows -t "$session" -F '#{window_id}' 2>/dev/null)
    for win in $windows; do
        _tmux set-option -w -t "$win" pane-border-status top 2>/dev/null
        _tmux set-option -w -t "$win" pane-border-format \
            '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}' \
            2>/dev/null
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3x3 グリッドレイアウト適用（列ファースト構造）
# 列ファースト {col[rows]} 構造で適用し、列ごとの高さ独立を保証する。
# フォールバック: 寸法取得失敗時は tiled を使用。
# ═══════════════════════════════════════════════════════════════════════════════
apply_3x3_grid() {
    local win="$1"
    local win_panes
    win_panes=$(_tmux list-panes -t "$win" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$win_panes" -eq 9 ]; then
        # まず tiled で均等配置（列ファースト構築の前提として必要）
        _tmux select-layout -t "$win" tiled 2>/dev/null

        # 列ファーストの均等レイアウトを構築・適用
        local dims
        dims=$(_tmux display-message -t "$win" -p '#{window_width} #{window_height}' 2>/dev/null)
        local ww=${dims%% *}
        local wh=${dims##* }

        if [ -n "$ww" ] && [ "$ww" -gt 10 ] && [ -n "$wh" ] && [ "$wh" -gt 10 ]; then
            local pids=()
            while read -r pid; do
                pids+=("${pid#%}")
            done <<< "$(_tmux list-panes -t "$win" -F '#{pane_id}' 2>/dev/null)"

            if [ "${#pids[@]}" -eq 9 ]; then
                local uh=$((wh - 2))
                local eq=$((uh / 3))
                local h2=$((uh - eq * 2))
                local hs=("$eq" "$eq" "$h2" "$eq" "$eq" "$h2" "$eq" "$eq" "$h2")

                local layout_str
                layout_str=$(build_column_first_layout "$ww" "$wh" "${pids[@]}" "${hs[@]}")
                _tmux select-layout -t "$win" "$layout_str" 2>/dev/null
                log "3x3 column-first layout applied to $win (9 panes)"
                PREV_RESIZE_STATE=""   # リサイズ状態をリセット（新レイアウト適用済み）
                return 0
            fi
        fi

        log "3x3 grid layout applied to $win (fallback tiled)"
        return 0
    fi
    return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Permission デッドロック検出 + Escape 復旧
# ═══════════════════════════════════════════════════════════════════════════════
# Agent Teams で mode="bypassPermissions" が省略された場合、エージェントが
# "Waiting for team lead approval" で永久にブロックする。
# ペイン内容をスキャンし、検出したら Escape で cancel して復旧を試みる。
#
# エスカレーション:
#   Phase 1 (0-60秒):  無視（正常な一時的待機の可能性）
#   Phase 2 (60-120秒): Escape 送信で Permission cancel
#   Phase 3 (120秒+):  Escape + /clear 送信（セッションリセット）
# ═══════════════════════════════════════════════════════════════════════════════
PERMISSION_PHASE1=60    # 60秒以上で Escape
PERMISSION_PHASE2=120   # 120秒以上で Escape + /clear

declare -A PANE_PERMISSION_FIRST_SEEN
declare -A PANE_PERMISSION_ESCAPE_COUNT

check_permission_deadlock() {
    local session="$1"
    local now
    now=$(date +%s)

    local pane_list
    pane_list=$(_tmux list-panes -s -t "$session" -F '#{pane_id} #{@agent_id}' 2>/dev/null)

    while IFS=' ' read -r pane_id agent_id; do
        [ -z "$pane_id" ] && continue
        [ -z "$agent_id" ] || [ "$agent_id" = "..." ] && continue

        # ペイン内容をスキャン（最後の20行）
        local content
        content=$(_tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -20)

        # "Waiting for permission" or "Waiting for team lead approval" を検出
        if echo "$content" | grep -q "Waiting for.*permission\|Waiting for team lead"; then
            # 初回検出
            if [ -z "${PANE_PERMISSION_FIRST_SEEN[$pane_id]:-}" ]; then
                PANE_PERMISSION_FIRST_SEEN[$pane_id]=$now
                PANE_PERMISSION_ESCAPE_COUNT[$pane_id]=0
                log "DEADLOCK-DETECT: $agent_id ($pane_id) — permission待ち検出"
                continue
            fi

            local first_seen="${PANE_PERMISSION_FIRST_SEEN[$pane_id]}"
            local age=$((now - first_seen))
            local esc_count="${PANE_PERMISSION_ESCAPE_COUNT[$pane_id]:-0}"

            if [ "$age" -ge "$PERMISSION_PHASE2" ]; then
                # Phase 3: Escape + /clear
                log "DEADLOCK-RECOVERY: $agent_id ($pane_id) — ${age}秒経過、Escape + /clear 送信"
                _tmux send-keys -t "$pane_id" Escape 2>/dev/null
                sleep 2
                _tmux send-keys -t "$pane_id" Escape 2>/dev/null
                sleep 2
                _tmux send-keys -t "$pane_id" "/clear" 2>/dev/null
                sleep 1
                _tmux send-keys -t "$pane_id" Enter 2>/dev/null
                # リセット
                unset "PANE_PERMISSION_FIRST_SEEN[$pane_id]"
                unset "PANE_PERMISSION_ESCAPE_COUNT[$pane_id]"

            elif [ "$age" -ge "$PERMISSION_PHASE1" ] && [ "$esc_count" -lt 2 ]; then
                # Phase 2: Escape で cancel
                log "DEADLOCK-RECOVERY: $agent_id ($pane_id) — ${age}秒経過、Escape 送信 (試行$((esc_count+1)))"
                _tmux send-keys -t "$pane_id" Escape 2>/dev/null
                sleep 1
                _tmux send-keys -t "$pane_id" Escape 2>/dev/null
                PANE_PERMISSION_ESCAPE_COUNT[$pane_id]=$((esc_count + 1))
            fi
        else
            # Permission待ちが解消された → リセット
            if [ -n "${PANE_PERMISSION_FIRST_SEEN[$pane_id]:-}" ]; then
                log "DEADLOCK-RESOLVED: $agent_id ($pane_id) — permission待ち解消"
                unset "PANE_PERMISSION_FIRST_SEEN[$pane_id]"
                unset "PANE_PERMISSION_ESCAPE_COUNT[$pane_id]"
            fi
        fi
    done <<< "$pane_list"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 無反応検出 + /clear 復旧（カーソル位置ベース）
# ═══════════════════════════════════════════════════════════════════════════════
declare -A PANE_LAST_ACTIVITY
declare -A PANE_LAST_CLEAR

check_unresponsive_panes() {
    local session="$1"
    local now
    now=$(date +%s)

    local pane_list
    pane_list=$(_tmux list-panes -s -t "$session" -F '#{pane_id} #{@agent_id}' 2>/dev/null)

    while IFS=' ' read -r pane_id agent_id; do
        [ -z "$pane_id" ] && continue
        [ -z "$agent_id" ] || [ "$agent_id" = "..." ] && continue

        # 将軍は /clear しない（人間との会話履歴を保持）
        [ "$agent_id" = "shogun" ] || [ "$agent_id" = "team-lead" ] && continue
        # 家老・軍師も /clear しない（Agent Teams のコマンド層）
        [ "$agent_id" = "karo" ] || [ "$agent_id" = "gunshi" ] && continue

        # ペインのカーソル位置（活動の指標）
        local cursor_y
        cursor_y=$(_tmux display-message -t "$pane_id" -p '#{cursor_y}' 2>/dev/null)

        # 活動追跡キー
        local activity_key="${pane_id}_${cursor_y}"

        if [ "${PANE_LAST_ACTIVITY[$pane_id]+exists}" ]; then
            if [ "${PANE_LAST_ACTIVITY[$pane_id]}" = "$activity_key" ]; then
                # カーソル位置が変わっていない = 無反応の可能性
                local first_seen="${PANE_LAST_ACTIVITY[${pane_id}_ts]:-$now}"
                local age=$((now - first_seen))

                if [ "$age" -ge "$UNRESPONSIVE_THRESHOLD" ]; then
                    # /clear クールダウンチェック
                    local last_clear="${PANE_LAST_CLEAR[$pane_id]:-0}"
                    if [ "$((now - last_clear))" -ge "$CLEAR_COOLDOWN" ]; then
                        log "RECOVERY: $agent_id ($pane_id) unresponsive for ${age}s — sending /clear"
                        _tmux send-keys -t "$pane_id" "/clear" 2>/dev/null
                        sleep 1
                        _tmux send-keys -t "$pane_id" Enter 2>/dev/null
                        PANE_LAST_CLEAR[$pane_id]=$now
                        # リセット
                        unset "PANE_LAST_ACTIVITY[${pane_id}_ts]"
                    fi
                fi
            else
                # 活動あり — タイマーリセット
                PANE_LAST_ACTIVITY[$pane_id]="$activity_key"
                PANE_LAST_ACTIVITY[${pane_id}_ts]=$now
            fi
        else
            # 初回追跡開始
            PANE_LAST_ACTIVITY[$pane_id]="$activity_key"
            PANE_LAST_ACTIVITY[${pane_id}_ts]=$now
        fi
    done <<< "$pane_list"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 動的リサイズ — 稼働中ペインを大きく、待機中を小さく（列独立）
# ═══════════════════════════════════════════════════════════════════════════════
# 列ファースト {col[rows]} 構造のカスタムレイアウトを構築し select-layout で
# 一括適用。各列の行高さが完全に独立しているため、列0のリサイズが列1・2に
# 波及しない。
# ═══════════════════════════════════════════════════════════════════════════════
MIN_PANE_HEIGHT=4
PREV_RESIZE_STATE=""
RESIZE_DEBUG_COUNTER=0

dynamic_resize_panes() {
    local session="$1"

    # agent_is_busy_check が使えなければスキップ
    type agent_is_busy_check &>/dev/null || return

    # 9ペインウィンドウを検索
    local win_id=""
    local wid
    while read -r wid; do
        [ -z "$wid" ] && continue
        local cnt
        cnt=$(_tmux list-panes -t "$wid" 2>/dev/null | wc -l | tr -d ' ')
        if [ "$cnt" -eq 9 ]; then
            win_id="$wid"
            break
        fi
    done <<< "$(_tmux list-windows -t "$session" -F '#{window_id}' 2>/dev/null)"
    [ -z "$win_id" ] && return

    # ウィンドウサイズ取得
    local dims
    dims=$(_tmux display-message -t "$win_id" -p '#{window_width} #{window_height}' 2>/dev/null)
    local win_width=${dims%% *}
    local win_height=${dims##* }
    [ -z "$win_width" ] || [ "$win_width" -lt 10 ] && return
    [ -z "$win_height" ] || [ "$win_height" -lt 10 ] && return

    # 全ペインの busy/idle 状態を収集
    local pane_list
    pane_list=$(_tmux list-panes -t "$win_id" -F '#{pane_id} #{@agent_id}' 2>/dev/null)
    [ -z "$pane_list" ] && return

    local pane_ids=() pane_nums=() pane_busy=()
    local current_state=""
    while IFS=' ' read -r pid aid; do
        pane_ids+=("$pid")
        pane_nums+=("${pid#%}")    # %5 → 5
        if [ -n "$aid" ] && [ "$aid" != "..." ] && agent_is_busy_check "$pid" 2>/dev/null; then
            pane_busy+=(1)
            current_state+="B"
        else
            pane_busy+=(0)
            current_state+="I"
        fi
    done <<< "$pane_list"

    # ペイン数確認
    [ "${#pane_ids[@]}" -ne 9 ] && return

    # 定期デバッグログ（30サイクル≒90秒ごと）
    RESIZE_DEBUG_COUNTER=$((RESIZE_DEBUG_COUNTER + 1))
    if [ "$((RESIZE_DEBUG_COUNTER % 30))" -eq 0 ]; then
        log "dynamic_resize_debug: state=$current_state prev=$PREV_RESIZE_STATE"
    fi

    # 前回と同じ状態ならスキップ
    if [ "$current_state" = "$PREV_RESIZE_STATE" ]; then
        return
    fi
    PREV_RESIZE_STATE="$current_state"

    # 各列の高さを独立に計算（行ボーダー2本分を引く）
    local usable_h=$((win_height - 2))
    local heights=()

    for col in 0 1 2; do
        local busy_cnt=0 idle_cnt=0
        for row in 0 1 2; do
            local idx=$((col * 3 + row))
            [ "${pane_busy[$idx]}" -eq 1 ] && busy_cnt=$((busy_cnt + 1)) || idle_cnt=$((idle_cnt + 1))
        done

        local col_h=()
        if [ "$busy_cnt" -eq 0 ]; then
            # 全員待機 → 均等
            local eq=$((usable_h / 3))
            col_h=("$eq" "$eq" "$eq")
        else
            # BUSY に余剰高さを割当、IDLE は最小
            local idle_total=$((idle_cnt * MIN_PANE_HEIGHT))
            local busy_h=$(( (usable_h - idle_total) / busy_cnt ))
            [ "$busy_h" -lt "$MIN_PANE_HEIGHT" ] && busy_h=$MIN_PANE_HEIGHT
            for row in 0 1 2; do
                local idx=$((col * 3 + row))
                if [ "${pane_busy[$idx]}" -eq 1 ]; then
                    col_h+=("$busy_h")
                else
                    col_h+=("$MIN_PANE_HEIGHT")
                fi
            done
        fi

        # 端数を最後のペインで吸収
        local sum=$((col_h[0] + col_h[1] + col_h[2]))
        col_h[2]=$((col_h[2] + usable_h - sum))
        heights+=("${col_h[@]}")
    done

    # カスタムレイアウト構築・適用（列ファースト構造 = 列ごと独立）
    local layout_str
    layout_str=$(build_column_first_layout "$win_width" "$win_height" \
        "${pane_nums[@]}" "${heights[@]}")
    _tmux select-layout -t "$win_id" "$layout_str" 2>/dev/null

    log "dynamic_resize: state=$current_state (column-independent)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# メインループ
# ═══════════════════════════════════════════════════════════════════════════════
declare -A STYLED_PANES
PREV_PANE_COUNT=0
RECOVERY_CHECK_COUNTER=0
DEADLOCK_CHECK_COUNTER=0

while true; do
    sleep "$POLL_INTERVAL"

    # セッション検出
    local_session=$(detect_session)
    if [ -z "$local_session" ]; then
        continue
    fi

    # shogun-main は統合ビューア（ユーザー操作画面）なのでスキップ
    if [ "$local_session" = "shogun-main" ]; then
        continue
    fi

    # セッションが存在するか確認
    if ! _tmux has-session -t "$local_session" 2>/dev/null; then
        continue
    fi

    # 現在のペイン一覧を取得
    pane_list=$(_tmux list-panes -s -t "$local_session" -F '#{pane_id}' 2>/dev/null)
    if [ -z "$pane_list" ]; then
        continue
    fi

    pane_count=$(echo "$pane_list" | wc -l | tr -d ' ')

    # 各ペインを処理
    while IFS= read -r pane_id; do
        [ -z "$pane_id" ] && continue

        # 既にスタイル済みかチェック
        if [ "${STYLED_PANES[$pane_id]+exists}" ]; then
            # 既にスタイル済みでも、自己登録で @agent_id が変わった場合は再適用
            current_id=$(_tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
            if [ -n "$current_id" ] && [ "$current_id" != "..." ] && [ "$current_id" != "${STYLED_PANES[$pane_id]}" ]; then
                style_pane "$pane_id" "$current_id"
                STYLED_PANES[$pane_id]="$current_id"
            else
                # bg_color が空でないエージェント（karo/gunshi）は毎サイクル色を再適用
                styled_agent="${STYLED_PANES[$pane_id]}"
                bg_check=$(get_bg_color_for_agent "$styled_agent")
                if [ -n "$bg_check" ]; then
                    style_pane "$pane_id" "$styled_agent"
                fi
            fi
            continue
        fi

        # エージェント名を検出
        agent_name=$(detect_agent_from_pane "$pane_id")

        if [ -n "$agent_name" ]; then
            style_pane "$pane_id" "$agent_name"
            STYLED_PANES[$pane_id]="$agent_name"
        else
            # 未検出でも空のデフォルトをセット（border表示のため）
            _tmux set-option -p -t "$pane_id" @agent_id "..." 2>/dev/null
            _tmux set-option -p -t "$pane_id" @model_name "..." 2>/dev/null
            _tmux set-option -p -t "$pane_id" @current_task "" 2>/dev/null
        fi
    done <<< "$pane_list"

    # pane-border-format を適用（ペイン数変化時 or 初回）
    if [ "$BORDER_APPLIED" = false ] || [ "$pane_count" -ne "$PREV_PANE_COUNT" ]; then
        apply_border_format "$local_session"
        BORDER_APPLIED=true
        log "pane-border-format applied (panes: $pane_count)"
    fi

    # レイアウト適用（ペイン数変化時のみ）
    if [ "$pane_count" -ne "$PREV_PANE_COUNT" ] && [ "$pane_count" -ge 4 ]; then
        windows=$(_tmux list-windows -t "$local_session" -F '#{window_id}' 2>/dev/null)
        for win in $windows; do
            win_panes=$(_tmux list-panes -t "$win" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$win_panes" -eq 9 ]; then
                # 9ペイン = 3x3 グリッド
                apply_3x3_grid "$win"
            elif [ "$win_panes" -ge 4 ]; then
                # それ以外は tiled
                _tmux select-layout -t "$win" tiled 2>/dev/null
                log "tiled layout applied to window $win ($win_panes panes)"
            fi
        done
    fi

    # 動的リサイズ（毎サイクル、状態変化時のみ実際にリサイズ）
    if [ "$pane_count" -eq 9 ]; then
        dynamic_resize_panes "$local_session" 2>/dev/null || true
    fi

    # Permission デッドロック検出（5サイクルごと = 約15秒ごと）
    # ※ 無反応検出より高頻度: デッドロックは即座に全軍停止するため早期検出が重要
    DEADLOCK_CHECK_COUNTER=$((DEADLOCK_CHECK_COUNTER + 1))
    if [ "$DEADLOCK_CHECK_COUNTER" -ge 5 ]; then
        check_permission_deadlock "$local_session"
        DEADLOCK_CHECK_COUNTER=0
    fi

    # 無反応ペイン検出（10サイクルごと = 約30秒ごと）
    RECOVERY_CHECK_COUNTER=$((RECOVERY_CHECK_COUNTER + 1))
    if [ "$RECOVERY_CHECK_COUNTER" -ge 10 ]; then
        check_unresponsive_panes "$local_session"
        RECOVERY_CHECK_COUNTER=0
    fi

    PREV_PANE_COUNT=$pane_count
done
