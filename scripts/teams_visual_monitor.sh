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
#   - ペイン背景色の適用（家老=赤、軍師=金、将軍=Solarized Dark）
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
# エージェント名に基づく背景色
# ═══════════════════════════════════════════════════════════════════════════════
get_bg_color_for_agent() {
    local agent="$1"
    case "$agent" in
        shogun|team-lead)
            echo "bg=#002b36"    # Solarized Dark
            ;;
        karo)
            echo "bg=#2a1215"    # 暗赤（家老）
            ;;
        gunshi)
            echo "bg=#2a2a10"    # 暗金（軍師）
            ;;
        ashigaru*)
            echo ""              # 足軽はデフォルト背景
            ;;
        *)
            echo ""
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

    # 背景色の適用
    local bg_color
    bg_color=$(get_bg_color_for_agent "$agent_name")
    if [ -n "$bg_color" ]; then
        _tmux select-pane -t "$pane_id" -P "$bg_color" 2>/dev/null
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
# 3x3 グリッドレイアウト適用
# Agent Teams はペインを自動作成するが、レイアウトは tiled のみ。
# 9ペイン時に 3x3 グリッドに再構成する。
# ═══════════════════════════════════════════════════════════════════════════════
apply_3x3_grid() {
    local win="$1"
    local win_panes
    win_panes=$(_tmux list-panes -t "$win" 2>/dev/null | wc -l | tr -d ' ')

    if [ "$win_panes" -eq 9 ]; then
        # tiled レイアウトをまず適用（均等分割のベース）
        _tmux select-layout -t "$win" tiled 2>/dev/null
        log "3x3 grid layout applied to window $win (9 panes)"
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
