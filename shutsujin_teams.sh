#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# shutsujin_teams.sh — 独立プロセス版 出陣スクリプト（ビューワー別ウィンドウ付き）
# ═══════════════════════════════════════════════════════════════════════════════
# オリジナル版 shutsujin_departure.sh と同じ独立プロセスアーキテクチャ。
# 各エージェントが独立 Claude Code プロセスとして tmux ペインで動作。
# 通信は inbox_write.sh (YAML mailbox)、回復は inbox_watcher.sh。
# ビューワーは別 Terminal.app ウィンドウで自動表示。
#
# 使用方法:
#   ./shutsujin_teams.sh              # 独立プロセスモードで全軍を起動
#   ./shutsujin_teams.sh -c           # キューをリセットして起動（クリーンスタート）
#   ./shutsujin_teams.sh -k           # 決戦の陣（全足軽をOpusで起動）
#   ./shutsujin_teams.sh -s           # セットアップのみ（Claude起動なし）
#   ./shutsujin_teams.sh -S           # サイレントモード
#   ./shutsujin_teams.sh -h           # ヘルプ表示
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# 言語・シェル設定読み取り
# ═══════════════════════════════════════════════════════════════════════════════
LANG_SETTING="ja"
if [ -f "./config/settings.yaml" ]; then
    LANG_SETTING=$(grep "^language:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "ja")
fi

SHELL_SETTING="bash"
if [ -f "./config/settings.yaml" ]; then
    SHELL_SETTING=$(grep "^shell:" ./config/settings.yaml 2>/dev/null | awk '{print $2}' || echo "bash")
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Python venv プリフライトチェック
# ═══════════════════════════════════════════════════════════════════════════════
VENV_DIR="$SCRIPT_DIR/.venv"
if [ ! -f "$VENV_DIR/bin/python3" ] || ! "$VENV_DIR/bin/python3" -c "import yaml" 2>/dev/null; then
    echo -e "\033[1;33m【報】\033[0m Python venv をセットアップ中..."
    if command -v python3 &>/dev/null; then
        # 壊れた venv を削除してから再作成
        rm -rf "$VENV_DIR"
        # Dropbox対応: symlink が使えない場合は --copies + Homebrew Python にフォールバック
        python3 -m venv "$VENV_DIR" 2>/dev/null || \
        python3 -m venv --copies "$VENV_DIR" 2>/dev/null || \
        /opt/homebrew/bin/python3 -m venv --copies "$VENV_DIR" 2>/dev/null || \
        /opt/homebrew/bin/python3 -m venv "$VENV_DIR" 2>/dev/null || {
            echo -e "\033[1;31m【ERROR】\033[0m python3 -m venv に失敗しました。"
            exit 1
        }
        "$VENV_DIR/bin/pip" install -r "$SCRIPT_DIR/requirements.txt" -q 2>/dev/null || {
            echo -e "\033[1;31m【ERROR】\033[0m pip install に失敗しました。"
            exit 1
        }
        echo -e "\033[1;32m【成】\033[0m Python venv セットアップ完了"
    else
        echo -e "\033[1;31m【ERROR】\033[0m python3 が見つかりません。first_setup.sh を実行してください。"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# CLI Adapter読み込み（Multi-CLI Support）
# ═══════════════════════════════════════════════════════════════════════════════
if [ -f "$SCRIPT_DIR/lib/cli_adapter.sh" ]; then
    source "$SCRIPT_DIR/lib/cli_adapter.sh"
    CLI_ADAPTER_LOADED=true
else
    CLI_ADAPTER_LOADED=false
fi

# 足軽IDリストと人数を動的に取得
if [ "$CLI_ADAPTER_LOADED" = true ]; then
    _ASHIGARU_IDS_STR=$(get_ashigaru_ids)
else
    _ASHIGARU_IDS_STR="ashigaru1 ashigaru2 ashigaru3 ashigaru4 ashigaru5 ashigaru6 ashigaru7"
fi
_ASHIGARU_COUNT=$(echo "$_ASHIGARU_IDS_STR" | wc -w | tr -d ' ')

# ═══════════════════════════════════════════════════════════════════════════════
# 色付きログ関数（戦国風）
# ═══════════════════════════════════════════════════════════════════════════════
log_info() {
    echo -e "\033[1;33m【報】\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m【成】\033[0m $1"
}

log_war() {
    echo -e "\033[1;31m【戦】\033[0m $1"
}

# ═══════════════════════════════════════════════════════════════════════════════
# プロンプト生成関数（bash/zsh対応）
# ═══════════════════════════════════════════════════════════════════════════════
generate_prompt() {
    local label="$1"
    local color="$2"
    local shell_type="$3"

    if [ "$shell_type" == "zsh" ]; then
        echo "(%F{${color}}%B${label}%b%f) %F{green}%B%~%b%f%# "
    else
        local color_code
        case "$color" in
            red)     color_code="1;31" ;;
            green)   color_code="1;32" ;;
            yellow)  color_code="1;33" ;;
            blue)    color_code="1;34" ;;
            magenta) color_code="1;35" ;;
            cyan)    color_code="1;36" ;;
            *)       color_code="1;37" ;;
        esac
        echo "(\[\033[${color_code}m\]${label}\[\033[0m\]) \[\033[1;32m\]\w\[\033[0m\]\$ "
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# オプション解析
# ═══════════════════════════════════════════════════════════════════════════════
MODEL="opus"
SETUP_ONLY=false
CLEAN_MODE=false
KESSEN_MODE=false
SHOGUN_NO_THINKING=false
SILENT_MODE=false
SHELL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --dangerously-skip-permissions)
            # 常に有効（独立プロセスは全て --dangerously-skip-permissions で起動）
            shift
            ;;
        -c|--clean)
            CLEAN_MODE=true
            shift
            ;;
        -k|--kessen)
            KESSEN_MODE=true
            shift
            ;;
        -s|--setup-only)
            SETUP_ONLY=true
            shift
            ;;
        -S|--silent)
            SILENT_MODE=true
            shift
            ;;
        --shogun-no-thinking)
            SHOGUN_NO_THINKING=true
            shift
            ;;
        -shell|--shell)
            if [[ -n "$2" && "$2" != -* ]]; then
                SHELL_OVERRIDE="$2"
                shift 2
            else
                echo "エラー: -shell オプションには bash または zsh を指定してください"
                exit 1
            fi
            ;;
        -h|--help)
            echo ""
            echo "🏯 独立プロセス版 出陣スクリプト（ビューワー別ウィンドウ付き）"
            echo ""
            echo "使用方法: ./shutsujin_teams.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  -c, --clean         キューとダッシュボードをリセットして起動（クリーンスタート）"
            echo "                      未指定時は前回の状態を維持して起動"
            echo "  -k, --kessen        決戦の陣（全足軽をOpusで起動）"
            echo "                      未指定時は平時の陣（足軽1-7=Sonnet, 軍師=Opus）"
            echo "  -s, --setup-only    セットアップのみ（Claude起動なし）"
            echo "  -S, --silent        サイレントモード（echo表示なし・API節約）"
            echo "  --model MODEL       将軍のモデル指定（デフォルト: opus）"
            echo "  --shogun-no-thinking  将軍のthinkingを無効化（中継特化）"
            echo "  --dangerously-skip-permissions  権限チェックスキップ"
            echo "  -shell, --shell SH  シェルを指定（bash または zsh）"
            echo "  -h, --help          このヘルプを表示"
            echo ""
            echo "仕組み（独立プロセス + mailbox）:"
            echo "  1. shogun-teams セッション（将軍1名）を作成"
            echo "  2. multiagent-teams セッション（3×3 = 9ペイン）を作成"
            echo "  3. 各ペインで独立 Claude Code プロセスを起動"
            echo "  4. 通信は inbox_write.sh（YAML mailbox）"
            echo "  5. 回復は inbox_watcher.sh（3段階エスカレーション）"
            echo "  6. ビューワーは別ウィンドウで自動表示（iTerm2優先、Terminal.appフォールバック）"
            echo ""
            echo "陣形:"
            echo "  平時の陣（デフォルト）: 足軽1-7=Sonnet, 軍師=Opus"
            echo "  決戦の陣（--kessen）:   全足軽=Opus, 軍師=Opus"
            echo ""
            echo "例:"
            echo "  ./shutsujin_teams.sh              # 前回の状態を維持して出陣"
            echo "  ./shutsujin_teams.sh -c           # クリーンスタート（キューリセット）"
            echo "  ./shutsujin_teams.sh -s           # セットアップのみ（手動でClaude起動）"
            echo "  ./shutsujin_teams.sh -k           # 決戦の陣（全足軽Opus）"
            echo "  ./shutsujin_teams.sh -c -k        # クリーンスタート＋決戦の陣"
            echo "  ./shutsujin_teams.sh -shell bash  # bash用プロンプトで起動"
            echo "  ./shutsujin_teams.sh -S           # サイレントモード（echo表示なし）"
            echo "  ./shutsujin_teams.sh --model sonnet  # 将軍をSonnetで起動"
            echo "  ./shutsujin_teams.sh --shogun-no-thinking  # 将軍のthinkingを無効化（中継特化）"
            echo ""
            echo "モデル構成:"
            echo "  将軍:      Opus（デフォルト。--model で変更可）"
            echo "  家老:      Sonnet（高速タスク管理）"
            echo "  軍師:      Opus（戦略立案・設計判断）"
            echo "  足軽1-7:   Sonnet（実働部隊）"
            echo ""
            echo "表示モード:"
            echo "  shout（デフォルト）:  タスク完了時に戦国風echo表示"
            echo "  silent（--silent）:   echo表示なし（API節約）"
            echo ""
            echo "エイリアス:"
            echo "  csst → cd ~/multi-agent-shogun && ./shutsujin_teams.sh"
            echo ""
            exit 0
            ;;
        *)
            echo "不明なオプション: $1"
            echo "./shutsujin_teams.sh -h でヘルプを表示"
            exit 1
            ;;
    esac
done

# シェル設定のオーバーライド
if [ -n "$SHELL_OVERRIDE" ]; then
    if [[ "$SHELL_OVERRIDE" == "bash" || "$SHELL_OVERRIDE" == "zsh" ]]; then
        SHELL_SETTING="$SHELL_OVERRIDE"
    else
        echo "エラー: -shell オプションには bash または zsh を指定してください（指定値: $SHELL_OVERRIDE）"
        exit 1
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# 出陣バナー表示
# ═══════════════════════════════════════════════════════════════════════════════
# 【著作権・ライセンス表示】
# 忍者ASCIIアート: syntax-samurai/ryu - CC0 1.0 Universal (Public Domain)
# 出典: https://github.com/syntax-samurai/ryu
show_battle_cry() {
    clear

    echo ""
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗██╗  ██╗██╗   ██╗████████╗███████╗██╗   ██╗     ██╗██╗███╗   ██╗\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔════╝██║  ██║██║   ██║╚══██╔══╝██╔════╝██║   ██║     ██║██║████╗  ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗███████║██║   ██║   ██║   ███████╗██║   ██║     ██║██║██╔██╗ ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚════██║██╔══██║██║   ██║   ██║   ╚════██║██║   ██║██   ██║██║██║╚██╗██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████║██║  ██║╚██████╔╝   ██║   ███████║╚██████╔╝╚█████╔╝██║██║ ╚████║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝  ╚════╝ ╚═╝╚═╝  ╚═══╝\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m    \033[1;37m出陣じゃーーー！！！\033[0m    \033[1;36m⚔\033[0m    \033[1;35m天下布武！ — 独立プロセス版\033[0m              \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    echo -e "\033[1;34m  ╔══════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m  ║\033[0m                \033[1;37m【 足 軽 隊 列 ・ 七 名 + 軍 師 配 備 】\033[0m                  \033[1;34m║\033[0m"
    echo -e "\033[1;34m  ╚══════════════════════════════════════════════════════════════════════════╝\033[0m"

    cat << 'ASHIGARU_EOF'

       /\      /\      /\      /\      /\      /\      /\      /\
      /||\    /||\    /||\    /||\    /||\    /||\    /||\    /||\
     /_||\   /_||\   /_||\   /_||\   /_||\   /_||\   /_||\   /_||\
       ||      ||      ||      ||      ||      ||      ||      ||
      /||\    /||\    /||\    /||\    /||\    /||\    /||\    /||\
      /  \    /  \    /  \    /  \    /  \    /  \    /  \    /  \
     [足1]   [足2]   [足3]   [足4]   [足5]   [足6]   [足7]   [軍師]

ASHIGARU_EOF

    echo -e "                    \033[1;36m「「「 はっ！！ 出陣いたす！！ 」」」\033[0m"
    echo ""

    echo -e "\033[1;33m  ┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37m🏯 multi-agent-shogun\033[0m  〜 \033[1;36m独立プロセス版\033[0m 〜                              \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;35m将軍\033[0m: 統括  \033[1;31m家老\033[0m: 管理  \033[1;33m軍師\033[0m: 戦略(Opus)  \033[1;34m足軽\033[0m: 実働×${_ASHIGARU_COUNT}                   \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  通信: inbox_write.sh (mailbox)  回復: inbox_watcher.sh                   \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# バナー表示実行
show_battle_cry

echo -e "  \033[1;33m天下布武！陣立てを開始いたす\033[0m (Setting up the battlefield — Independent Processes)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: 既存セッションクリーンアップ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🧹 既存の陣を撤収中..."
# 独立プロセス版: shogun-teams + multiagent-teams セッション + inbox_watcher を撤収
tmux kill-session -t shogun-teams 2>/dev/null && log_info "  └─ shogun-teams陣、撤収完了" || log_info "  └─ shogun-teams陣は存在せず"
tmux kill-session -t multiagent-teams 2>/dev/null && log_info "  └─ multiagent-teams陣、撤収完了" || log_info "  └─ multiagent-teams陣は存在せず"
pkill -f "inbox_watcher.sh" 2>/dev/null && log_info "  └─ inbox_watcher撤収完了" || true
pkill -f "teams_visual_monitor.sh" 2>/dev/null && log_info "  └─ visual_monitor撤収完了" || true
pkill -f "inotifywait.*queue/inbox" 2>/dev/null || true
pkill -f "fswatch.*queue/inbox" 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1.5: 前回記録のバックアップ（--clean時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    BACKUP_DIR="./logs/backup_$(date '+%Y%m%d_%H%M%S')"
    NEED_BACKUP=false

    if [ -f "./dashboard.md" ]; then
        if grep -q "cmd_" "./dashboard.md" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    if [ -f "./queue/shogun_to_karo.yaml" ]; then
        if grep -q "id: cmd_" "./queue/shogun_to_karo.yaml" 2>/dev/null; then
            NEED_BACKUP=true
        fi
    fi

    if [ "$NEED_BACKUP" = true ]; then
        mkdir -p "$BACKUP_DIR" || true
        cp "./dashboard.md" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/reports" "$BACKUP_DIR/" 2>/dev/null || true
        cp -r "./queue/tasks" "$BACKUP_DIR/" 2>/dev/null || true
        cp "./queue/shogun_to_karo.yaml" "$BACKUP_DIR/" 2>/dev/null || true
        log_info "📦 前回の記録をバックアップ: $BACKUP_DIR"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: キューディレクトリ確保 + リセット（--clean時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
[ -d ./queue/reports ] || mkdir -p ./queue/reports
[ -d ./queue/tasks ] || mkdir -p ./queue/tasks
# 独立プロセス版: inboxディレクトリはmailbox通信に必須
[ -d ./queue/inbox ] || mkdir -p ./queue/inbox

if [ "$CLEAN_MODE" = true ]; then
    log_info "📜 前回の軍議記録を破棄中..."

    # 足軽タスクファイルリセット
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        cat > ./queue/tasks/ashigaru${i}.yaml << EOF
# 足軽${i}専用タスクファイル
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF
    done

    # 軍師タスクファイルリセット
    cat > ./queue/tasks/gunshi.yaml << EOF
# 軍師専用タスクファイル
task:
  task_id: null
  parent_cmd: null
  description: null
  target_path: null
  status: idle
  timestamp: ""
EOF

    # 足軽レポートファイルリセット
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        cat > ./queue/reports/ashigaru${i}_report.yaml << EOF
worker_id: ashigaru${i}
task_id: null
timestamp: ""
status: idle
result: null
EOF
    done

    # 軍師レポートファイルリセット
    cat > ./queue/reports/gunshi_report.yaml << EOF
worker_id: gunshi
task_id: null
timestamp: ""
status: idle
result: null
EOF

    # ntfy inbox リセット
    echo "inbox:" > ./queue/ntfy_inbox.yaml

    # agent inbox リセット（互換性維持）
    for agent in shogun karo $_ASHIGARU_IDS_STR gunshi; do
        echo "messages:" > "./queue/inbox/${agent}.yaml"
    done

    log_success "✅ 陣払い完了"
else
    log_info "📜 前回の陣容を維持して出陣..."
    log_success "✅ キュー・報告ファイルはそのまま継続"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: ダッシュボード初期化（--clean時のみ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$CLEAN_MODE" = true ]; then
    log_info "📊 戦況報告板を初期化中..."

    # update_dashboard.sh があれば使う、なければ直接生成
    if [ -f "$SCRIPT_DIR/scripts/update_dashboard.sh" ]; then
        bash "$SCRIPT_DIR/scripts/update_dashboard.sh" --init
    else
        TIMESTAMP=$(date "+%Y-%m-%d %H:%M")

        if [ "$LANG_SETTING" = "ja" ]; then
            # 日本語のみ
            cat > ./dashboard.md << EOF
# 📊 戦況報告
最終更新: ${TIMESTAMP}

## 🚨 要対応 - 殿のご判断をお待ちしております
なし

## 🔄 進行中 - 只今、戦闘中でござる
なし

## ✅ 本日の戦果
| 時刻 | 戦場 | 任務 | 結果 |
|------|------|------|------|

## 🎯 スキル化候補 - 承認待ち
なし

## 🛠️ 生成されたスキル
なし

## ⏸️ 待機中
なし

## ❓ 伺い事項
なし
EOF
        else
            # 日本語 + 翻訳併記
            cat > ./dashboard.md << EOF
# 📊 戦況報告 (Battle Status Report)
最終更新 (Last Updated): ${TIMESTAMP}

## 🚨 要対応 - 殿のご判断をお待ちしております (Action Required - Awaiting Lord's Decision)
なし (None)

## 🔄 進行中 - 只今、戦闘中でござる (In Progress - Currently in Battle)
なし (None)

## ✅ 本日の戦果 (Today's Achievements)
| 時刻 (Time) | 戦場 (Battlefield) | 任務 (Mission) | 結果 (Result) |
|------|------|------|------|

## 🎯 スキル化候補 - 承認待ち (Skill Candidates - Pending Approval)
なし (None)

## 🛠️ 生成されたスキル (Generated Skills)
なし (None)

## ⏸️ 待機中 (On Standby)
なし (None)

## ❓ 伺い事項 (Questions for Lord)
なし (None)
EOF
        fi
    fi

    log_success "  └─ ダッシュボード初期化完了 (言語: $LANG_SETTING, シェル: $SHELL_SETTING)"
else
    log_info "📊 前回のダッシュボードを維持"
fi
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: tmux の存在確認
# ═══════════════════════════════════════════════════════════════════════════════
if ! command -v tmux &> /dev/null; then
    echo ""
    echo "  ╔════════════════════════════════════════════════════════╗"
    echo "  ║  [ERROR] tmux not found!                               ║"
    echo "  ║  tmux が見つかりません                                 ║"
    echo "  ╠════════════════════════════════════════════════════════╣"
    echo "  ║  Run first_setup.sh first:                             ║"
    echo "  ║     ./first_setup.sh                                   ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: 環境変数
# ═══════════════════════════════════════════════════════════════════════════════
# 独立プロセス版: Agent Teams は使用しない（デッドロック回避）
# export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1  ← 廃止
export SHOGUN_ROOT="$SCRIPT_DIR"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5.5: ntfy_inbox 古メッセージ退避（7日より前のprocessed分をアーカイブ）
# ═══════════════════════════════════════════════════════════════════════════════
if [ -f ./queue/ntfy_inbox.yaml ]; then
    _archive_result=$("$VENV_DIR/bin/python3" -c "
import yaml, sys
from datetime import datetime, timedelta, timezone

INBOX = './queue/ntfy_inbox.yaml'
ARCHIVE = './queue/ntfy_inbox_archive.yaml'
DAYS = 7

with open(INBOX) as f:
    data = yaml.safe_load(f) or {}

entries = data.get('inbox', []) or []
if not entries:
    sys.exit(0)

cutoff = datetime.now(timezone(timedelta(hours=9))) - timedelta(days=DAYS)
recent, old = [], []

for e in entries:
    ts = e.get('timestamp', '')
    try:
        dt = datetime.fromisoformat(str(ts))
        if dt < cutoff and e.get('status') == 'processed':
            old.append(e)
        else:
            recent.append(e)
    except Exception:
        recent.append(e)

if not old:
    sys.exit(0)

try:
    with open(ARCHIVE) as f:
        archive = yaml.safe_load(f) or {}
except FileNotFoundError:
    archive = {}
archive_entries = archive.get('inbox', []) or []
archive_entries.extend(old)
with open(ARCHIVE, 'w') as f:
    yaml.dump({'inbox': archive_entries}, f, allow_unicode=True, default_flow_style=False)

with open(INBOX, 'w') as f:
    yaml.dump({'inbox': recent}, f, allow_unicode=True, default_flow_style=False)

print(f'{len(old)}件退避 {len(recent)}件保持')
" 2>/dev/null) || true
    if [ -n "$_archive_result" ]; then
        log_info "📱 ntfy_inbox整理: $_archive_result → ntfy_inbox_archive.yaml"
    fi
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 6: tmux セッション構築 + Claude Code 起動（独立プロセスモード）
# ═══════════════════════════════════════════════════════════════════════════════
if [ "$SETUP_ONLY" = false ]; then
    # CLI の存在チェック
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _default_cli=$(get_cli_type "")
        if ! validate_cli_availability "$_default_cli"; then
            exit 1
        fi
    else
        if ! command -v npx &> /dev/null && ! command -v claude &> /dev/null; then
            log_info "⚠️  claude / npx コマンドが見つかりません"
            echo "  first_setup.sh を再実行してください"
            exit 1
        fi
    fi

    # --shogun-no-thinking 処理
    if [ "$SHOGUN_NO_THINKING" = true ] && [ "$CLI_ADAPTER_LOADED" = true ]; then
        "$CLI_ADAPTER_PROJECT_ROOT/.venv/bin/python3" -c "
import yaml
f = '${CLI_ADAPTER_SETTINGS}'
with open(f) as fh: d = yaml.safe_load(fh) or {}
d.setdefault('cli',{}).setdefault('agents',{}).setdefault('shogun',{})['thinking'] = False
with open(f,'w') as fh: yaml.safe_dump(d, fh, default_flow_style=False, allow_unicode=True, sort_keys=False)
" 2>/dev/null
        log_info "  └─ 将軍 settings.yaml thinking=false に設定"
    fi

    # DISPLAY_MODE 環境変数
    if [ "$SILENT_MODE" = true ]; then
        export DISPLAY_MODE="silent"
        log_info "📢 表示モード: サイレント（echo表示なし）"
    else
        export DISPLAY_MODE="shout"
    fi

    # KESSEN_MODE 環境変数（決戦の陣）
    if [ "$KESSEN_MODE" = true ]; then
        export KESSEN_MODE=true
    fi

    # 忍者アスキーアート（CC0 Public Domain）
    echo -e "\033[1;35m  ┌────────────────────────────────────────────────────────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;35m  │\033[0m                              \033[1;37m【 忍 者 戦 士 】\033[0m  Ryu Hayabusa (CC0 Public Domain)                        \033[1;35m│\033[0m"
    echo -e "\033[1;35m  └────────────────────────────────────────────────────────────────────────────────────────────────────────────┘\033[0m"

    cat << 'NINJA_EOF'
...................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒                        ...................................
..................................░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒░░░░░░░░▒▒▒▒▒▒                         ...................................
NINJA_EOF

    echo ""
    echo -e "                                    \033[1;35m「 天下布武！勝利を掴め！ 」\033[0m"
    echo ""
    echo -e "                               \033[0;36m[ASCII Art: syntax-samurai/ryu - CC0 1.0 Public Domain]\033[0m"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.1: shogun-teams セッション作成（将軍の本陣）
    # ═══════════════════════════════════════════════════════════════════════════
    log_war "👑 将軍の本陣を構築中..."

    # pane-base-index を取得（1 の環境ではペインは 1,2,... になる）
    PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)

    if ! tmux has-session -t shogun-teams 2>/dev/null; then
        tmux new-session -d -s shogun-teams -n main
    fi

    # ユーザーの .tmux.conf を反映（bg=#ffffff 等）
    tmux source-file ~/.tmux.conf 2>/dev/null || true

    # スマホ等の小画面クライアント対策
    tmux set-option -g window-size latest
    tmux set-option -g aggressive-resize on

    SHOGUN_PROMPT=$(generate_prompt "将軍" "magenta" "$SHELL_SETTING")
    tmux send-keys -t "shogun-teams:main" "cd \"$(pwd)\" && export PS1='${SHOGUN_PROMPT}' && clear" Enter
    tmux set-option -p -t "shogun-teams:main" @agent_id "shogun"

    log_success "  └─ 将軍の本陣、構築完了"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.2: multiagent-teams セッション作成（家老大 + 2×4 = 9ペイン）
    # ═══════════════════════════════════════════════════════════════════════════
    log_war "⚔️ 家老・足軽・軍師の陣を構築中（$((${_ASHIGARU_COUNT} + 2))名配備）..."

    if ! tmux new-session -d -s multiagent-teams -n "agents" -x 200 -y 60 2>/dev/null; then
        echo ""
        echo "  ╔════════════════════════════════════════════════════════════╗"
        echo "  ║  [ERROR] Failed to create tmux session 'multiagent-teams'  ║"
        echo "  ║  tmux セッション 'multiagent-teams' の作成に失敗           ║"
        echo "  ╠════════════════════════════════════════════════════════════╣"
        echo "  ║  既存セッションが残っている可能性があります                ║"
        echo "  ║  Check: tmux ls                                            ║"
        echo "  ║  Kill:  tmux kill-session -t multiagent-teams              ║"
        echo "  ╚════════════════════════════════════════════════════════════╝"
        echo ""
        exit 1
    fi

    # ウィンドウリサイズ対応: ビューワー(attach)のサイズに自動追従
    tmux set-option -t multiagent-teams -w aggressive-resize on

    # DISPLAY_MODE を tmux 環境変数にセット
    if [ "$SILENT_MODE" = true ]; then
        tmux set-environment -t multiagent-teams DISPLAY_MODE "silent"
        log_info "📢 表示モード: サイレント（echo表示なし）"
    else
        tmux set-environment -t multiagent-teams DISPLAY_MODE "shout"
    fi

    # KESSEN_MODE も tmux 環境変数にセット
    if [ "$KESSEN_MODE" = true ]; then
        tmux set-environment -t multiagent-teams KESSEN_MODE "true"
    fi

    # 家老大ペイン + 2×4グリッド（合計9ペイン）
    # ┌──────────┬──────┬──────┐
    # │          │  A1  │  A2  │
    # │          ├──────┼──────┤
    # │   家老   │  A3  │  A6  │
    # │  (1/3幅  ├──────┼──────┤
    # │  全高)   │  A4  │  A7  │
    # │          ├──────┼──────┤
    # │          │  A5  │ 軍師 │
    # └──────────┴──────┴──────┘

    # Step 1: 家老(左33%) と エージェント領域(右67%) に分割
    tmux split-window -h -p 67 -t "multiagent-teams:agents"

    # Step 2: エージェント領域を2列に分割
    tmux split-window -h -t "multiagent-teams:agents.$((PANE_BASE+1))"

    # Step 3: 中央列を4等分（足軽1,3,4,5）
    tmux select-pane -t "multiagent-teams:agents.$((PANE_BASE+1))"
    tmux split-window -v -p 75
    tmux split-window -v -p 67
    tmux split-window -v

    # Step 4: 右列を4等分（足軽2,6,7,軍師）
    tmux select-pane -t "multiagent-teams:agents.$((PANE_BASE+2))"
    tmux split-window -v -p 75
    tmux split-window -v -p 67
    tmux split-window -v

    # ペインラベル・エージェントID設定 — settings.yaml から動的に構築
    PANE_LABELS=("karo")
    AGENT_IDS=("karo")
    PANE_COLORS=("red")
    for _ai in $_ASHIGARU_IDS_STR; do
        PANE_LABELS+=("$_ai")
        AGENT_IDS+=("$_ai")
        PANE_COLORS+=("blue")
    done
    PANE_LABELS+=("gunshi")
    AGENT_IDS+=("gunshi")
    PANE_COLORS+=("yellow")

    # モデル名設定（pane-border-format で常時表示）
    MODEL_NAMES=()
    for _ai in "${AGENT_IDS[@]}"; do
        if [[ "$_ai" == "gunshi" ]]; then
            MODEL_NAMES+=("Opus")
        elif [ "$KESSEN_MODE" = true ]; then
            MODEL_NAMES+=("Opus")
        else
            MODEL_NAMES+=("Sonnet")
        fi
    done

    # CLI Adapter 経由でモデル表示名を統一形式で設定
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        for i in "${!AGENT_IDS[@]}"; do
            _agent="${AGENT_IDS[$i]}"
            MODEL_NAMES[$i]=$(get_model_display_name "$_agent")
        done
    fi

    for i in "${!AGENT_IDS[@]}"; do
        p=$((PANE_BASE + i))
        tmux select-pane -t "multiagent-teams:agents.${p}" -T "${MODEL_NAMES[$i]}"
        tmux set-option -p -t "multiagent-teams:agents.${p}" @agent_id "${AGENT_IDS[$i]}"
        tmux set-option -p -t "multiagent-teams:agents.${p}" @model_name "${MODEL_NAMES[$i]}"
        tmux set-option -p -t "multiagent-teams:agents.${p}" @current_task ""
        PROMPT_STR=$(generate_prompt "${PANE_LABELS[$i]}" "${PANE_COLORS[$i]}" "$SHELL_SETTING")
        tmux send-keys -t "multiagent-teams:agents.${p}" "cd \"$(pwd)\" && export PS1='${PROMPT_STR}' && clear" Enter
    done

    # pane-border-format でモデル名を常時表示
    tmux set-option -t multiagent-teams -w pane-border-status top
    tmux set-option -t multiagent-teams -w pane-border-format \
      '#{?pane_active,#[reverse],}#[bold]#{@agent_id}#[default] (#{@model_name}) #{@current_task}'

    # 家老ペインを選択状態にしておく（ビューワーで見やすいように）
    tmux select-pane -t "multiagent-teams:agents.${PANE_BASE}"

    log_success "  └─ 家老・足軽・軍師の陣、構築完了"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.3: 全軍に Claude Code を召喚（独立プロセス）
    # ═══════════════════════════════════════════════════════════════════════════
    log_war "👑 全軍に Claude Code を召喚中..."

    # Agent Teams 環境変数を無効化（.zshrc / launchctl 由来の残留を除去）
    # これがないと Claude Code が Agent Teams モードで起動し、mailbox ではなく
    # 内蔵 teammate を spawn してしまい、独立プロセスが使われない
    tmux send-keys -t "shogun-teams:main" "unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" Enter
    for _p in $(seq "$PANE_BASE" "$((PANE_BASE + _ASHIGARU_COUNT + 1))"); do
        tmux send-keys -t "multiagent-teams:agents.${_p}" "unset CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" Enter
    done
    sleep 0.5

    # 将軍: CLI Adapter 経由でコマンド構築
    _shogun_cli_type="claude"
    _shogun_cmd="claude --model ${MODEL} --dangerously-skip-permissions"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _shogun_cli_type=$(get_cli_type "shogun")
        _shogun_cmd=$(build_cli_command "shogun")
    fi
    if [ "$SHOGUN_NO_THINKING" = true ] && [ "$CLI_ADAPTER_LOADED" = true ]; then
        _shogun_cmd=$(build_cli_command "shogun")
    fi
    tmux set-option -p -t "shogun-teams:main" @agent_cli "$_shogun_cli_type"
    tmux send-keys -t "shogun-teams:main" "$_shogun_cmd"
    tmux send-keys -t "shogun-teams:main" Enter
    _shogun_display=$(get_model_display_name "shogun" 2>/dev/null || echo "Opus")
    tmux set-option -p -t "shogun-teams:main" @model_name "$_shogun_display" 2>/dev/null || true
    log_info "  └─ 将軍（${_shogun_cli_type} / ${_shogun_display}）、召喚完了"

    sleep 1

    # 家老（pane 0）
    p=$((PANE_BASE + 0))
    _karo_cli_type="claude"
    _karo_cmd="claude --model opus --dangerously-skip-permissions"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _karo_cli_type=$(get_cli_type "karo")
        _karo_cmd=$(build_cli_command "karo")
    fi
    _startup_prompt=$(get_startup_prompt "karo" 2>/dev/null)
    if [[ -n "$_startup_prompt" ]]; then
        _karo_cmd="$_karo_cmd \"$_startup_prompt\""
    fi
    tmux set-option -p -t "multiagent-teams:agents.${p}" @agent_cli "$_karo_cli_type"
    tmux send-keys -t "multiagent-teams:agents.${p}" "$_karo_cmd"
    tmux send-keys -t "multiagent-teams:agents.${p}" Enter
    _karo_display=$(get_model_display_name "karo" 2>/dev/null || echo "Opus")
    tmux set-option -p -t "multiagent-teams:agents.${p}" @model_name "$_karo_display" 2>/dev/null || true
    log_info "  └─ 家老（${_karo_display}）、召喚完了"

    # 足軽
    if [ "$KESSEN_MODE" = true ]; then
        for i in $(seq 1 "$_ASHIGARU_COUNT"); do
            p=$((PANE_BASE + i))
            _ashi_cli_type="claude"
            _ashi_cmd="claude --model opus --dangerously-skip-permissions"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _ashi_cli_type=$(get_cli_type "ashigaru${i}")
                if [ "$_ashi_cli_type" = "claude" ]; then
                    _ashi_cmd="claude --model opus --dangerously-skip-permissions"
                else
                    _ashi_cmd=$(build_cli_command "ashigaru${i}")
                fi
            fi
            _startup_prompt=$(get_startup_prompt "ashigaru${i}" 2>/dev/null)
            if [[ -n "$_startup_prompt" ]]; then
                _ashi_cmd="$_ashi_cmd \"$_startup_prompt\""
            fi
            tmux set-option -p -t "multiagent-teams:agents.${p}" @agent_cli "$_ashi_cli_type"
            tmux send-keys -t "multiagent-teams:agents.${p}" "$_ashi_cmd"
            tmux send-keys -t "multiagent-teams:agents.${p}" Enter
        done
        log_info "  └─ 足軽1-${_ASHIGARU_COUNT}（決戦の陣）、召喚完了"
    else
        for i in $(seq 1 "$_ASHIGARU_COUNT"); do
            p=$((PANE_BASE + i))
            _ashi_cli_type="claude"
            _ashi_cmd="claude --model sonnet --dangerously-skip-permissions"
            if [ "$CLI_ADAPTER_LOADED" = true ]; then
                _ashi_cli_type=$(get_cli_type "ashigaru${i}")
                _ashi_cmd=$(build_cli_command "ashigaru${i}")
            fi
            _startup_prompt=$(get_startup_prompt "ashigaru${i}" 2>/dev/null)
            if [[ -n "$_startup_prompt" ]]; then
                _ashi_cmd="$_ashi_cmd \"$_startup_prompt\""
            fi
            tmux set-option -p -t "multiagent-teams:agents.${p}" @agent_cli "$_ashi_cli_type"
            tmux send-keys -t "multiagent-teams:agents.${p}" "$_ashi_cmd"
            tmux send-keys -t "multiagent-teams:agents.${p}" Enter
        done
        log_info "  └─ 足軽1-${_ASHIGARU_COUNT}（平時の陣）、召喚完了"
    fi

    # 軍師（最終ペイン）
    p=$((PANE_BASE + _ASHIGARU_COUNT + 1))
    _gunshi_cli_type="claude"
    _gunshi_cmd="claude --model opus --dangerously-skip-permissions"
    if [ "$CLI_ADAPTER_LOADED" = true ]; then
        _gunshi_cli_type=$(get_cli_type "gunshi")
        _gunshi_cmd=$(build_cli_command "gunshi")
    fi
    _startup_prompt=$(get_startup_prompt "gunshi" 2>/dev/null)
    if [[ -n "$_startup_prompt" ]]; then
        _gunshi_cmd="$_gunshi_cmd \"$_startup_prompt\""
    fi
    tmux set-option -p -t "multiagent-teams:agents.${p}" @agent_cli "$_gunshi_cli_type"
    tmux send-keys -t "multiagent-teams:agents.${p}" "$_gunshi_cmd"
    tmux send-keys -t "multiagent-teams:agents.${p}" Enter
    _gunshi_display=$(get_model_display_name "gunshi" 2>/dev/null || echo "Opus+T")
    tmux set-option -p -t "multiagent-teams:agents.${p}" @model_name "$_gunshi_display" 2>/dev/null || true
    log_info "  └─ 軍師（${_gunshi_display}）、召喚完了"

    if [ "$KESSEN_MODE" = true ]; then
        log_success "✅ 決戦の陣で出陣！全軍Opus！"
    else
        log_success "✅ 平時の陣で出陣（将軍=Opus, 家老=Opus, 足軽=Sonnet, 軍師=Opus）"
    fi
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.4: 指示書読み込み（各エージェントが自律実行）
    # ═══════════════════════════════════════════════════════════════════════════
    log_info "📜 指示書読み込みは各エージェントが自律実行（CLAUDE.md Session Start）"
    echo ""

    # 将軍の起動を確認（最大30秒待機）
    echo "  Claude Code の起動を待機中（最大30秒）..."
    for _wait_i in {1..30}; do
        if tmux capture-pane -t "shogun-teams:main" -p | grep -q "bypass permissions"; then
            echo "  └─ 将軍の Claude Code 起動確認完了（${_wait_i}秒）"
            break
        fi
        sleep 1
    done

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.5: inbox_watcher 起動（全エージェント）
    # ═══════════════════════════════════════════════════════════════════════════
    log_info "📬 メールボックス監視を起動中..."
    mkdir -p "$SCRIPT_DIR/logs"

    # inbox ディレクトリ初期化
    for agent in shogun karo $_ASHIGARU_IDS_STR gunshi; do
        [ -f "$SCRIPT_DIR/queue/inbox/${agent}.yaml" ] || echo "messages:" > "$SCRIPT_DIR/queue/inbox/${agent}.yaml"
    done

    # 将軍のwatcher（ntfy受信の自動起床に必要）
    _shogun_watcher_cli=$(tmux show-options -p -t "shogun-teams:main" -v @agent_cli 2>/dev/null || echo "claude")
    nohup env ASW_DISABLE_ESCALATION=1 ASW_PROCESS_TIMEOUT=0 ASW_DISABLE_NORMAL_NUDGE=0 \
        bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" shogun "shogun-teams:main" "$_shogun_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_shogun.log" 2>&1 &
    disown

    # 家老のwatcher
    _karo_watcher_cli=$(tmux show-options -p -t "multiagent-teams:agents.${PANE_BASE}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" karo "multiagent-teams:agents.${PANE_BASE}" "$_karo_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_karo.log" 2>&1 &
    disown

    # 足軽のwatcher
    for i in $(seq 1 "$_ASHIGARU_COUNT"); do
        p=$((PANE_BASE + i))
        _ashi_watcher_cli=$(tmux show-options -p -t "multiagent-teams:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
        nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "ashigaru${i}" "multiagent-teams:agents.${p}" "$_ashi_watcher_cli" \
            >> "$SCRIPT_DIR/logs/inbox_watcher_ashigaru${i}.log" 2>&1 &
        disown
    done

    # 軍師のwatcher
    p=$((PANE_BASE + _ASHIGARU_COUNT + 1))
    _gunshi_watcher_cli=$(tmux show-options -p -t "multiagent-teams:agents.${p}" -v @agent_cli 2>/dev/null || echo "claude")
    nohup bash "$SCRIPT_DIR/scripts/inbox_watcher.sh" "gunshi" "multiagent-teams:agents.${p}" "$_gunshi_watcher_cli" \
        >> "$SCRIPT_DIR/logs/inbox_watcher_gunshi.log" 2>&1 &
    disown

    log_success "  └─ $((_ASHIGARU_COUNT + 3))エージェント分のinbox_watcher起動完了（将軍+家老+足軽${_ASHIGARU_COUNT}+軍師）"
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 6.6: ntfy 入力リスナー起動
    # ═══════════════════════════════════════════════════════════════════════════
    NTFY_TOPIC=$(grep 'ntfy_topic:' ./config/settings.yaml 2>/dev/null | awk '{print $2}' | tr -d '"')
    if [ -n "$NTFY_TOPIC" ]; then
        pkill -f "ntfy_listener.sh" 2>/dev/null || true
        [ ! -f ./queue/ntfy_inbox.yaml ] && echo "inbox:" > ./queue/ntfy_inbox.yaml
        nohup bash "$SCRIPT_DIR/scripts/ntfy_listener.sh" &>/dev/null &
        disown
        log_info "📱 ntfy入力リスナー起動 (topic: $NTFY_TOPIC)"
    else
        log_info "📱 ntfy未設定のためリスナーはスキップ"
    fi
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # STEP 7: 環境確認・ビューワー起動・完了メッセージ
    # ═══════════════════════════════════════════════════════════════════════════
    log_info "🔍 陣容を確認中..."
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  📺 Tmux陣容 (Sessions)                                  │"
    echo "  └──────────────────────────────────────────────────────────┘"
    tmux list-sessions | sed 's/^/     /'
    echo ""
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  📋 布陣図 (Formation)                                   │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""
    echo "     【shogun-teamsセッション】将軍の本陣"
    echo "     ┌─────────────────────────────┐"
    echo "     │  Pane 0: 将軍 (SHOGUN)      │  ← 総大将・プロジェクト統括"
    echo "     └─────────────────────────────┘"
    echo ""
    echo "     【multiagent-teamsセッション】家老・足軽・軍師の陣（3x3 = 9ペイン）"
    echo "     ┌─────────┬─────────┬─────────┐"
    echo "     │  karo   │ashigaru3│ashigaru6│"
    echo "     │  (家老) │ (足軽3) │ (足軽6) │"
    echo "     ├─────────┼─────────┼─────────┤"
    echo "     │ashigaru1│ashigaru4│ashigaru7│"
    echo "     │ (足軽1) │ (足軽4) │ (足軽7) │"
    echo "     ├─────────┼─────────┼─────────┤"
    echo "     │ashigaru2│ashigaru5│ gunshi  │"
    echo "     │ (足軽2) │ (足軽5) │ (軍師)  │"
    echo "     └─────────┴─────────┴─────────┘"
    echo ""

    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🏯 出陣準備完了！天下布武！                             ║"
    echo "  ║  独立プロセス + mailbox + inbox_watcher で統率           ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""

    # ─── 別ウィンドウでビューワーを起動 ───
    log_info "🖥️  ビューワーウィンドウを起動中..."
    _viewer_opened=false

    # iTerm2 が利用可能なら優先使用
    if [ -d "/Applications/iTerm.app" ] || pgrep -x "iTerm2" >/dev/null 2>&1; then
        osascript -e "
            tell application \"iTerm\"
                create window with default profile command \"tmux attach-session -t multiagent-teams\"
                activate
            end tell
        " 2>/dev/null && _viewer_opened=true
    fi

    # iTerm2 で開けなかった場合は Terminal.app にフォールバック
    if [ "$_viewer_opened" = false ]; then
        osascript -e "
            tell application \"Terminal\"
                do script \"tmux attach-session -t multiagent-teams\"
                activate
            end tell
        " 2>/dev/null && _viewer_opened=true
    fi

    if [ "$_viewer_opened" = true ]; then
        log_success "  └─ ビューワーウィンドウ起動完了"
    else
        log_info "  ⚠  ビューワーウィンドウを開けませんでした"
        echo "  手動でビューワーを起動: tmux attach-session -t multiagent-teams"
    fi
    echo ""

    echo "  ════════════════════════════════════════════════════════════"
    echo "   天下布武！勝利を掴め！ (Tenka Fubu! Seize victory!)"
    echo "  ════════════════════════════════════════════════════════════"
    echo ""

    # ─── 将軍の本陣にアタッチ ───
    # ネスト tmux を許可
    unset TMUX
    exec tmux attach-session -t shogun-teams
else
    # セットアップのみモード
    PANE_BASE=$(tmux show-options -gv pane-base-index 2>/dev/null || echo 0)
    log_info "📊 セットアップのみモード: Claude Code は未起動です"
    echo ""
    echo "  手動で起動するには:"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  # 将軍を召喚                                            │"
    echo "  │  tmux send-keys -t shogun-teams:main \                   │"
    echo "  │    'claude --dangerously-skip-permissions' Enter         │"
    echo "  │                                                          │"
    echo "  │  # 家老・足軽を一斉召喚                                  │"
    printf "  │  %-56s│\n" "for p in \$(seq ${PANE_BASE} $((PANE_BASE+8))); do"
    printf "  │  %-56s│\n" "    tmux send-keys -t multiagent-teams:agents.\$p \\"
    printf "  │  %-56s│\n" "    'claude --dangerously-skip-permissions' Enter"
    printf "  │  %-56s│\n" "done"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""

    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🏯 出陣準備完了！天下布武！                             ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""
fi
