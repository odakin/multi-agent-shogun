#!/bin/bash
# 🏯 multi-agent-shogun ワンコマンド起動スクリプト
# One-Command Startup Script for Multi-Agent Orchestration System

set -e

# 色付きログ関数
log_info() {
    echo -e "\033[1;33m【報】\033[0m $1"
}

log_success() {
    echo -e "\033[1;32m【成】\033[0m $1"
}

log_war() {
    echo -e "\033[1;31m【戦】\033[0m $1"
}

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  🏯 multi-agent-shogun 〜 ワンコマンド出陣 〜             ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""

# オプション解析
OPEN_TERMINAL=false
SKIP_CLAUDE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--terminal)
            OPEN_TERMINAL=true
            shift
            ;;
        -s|--setup-only)
            SKIP_CLAUDE=true
            shift
            ;;
        -h|--help)
            echo "使用方法: ./setup.sh [オプション]"
            echo ""
            echo "オプション:"
            echo "  -t, --terminal    Windows Terminal で新しいタブを開く"
            echo "  -s, --setup-only  tmuxセッションのセットアップのみ（Claude起動なし）"
            echo "  -h, --help        このヘルプを表示"
            echo ""
            echo "例:"
            echo "  ./setup.sh           # 全エージェント起動"
            echo "  ./setup.sh -t        # 全エージェント起動 + ターミナルタブ展開"
            echo "  ./setup.sh -s        # セットアップのみ（手動でClaude起動）"
            exit 0
            ;;
        *)
            echo "不明なオプション: $1"
            echo "./setup.sh -h でヘルプを表示"
            exit 1
            ;;
    esac
done

# STEP 1: tmuxセッションのセットアップ
log_war "⚔️ 陣立てを開始..."
./shutsujin_departure.sh

# STEP 2: Claude Code 起動（オプション）
if [ "$SKIP_CLAUDE" = false ]; then
    echo ""
    log_war "👑 全軍に Claude Code を召喚中..."

    # 将軍
    tmux send-keys -t shogun "claude --dangerously-skip-permissions"
    tmux send-keys -t shogun Enter
    log_info "  └─ 将軍、召喚完了"

    # 少し待機（安定のため）
    sleep 1

    # 家老 + 足軽（9ペイン）
    for i in {0..8}; do
        tmux send-keys -t "multiagent:0.$i" "claude --dangerously-skip-permissions"
        tmux send-keys -t "multiagent:0.$i" Enter
    done
    log_info "  └─ 家老・足軽、召喚完了"

    log_success "✅ 全軍 Claude Code 起動完了"
fi

# STEP 3: Windows Terminal でタブを開く（オプション）
if [ "$OPEN_TERMINAL" = true ]; then
    echo ""
    log_info "📺 Windows Terminal でタブを展開中..."

    # Windows Terminal が利用可能か確認
    if command -v wt.exe &> /dev/null; then
        wt.exe -w 0 new-tab wsl.exe -e bash -c "tmux attach-session -t shogun" \; new-tab wsl.exe -e bash -c "tmux attach-session -t multiagent"
        log_success "  └─ ターミナルタブ展開完了"
    else
        log_info "  └─ wt.exe が見つかりません。手動でアタッチしてください。"
    fi
fi

echo ""
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║  🏯 出陣準備完了！天下布武！                              ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo ""
echo "  次のステップ:"
echo "  ┌──────────────────────────────────────────────────────────┐"
echo "  │  1. 将軍の本陣にアタッチ:                                 │"
echo "  │     tmux attach-session -t shogun                        │"
echo "  │                                                          │"
echo "  │  2. 将軍に命令:                                          │"
echo "  │     「汝は将軍なり。instructions/shogun.md を読め」       │"
echo "  └──────────────────────────────────────────────────────────┘"
echo ""
