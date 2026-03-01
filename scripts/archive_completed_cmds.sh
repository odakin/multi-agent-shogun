#!/usr/bin/env bash
# archive_completed_cmds.sh — cmd_225 Phase 1a
# アーカイブ対象(done/done_ng/stalled/qc_pass)を queue/archive/cmds_YYYYMMDD.yaml に移動
# Usage: bash scripts/archive_completed_cmds.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
QUEUE_FILE="$REPO_ROOT/queue/shogun_to_karo.yaml"
ARCHIVE_DIR="$REPO_ROOT/queue/archive"
TODAY="$(date +%Y%m%d)"
ARCHIVE_FILE="$ARCHIVE_DIR/cmds_${TODAY}.yaml"
LOCK_FILE="$QUEUE_FILE.lock"
DRY_RUN=false

# --- 引数解析 ---
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    *) echo "Unknown argument: $arg" >&2; exit 1 ;;
  esac
done

# --- ディレクトリ確認 ---
mkdir -p "$ARCHIVE_DIR"

# --- flock でクリティカルセクション ---
(
  flock -x 200

  # バックアップ（dry-run でも作成しない）
  if [ "$DRY_RUN" = false ]; then
    BACKUP_FILE="$ARCHIVE_DIR/backup_$(date +%Y%m%d_%H%M%S).yaml"
    cp "$QUEUE_FILE" "$BACKUP_FILE"
    echo "[INFO] Backup created: $BACKUP_FILE"
  fi

  # --- awk でブロック分割 → 分類 ---
  # アーカイブ対象のステータス
  ARCHIVE_STATUSES="done|done_ng|stalled|qc_pass"

  # ブロックを分割し、各ブロックをステータスで分類
  awk -v archive_pat="$ARCHIVE_STATUSES" -v dry_run="$DRY_RUN" \
      -v archive_file="$ARCHIVE_FILE" \
      -v queue_file="$QUEUE_FILE" \
  '
  BEGIN {
    block = ""
    archive_count = 0
    active_count = 0
  }

  /^- id: cmd_/ {
    # 前ブロックを処理
    if (block != "") {
      process_block(block)
    }
    block = $0 "\n"
    next
  }

  {
    block = block $0 "\n"
  }

  END {
    if (block != "") {
      process_block(block)
    }
    print archive_count " cmd(s) to archive, " active_count " cmd(s) to keep" > "/dev/stderr"
  }

  function process_block(b,    status, cmd_id) {
    # status 抽出（"  status: xxx" 形式）
    status = ""
    cmd_id = ""
    n = split(b, lines, "\n")
    for (i = 1; i <= n; i++) {
      if (lines[i] ~ /^  status: /) {
        status = lines[i]
        sub(/^  status: /, "", status)
        gsub(/^[ \t]+|[ \t]+$/, "", status)
      }
      if (lines[i] ~ /^- id: cmd_/) {
        cmd_id = lines[i]
        sub(/^- id: /, "", cmd_id)
        gsub(/^[ \t]+|[ \t]+$/, "", cmd_id)
      }
    }

    if (status ~ "^(" archive_pat ")$") {
      # アーカイブ対象
      archive_count++
      if (dry_run == "true") {
        print "[DRY-RUN] ARCHIVE: " cmd_id " (status=" status ")"
      } else {
        # archive_file に追記
        print b >> archive_file
      }
    } else {
      # アクティブ → active_blocks に蓄積
      active_count++
      if (dry_run != "true") {
        print b >> (queue_file ".new")
      }
    }
  }
  ' "$QUEUE_FILE"

  if [ "$DRY_RUN" = false ]; then
    # 新しいキューファイルで置き換え
    if [ -f "${QUEUE_FILE}.new" ]; then
      mv "${QUEUE_FILE}.new" "$QUEUE_FILE"
      echo "[INFO] Queue updated: $QUEUE_FILE"
      echo "[INFO] Archive: $ARCHIVE_FILE"
    else
      echo "[WARN] No active cmds found — queue file unchanged"
    fi
  fi

) 200>"$LOCK_FILE"

echo "[DONE] archive_completed_cmds.sh finished (dry-run=$DRY_RUN)"
