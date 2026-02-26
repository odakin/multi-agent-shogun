#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# shutsujin_teams.sh — Agent Teams 版 出陣スクリプト
# ═══════════════════════════════════════════════════════════════════════════════
# Agent Teams の組み込み通信基盤を使用。
# inbox_write.sh / inbox_watcher.sh は不要。
# tmux ペイン管理は Agent Teams が自動で行う。
#
# 使用方法:
#   ./shutsujin_teams.sh              # Agent Teams モードで将軍を起動
#   ./shutsujin_teams.sh --model opus # モデル指定
#   ./shutsujin_teams.sh -h           # ヘルプ
# ═══════════════════════════════════════════════════════════════════════════════

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ─── オプション解析 ───
MODEL="opus"
SKIP_PERMISSIONS=false

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
        -h|--help)
            echo ""
            echo "Agent Teams 版 出陣スクリプト"
            echo ""
            echo "使用方法: ./shutsujin_teams.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  --model MODEL                    モデル指定 (デフォルト: opus)"
            echo "  --dangerously-skip-permissions   権限チェックスキップ"
            echo "  -h, --help                       ヘルプ表示"
            echo ""
            echo "仕組み:"
            echo "  1. 将軍を1つ起動（Agent Teams有効）"
            echo "  2. 将軍がTeamCreateでチーム作成"
            echo "  3. 将軍がTask()で家老・足軽・軍師をspawn"
            echo "  4. 通信はSendMessage、タスク管理はTaskCreate/TaskUpdate"
            echo "  5. tmuxペインはAgent Teamsが自動管理"
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

# ─── バナー ───
echo ""
echo -e "\033[1;31m╔════════════════════════════════════════════════════════════╗\033[0m"
echo -e "\033[1;31m║\033[0m  \033[1;33m出陣じゃ！ — Agent Teams 版\033[0m                              \033[1;31m║\033[0m"
echo -e "\033[1;31m╠════════════════════════════════════════════════════════════╣\033[0m"
echo -e "\033[1;31m║\033[0m  通信: SendMessage (自動配信)                              \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m  タスク: TaskCreate / TaskUpdate / TaskList                \033[1;31m║\033[0m"
echo -e "\033[1;31m║\033[0m  tmux: Agent Teams 自動管理                                \033[1;31m║\033[0m"
echo -e "\033[1;31m╚════════════════════════════════════════════════════════════╝\033[0m"
echo ""

# ─── 環境変数 ───
export CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1
export SHOGUN_ROOT="$SCRIPT_DIR"

# ─── Claude Code 起動引数の組み立て ───
CLAUDE_ARGS=("--model" "$MODEL" "--teammate-mode" "tmux")

if [ "$SKIP_PERMISSIONS" = true ]; then
    CLAUDE_ARGS+=("--dangerously-skip-permissions")
fi

echo -e "\033[1;32m【起動】\033[0m npx @anthropic-ai/claude-code ${CLAUDE_ARGS[*]}"
echo ""

# ─── 起動 ───
exec npx -y @anthropic-ai/claude-code "${CLAUDE_ARGS[@]}"
