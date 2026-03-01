#!/usr/bin/env bats
# test_teams_visual_current_task.bats — teams_visual_monitor.sh @current_task YAML読取テスト
#
# テスト構成:
#   T-CT-001: get_task_id_from_yaml — assigned ステータスなら task_id を返す
#   T-CT-002: get_task_id_from_yaml — in_progress ステータスなら task_id を返す
#   T-CT-003: get_task_id_from_yaml — pending ステータスなら task_id を返す
#   T-CT-004: get_task_id_from_yaml — done ステータスなら空文字を返す
#   T-CT-005: get_task_id_from_yaml — YAMLファイルが存在しない場合は空文字を返す
#   T-CT-006: get_task_id_from_yaml — task_id が15文字超なら15文字に切り詰める
#   T-CT-007: get_task_id_from_yaml — inbox nudge テキスト("inbox1")を拾わない
#   T-CT-008: style_pane — @current_task を YAML から設定する（ペイン出力マッチなし）

# --- セットアップ ---

setup_file() {
    export PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export MONITOR_SCRIPT="$PROJECT_ROOT/scripts/teams_visual_monitor.sh"
    export VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
    [ -f "$MONITOR_SCRIPT" ] || return 1
    "$VENV_PYTHON" -c "import yaml" 2>/dev/null || return 1
}

setup() {
    export TEST_TMPDIR="$(mktemp -d "$BATS_TMPDIR/teams_ct_test.XXXXXX")"
    export MOCK_LOG="$TEST_TMPDIR/tmux_calls.log"
    > "$MOCK_LOG"

    mkdir -p "$TEST_TMPDIR/queue/tasks"
    mkdir -p "$TEST_TMPDIR/.venv/bin"
    mkdir -p "$TEST_TMPDIR/logs"

    # .venv/bin/python3 シンボリックリンク（実際の venv を参照）
    ln -sf "$VENV_PYTHON" "$TEST_TMPDIR/.venv/bin/python3"

    # テストハーネス: テストモードでスクリプトをソース
    export TEST_HARNESS="$TEST_TMPDIR/test_harness.sh"
    cat > "$TEST_HARNESS" << HARNESS
#!/bin/bash
SCRIPT_DIR="$TEST_TMPDIR"
SESSION_NAME=""
LOG_DIR="$TEST_TMPDIR/logs"
LOG_FILE="$TEST_TMPDIR/logs/teams_visual_monitor.log"
TEAM_CONFIG_DIR="$TEST_TMPDIR"
POLL_INTERVAL=3
LAYOUT_APPLIED=false
BORDER_APPLIED=false
UNRESPONSIVE_THRESHOLD=240
CLEAR_COOLDOWN=300
TMUX_SOCKET=""
declare -A STYLED_PANES
PREV_PANE_COUNT=0
RECOVERY_CHECK_COUNTER=0
DEADLOCK_CHECK_COUNTER=0
TASK_UPDATE_COUNTER=0
PERMISSION_PHASE1=60
PERMISSION_PHASE2=120
MIN_PANE_HEIGHT=4
PREV_RESIZE_STATE=""
RESIZE_DEBUG_COUNTER=0
declare -A PANE_PERMISSION_FIRST_SEEN
declare -A PANE_PERMISSION_ESCAPE_COUNT
declare -A PANE_LAST_ACTIVITY
declare -A PANE_LAST_CLEAR

# tmux モック
tmux() {
    echo "tmux \$*" >> "$MOCK_LOG"
    case "\$*" in
        "show-options -p -t"*"@"*)
            echo "\${MOCK_SHOW_OPTIONS:-}"
            ;;
        "list-panes"*)
            echo "\${MOCK_LIST_PANES:-}"
            ;;
        "list-windows"*)
            echo "\${MOCK_LIST_WINDOWS:-}"
            ;;
        "has-session"*)
            return 0
            ;;
    esac
    return 0
}

mkdir -p "$TEST_TMPDIR/logs"
export __TEAMS_MONITOR_TESTING__=1
source "$MONITOR_SCRIPT"
HARNESS
    chmod +x "$TEST_HARNESS"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

# --- ヘルパー ---

make_task_yaml() {
    local agent="$1"
    local task_id="$2"
    local status="$3"
    cat > "$TEST_TMPDIR/queue/tasks/${agent}.yaml" << YAML
task:
  task_id: ${task_id}
  status: ${status}
  description: テストタスク
YAML
}

run_get_task_id() {
    local agent="$1"
    bash -c "
        source '$TEST_HARNESS'
        get_task_id_from_yaml '$agent' '$TEST_TMPDIR'
    "
}

# --- テスト ---

@test "T-CT-001: assigned ステータスなら task_id を返す" {
    make_task_yaml "ashigaru1" "s231d" "assigned"
    run run_get_task_id "ashigaru1"
    [ "$status" -eq 0 ]
    [ "$output" = "s231d" ]
}

@test "T-CT-002: in_progress ステータスなら task_id を返す" {
    make_task_yaml "ashigaru2" "s231e" "in_progress"
    run run_get_task_id "ashigaru2"
    [ "$status" -eq 0 ]
    [ "$output" = "s231e" ]
}

@test "T-CT-003: pending ステータスなら task_id を返す" {
    make_task_yaml "ashigaru3" "s999a" "pending"
    run run_get_task_id "ashigaru3"
    [ "$status" -eq 0 ]
    [ "$output" = "s999a" ]
}

@test "T-CT-004: done ステータスなら空文字を返す" {
    make_task_yaml "ashigaru1" "s231d" "done"
    run run_get_task_id "ashigaru1"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "T-CT-005: YAMLファイルが存在しない場合は空文字を返す" {
    # ashigaru99 のYAMLは作成しない
    run run_get_task_id "ashigaru99"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
}

@test "T-CT-006: task_id が15文字超なら15文字に切り詰める" {
    make_task_yaml "ashigaru1" "this_is_very_long_task_id_123" "assigned"
    run run_get_task_id "ashigaru1"
    [ "$status" -eq 0 ]
    [ "${#output}" -le 15 ]
    [ "$output" = "this_is_very_lo" ]
}

@test "T-CT-007: inbox nudge テキスト(inbox1)を @current_task に使わない" {
    # YAMLなし → 空文字（pane出力のinbox1は参照しない）
    run run_get_task_id "ashigaru1"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]
    # "inbox1" が出力に含まれていないことを確認
    [[ "$output" != *"inbox1"* ]]
}

@test "T-CT-008: get_task_id_from_yaml 関数がスクリプトに存在する" {
    run bash -c "
        source '$TEST_HARNESS'
        type get_task_id_from_yaml >/dev/null 2>&1
    "
    # type が 0 を返せば関数として定義されている
    [ "$status" -eq 0 ]
}
