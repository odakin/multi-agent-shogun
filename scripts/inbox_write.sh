#!/bin/bash
# inbox_write.sh — メールボックスへのメッセージ書き込み（排他ロック付き）
# Usage: bash scripts/inbox_write.sh <target_agent> <content> [type] [from]
# Example: bash scripts/inbox_write.sh karo "足軽5号、任務完了" report_received ashigaru5

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$1"
CONTENT="$2"
TYPE="${3:-wake_up}"
FROM="${4:-unknown}"

INBOX="$SCRIPT_DIR/queue/inbox/${TARGET}.yaml"
LOCKFILE="${INBOX}.lock"

# Validate arguments
if [ -z "$TARGET" ] || [ -z "$CONTENT" ]; then
    echo "Usage: inbox_write.sh <target_agent> <content> [type] [from]" >&2
    exit 1
fi

# Initialize inbox if not exists
if [ ! -f "$INBOX" ]; then
    mkdir -p "$(dirname "$INBOX")"
    echo "messages: []" > "$INBOX"
fi

# Generate unique message ID (timestamp-based)
MSG_ID="msg_$(date +%Y%m%d_%H%M%S)_$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n')"
TIMESTAMP=$(date "+%Y-%m-%dT%H:%M:%S")

# Atomic write with flock (3 retries)
attempt=0
max_attempts=3

while [ $attempt -lt $max_attempts ]; do
    if (
        flock -w 5 200 || exit 1

        # Add message via python3 (unified YAML handling)
        # Pass variables via environment to avoid shell/Python injection issues
        IW_INBOX="$INBOX" IW_MSG_ID="$MSG_ID" IW_FROM="$FROM" \
        IW_TIMESTAMP="$TIMESTAMP" IW_TYPE="$TYPE" IW_CONTENT="$CONTENT" \
        "$SCRIPT_DIR/.venv/bin/python3" -c "
import yaml, sys, os, tempfile

try:
    inbox = os.environ['IW_INBOX']

    # Load existing inbox
    with open(inbox) as f:
        data = yaml.safe_load(f)

    # Initialize if needed
    if not data:
        data = {}
    if not data.get('messages'):
        data['messages'] = []

    # Add new message
    new_msg = {
        'id': os.environ['IW_MSG_ID'],
        'from': os.environ['IW_FROM'],
        'timestamp': os.environ['IW_TIMESTAMP'],
        'type': os.environ['IW_TYPE'],
        'content': os.environ['IW_CONTENT'],
        'read': False
    }
    data['messages'].append(new_msg)

    # Inbox pruning: move read:true messages to archive (reduce token cost on Read)
    read_msgs = [m for m in data['messages'] if m.get('read', False)]
    if read_msgs:
        archive_dir = os.path.join(os.path.dirname(os.path.dirname(inbox)), 'archive')
        os.makedirs(archive_dir, exist_ok=True)
        ts = os.environ['IW_TIMESTAMP'].replace(':', '').replace('-', '').replace('T', '_')
        agent_name = os.path.splitext(os.path.basename(inbox))[0]
        archive_path = os.path.join(archive_dir, f'inbox_{agent_name}_{ts}.yaml')
        archive_data = {'archived_at': os.environ['IW_TIMESTAMP'], 'messages': read_msgs}
        tmp_fd2, tmp_path2 = tempfile.mkstemp(dir=archive_dir, suffix='.tmp')
        try:
            with os.fdopen(tmp_fd2, 'w') as f:
                yaml.dump(archive_data, f, default_flow_style=False, allow_unicode=True, indent=2)
            os.replace(tmp_path2, archive_path)
        except Exception:
            try:
                os.unlink(tmp_path2)
            except Exception:
                pass
            raise
        # Remove pruned messages from inbox (keep only unread)
        data['messages'] = [m for m in data['messages'] if not m.get('read', False)]

    # Overflow protection: keep max 50 messages
    if len(data['messages']) > 50:
        msgs = data['messages']
        unread = [m for m in msgs if not m.get('read', False)]
        read = [m for m in msgs if m.get('read', False)]
        # Keep all unread + newest 30 read messages
        data['messages'] = unread + read[-30:]

    # Atomic write: tmp file + rename (prevents partial reads)
    tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True, indent=2)
        os.replace(tmp_path, inbox)
    except:
        os.unlink(tmp_path)
        raise

    # Unread count をロック内で算出しファイルに書き出す（レース条件防止）
    unread = sum(1 for m in data['messages'] if not m.get('read', False))
    with open(inbox + '.unread', 'w') as uf:
        uf.write(str(unread))

except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
" || exit 1

    ) 200>"$LOCKFILE"; then
        # Success — now send best-effort nudge to wake the target agent
        # This ensures delivery even when inbox_watcher is dead.
        # inbox_watcher serves as escalation backup (re-nudge if still unread).
        _send_nudge() {
            # 将軍への send-keys nudge は抑制（大殿様は自分のタイミングでinboxを読む。
            # tmux send-keys でナッジを送るとプロンプトに "inbox1" が挿入されて邪魔になる。
            # YAML書き込み（inbox_write.sh の主目的）は上のロック内で既に完了している。）
            [ "$TARGET" = "shogun" ] && return 0

            # Find target pane by @agent_id tmux user variable
            local target_pane=""
            while IFS= read -r _line; do
                local _pid="${_line%% *}"
                local _aid="${_line#* }"
                if [ "$_aid" = "$TARGET" ]; then
                    target_pane="$_pid"
                    break
                fi
            done < <(tmux list-panes -a -F '#{pane_id} #{@agent_id}' 2>/dev/null)

            [ -z "$target_pane" ] && return 0

            # Busy check: skip nudge only if agent is actively processing.
            # Uses busy-pattern detection (not idle-pattern) because Claude Code
            # renders multiple status lines below ❯ (permissions, context %, etc.)
            # making tail-N unreliable for finding the prompt.
            local pane_content
            pane_content=$(timeout 2 tmux capture-pane -t "$target_pane" -p 2>/dev/null || true)
            if echo "$pane_content" | grep -qE "thinking|thought for|esc to interrupt"; then
                return 0  # Agent is busy; Stop hook or inbox_watcher will deliver
            fi

            # Transcript view detection: agent is stuck showing detailed transcript.
            # Nudge text would be silently lost in this view — must Escape first.
            if echo "$pane_content" | grep -qiE "Showing detailed transcript|ctrl.o to toggle"; then
                timeout 2 tmux send-keys -t "$target_pane" Escape 2>/dev/null || true
                sleep 0.5
                timeout 2 tmux send-keys -t "$target_pane" Escape 2>/dev/null || true
                sleep 1  # Wait for prompt to appear after exiting transcript view
            fi

            # Unread count をロック内で書き出したファイルから取得（レース条件なし）
            local unread
            unread=$(cat "${INBOX}.unread" 2>/dev/null || echo "1")
            rm -f "${INBOX}.unread"

            # Send nudge: text + Enter (separated to avoid Codex TUI issues)
            timeout 5 tmux send-keys -t "$target_pane" "inbox${unread}" 2>/dev/null || true
            sleep 0.3
            timeout 5 tmux send-keys -t "$target_pane" Enter 2>/dev/null || true
        }
        _send_nudge 2>/dev/null || true  # Never fail the script
        exit 0
    else
        # Lock timeout or error
        attempt=$((attempt + 1))
        if [ $attempt -lt $max_attempts ]; then
            echo "[inbox_write] Lock timeout for $INBOX (attempt $attempt/$max_attempts), retrying..." >&2
            sleep 1
        else
            echo "[inbox_write] Failed to acquire lock after $max_attempts attempts for $INBOX" >&2
            exit 1
        fi
    fi
done
