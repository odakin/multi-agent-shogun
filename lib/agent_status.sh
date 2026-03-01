#!/usr/bin/env bash
# lib/agent_status.sh — エージェント稼働状態検出の共有ライブラリ
#
# 提供関数:
#   agent_is_busy_check <pane_target>   → 0=busy, 1=idle, 2=pane不在
#   get_pane_state_label <pane_target>  → "稼働中" / "待機中" / "不在"
#
# 使用例:
#   source lib/agent_status.sh
#   agent_is_busy_check "multiagent:agents.0"
#   state=$(get_pane_state_label "multiagent:agents.3")

# agent_is_busy_check <pane_target>
# tmux paneの末尾5行からCLI固有のidle/busyパターンを検出する。
# Returns: 0=busy, 1=idle, 2=pane不在
#
# Detection strategy:
#   1. Status bar check (last non-empty line): 'esc to' only appears in
#      Claude Code's status bar during active processing. This is the most
#      reliable busy signal — immune to old spinner text in scroll-back.
#   2. Idle checks: CLI-specific idle prompts (❯, Codex ? prompt)
#   3. Text-based busy markers: spinner keywords in bottom 5 lines
#
# Why this order matters:
#   - Claude Code shows ❯ prompt even during thinking/working, so idle
#     checks alone cause false-idle (the bug that broke is_busy).
#   - Old spinner text (e.g. "Working on task • esc to interrupt") lingers
#     in scroll-back, so checking all 5 lines for 'esc to' causes false-busy
#     (the bug T-BUSY-008 fixed). Solution: check ONLY the last line for
#     'esc to' — the status bar is always at the bottom.
agent_is_busy_check() {
    local pane_target="$1"
    local pane_tail
    # Grab bottom 20 lines, strip blank lines, then keep last 5 with content.
    # Why: Claude Code pads the pane bottom with blank lines after /clear,
    # so raw `tail -5` can return all-blank → command substitution strips
    # trailing newlines → pane_tail="" → false "absent" (T-BUSY-009).
    pane_tail=$(timeout 2 tmux capture-pane -t "$pane_target" -p 2>/dev/null | tail -20 | grep -v '^[[:space:]]*$' | tail -5)

    # Pane doesn't exist or truly empty (no content in bottom 20 lines)
    if [[ -z "$pane_tail" ]]; then
        return 2
    fi

    # ── Status bar check (last non-empty line = most reliable) ──
    # Claude Code status bar appends 'esc to interrupt' (or truncated 'esc to…')
    # ONLY during active processing. When idle, this suffix disappears.
    # Checking only the last line avoids false-busy from old spinner text
    # that might still be visible in the bottom 5 lines (T-BUSY-008 scenario).
    local last_line
    last_line=$(echo "$pane_tail" | grep -v '^[[:space:]]*$' | tail -1)
    if echo "$last_line" | grep -qiF 'esc to'; then
        return 0  # busy — status bar confirms active processing
    fi

    # ── Idle checks (BEFORE text-based busy markers) ──
    # These take priority over historical busy text that may linger in pane.
    # Codex idle prompt
    if echo "$pane_tail" | grep -qE '(\? for shortcuts|context left)'; then
        return 1
    fi
    # Claude Code bare prompt (❯ at start or after whitespace, line-final)
    # Removed ^ anchor: tmux capture may have leading spaces in some layouts.
    if echo "$pane_tail" | grep -qE '(❯|›)\s*$'; then
        return 1
    fi
    # Claude Code status bar with no 'esc to' = idle
    # (bypass permissions / auto-compact info visible = definitely at prompt)
    if echo "$pane_tail" | grep -qiE '(bypass permissions|auto-compact)'; then
        return 1
    fi

    # ── Text-based busy markers (bottom 5 lines) ──
    # These catch non-Claude-Code CLIs and edge cases where status bar
    # isn't present but spinner text indicates active work.
    # NOTE: These run AFTER idle checks. If prompt is visible, agent is idle
    # even if old "Thinking..." text lingers in scroll-back.
    if echo "$pane_tail" | grep -qiF 'background terminal running'; then
        return 0
    fi
    if echo "$pane_tail" | grep -qiE '(Working|Thinking|Planning|Sending|task is in progress|Compacting conversation|thought for|思考中|考え中|計画中|送信中|処理中|実行中)'; then
        return 0
    fi

    return 1  # idle (default)
}

# ═══════════════════════════════════════════════════════════════
# agent_stuck_check — スタック検知＆自動復旧
# ═══════════════════════════════════════════════════════════════
#
# Claude Code が対話的プロンプト（フィードバック、確認ダイアログ等）で
# ブロックされているかを検知し、自動的にキー送信で復旧する。
#
# 使い方:
#   agent_stuck_check <pane_target> [agent_id]
#   → 0=stuck検知＆復旧実施, 1=正常（stuckではない）, 2=ペイン不在
#
# 検知パターン:
#   - フィードバックプロンプト（「このセッションはどうでしたか？」等）
#   - セッション終了確認
#   - その他の対話的ブロッキングプロンプト
#
# 設計:
#   インフラ層（watcher）で動作するため F001/F004 に抵触しない。
#   家老・足軽の役割分担を崩さずにスタック復旧を実現する。
# ═══════════════════════════════════════════════════════════════

# Stuck pattern list (case-insensitive grep patterns)
# Each entry: "pattern|recovery_keys|description"
#   recovery_keys: キーシーケンス（tmux send-keys 形式）
#     "Enter" = Enter キー, "Escape" = Esc キー, "q Enter" = q → Enter
STUCK_PATTERNS=(
    "このセッションはどうでしたか|Escape|feedback_prompt_ja"
    "How was this session|Escape|feedback_prompt_en"
    "Would you like to provide feedback|Escape|feedback_request"
    "Rate this conversation|Escape|rate_conversation"
    "Press any key to continue|Enter|press_any_key"
    "Do you want to exit|n Enter|exit_confirmation"
    "Session ended|Enter|session_ended"
    "has been compacted.*continue|Enter|compaction_continue"
    "Showing detailed transcript|Escape Escape|transcript_view"
    "ctrl.o to toggle|Escape Escape|transcript_view_alt"
)

# agent_stuck_check <pane_target> [agent_id]
# Returns: 0=stuck (recovered), 1=not stuck, 2=pane absent
agent_stuck_check() {
    local pane_target="$1"
    local agent_id="${2:-unknown}"
    local pane_content

    # Capture last 15 lines (more than busy check — stuck prompts may appear higher)
    pane_content=$(timeout 2 tmux capture-pane -t "$pane_target" -p 2>/dev/null | tail -15)

    if [[ -z "$pane_content" ]]; then
        return 2  # pane doesn't exist
    fi

    local pattern recovery_keys description
    for entry in "${STUCK_PATTERNS[@]}"; do
        IFS='|' read -r pattern recovery_keys description <<< "$entry"

        if echo "$pane_content" | grep -qi "$pattern"; then
            # Stuck detected — send recovery keys
            echo "[$(date)] [STUCK-RECOVERY] $agent_id ($pane_target): detected '$description' — sending '$recovery_keys'" >&2

            # Send recovery keys (space-separated keys sent individually)
            for key in $recovery_keys; do
                tmux send-keys -t "$pane_target" "$key"
                sleep 0.3
            done

            # Log to stuck_recovery.log
            local log_dir
            log_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/logs"
            mkdir -p "$log_dir"
            echo "[$(date)] agent=$agent_id pane=$pane_target pattern=$description keys=$recovery_keys" >> "$log_dir/stuck_recovery.log"

            return 0  # stuck, recovery attempted
        fi
    done

    return 1  # not stuck
}

# get_pane_state_label <pane_target>
# 人間が読めるラベルを返す。
get_pane_state_label() {
    local pane_target="$1"
    agent_is_busy_check "$pane_target"
    local rc=$?
    case $rc in
        0) echo "稼働中" ;;
        1) echo "待機中" ;;
        2) echo "不在" ;;
    esac
}
