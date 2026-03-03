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

# pane-border-lines スタイル: heavy は tmux 3.2+ 必須。バージョン検出して自動選択。
_detect_border_line_style() {
    local ver major minor
    ver=$(tmux -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    major="${ver%%.*}"
    minor="${ver##*.}"
    if [ -n "$major" ] && { [ "$major" -gt 3 ] || { [ "$major" -eq 3 ] && [ "${minor:-0}" -ge 2 ]; }; }; then
        echo "heavy"
    else
        echo "single"
    fi
}
BORDER_LINE_STYLE=$(_detect_border_line_style)

# /clear recovery settings
UNRESPONSIVE_THRESHOLD=240   # 4分間無反応で /clear 送信
CLEAR_COOLDOWN=300           # /clear は5分に1回まで
STALE_TASK_THRESHOLD=600     # 10分でタスク滞留 ⏰ 表示

# claude-swarm tmux サーバー検出用
TMUX_SOCKET=""               # -L オプションの値（空なら デフォルトサーバー）
declare -A TASK_DESC_CACHE   # agent名 → description冒頭テキスト
declare -A TASK_ID_CACHE     # agent名 → 前回のtask_id

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

# Source shared library for busy/idle detection (used by dynamic_resize_by_content)
if [ -f "$SCRIPT_DIR/lib/agent_status.sh" ]; then
    source "$SCRIPT_DIR/lib/agent_status.sh"
fi

# Source Japanese name conversion library
if [ -f "$SCRIPT_DIR/scripts/agent_name_ja.sh" ]; then
    source "$SCRIPT_DIR/scripts/agent_name_ja.sh"
else
    # フォールバック: ライブラリ未存在時は変換なし
    to_ja() { echo "$1"; }
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
    local settings_yaml="$SCRIPT_DIR/config/settings.yaml"

    # config/settings.yaml から cli.agents.{agent}.model を動的取得
    if [ -f "$settings_yaml" ] && [ -f "$SCRIPT_DIR/.venv/bin/python3" ]; then
        # ashigaru{N} の場合は ashigaru も検索対象にする
        local base_agent="$agent"
        [[ "$agent" =~ ^ashigaru[0-9]+$ ]] && base_agent="ashigaru"

        local model_raw
        model_raw=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml
try:
    with open('$settings_yaml') as f:
        data = yaml.safe_load(f) or {}
    # cli.agents パスを優先（cli_adapter.sh と同じパス）
    cli = data.get('cli', {}) or {}
    agents = cli.get('agents', {}) or {}
    for name in ['$agent', '$base_agent']:
        cfg = agents.get(name)
        if isinstance(cfg, dict):
            m = cfg.get('model', '')
            if m:
                print(str(m).capitalize())
                break
except Exception:
    pass
" 2>/dev/null)
        if [ -n "$model_raw" ]; then
            echo "$model_raw"
            return
        fi
    fi

    # フォールバック: デフォルト値
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
# ペイン内容から実際に稼働中のモデルを検出
# Claude Code バナー "Sonnet 4.6 · Claude Max" 等をパースする
# ═══════════════════════════════════════════════════════════════════════════════
detect_pane_model() {
    local pane_id="$1"
    local content
    content=$(timeout 2 tmux capture-pane -t "$pane_id" -p 2>/dev/null | head -5)
    if [ -z "$content" ]; then
        echo ""
        return
    fi
    # Claude Code バナーから "Opus 4.6", "Sonnet 4.6", "Haiku 4.5" 等を検出
    local model_full
    model_full=$(echo "$content" | grep -oE '(Opus|Sonnet|Haiku) [0-9]+\.[0-9]+' | head -1)
    if [ -n "$model_full" ]; then
        # "Sonnet 4.6" → "Sonnet" (モデルファミリーのみ返す)
        echo "${model_full%% *}"
        return
    fi
    echo ""
}

# model reconciliation 用: 送信済みフラグ（エージェントごと）
declare -A MODEL_RECONCILED 2>/dev/null || true

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

    # 方法1: 既に @agent_id が自己登録されている場合（最優先・上書き禁止）
    # エージェントが tmux set-option -p @agent_id で自己登録した値は
    # コンテンツスキャンで絶対に上書きしない（軍師ペインに karo が入るバグの原因）
    local existing_id
    existing_id=$(_tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
    if [ -n "$existing_id" ] && [ "$existing_id" != "" ] && [ "$existing_id" != "..." ]; then
        echo "$existing_id"
        return
    fi

    # 方法2: STYLED_PANES に記録済みなら再スキャンしない（誤検出防止）
    # ※ STYLED_PANES はグローバル変数。この関数からは直接参照できないが、
    #    呼び出し元(メインループ)で既にスタイル済みペインはスキップされる。

    # 方法3: ペイン内容をスキャンして初回検出のみ行う
    # ⚠️ コンテンツスキャンは誤検出リスクが高い（inbox メッセージ等で別エージェント名が出る）
    # そのため、検出結果は「自己登録が来るまでの仮ID」として扱う
    local content
    content=$(_tmux capture-pane -t "$pane_id" -p 2>/dev/null | head -30)

    # spawn prompt の set-option パターンから検出（最も信頼性が高い）
    local set_id
    set_id=$(echo "$content" | grep -o "@agent_id ['\"]\\?[a-z]*[0-9]*['\"]\\?" | head -1 | grep -o "[a-z]*[0-9]*$" | head -1)
    if [ -n "$set_id" ]; then
        echo "$set_id"
        return
    fi

    # instructions ファイルの読み込みパターンから検出
    # ⚠️ 複数エージェント名がマッチする場合は検出しない（誤検出防止）
    local match_count=0
    local detected=""
    if echo "$content" | grep -q "instructions/shogun.md"; then
        detected="shogun"; match_count=$((match_count + 1))
    fi
    if echo "$content" | grep -q "instructions/karo.md"; then
        detected="karo"; match_count=$((match_count + 1))
    fi
    if echo "$content" | grep -q "instructions/gunshi.md"; then
        detected="gunshi"; match_count=$((match_count + 1))
    fi
    # 足軽チェック（instructions/ashigaru.md を読んでいる + 番号特定）
    if echo "$content" | grep -q "instructions/ashigaru.md"; then
        local ashi_num
        ashi_num=$(echo "$content" | grep -o "ashigaru[0-9]" | head -1 | grep -o "[0-9]")
        if [ -n "$ashi_num" ]; then
            detected="ashigaru${ashi_num}"; match_count=$((match_count + 1))
        fi
    fi

    # 単一マッチのみ採用（複数マッチ = 誤検出の可能性大）
    if [ "$match_count" -eq 1 ]; then
        echo "$detected"
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

    # @agent_id: 自己登録値がある場合は上書きしない（誤検出防止）
    # コンテンツスキャンの結果が自己登録と異なる場合、自己登録を優先する
    local current_id
    current_id=$(_tmux show-options -p -t "$pane_id" -v @agent_id 2>/dev/null)
    if [ -n "$current_id" ] && [ "$current_id" != "..." ] && [ "$current_id" != "$agent_name" ]; then
        # 既に有効な agent_id が設定済み → 上書きしない（自己登録優先）
        agent_name="$current_id"
        model=$(get_model_for_agent "$agent_name")
    elif [ "$current_id" != "$agent_name" ]; then
        _tmux set-option -p -t "$pane_id" @agent_id "$agent_name" 2>/dev/null
    fi

    # @agent_name_ja: 日本語表示名（表示専用。routing には使わない）
    _tmux set-option -p -t "$pane_id" @agent_name_ja "$(to_ja "$agent_name")" 2>/dev/null

    # @model_name: ペインから実際のモデルを検出して表示（settings.yaml 上書き廃止）
    local actual_model
    actual_model=$(detect_pane_model "$pane_id")
    if [ -n "$actual_model" ]; then
        local current_model
        current_model=$(_tmux show-options -p -t "$pane_id" -v @model_name 2>/dev/null)
        if [ "$current_model" != "$actual_model" ]; then
            _tmux set-option -p -t "$pane_id" @model_name "$actual_model" 2>/dev/null
        fi
        # Model reconciliation: 設定値と実際が異なれば /model 送信（一度だけ）
        local config_model="$model"  # get_model_for_agent() の結果（settings.yaml の値）
        local actual_lower="${actual_model,,}"
        local config_lower="${config_model,,}"
        if [ "$actual_lower" != "$config_lower" ] && [ "${MODEL_RECONCILED[$agent_name]:-}" != "$config_lower" ]; then
            log_info "Model mismatch: ${agent_name} actual=${actual_model} config=${config_model} → sending /model ${config_lower}"
            bash "$SCRIPT_DIR/scripts/inbox_write.sh" "$agent_name" "/model ${config_lower}" model_switch monitor 2>/dev/null &
            MODEL_RECONCILED[$agent_name]="$config_lower"
        fi
    else
        # バナー未検出（起動中など）→ settings.yaml の値をフォールバックとして使用
        local current_model
        current_model=$(_tmux show-options -p -t "$pane_id" -v @model_name 2>/dev/null)
        if [ -z "$current_model" ] || [ "$current_model" = "..." ]; then
            _tmux set-option -p -t "$pane_id" @model_name "$model" 2>/dev/null
        fi
    fi

    # @current_task: task YAML から task_id を読み取り設定（ペイン出力文字列マッチ廃止）
    # inbox nudge テキスト("inbox1"等)の誤検出を防止するため YAML を正規参照とする
    local task_id_val
    task_id_val=$(get_task_id_from_yaml "$agent_name")
    _tmux set-option -p -t "$pane_id" @current_task "$task_id_val" 2>/dev/null

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
        _tmux set-option -w -t "$win" pane-border-style "fg=colour240" 2>/dev/null
        _tmux set-option -w -t "$win" pane-active-border-style "fg=colour33,bold" 2>/dev/null
        # heavy: 太線で9ペイン密集時の境界が明確。tmux 3.2+ のみ対応。
        # 起動時にバージョン検出済み（BORDER_LINE_STYLE）→ フォント非対応なら "single" を使用。
        _tmux set-option -w -t "$win" pane-border-lines "$BORDER_LINE_STYLE" 2>/dev/null
        _tmux set-option -w -t "$win" pane-border-format \
            '#{?pane_active,#[fg=colour33,bold],#[fg=colour240]}#{@agent_name_ja}#[default] #[dim](#{@model_name})#[default] #{@current_task}' \
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

# ═══════════════════════════════════════════════════════════════════════════════
# task YAML から現在のtask_id を取得
# ペイン出力文字列マッチは使わない — inbox nudge("inbox1"等)の誤検出を防止
# ═══════════════════════════════════════════════════════════════════════════════
get_task_id_from_yaml() {
    local agent_name="$1"
    local script_dir="${2:-$SCRIPT_DIR}"
    local task_yaml="$script_dir/queue/tasks/${agent_name}.yaml"
    [ -f "$task_yaml" ] || { echo ""; return; }
    "$script_dir/.venv/bin/python3" -c "
import yaml
try:
    with open('$task_yaml') as f:
        data = yaml.safe_load(f) or {}
    task = data.get('task', {}) or {}
    status = task.get('status', '')
    if status in ('assigned', 'in_progress', 'pending'):
        tid = task.get('task_id', '') or ''
        print(tid[:15])
except Exception as e:
    import sys
    print(f'WARN get_task_id: {e}', file=sys.stderr)
" 2>/dev/null || echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# 全スタイル済みペインの @current_task を task YAML から定期更新
# ⏰ 滞留検知（STALE_TASK_THRESHOLD 超過）と 📬 idle+inbox未読検知を統合
# ═══════════════════════════════════════════════════════════════════════════════
update_current_tasks() {
    local pane_id agent_name
    for pane_id in "${!STYLED_PANES[@]}"; do
        agent_name="${STYLED_PANES[$pane_id]}"
        { [ -z "$agent_name" ] || [ "$agent_name" = "..." ]; } && continue

        # task YAML から task_id + description を取得（⏰滞留チェック付き）
        local task_yaml="$SCRIPT_DIR/queue/tasks/${agent_name}.yaml"
        local py_out=""
        if [ -f "$task_yaml" ]; then
            py_out=$("$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml, datetime
try:
    with open('$task_yaml') as f:
        data = yaml.safe_load(f) or {}
    task = data.get('task', {}) or {}
    status = task.get('status', '')
    if status in ('assigned', 'in_progress', 'pending'):
        tid = (task.get('task_id', '') or '')[:15]
        ts_str = task.get('timestamp', '') or ''
        prefix = ''
        if ts_str and tid:
            try:
                ts = datetime.datetime.fromisoformat(ts_str)
                age = (datetime.datetime.now() - ts.replace(tzinfo=None)).total_seconds()
                if age > $STALE_TASK_THRESHOLD:
                    prefix = chr(0x23f0)
            except Exception:
                pass
        desc_raw = (task.get('description', '') or '').split('\\n')[0].strip()
        desc = desc_raw[:20] + ('…' if len(desc_raw) > 20 else '')
        print(prefix + tid + '\\t' + tid + '\\t' + desc)
except Exception:
    pass
" 2>/dev/null || echo "")
        fi

        # Python出力をパース: {display_val}\t{raw_tid}\t{desc}
        local display_val raw_tid desc_from_py
        if [[ "$py_out" == *$'\t'* ]]; then
            display_val="${py_out%%$'\t'*}"
            local rest="${py_out#*$'\t'}"
            raw_tid="${rest%%$'\t'*}"
            desc_from_py="${rest#*$'\t'}"
        else
            display_val="$py_out"
            raw_tid="$py_out"
            desc_from_py=""
        fi

        # task_id変化時のみキャッシュ更新
        if [ "${TASK_ID_CACHE[$agent_name]:-}" != "$raw_tid" ]; then
            TASK_ID_CACHE[$agent_name]="$raw_tid"
            TASK_DESC_CACHE[$agent_name]="$desc_from_py"
        fi

        # description表示（display_valが空=idle時は非表示）
        local task_desc="${TASK_DESC_CACHE[$agent_name]:-}"
        local desc_suffix=""
        [ -n "$display_val" ] && [ -n "$task_desc" ] && desc_suffix=" $task_desc"

        # idle + inbox未読チェック（📬）— 将軍・家老は対象外
        local mailbox=""
        if [[ "$agent_name" != "shogun" && "$agent_name" != "team-lead" && "$agent_name" != "karo" ]]; then
            local inbox_file="$SCRIPT_DIR/queue/inbox/${agent_name}.yaml"
            if [ -f "$inbox_file" ]; then
                local unread
                unread=$(grep -c "read: false" "$inbox_file" 2>/dev/null) || unread=0
                if [ "$unread" -gt 0 ]; then
                    local is_busy=false
                    if type agent_is_busy_check &>/dev/null; then
                        agent_is_busy_check "$pane_id" 2>/dev/null && is_busy=true
                    fi
                    [ "$is_busy" = "false" ] && mailbox=" 📬"
                fi
            fi
        fi

        _tmux set-option -p -t "$pane_id" @current_task "${display_val}${desc_suffix}${mailbox}" 2>/dev/null
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# idle + inbox未読 自動 re-nudge
# idle（プロンプト待ち）かつ inbox に未読がある足軽/軍師に inboxN を送信。
# 60秒間隔制限で連打防止。表示更新は update_current_tasks() が担当。
# 対象: 足軽1-7 + 軍師 + 家老（全エージェント、将軍のみ除外）
# ═══════════════════════════════════════════════════════════════════════════════
check_idle_inbox_unread() {
    local session="$1"
    local now
    now=$(date +%s)

    local pane_list
    pane_list=$(_tmux list-panes -s -t "$session" -F '#{pane_id} #{@agent_id}' 2>/dev/null)

    while IFS=' ' read -r pane_id agent_id; do
        [ -z "$pane_id" ] && continue
        { [ -z "$agent_id" ] || [ "$agent_id" = "..." ]; } && continue
        # 将軍のみスキップ（家老・軍師も自動re-nudge対象）
        [[ "$agent_id" == "shogun" || "$agent_id" == "team-lead" || "$agent_id" == "monitor" ]] && continue

        # inbox未読件数を確認
        local inbox_file="$SCRIPT_DIR/queue/inbox/${agent_id}.yaml"
        [ -f "$inbox_file" ] || continue
        local unread
        unread=$(grep -c "read: false" "$inbox_file" 2>/dev/null) || unread=0
        [ "$unread" -gt 0 ] || continue

        # idle 判定（busy なら re-nudge しない）
        if type agent_is_busy_check &>/dev/null; then
            agent_is_busy_check "$pane_id" 2>/dev/null && continue
        fi

        # re-nudge 間隔制限（家老・軍師は処理に時間がかかるため長め）
        local nudge_interval=60
        [[ "$agent_id" == "karo" || "$agent_id" == "gunshi" ]] && nudge_interval=120
        local last_nudge="${LAST_RENUDGE_TS[$agent_id]:-0}"
        if [ "$((now - last_nudge))" -ge "$nudge_interval" ]; then
            log "IDLE-INBOX: $agent_id ($pane_id) — idle+unread(${unread}件) 検出、re-nudge送信"
            _tmux send-keys -t "$pane_id" "inbox${unread}" 2>/dev/null
            sleep 0.3
            _tmux send-keys -t "$pane_id" Enter 2>/dev/null
            LAST_RENUDGE_TS[$agent_id]=$now
        fi
    done <<< "$pane_list"
}

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
        { [ -z "$agent_id" ] || [ "$agent_id" = "..." ]; } && continue

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
declare -A LAST_RENUDGE_TS

check_unresponsive_panes() {
    local session="$1"
    local now
    now=$(date +%s)

    local pane_list
    pane_list=$(_tmux list-panes -s -t "$session" -F '#{pane_id} #{@agent_id}' 2>/dev/null)

    while IFS=' ' read -r pane_id agent_id; do
        [ -z "$pane_id" ] && continue
        { [ -z "$agent_id" ] || [ "$agent_id" = "..." ]; } && continue

        # 将軍・モニターは /clear しない（人間との会話履歴を保持）
        [[ "$agent_id" == "shogun" || "$agent_id" == "team-lead" || "$agent_id" == "monitor" ]] && continue

        # タスクなしの正当な idle 状態なら /clear 不要（idle /clear ループ防止）
        local task_yaml="$SCRIPT_DIR/queue/tasks/${agent_id}.yaml"
        if [ -f "$task_yaml" ]; then
            local task_status
            task_status=$(grep -m1 'status:' "$task_yaml" 2>/dev/null | awk '{print $2}' | tr -d "\"'" || echo "")
            [[ "$task_status" == "done" || "$task_status" == "idle" || -z "$task_status" ]] && continue
        else
            continue  # タスクファイルなし = 正当な idle
        fi

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
                        # 家老・軍師の /clear は将軍にエスカレーション通知
                        if [[ "$agent_id" == "karo" || "$agent_id" == "gunshi" ]]; then
                            log "ESCALATION: $agent_id recovery /clear sent — notifying shogun"
                            bash "$SCRIPT_DIR/scripts/inbox_write.sh" shogun \
                                "【モニタ自動復旧】${agent_id} が${age}秒間無応答のため /clear を送信した。自動復旧を試行中。" \
                                escalation monitor 2>/dev/null &
                        fi
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
# 動的リサイズ — コンテンツスコアベースで高さを動的に追従（列独立）
# ═══════════════════════════════════════════════════════════════════════════════
# cursor_y と history_size のデルタでコンテンツスコアを累積管理。
# スコアが高いペインを大きく、idle+無増加ペインは25%減衰で縮小。
# select-layout + 列ファースト構造で各列独立リサイズを保証。
# ═══════════════════════════════════════════════════════════════════════════════
MIN_PANE_HEIGHT=6
PREV_RESIZE_STATE=""
RESIZE_DEBUG_COUNTER=0
declare -A PANE_CONTENT_SCORE=()      # 各ペインのコンテンツスコア（累積）
declare -A PANE_PREV_CURSOR_Y=()      # 前サイクルの cursor_y
declare -A PANE_PREV_HISTORY_SIZE=()  # 前サイクルの history_size

dynamic_resize_by_content() {
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

    # 全ペイン情報を収集
    local pane_list
    pane_list=$(_tmux list-panes -t "$win_id" -F '#{pane_id} #{@agent_id}' 2>/dev/null)
    [ -z "$pane_list" ] && return

    local pane_ids=() pane_nums=() scores_arr=()
    while IFS=' ' read -r pid aid; do
        pane_ids+=("$pid")
        pane_nums+=("${pid#%}")    # %5 → 5

        # cursor_y と history_size を1回で取得
        local metrics
        metrics=$(_tmux display-message -t "$pid" -p '#{cursor_y} #{history_size}' 2>/dev/null)
        local cur_y="${metrics%% *}"
        local hist_size="${metrics##* }"

        # 非数値は0として扱う（エラー時の安全策）
        [[ "$cur_y" =~ ^[0-9]+$ ]] || cur_y=0
        [[ "$hist_size" =~ ^[0-9]+$ ]] || hist_size=0

        # デルタ計算（負値は無視: カーソル上移動・リサイズ起因の変化を除外）
        local prev_y="${PANE_PREV_CURSOR_Y[$pid]:-$cur_y}"
        local prev_hist="${PANE_PREV_HISTORY_SIZE[$pid]:-$hist_size}"
        local dy=$(( cur_y - prev_y ))
        local dh=$(( hist_size - prev_hist ))
        [ "$dy" -lt 0 ] && dy=0
        [ "$dh" -lt 0 ] && dh=0
        local delta=$(( dy + dh ))

        # スコア更新
        local score="${PANE_CONTENT_SCORE[$pid]:-0}"
        if [ "$delta" -gt 0 ]; then
            # コンテンツ増加 → スコア加算
            score=$(( score + delta ))
        else
            # idle かつ delta==0 → スコア25%減衰
            local is_busy=false
            if [ -n "$aid" ] && [ "$aid" != "..." ]; then
                agent_is_busy_check "$pid" 2>/dev/null && is_busy=true
            fi
            if [ "$is_busy" = "false" ]; then
                score=$(( score * 3 / 4 ))
            fi
        fi

        PANE_CONTENT_SCORE[$pid]=$score
        PANE_PREV_CURSOR_Y[$pid]=$cur_y
        PANE_PREV_HISTORY_SIZE[$pid]=$hist_size
        scores_arr+=("$score")
    done <<< "$pane_list"

    [ "${#pane_ids[@]}" -ne 9 ] && return

    # 高さ計算（列ごと独立）
    # 各ペインに MIN_PANE_HEIGHT を確保後、残りをスコア比例で配分
    local usable_h=$(( win_height - 2 ))
    local remaining=$(( usable_h - MIN_PANE_HEIGHT * 3 ))
    [ "$remaining" -lt 0 ] && remaining=0

    local heights=()
    for col in 0 1 2; do
        local col_scores=()
        for row in 0 1 2; do
            col_scores+=("${scores_arr[$((col * 3 + row))]}")
        done

        # 列内スコア合計
        local total_score=0
        for s in "${col_scores[@]}"; do
            total_score=$(( total_score + s ))
        done

        local col_h=()
        if [ "$total_score" -le 0 ]; then
            # 全員スコア0 → 均等配分
            local eq=$(( usable_h / 3 ))
            col_h=("$eq" "$eq" "$eq")
        else
            for row in 0 1 2; do
                local s="${col_scores[$row]}"
                local extra=$(( remaining * s / total_score ))
                col_h+=("$(( MIN_PANE_HEIGHT + extra ))")
            done
        fi

        # 端数を最終ペインで吸収（合計を usable_h に）
        local col_sum=$(( col_h[0] + col_h[1] + col_h[2] ))
        col_h[2]=$(( col_h[2] + usable_h - col_sum ))
        [ "${col_h[2]}" -lt "$MIN_PANE_HEIGHT" ] && col_h[2]=$MIN_PANE_HEIGHT

        heights+=("${col_h[@]}")
    done

    # 状態変化チェック（同一高さ構成ならスキップ）
    local dim_key="${win_width}x${win_height}"
    local heights_key="${heights[*]}"
    local full_state="${dim_key}|${heights_key}"
    if [ "$full_state" = "$PREV_RESIZE_STATE" ]; then
        return
    fi
    PREV_RESIZE_STATE="$full_state"

    # カスタムレイアウト構築・適用（列ファースト構造 = 列ごと独立）
    local layout_str
    layout_str=$(build_column_first_layout "$win_width" "$win_height" \
        "${pane_nums[@]}" "${heights[@]}")
    _tmux select-layout -t "$win_id" "$layout_str" 2>/dev/null

    # 定期デバッグログ（10回select-layoutごと）
    RESIZE_DEBUG_COUNTER=$((RESIZE_DEBUG_COUNTER + 1))
    if [ "$((RESIZE_DEBUG_COUNTER % 10))" -eq 0 ]; then
        log "dynamic_resize_by_content: scores=${scores_arr[*]} heights=${heights[*]}"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# 大殿裁可待ち表示 — lord_pending.yaml から awaiting_lord 案件を抽出・表示
# tmux ステータスバー（画面最下部）に "═══ 裁可待ち ═══" セクションを表示。
# 0件の場合はセクション自体を非表示にする。
# ═══════════════════════════════════════════════════════════════════════════════

# awaiting_lord 案件の "cmd_id<TAB>title（summary）" 行を返す（0件なら空）
get_lord_pending_items() {
    local yaml="$SCRIPT_DIR/queue/lord_pending.yaml"
    [ -f "$yaml" ] || return 0

    awk '
        /cmd_id:/  { cmd = $2; gsub(/["'"'"']/, "", cmd) }
        /title:/   {
            title = $0
            sub(/^[[:space:]]*title:[[:space:]"'"'"']*/, "", title)
            sub(/["'"'"'[:space:]]*$/, "", title)
        }
        /summary:/ {
            summary = $0
            sub(/^[[:space:]]*summary:[[:space:]"'"'"']*/, "", summary)
            sub(/["'"'"'[:space:]]*$/, "", summary)
        }
        /status:.*awaiting_lord/ {
            if (cmd != "") {
                out = cmd "\t" title
                if (summary != "") out = out "（" summary "）"
                print out
            }
            cmd = ""; title = ""; summary = ""
        }
    ' "$yaml" 2>/dev/null
}

# 裁可待ちセクションを tmux ステータスバー（最下部）に更新
# 0件なら status-right をクリアしてセクション非表示
update_lord_pending_display() {
    local session="$1"
    local items
    items=$(get_lord_pending_items)

    if [ -z "$items" ]; then
        _tmux set-option -t "$session" status-right "" 2>/dev/null
        return
    fi

    local display_str="#[fg=yellow,bold]═══ 裁可待ち ═══"
    while IFS=$'\t' read -r cmd_id rest; do
        [ -z "$cmd_id" ] && continue
        display_str+="#[fg=white,nobold] 📋 ${cmd_id} ${rest}"
    done <<< "$items"

    _tmux set-option -t "$session" status on 2>/dev/null
    _tmux set-option -t "$session" status-right "$display_str" 2>/dev/null
    log "lord_pending: $(echo "$items" | wc -l | tr -d ' ') item(s) displayed"
}

# ═══════════════════════════════════════════════════════════════════════════════
# メインループ
# ═══════════════════════════════════════════════════════════════════════════════
declare -A STYLED_PANES
PREV_PANE_COUNT=0
RECOVERY_CHECK_COUNTER=0
DEADLOCK_CHECK_COUNTER=0
TASK_UPDATE_COUNTER=0
LORD_PENDING_COUNTER=0
IDLE_INBOX_CHECK_COUNTER=0

# テストモード: __TEAMS_MONITOR_TESTING__=1 の場合は関数定義のみロードしてループを起動しない
[ "${__TEAMS_MONITOR_TESTING__:-}" = "1" ] && return 0 2>/dev/null || true

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
            _tmux set-option -p -t "$pane_id" @agent_name_ja "..." 2>/dev/null
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
        dynamic_resize_by_content "$local_session" 2>/dev/null || true
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

    # @current_task を task YAML から定期更新（5サイクルごと = 約15秒ごと）
    # ⏰ 滞留検知 + 📬 idle+inbox未読検知を含む
    TASK_UPDATE_COUNTER=$((TASK_UPDATE_COUNTER + 1))
    if [ "$TASK_UPDATE_COUNTER" -ge 5 ]; then
        update_current_tasks
        TASK_UPDATE_COUNTER=0
    fi

    # idle + inbox未読 自動 re-nudge（10サイクルごと = 約30秒ごと）
    IDLE_INBOX_CHECK_COUNTER=$((IDLE_INBOX_CHECK_COUNTER + 1))
    if [ "$IDLE_INBOX_CHECK_COUNTER" -ge 10 ]; then
        check_idle_inbox_unread "$local_session" 2>/dev/null || true
        IDLE_INBOX_CHECK_COUNTER=0
    fi

    # 大殿裁可待ち表示更新（10サイクルごと = 約30秒ごと）
    LORD_PENDING_COUNTER=$((LORD_PENDING_COUNTER + 1))
    if [ "$LORD_PENDING_COUNTER" -ge 10 ]; then
        update_lord_pending_display "$local_session" 2>/dev/null || true
        LORD_PENDING_COUNTER=0
    fi

    PREV_PANE_COUNT=$pane_count
done
