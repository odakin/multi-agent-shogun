# Task Flow — v4.0 ダンベル型アーキテクチャ

## Workflow: Shogun(decompose) → Karo(dispatch) → Ashigaru(execute) → Gunshi(QC exit gate)

```
Lord: command
  → Shogun(Opus): 分解 + phases設計 → queue/cmds/cmd_XXX.yaml → inbox_write karo
  → Karo(Haiku): 機械的配分 → task YAML → inbox_write ashigaru{N}
  → Ashigaru(Sonnet): execute → report YAML → inbox_write gunshi + karo("空き"のみ)
  → Gunshi(Opus): ★QC(mandatory)★ → PASS → dashboard更新
    → QC FAIL → karo にredo通知
    → 全サブタスクQC PASS → 将軍に直接 cmd完了報告
  → Shogun: 軍師報告受領 → 大殿様に奏上
```

### 知能配分（ダンベル型）
```
  賢い(Opus)         馬鹿(Haiku/Sonnet)         賢い(Opus)
  ┌────────┐         ┌──────────────┐          ┌────────┐
  │ 将軍    │ ──────→ │ 家老 → 足軽  │ ──────→  │ 軍師    │
  │ 入口の脳│  phases │ 配達 → 実行  │  report  │ 出口の脳│
  └────────┘         └──────────────┘          └────────┘
```

## Status Reference (Single Source)

Status is defined per YAML file type. **Keep it minimal. Simple is best.**

Fixed status set (do not add casually):
- `queue/cmds/cmd_XXX.yaml`: `pending`, `in_progress`, `done`, `cancelled`
- `queue/tasks/ashigaruN.yaml`: `assigned`, `blocked`, `done`, `failed`
- `queue/tasks/pending.yaml`: `pending_blocked`
- `queue/ntfy_inbox.yaml`: `pending`, `processed`

Do NOT invent new status values without updating this section.

### Command Queue: `queue/cmds/cmd_XXX.yaml` (per-cmd files)

Meanings and allowed/forbidden actions (short):

- `pending`: not acknowledged yet
  - Allowed: Karo reads and immediately ACKs (`pending → in_progress`)
  - Forbidden: dispatching subtasks while still `pending`

- `in_progress`: acknowledged and being worked
  - Allowed: decompose/dispatch/collect/consolidate
  - Forbidden: moving goalposts (editing acceptance_criteria), or marking `done` without meeting all criteria

- `done`: complete and validated
  - Allowed: read-only (history)
  - Forbidden: editing old cmd to "reopen" (use a new cmd instead)

- `cancelled`: intentionally stopped
  - Allowed: read-only (history)
  - Forbidden: continuing work under this cmd (use a new cmd instead)

**Karo rule (ack fast)**:
- The moment Karo starts processing a cmd (after reading it), update that cmd status:
  - `pending` → `in_progress`
  - This prevents "nobody is working" confusion and stabilizes escalation logic.

### Ashigaru Task File: `queue/tasks/ashigaruN.yaml`

Meanings and allowed/forbidden actions (short):

- `assigned`: start now
  - Allowed: assignee ashigaru executes and updates to `done/failed` + report + inbox_write
  - Forbidden: other agents editing that ashigaru YAML

- `blocked`: do NOT start yet (prereqs missing)
  - Allowed: Karo unblocks by changing to `assigned` when ready, then inbox_write
  - Forbidden: nudging or starting work while `blocked`
  - **Anti-fake-parallelism**: If a task is `blocked` because it depends on another ashigaru's in-progress work, it is a mis-assignment. Dependent tasks should be assigned to the same ashigaru as their prerequisite. `blocked` status is reserved for genuine cross-agent timing constraints (e.g., "deploy after all modules built").

- `done`: completed
  - Allowed: read-only; used for consolidation
  - Forbidden: reusing task_id for redo (use redo protocol)

- `failed`: failed with reason
  - Allowed: report must include reason + unblock suggestion
  - Forbidden: silent failure

Note:
- Normally, "idle" is a UI state (no active task), not a YAML status value.
- Exception (placeholder only): `status: idle` is allowed **only** when `task_id: null` (clean start template written by `shutsujin_departure.sh --clean`).
  - In that state, the file is a placeholder and should be treated as "no task assigned yet".

### Pending Tasks (Karo-managed): `queue/tasks/pending.yaml`

- `pending_blocked`: holding area; **must not** be assigned yet
  - Allowed: Karo moves it to an `ashigaruN.yaml` as `assigned` after prerequisites complete
  - Forbidden: pre-assigning to ashigaru before ready

### NTFY Inbox (Lord phone): `queue/ntfy_inbox.yaml`

- `pending`: needs processing
  - Allowed: Shogun processes and sets `processed`
  - Forbidden: leaving it pending without reason

- `processed`: processed; keep record
  - Allowed: read-only
  - Forbidden: flipping back to pending without creating a new entry

## Immediate Delegation Principle (Shogun)

**Delegate to Karo immediately and end your turn** so the Lord can input next command.

```
Lord: command → Shogun: write YAML → inbox_write → END TURN
                                        ↓
                                  Lord: can input next
                                        ↓
                              Karo/Ashigaru: work in background
                                        ↓
                              dashboard.md updated as report
```

## Event-Driven Wait Pattern (Karo)

**After dispatching all subtasks: STOP.** Do not launch background monitors or sleep loops.

```
Step 7: Dispatch cmd_N subtasks → inbox_write to ashigaru
Step 8: check_pending → if pending cmd_N+1, process it → then STOP
  → Karo becomes idle (prompt waiting)
Step 9: Ashigaru completes → inbox_write karo → watcher nudges karo
  → Karo wakes, scans reports, acts
```

**Why no background monitor**: inbox_watcher.sh detects ashigaru's inbox_write to karo and sends a nudge. This is true event-driven. No sleep, no polling, no CPU waste.

**Karo wakes via**: inbox nudge from ashigaru report, shogun new cmd, or system event. Nothing else.

## "Wake = Full Scan" Pattern (All Agents, Checkpoint-Enhanced)

Claude Code cannot "wait". Prompt-wait = stopped.
**After auto-compact, all in-context state is lost.** Recovery MUST use persistent files.

### Universal Rule: Every Agent, Every Wakeup

**All agents** (Karo, Ashigaru, Gunshi) MUST self-recover on every wakeup (including post-compact).
No agent may assume a nudge will tell them what to do. **File state is ground truth.**

### Karo: On Every Wakeup (including post-compact) — v4.0

1. **Read cmd queue** `queue/cmds/*.yaml` → find `in_progress` / `pending` cmd files
2. **Check phases**: 現在の cmd の phases を読み、未完了フェーズを特定
3. **Scan task YAMLs** `queue/tasks/ashigaru*.yaml` → 各足軽の status 確認（空き検出）
4. **Dispatch**: 現在フェーズの未発令 subtask を空き足軽に割当
5. **Phase advance**: フェーズ内全 subtask 完了 → 次フェーズ → mode: qc なら軍師派遣
6. If no work to do → stop (await next inbox wakeup)

**v4.0 簡素化**: checkpoint は不要（phases が状態を持つ）。将軍が分解済みなので家老は配分のみ。

### Ashigaru: On Every Wakeup (including post-compact)

1. **Identify self**: `tmux display-message -p '#{@agent_id}'` → know your ID (e.g. ashigaru3)
2. **Read task YAML**: `queue/tasks/{my_id}.yaml` → your assigned task (task_id, description, status)
3. **Read inbox**: `queue/inbox/{my_id}.yaml` → any unread messages, mark `read: true`
4. **Decision**:
   - Task status = `assigned` → **execute it** (the task YAML IS your checkpoint)
   - Task status = `done` and you wrote it → **idle** (wait for next assignment)
   - No task or status = `idle` → **idle**
5. Task YAML `description` contains ALL info needed. No prior context required.

### Gunshi: On Every Wakeup (including post-compact)

1. **Identify self**: `tmux display-message -p '#{@agent_id}'` → confirm "gunshi"
2. **Read task YAML**: `queue/tasks/gunshi.yaml` → your assigned QC/analysis task
3. **Read inbox**: `queue/inbox/gunshi.yaml` → any unread messages, mark `read: true`
4. **Decision**:
   - Task status = `assigned` → **execute QC/analysis**
   - Task status = `done` → **idle**
   - No task → **idle**

**Key rule**: Do NOT wait for nudges to discover completed work. **Proactively scan files.** Nudges are a performance optimization, not a correctness requirement.

### Why Checkpoint + Scan (ARIES Pattern)

```
Checkpoint alone: fast but can be stale (agent crashed between action and checkpoint write)
Scan alone: always correct but expensive (16+ file reads, ambiguous states)
Checkpoint + Scan: checkpoint for fast-path, scan for validation → best of both
Ashigaru/Gunshi: task YAML = checkpoint (single file, always accurate)
```

## Report Scanning (Communication Loss Safety)

On every wakeup (regardless of reason), scan ALL `queue/reports/ashigaru*_report.yaml`.
Cross-reference with checkpoint and dashboard.md — process any reports not yet reflected.

**Why**: inbox_write nudges may fail (watcher dead, busy detection false positive). Report files are the **ground truth** — always scannable regardless of nudge delivery.

## Foreground Block Prevention (24-min Freeze Lesson)

**Karo blocking = entire army halts.** On 2026-02-06, foreground `sleep` during delivery checks froze karo for 24 minutes.

**Rule: NEVER use `sleep` in foreground.** After dispatching tasks → stop and wait for inbox wakeup.

| Command Type | Execution Method | Reason |
|-------------|-----------------|--------|
| Read / Write / Edit | Foreground | Completes instantly |
| inbox_write.sh | Foreground | Completes instantly |
| `sleep N` | **FORBIDDEN** | Use inbox event-driven instead |
| tmux capture-pane | **FORBIDDEN** | Read report YAML instead |

### Dispatch-then-Stop Pattern

```
✅ Correct (event-driven):
  cmd_008 dispatch → inbox_write ashigaru → stop (await inbox wakeup)
  → ashigaru completes → inbox_write karo → karo wakes → process report

❌ Wrong (polling):
  cmd_008 dispatch → sleep 30 → capture-pane → check status → sleep 30 ...
```

## Timestamps

**Always use `date` command.** Never guess.
```bash
date "+%Y-%m-%d %H:%M"       # For dashboard.md
date "+%Y-%m-%dT%H:%M:%S"    # For YAML (ISO 8601)
```

## Pre-Commit Gate (CI-Aligned)

Rule:
- Run the same checks as GitHub Actions *before* committing.
- Only commit when checks are OK.
- Ask the Lord before any `git push`.

Minimum local checks:
```bash
# Unit tests (same as CI)
bats tests/*.bats tests/unit/*.bats

# Instruction generation must be in sync (same as CI "Build Instructions Check")
bash scripts/build_instructions.sh
git diff --exit-code instructions/generated/
```
