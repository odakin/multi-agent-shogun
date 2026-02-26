#!/bin/bash
# Agent Teams フィーチャーゲート確認スクリプト
# tengu_amber_flint ゲートが有効かテストする

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=== Agent Teams フィーチャーゲートテスト ==="
echo "Claude Code version: $(npx -y @anthropic-ai/claude-code --version 2>/dev/null)"
echo ""

# CLAUDECODE を unset（ネストセッション防止）
unset CLAUDECODE

# テスト: env varを設定してTeamCreateツールが利用可能か確認
echo "[テスト] CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 でツール一覧を確認..."
RESULT=$(CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 npx @anthropic-ai/claude-code \
  -p "List tool names containing 'Team', 'Send', or 'Task'. One per line, names only." \
  --output-format text \
  2>/dev/null || echo "ERROR")

if echo "$RESULT" | grep -qi "TeamCreate"; then
    echo "  ✅ Agent Teams ツールが検出されました！"
    echo ""
    echo "  検出されたツール:"
    echo "$RESULT" | grep -i "Team\|SendMessage\|Task" | head -20
    echo ""
    echo "==> Agent Teams は有効です。"
    echo "    ./shutsujin_teams.sh で起動できます。"
    exit 0
else
    echo "  ❌ Agent Teams ツールが検出されませんでした"
    echo "  （tengu_amber_flint ゲートが無効の可能性）"
    echo ""
    echo "  出力（先頭10行）:"
    echo "$RESULT" | head -10
    echo ""
    echo "==> Agent Teams はまだ利用不可です。"
    echo "    現行の ./shutsujin_departure.sh を継続してください。"
    exit 1
fi
