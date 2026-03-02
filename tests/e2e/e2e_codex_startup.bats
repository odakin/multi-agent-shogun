#!/usr/bin/env bats
# ═══════════════════════════════════════════════════════════════
# E2E-008: Codex CLI Startup Prompt after /new
# ═══════════════════════════════════════════════════════════════
# Validates that inbox_watcher correctly handles Codex CLI agents:
#   1. Sends /new (not /clear) for context reset
#   2. Sends startup prompt AFTER /new to trigger Session Start
#   3. Agent processes assigned task via startup prompt
#   4. Nudge is suppressed immediately after startup prompt
#
# Background: Codex CLI's /new does NOT auto-reload AGENTS.md and
# trigger Session Start like Claude Code's /clear does with CLAUDE.md.
# inbox_watcher must explicitly send a startup prompt after /new.
#
# IMPORTANT: These tests use write_inbox_direct (no tmux nudge) so that
# only the inbox_watcher handles delivery. inbox_write.sh's direct nudge
# would bypass the watcher's startup prompt flow.
# ═══════════════════════════════════════════════════════════════

# bats file_tags=e2e

load "../test_helper/bats-support/load"
load "../test_helper/bats-assert/load"

# Load E2E helpers
E2E_HELPERS_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/helpers" && pwd)"
source "$E2E_HELPERS_DIR/setup.bash"
source "$E2E_HELPERS_DIR/assertions.bash"
source "$E2E_HELPERS_DIR/tmux_helpers.bash"

# ─── Lifecycle ───

setup_file() {
    command -v tmux &>/dev/null || skip "tmux not available"
    command -v python3 &>/dev/null || skip "python3 not available"
    python3 -c "import yaml" 2>/dev/null || skip "python3-yaml not available"

    setup_e2e_session 3
}

teardown_file() {
    teardown_e2e_session
}

setup() {
    reset_queues
    sleep 1
}

# Helper: dump watcher log on failure
dump_watcher_log() {
    local log_file="$1"
    echo "=== Watcher log ($log_file) ===" >&2
    cat "$log_file" >&2 2>/dev/null || echo "(log not found)" >&2
    echo "=== End watcher log ===" >&2
}

# Helper: start watcher with boot grace disabled for Codex startup tests
start_codex_watcher() {
    local agent_id="$1"
    local pane_idx="$2"
    local pane_target="${E2E_SESSION}:agents.${pane_idx}"
    local log_file="/tmp/e2e_inbox_watcher_${agent_id}_$$.log"

    # ASW_BOOT_GRACE=0: disable boot grace so process_unread_once runs immediately
    ESCALATE_PHASE1="${E2E_ESCALATE_PHASE1:-10}" \
    ESCALATE_PHASE2="${E2E_ESCALATE_PHASE2:-20}" \
    ESCALATE_COOLDOWN="${E2E_ESCALATE_COOLDOWN:-25}" \
    INOTIFY_TIMEOUT="${E2E_INOTIFY_TIMEOUT:-5}" \
    ASW_BOOT_GRACE=0 \
    bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "$agent_id" "$pane_target" "codex" \
        > "$log_file" 2>&1 &

    local pid=$!
    echo "$pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-A: Codex agent receives startup prompt after /new
#            and processes assigned task
# ═══════════════════════════════════════════════════════════════

@test "E2E-008-A: Codex startup prompt triggers task processing via inbox_watcher" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock (clean restart)
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Write task_assigned directly to inbox (no tmux nudge)
    #    so only the watcher handles delivery via startup prompt flow
    write_inbox_direct "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 4. Start inbox_watcher (boot grace disabled)
    #    process_unread_once sees unread → sends /new → sends startup prompt
    local watcher_pid log_file
    watcher_pid=$(start_codex_watcher "ashigaru1" 1)
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. Wait for task to complete
    #    Flow: watcher detects unread → sends /new → polls idle (5s) → sends startup prompt → mock processes
    #    Expected time: ~10-15s
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 45
    if [ "$status" -ne 0 ]; then
        dump_pane_for_debug "$ashigaru1_pane" "ashigaru1-codex"
        dump_watcher_log "$log_file"
    fi
    assert_success

    # 6. Verify report was written
    run wait_for_file "$E2E_QUEUE/queue/reports/ashigaru1_report.yaml" 10
    assert_success

    # 7. Verify report content
    assert_yaml_field "$E2E_QUEUE/queue/reports/ashigaru1_report.yaml" "status" "done"
    assert_yaml_field "$E2E_QUEUE/queue/reports/ashigaru1_report.yaml" "task_id" "subtask_test_001a"

    # 8. Verify startup prompt appeared in pane output (scrollback search)
    run wait_for_pane_text "$ashigaru1_pane" "Startup prompt received" 10
    if [ "$status" -ne 0 ]; then
        dump_watcher_log "$log_file"
    fi
    assert_success

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-B: Codex watcher log confirms startup prompt sent
#            and nudge suppressed
# ═══════════════════════════════════════════════════════════════

@test "E2E-008-B: Codex watcher log shows startup prompt sent and nudge skipped" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place task and write inbox message directly (no tmux nudge)
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    write_inbox_direct "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 3. Start watcher (boot grace disabled)
    local watcher_pid log_file
    watcher_pid=$(start_codex_watcher "ashigaru1" 1)
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 4. Wait for processing
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 45
    if [ "$status" -ne 0 ]; then
        dump_pane_for_debug "$ashigaru1_pane" "ashigaru1-codex-B"
        dump_watcher_log "$log_file"
    fi
    assert_success

    # 5. Check watcher log for startup prompt delivery
    run grep "Sending startup prompt to ashigaru1" "$log_file"
    if [ "$status" -ne 0 ]; then
        dump_watcher_log "$log_file"
    fi
    assert_success

    # 6. Check watcher log for nudge suppression after startup prompt
    run grep "Startup prompt just sent.*skipping nudge" "$log_file"
    assert_success

    # 7. Check that /new was sent (not /clear)
    run grep "CONTEXT-RESET.*Sending /new" "$log_file"
    assert_success

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-C: Claude agent does NOT receive startup prompt
#            (only Codex gets it)
# ═══════════════════════════════════════════════════════════════

@test "E2E-008-C: Claude agent does not receive startup prompt after /clear" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with claude mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=claude MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "claude"

    # 2. Place task and write inbox message directly (no tmux nudge)
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    write_inbox_direct "ashigaru1" \
        "タスクYAMLを読んで作業開始せよ。" "task_assigned" "karo"

    # 3. Start watcher (claude CLI type, boot grace disabled)
    local watcher_pid log_file
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    ESCALATE_PHASE1="${E2E_ESCALATE_PHASE1:-10}" \
    ESCALATE_PHASE2="${E2E_ESCALATE_PHASE2:-20}" \
    ESCALATE_COOLDOWN="${E2E_ESCALATE_COOLDOWN:-25}" \
    INOTIFY_TIMEOUT="${E2E_INOTIFY_TIMEOUT:-5}" \
    ASW_BOOT_GRACE=0 \
    bash "$E2E_QUEUE/scripts/inbox_watcher.sh" "ashigaru1" "$ashigaru1_pane" "claude" \
        > "$log_file" 2>&1 &
    watcher_pid=$!

    # 4. Wait for task to complete (claude uses /clear → auto-recovery via mock handle_clear)
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 45
    if [ "$status" -ne 0 ]; then
        dump_pane_for_debug "$ashigaru1_pane" "ashigaru1-claude-C"
        dump_watcher_log "$log_file"
    fi
    assert_success

    # 5. Check that startup prompt was NOT sent (claude doesn't need it)
    run grep "Sending startup prompt" "$log_file"
    assert_failure

    # 6. Check that /clear was sent (not /new)
    run grep "CONTEXT-RESET.*Sending /clear" "$log_file"
    assert_success

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-D: Codex clear_command sends /new exactly once
#            (dedup guard prevents multiple /new sends)
# ═══════════════════════════════════════════════════════════════
# Regression test for the /new multi-send bug where clear_command
# followed by auto-recovery task_assigned caused 2+ /new sends,
# wiping the startup prompt each time.

@test "E2E-008-D: Codex clear_command sends /new exactly once, not multiple times" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Write clear_command directly to inbox (no tmux nudge)
    write_inbox_direct "ashigaru1" "/clear" "clear_command" "karo"

    # 4. Start inbox_watcher (boot grace disabled)
    local watcher_pid log_file
    watcher_pid=$(start_codex_watcher "ashigaru1" 1)
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. Wait for task to complete
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 60
    if [ "$status" -ne 0 ]; then
        dump_pane_for_debug "$ashigaru1_pane" "ashigaru1-codex-D"
        dump_watcher_log "$log_file"
    fi
    assert_success

    # 6. Count /new sends in watcher log — must be exactly 1
    local new_count
    new_count=$(grep -c "Codex /clear→/new" "$log_file" 2>/dev/null || true)
    if [ "$new_count" -ne 1 ]; then
        echo "Expected 1 /new send, got $new_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$new_count" -eq 1 ]

    # 7. Verify startup prompt was sent exactly once
    local startup_count
    startup_count=$(grep -c "Sending startup prompt to ashigaru1" "$log_file" 2>/dev/null || true)
    if [ "$startup_count" -ne 1 ]; then
        echo "Expected 1 startup prompt, got $startup_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$startup_count" -eq 1 ]

    # 8. Verify no duplicate context-reset /new was sent
    local context_reset_new_count
    context_reset_new_count=$(grep -c "CONTEXT-RESET.*Sending /new" "$log_file" 2>/dev/null || true)
    if [ "$context_reset_new_count" -ne 0 ]; then
        echo "Expected 0 context-reset /new sends (clear_command path should skip), got $context_reset_new_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$context_reset_new_count" -eq 0 ]

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}

# ═══════════════════════════════════════════════════════════════
# E2E-008-E: Multiple clear_commands to Codex agent still
#            result in only one /new send
# ═══════════════════════════════════════════════════════════════

@test "E2E-008-E: Multiple rapid clear_commands to Codex result in single /new" {
    local ashigaru1_pane
    ashigaru1_pane=$(pane_target 1)

    # 1. Respawn pane with codex mock
    tmux respawn-pane -k -t "$ashigaru1_pane" \
        "MOCK_CLI_TYPE=codex MOCK_AGENT_ID=ashigaru1 MOCK_PROCESSING_DELAY=1 MOCK_PROJECT_ROOT=$E2E_QUEUE bash $PROJECT_ROOT/tests/e2e/mock_cli.sh"
    sleep 2
    tmux set-option -p -t "$ashigaru1_pane" @agent_cli "codex"

    # 2. Place assigned task YAML
    cp "$PROJECT_ROOT/tests/e2e/fixtures/task_ashigaru1_basic.yaml" \
       "$E2E_QUEUE/queue/tasks/ashigaru1.yaml"

    # 3. Write THREE clear_commands directly to inbox (no tmux nudge)
    write_inbox_direct "ashigaru1" "/clear" "clear_command" "karo"
    write_inbox_direct "ashigaru1" "/clear" "clear_command" "karo"
    write_inbox_direct "ashigaru1" "/clear" "clear_command" "karo"

    # 4. Start inbox_watcher (boot grace disabled)
    local watcher_pid log_file
    watcher_pid=$(start_codex_watcher "ashigaru1" 1)
    log_file="/tmp/e2e_inbox_watcher_ashigaru1_$$.log"

    # 5. Wait for task to complete
    run wait_for_yaml_value "$E2E_QUEUE/queue/tasks/ashigaru1.yaml" "task.status" "done" 60
    if [ "$status" -ne 0 ]; then
        dump_pane_for_debug "$ashigaru1_pane" "ashigaru1-codex-E"
        dump_watcher_log "$log_file"
    fi
    assert_success

    # 6. Count /new sends — must be exactly 1 despite 3 clear_commands
    local new_count
    new_count=$(grep -c "Codex /clear→/new" "$log_file" 2>/dev/null || true)
    if [ "$new_count" -ne 1 ]; then
        echo "Expected 1 /new send despite 3 clear_commands, got $new_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$new_count" -eq 1 ]

    # 7. Verify dedup guard logged skips for extra clear_commands
    local skip_count
    skip_count=$(grep -c "SKIP.*Codex /new already sent" "$log_file" 2>/dev/null || true)
    if [ "$skip_count" -lt 1 ]; then
        echo "Expected at least 1 dedup skip log, got $skip_count" >&2
        dump_watcher_log "$log_file"
    fi
    [ "$skip_count" -ge 1 ]

    # Cleanup
    stop_inbox_watcher "$watcher_pid"
}
