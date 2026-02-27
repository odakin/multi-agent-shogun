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
#   - tiled レイアウトを自動適用（4ペイン以上）
#   - エージェント識別: (1) 自己登録, (2) ペイン内容スキャン
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

mkdir -p "$LOG_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# ログ関数
# ═══════════════════════════════════════════════════════════════════════════════
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

log "=== ビジュアルモニター起動 ==="
log "SESSION_NAME=$SESSION_NAME"
log "SCRIPT_DIR=$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# セッション名の自動検出
# ═══════════════════════════════════════════════════════════════════════════════
detect_session() {
    if [ -n "$SESSION_NAME" ]; then
        echo "$SESSION_NAME"
        return
    fi

    # Agent Teams のセッションを探す
    local sessions
    sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null)
    for s in $sessions; do
        # Claude Code が動いているセッションを探す
        local pane_content
        pane_content=$(tmux capture-pane -t "$s" -p 2>/dev/null | head -5)
        if echo "$pane_content" | grep -q "Claude Code\|claude-code\|multi-agent-shogun"; then
            echo "$s"
            return
        fi
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
            echo "Sonnet"
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
# ペインからエージェント名を検出
# ═══════════════════════════════════════════════════════════════════════════════
detect_agent_from_pane() {
    local pane_id="$1"

    # 方法1: 既に @agent_id が自己登録されている場合（最優先）
    local existing_id
    existing_id=$(tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
    if [ -n "$existing_id" ] && [ "$existing_id" != "" ]; then
        echo "$existing_id"
        return
    fi

    # 方法2: ペイン内容をスキャンしてエージェント名を検出
    local content
    content=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | head -30)

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

    # 方法3: チーム config から名前リストを取得
    # （spawn順序と pane 順序の対応は不確実なためフォールバック）
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

    tmux set-option -p -t "$pane_id" @agent_id "$agent_name" 2>/dev/null
    tmux set-option -p -t "$pane_id" @model_name "$model" 2>/dev/null
    tmux set-option -p -t "$pane_id" @current_task "" 2>/dev/null

    log "Styled pane $pane_id as $agent_name ($model)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# pane-border-format を適用
# ═══════════════════════════════════════════════════════════════════════════════
apply_border_format() {
    local session="$1"

    # 全ウィンドウに適用
    local windows
    windows=$(tmux list-windows -t "$session" -F '#{window_id}' 2>/dev/null)
    for win in $windows; do
        tmux set-option -w -t "$win" pane-border-status top 2>/dev/null
        tmux set-option -w -t "$win" pane-border-format \
            '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}' \
            2>/dev/null
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# メインループ
# ═══════════════════════════════════════════════════════════════════════════════
declare -A STYLED_PANES
PREV_PANE_COUNT=0

while true; do
    sleep "$POLL_INTERVAL"

    # セッション検出
    local_session=$(detect_session)
    if [ -z "$local_session" ]; then
        continue
    fi

    # セッションが存在するか確認
    if ! tmux has-session -t "$local_session" 2>/dev/null; then
        continue
    fi

    # 現在のペイン一覧を取得
    pane_list=$(tmux list-panes -s -t "$local_session" -F '#{pane_id}' 2>/dev/null)
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
            current_id=$(tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
            if [ -n "$current_id" ] && [ "$current_id" != "${STYLED_PANES[$pane_id]}" ]; then
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
            tmux set-option -p -t "$pane_id" @agent_id "..." 2>/dev/null
            tmux set-option -p -t "$pane_id" @model_name "..." 2>/dev/null
            tmux set-option -p -t "$pane_id" @current_task "" 2>/dev/null
        fi
    done <<< "$pane_list"

    # pane-border-format を適用（毎回冪等に実行）
    if [ "$BORDER_APPLIED" = false ] || [ "$pane_count" -ne "$PREV_PANE_COUNT" ]; then
        apply_border_format "$local_session"
        BORDER_APPLIED=true
        log "pane-border-format applied (panes: $pane_count)"
    fi

    # tiled レイアウト適用（4ペイン以上、ペイン数変化時のみ）
    if [ "$pane_count" -ge 4 ] && [ "$pane_count" -ne "$PREV_PANE_COUNT" ]; then
        # 全ウィンドウに tiled レイアウト適用
        windows=$(tmux list-windows -t "$local_session" -F '#{window_id}' 2>/dev/null)
        for win in $windows; do
            win_panes=$(tmux list-panes -t "$win" 2>/dev/null | wc -l | tr -d ' ')
            if [ "$win_panes" -ge 4 ]; then
                tmux select-layout -t "$win" tiled 2>/dev/null
                log "tiled layout applied to window $win ($win_panes panes)"
            fi
        done
    fi

    PREV_PANE_COUNT=$pane_count
done
