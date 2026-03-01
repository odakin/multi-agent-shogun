#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# update_dashboard.sh — dashboard.md 自動生成・更新スクリプト
# ═══════════════════════════════════════════════════════════════════════════════
# YAML報告ファイル群から dashboard.md を生成する。
# Karo / Gunshi が手動更新する設計だが、このスクリプトで初期生成やリカバリも可能。
#
# 使用方法:
#   bash scripts/update_dashboard.sh              # 通常更新
#   bash scripts/update_dashboard.sh --watch      # inotifywait で自動更新
#   bash scripts/update_dashboard.sh --init       # 初期テンプレート生成
# ═══════════════════════════════════════════════════════════════════════════════

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
DASHBOARD="$ROOT_DIR/dashboard.md"
TASKS_DIR="$ROOT_DIR/queue/tasks"
REPORTS_DIR="$ROOT_DIR/queue/reports"
CMD_QUEUE="$ROOT_DIR/queue/cmds"
STREAKS_FILE="$ROOT_DIR/saytask/streaks.yaml"

# ─── ヘルパー関数 ───

timestamp() {
    date "+%Y-%m-%d %H:%M"
}

# YAML から値を抽出（簡易パーサー）
yaml_get() {
    local file="$1" key="$2"
    grep "^${key}:" "$file" 2>/dev/null | head -1 | sed "s/^${key}:[[:space:]]*//" | sed 's/^"//' | sed 's/"$//' || echo ""
}

# タスクファイルをスキャンしてステータス集計
count_tasks_by_status() {
    local status="$1"
    local count=0
    for f in "$TASKS_DIR"/ashigaru*.yaml "$TASKS_DIR"/gunshi.yaml; do
        [ -f "$f" ] || continue
        if grep -q "^status:[[:space:]]*${status}" "$f" 2>/dev/null; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# レポートファイルから完了タスク一覧を生成
collect_completed_reports() {
    local has_entries=false
    for f in "$REPORTS_DIR"/ashigaru*_report.yaml; do
        [ -f "$f" ] || continue
        local worker task_id status result timestamp_val
        worker=$(yaml_get "$f" "worker_id")
        task_id=$(yaml_get "$f" "task_id")
        status=$(yaml_get "$f" "status")
        result=$(yaml_get "$f" "result")
        timestamp_val=$(yaml_get "$f" "timestamp")
        # idle や null タスクはスキップ
        [ "$status" = "idle" ] && continue
        [ -z "$task_id" ] || [ "$task_id" = "null" ] && continue
        has_entries=true
        echo "| ${timestamp_val:-???} | ${worker:-???} | ${task_id} | ${status:-???} | ${result:-（報告なし）} |"
    done
    if [ "$has_entries" = false ]; then
        echo "| — | — | — | — | （戦果なし） |"
    fi
}

# 現在の割当状況を表示
collect_active_tasks() {
    local has_active=false
    for f in "$TASKS_DIR"/ashigaru*.yaml; do
        [ -f "$f" ] || continue
        local worker task_id status description
        worker=$(basename "$f" .yaml)
        task_id=$(yaml_get "$f" "task_id")
        status=$(yaml_get "$f" "status")
        description=$(yaml_get "$f" "description")
        # idle で未割当はスキップ
        if [ "$status" = "idle" ] && { [ -z "$task_id" ] || [ "$task_id" = "null" ]; }; then
            continue
        fi
        has_active=true
        echo "| ${worker} | ${task_id:-（未割当）} | ${status:-idle} | ${description:-—} |"
    done
    if [ "$has_active" = false ]; then
        echo "| — | — | — | 全足軽待機中 |"
    fi
}

# Gunshi の状態
gunshi_status() {
    local f="$TASKS_DIR/gunshi.yaml"
    [ -f "$f" ] || { echo "（未配置）"; return; }
    local task_id status
    task_id=$(yaml_get "$f" "task_id")
    status=$(yaml_get "$f" "status")
    if [ -z "$task_id" ] || [ "$status" = "idle" ]; then
        echo "待機中"
    else
        echo "${status}: ${task_id}"
    fi
}

# Frog / ストリーク情報
frog_section() {
    if [ ! -f "$STREAKS_FILE" ]; then
        cat <<'FROG'
| 項目 | 値 |
|------|-----|
| 今日のFrog | （未設定） |
| Frog状態 | — |
| ストリーク | — |
| 今日の完了 | — |
FROG
        return
    fi

    local frog current longest completed total
    frog=$(yaml_get "$STREAKS_FILE" "  frog" 2>/dev/null || echo "")
    current=$(grep "current:" "$STREAKS_FILE" 2>/dev/null | head -1 | awk '{print $2}' || echo "0")
    longest=$(grep "longest:" "$STREAKS_FILE" 2>/dev/null | head -1 | awk '{print $2}' || echo "0")
    completed=$(grep "completed:" "$STREAKS_FILE" 2>/dev/null | head -1 | awk '{print $2}' || echo "0")
    total=$(grep "total:" "$STREAKS_FILE" 2>/dev/null | head -1 | awk '{print $2}' || echo "0")

    local frog_status
    if [ -z "$frog" ] || [ "$frog" = "null" ] || [ "$frog" = '""' ]; then
        frog_status="🐸✅ 撃破済み"
        frog="（なし）"
    else
        frog_status="🐸 未撃破"
    fi

    cat <<FROG
| 項目 | 値 |
|------|-----|
| 今日のFrog | ${frog} |
| Frog状態 | ${frog_status} |
| ストリーク | 🔥 ${current}日目 (最長: ${longest}日) |
| 今日の完了 | ${completed}/${total} |
FROG
}

# 現在のコマンド（将軍からの指令 — per-cmd files）
current_cmd() {
    if [ ! -d "$CMD_QUEUE" ]; then
        echo "（指令なし）"
        return
    fi
    local output=""
    for f in "$CMD_QUEUE"/*.yaml; do
        [ -f "$f" ] || continue
        local cmd_id purpose cmd_status
        cmd_id=$(yaml_get "$f" "id")
        purpose=$(yaml_get "$f" "purpose")
        cmd_status=$(yaml_get "$f" "status")
        if [ -n "$output" ]; then output="$output / "; fi
        output="${output}${cmd_id:-???}: ${purpose:-???} [${cmd_status:-???}]"
    done
    echo "${output:-（指令なし）}"
}

# ─── ダッシュボード生成 ───

generate_dashboard() {
    local now
    now=$(timestamp)

    local in_progress assigned completed blocked idle
    in_progress=$(count_tasks_by_status "in_progress")
    assigned=$(count_tasks_by_status "assigned")
    completed=$(count_tasks_by_status "completed")
    blocked=$(count_tasks_by_status "blocked")
    idle=$(count_tasks_by_status "idle")

    cat > "$DASHBOARD" <<DASHBOARD
# 🏯 戦況報告 — dashboard.md
> 最終更新: ${now}
> 更新者: scripts/update_dashboard.sh

## 🐸 Frog / ストリーク

$(frog_section)

## 📋 現在の指令

$(current_cmd)

## ⚔️ 進行中

| 足軽 | タスクID | 状態 | 内容 |
|------|---------|------|------|
$(collect_active_tasks)

**集計**: 実行中 ${in_progress} / 割当済 ${assigned} / 完了 ${completed} / ブロック ${blocked} / 待機 ${idle}

**軍師**: $(gunshi_status)

## 🏆 戦果

| 時刻 | 実行者 | タスクID | 結果 | 詳細 |
|------|--------|---------|------|------|
$(collect_completed_reports)

## 🚨 要対応

（なし）

## 💡 スキル化候補

（なし）

---
*YAML files are ground truth. This dashboard is secondary.*
DASHBOARD

    echo "[$(timestamp)] dashboard.md 更新完了" >&2
}

# ─── Watch モード ───

watch_mode() {
    echo "dashboard.md 自動更新モード開始（Ctrl+C で終了）" >&2
    generate_dashboard

    # macOS: fswatch, Linux: inotifywait
    if command -v fswatch &>/dev/null; then
        fswatch -r "$TASKS_DIR" "$REPORTS_DIR" "$CMD_QUEUE" 2>/dev/null | while read -r _; do
            sleep 1  # デバウンス
            generate_dashboard
        done
    elif command -v inotifywait &>/dev/null; then
        while true; do
            inotifywait -r -e modify,create,delete "$TASKS_DIR" "$REPORTS_DIR" "$CMD_QUEUE" 2>/dev/null
            sleep 1
            generate_dashboard
        done
    else
        echo "警告: fswatch / inotifywait が見つかりません。5秒ポーリングにフォールバック。" >&2
        while true; do
            sleep 5
            generate_dashboard
        done
    fi
}

# ─── メイン ───

case "${1:-}" in
    --watch)
        watch_mode
        ;;
    --init)
        generate_dashboard
        echo "dashboard.md を初期生成しました。" >&2
        ;;
    --help|-h)
        echo "使用方法: bash scripts/update_dashboard.sh [--watch|--init|--help]"
        echo "  (引数なし)  一回だけ dashboard.md を更新"
        echo "  --watch     ファイル変更を監視して自動更新"
        echo "  --init      初期テンプレートを生成"
        ;;
    *)
        generate_dashboard
        ;;
esac
