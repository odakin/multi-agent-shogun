# Philosophy

> "Don't execute tasks mindlessly. Always keep 'fastest × best output' in mind."

## Architecture v4.0 — ダンベル型知能配分

### The Dumbbell Architecture (ダンベル型)

```
  Smart (Opus)          Dumb (Haiku/Sonnet)          Smart (Opus)
  ┌──────────┐          ┌────────────────┐           ┌──────────┐
  │  Shogun   │ ───────→ │ Karo → Ashigaru│ ────────→ │  Gunshi   │
  │ Entry Brain│ phases  │ Dispatch→Execute│  report   │ Exit Brain│
  └──────────┘          └────────────────┘           └──────────┘
```

Intelligence is concentrated at the **entry point** (Shogun) and the **exit point** (Gunshi). Everything in between is mechanical. This is the "Dumbbell Architecture" — smart at both ends, dumb in the middle.

**Why?** Because:
1. Planning (decomposition, parallelization) requires deep understanding → Opus
2. Quality judgment (QC, integration review) requires deep understanding → Opus
3. Dispatching (matching tasks to workers) is mechanical → Haiku/Sonnet
4. Execution (writing code, running commands) is directed work → Sonnet

### Intelligence Allocation

| Role | Model | Speed | Thinks About | Does NOT Think About |
|------|-------|-------|-------------|---------------------|
| **Shogun** | Opus | Slow | Goal decomposition, phase design, parallelization, acceptance criteria | Technical approach, code structure, API selection |
| **Karo** | Haiku | Fast | Available workers, phase progression | Task decomposition, parallelization strategy, quality |
| **Ashigaru** | Sonnet | Fast | Implementation details, technical approach | Strategy, management, quality assurance |
| **Gunshi** | Opus | Slow | Quality assessment, integration review, cmd completion | Task management, dispatching, implementation |

### Key Design Principle: S001 v4.0

The Shogun decides **WHAT** (goals) and **WHEN/WHICH** (phases, parallel groups), but NOT **HOW** (technical implementation). This replaced v3.0's rule where the Shogun could only specify WHAT and the Karo had to figure out WHEN/WHICH — which the Karo (being a dumber model) consistently failed at.

## Six Core Principles

### 1. Dumbbell Intelligence (v4.0)

Place intelligence at decision points, not at throughput points. The Shogun (entry) and Gunshi (exit) use expensive Opus for critical thinking. The Karo (dispatch) and Ashigaru (execution) use cheaper, faster models for throughput. No model budget is wasted on mechanical work.

### 2. Phases-First Parallelization (v4.0)

The Shogun writes `phases` in every cmd, explicitly defining what can run in parallel and what must be sequential. The Karo follows this structure mechanically. This replaced the old P001 system where the Karo was expected to design parallelization — a task too complex for a fast, cheap model.

### 3. Research First

Search for evidence before making decisions. Agents don't rely solely on their training data — they actively research using web search, file exploration, and codebase analysis before proposing solutions.

### 4. Continuous Learning

The system uses Memory MCP to persist lessons learned, discovered patterns, and operational insights across sessions. When an agent encounters a problem it has solved before, it checks memory first.

### 5. Triangulation

Multi-perspective research with integrated authorization. Important decisions are validated from multiple sources — not just one search result or one file.

### 6. Mandatory QC Exit Gate (v4.0)

Every cmd has a `mode: qc` phase. The Gunshi (Opus) performs quality checks on all completed work. No cmd is marked done until the Gunshi returns QC PASS. The Gunshi reports directly to the Shogun — not through the Karo — ensuring the quality gate cannot be bypassed.

## Design Decisions

### Why a hierarchy (Shogun → Karo → Ashigaru → Gunshi)?

1. **Instant response**: The Shogun delegates immediately, returning control to you
2. **Parallel execution**: The Karo distributes to multiple Ashigaru simultaneously
3. **Single responsibility**: Each role is clearly separated — no confusion
4. **Scalability**: Adding more Ashigaru doesn't break the structure
5. **Fault isolation**: One Ashigaru failing doesn't affect the others
6. **Unified reporting**: Only the Shogun communicates with you, keeping information organized

### Why Dumbbell, not Pyramid? (v4.0)

In a pyramid (Shogun = smart, Karo = medium, Ashigaru = dumb), the Karo becomes a bottleneck — it's asked to do tasks beyond its model's capability (decomposition, parallelization planning). In the dumbbell, the Karo is explicitly dumb (just dispatch), and all thinking is pushed to the two Opus endpoints.

### Why Shogun decomposes, not Karo? (v4.0)

**Problem**: The Karo (Sonnet/Haiku) consistently failed at task decomposition and parallelization planning. It would assign all work to 1 Ashigaru, miss parallelization opportunities, or create fake parallelism (tasks that depend on each other split across agents).

**Solution**: The Shogun (Opus) handles conceptual decomposition because:
- It receives the Lord's intent directly and understands context best
- Decomposition and parallelization are judgment calls, not mechanical tasks
- The `phases` format makes the Karo's job trivially simple

### Why Gunshi reports to Shogun directly? (v3.1→v4.0)

Previously: Gunshi → Karo → Shogun (Karo relayed completion). This was:
- An unnecessary hop (Karo just forwarded the message)
- A failure point (Karo could forget, compact, or misreport)
- Inconsistent with the dumbbell model (Karo shouldn't make completion judgments)

Now: Gunshi → Shogun (direct). The quality gate (Gunshi) talks directly to the strategic brain (Shogun). The Karo is notified separately but doesn't relay.

### Why Mailbox System?

1. **State persistence**: YAML files provide structured communication that survives agent restarts
2. **No polling needed**: `inotifywait` is event-driven (kernel-level), reducing API costs to zero during idle
3. **No interruptions**: Prevents agents from interrupting each other or your input
4. **Easy debugging**: Humans can read inbox YAML files directly to understand message flow
5. **No conflicts**: `flock` (exclusive lock) prevents concurrent writes
6. **Guaranteed delivery**: File write succeeded = message will be delivered
7. **Nudge-only delivery**: `send-keys` transmits only a short wake-up signal, not full message content

### Why Gunshi updates dashboard.md (v4.0)

Previously the Karo updated dashboard.md. In v4.0:
1. **Gunshi already reads all reports for QC** — it has the full picture
2. **Single writer**: Only the Gunshi writes dashboard.md, preventing conflicts
3. **Quality-aware**: Dashboard reflects QC-verified status, not raw completion
4. **Karo is dumber now**: Dashboard updates require judgment about what to highlight

### Why Skills are not committed to the repo

Skills in `.claude/commands/` are excluded from version control by design:
- Every user's workflow is different
- Rather than imposing generic skills, each user grows their own skill set
- Skills emerge organically during operation — you approve candidates as they're discovered

## Version History

| Version | Date | Key Change |
|---------|------|-----------|
| v1.0 | 2026-02 | Initial hierarchy: Shogun → Karo → Ashigaru |
| v2.0 | 2026-02 | Added Gunshi, mailbox system, dashboard |
| v3.0 | 2026-02 | P001 parallelization enforcement, Karo decomposition |
| v3.1 | 2026-02 | Gunshi QC mandatory, Gunshi → Shogun direct report |
| v4.0 | 2026-03 | Dumbbell architecture: Shogun decomposes (phases), Karo mechanical dispatch |
