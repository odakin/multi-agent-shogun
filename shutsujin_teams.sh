#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# shutsujin_teams.sh — Agent Teams 版 出陣スクリプト
# ═══════════════════════════════════════════════════════════════════════════════
# Agent Teams の組み込み通信基盤を使用。
# inbox_write.sh / inbox_watcher.sh は不要（SendMessage で代替）。
# tmux ペイン管理は Agent Teams が自動で行う。
#
# 使用方法:
#   ./shutsujin_teams.sh              # Agent Teams モードで将軍を起動
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
        python3 -m venv "$VENV_DIR" 2>/dev/null || {
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
SKIP_PERMISSIONS=false
SHELL_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --dangerously-skip-permissions)
            SKIP_PERMISSIONS=true
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
            echo "🏯 Agent Teams 版 出陣スクリプト"
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
            echo "仕組み（Agent Teams）:"
            echo "  1. 将軍を1つ起動（--teammate-mode tmux）"
            echo "  2. 将軍がTeamCreateでチーム作成"
            echo "  3. 将軍がTask()で家老・足軽・軍師をspawn"
            echo "  4. 通信はSendMessage（自動配信）、タスク管理はTaskCreate/TaskUpdate"
            echo "  5. tmuxペインはAgent Teamsが自動管理"
            echo "  6. inbox_watcher / ntfy_listener は不要（SendMessageで代替）"
            echo ""
            echo "陣形:"
            echo "  平時の陣（デフォルト）: 足軽1-7=Sonnet, 軍師=Opus"
            echo "  決戦の陣（--kessen）:   全足軽=Opus, 軍師=Opus"
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
    echo -e "\033[1;31m╔══════════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗██╗  ██╗██╗   ██╗████████╗███████╗██╗   ██╗     ██╗██╗███╗   ██╗\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m██╔════╝██║  ██║██║   ██║╚══██╔══╝██╔════╝██║   ██║     ██║██║████╗  ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████╗███████║██║   ██║   ██║   ███████╗██║   ██║     ██║██║██╔██╗ ██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚════██║██╔══██║██║   ██║   ██║   ╚════██║██║   ██║██   ██║██║██║╚██╗██║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m███████║██║  ██║╚██████╔╝   ██║   ███████║╚██████╔╝╚█████╔╝██║██║ ╚████║\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m║\033[0m \033[1;33m╚══════╝╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚══════╝ ╚═════╝  ╚════╝ ╚═╝╚═╝  ╚═══╝\033[0m \033[1;31m║\033[0m"
    echo -e "\033[1;31m╠══════════════════════════════════════════════════════════════════════════════════╣\033[0m"
    echo -e "\033[1;31m║\033[0m       \033[1;37m出陣じゃーーー！！！\033[0m    \033[1;36m⚔\033[0m    \033[1;35m天下布武！ — Agent Teams 版\033[0m           \033[1;31m║\033[0m"
    echo -e "\033[1;31m╚══════════════════════════════════════════════════════════════════════════════════╝\033[0m"
    echo ""

    echo -e "\033[1;34m  ╔═════════════════════════════════════════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;34m  ║\033[0m                \033[1;37m【 足 軽 隊 列 ・ 七 名 + 軍 師 配 備 】\033[0m                  \033[1;34m║\033[0m"
    echo -e "\033[1;34m  ╚═════════════════════════════════════════════════════════════════════════════╝\033[0m"

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
    echo -e "\033[1;33m  ┃\033[0m  \033[1;37m🏯 multi-agent-shogun\033[0m  〜 \033[1;36mAgent Teams 版\033[0m 〜                                \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m                                                                           \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  \033[1;35m将軍\033[0m: 統括  \033[1;31m家老\033[0m: 管理  \033[1;33m軍師\033[0m: 戦略(Opus)  \033[1;34m足軽\033[0m: 実働×${_ASHIGARU_COUNT}  \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┃\033[0m  通信: SendMessage (自動配信)  タスク: TaskCreate/TaskUpdate               \033[1;33m┃\033[0m"
    echo -e "\033[1;33m  ┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛\033[0m"
    echo ""
}

# バナー表示実行
show_battle_cry

echo -e "  \033[1;33m天下布武！陣立てを開始いたす\033[0m (Setting up the battlefield — Agent Teams)"
echo ""

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: 既存セッションクリーンアップ
# ═══════════════════════════════════════════════════════════════════════════════
log_info "🧹 既存の陣を撤収中..."
# Agent Teams版はshogun-teamsセッション名を使用
tmux kill-session -t shogun-teams 2>/dev/null && log_info "  └─ shogun-teams陣、撤収完了" || log_info "  └─ shogun-teams陣は存在せず"

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
# Agent Teams版ではinboxディレクトリは不要（SendMessageで代替）
# ただし互換性のために存在する場合は維持
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
        cat > ./dashboard.md << EOF
# 🏯 戦況報告 — dashboard.md
> 最終更新: ${TIMESTAMP}
> 更新者: shutsujin_teams.sh --clean

## 🚨 要対応
なし

## 🔄 進行中
なし

## ✅ 本日の戦果
| 時刻 | 戦場 | 任務 | 結果 |
|------|------|------|------|

## 🎯 スキル化候補
なし

## ⏸️ 待機中
なし
EOF
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
    echo "  ║  [ERROR] tmux not found!                              ║"
    echo "  ║  tmux が見つかりません                                 ║"
    echo "  ╠════════════════════════════════════════════════════════╣"
    echo "  ║  Run first_setup.sh first:                            ║"
    echo "  ║     ./first_setup.sh                                  ║"
    echo "  ╚════════════════════════════════════════════════════════╝"
    echo ""
    exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: 環境変数
# ═══════════════════════════════════════════════════════════════════════════════
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
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
# STEP 6: Claude Code 起動（Agent Teams モード）
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

    # Claude Code 起動引数の組み立て（Agent Teams版）
    CLAUDE_ARGS=("--model" "$MODEL" "--teammate-mode" "tmux")

    if [ "$SKIP_PERMISSIONS" = true ]; then
        CLAUDE_ARGS+=("--dangerously-skip-permissions")
    fi

    log_war "👑 将軍を召喚中... (Agent Teams モード)"
    echo ""

    if [ "$KESSEN_MODE" = true ]; then
        log_success "⚔️  決戦の陣で出陣！全軍Opus！"
    else
        log_success "⚔️  平時の陣で出陣（足軽=Sonnet, 軍師=Opus）"
    fi
    echo ""

    # ═══════════════════════════════════════════════════════════════════════════
    # ntfy 入力リスナー起動
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

    # ═══════════════════════════════════════════════════════════════════════════
    # ビジュアルモニター起動（サイレントモード以外）
    # ═══════════════════════════════════════════════════════════════════════════
    # Agent Teams が自動作成する tmux ペインを監視し、
    # pane-border-format, @agent_id, tiled レイアウトを適用する。
    if [ "$SILENT_MODE" != true ]; then
        # 現在の tmux セッション名を検出（tmux 内で実行されている場合）
        TEAMS_SESSION=""
        if [ -n "${TMUX:-}" ]; then
            TEAMS_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null)
        fi
        export TEAMS_SESSION

        # tmux 環境変数にも DISPLAY_MODE と KESSEN_MODE をセット
        # （エージェントが tmux show-environment で読めるように）
        if [ -n "$TEAMS_SESSION" ]; then
            tmux set-environment -t "$TEAMS_SESSION" DISPLAY_MODE "$DISPLAY_MODE" 2>/dev/null || true
            if [ "$KESSEN_MODE" = true ]; then
                tmux set-environment -t "$TEAMS_SESSION" KESSEN_MODE "true" 2>/dev/null || true
            fi
        fi

        mkdir -p "$SCRIPT_DIR/logs"
        log_info "🎨 ビジュアルモニター起動中..."
        nohup bash "$SCRIPT_DIR/scripts/teams_visual_monitor.sh" \
            "$TEAMS_SESSION" \
            "$SCRIPT_DIR" \
            >> "$SCRIPT_DIR/logs/teams_visual_monitor.log" 2>&1 &
        MONITOR_PID=$!
        disown
        log_success "  └─ ビジュアルモニター起動完了 (PID: $MONITOR_PID)"
        echo ""
    fi

    echo -e "\033[1;32m【起動】\033[0m npx @anthropic-ai/claude-code ${CLAUDE_ARGS[*]}"
    echo ""

    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🏯 出陣準備完了！天下布武！                              ║"
    echo "  ║  Agent Teams + ビジュアルモニター で tmux 管理            ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""
    echo "  ════════════════════════════════════════════════════════════"
    echo "   天下布武！勝利を掴め！ (Tenka Fubu! Seize victory!)"
    echo "  ════════════════════════════════════════════════════════════"
    echo ""

    # ─── 起動 ───
    exec npx -y @anthropic-ai/claude-code "${CLAUDE_ARGS[@]}"
else
    # セットアップのみモード
    log_info "📊 セットアップのみモード: Claude Code は未起動です"
    echo ""
    echo "  手動で起動するには:"
    echo "  ┌──────────────────────────────────────────────────────────┐"
    echo "  │  export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1          │"
    echo "  │  npx @anthropic-ai/claude-code --model $MODEL \\         │"
    echo "  │    --teammate-mode tmux                                 │"
    echo "  └──────────────────────────────────────────────────────────┘"
    echo ""

    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║  🏯 出陣準備完了！天下布武！                              ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo ""
fi
