# Changelog

## v3.5 — Dynamic Model Routing

> **Right model for the right task — without restarting any agent.** Sonnet 4.6 closes the gap with Opus to just 1.2pp on SWE-bench (79.6% vs 80.8%), making per-task model routing practical and cost-effective for the first time.

- **Bloom Dynamic Model Routing** — `capability_tiers` in `config/settings.yaml` maps each model to its Bloom ceiling. L1–L3 → Spark (1000+ tok/s), L4 → Sonnet 4.6, L5 → Sonnet 4.6 + extended thinking, L6 → Opus (genuinely novel design only). Routing happens without agent restarts — the system finds the right idle agent by model capability
- **Sonnet 4.6 as the new standard** — SWE-bench 79.6%, only 1.2pp below Opus 4.6. Gunshi downgraded Opus → Sonnet 4.6. All Ashigaru default to Sonnet 4.6. One YAML line change, no restarts required
- **`/shogun-model-list` skill** — Complete reference table: all CLI tools × models × subscriptions × Bloom max level. Updated for Sonnet 4.6 and Spark positioning
- **`/shogun-bloom-config` skill** — Interactive configurator: answer 2 questions about your subscriptions → get ready-to-paste `capability_tiers` YAML

## v3.4 — Bloom→Agent Routing, E2E Tests, Stop Hook

- **Bloom → Agent routing** — Replaced dynamic model switching with agent-level routing. L1–L3 tasks go to Ashigaru, L4–L6 tasks go to Gunshi. No more mid-session `/model opus` promotions
- **Gunshi (軍師) as first-class agent** — Strategic advisor on pane 8. Handles deep analysis, design review, architecture evaluation, and complex QC
- **E2E test suite (19 tests, 7 scenarios)** — Mock CLI framework simulates agent behavior in isolated tmux sessions
- **Stop hook inbox delivery** — Claude Code agents automatically check inbox at turn end via `.claude/settings.json` Stop hook. Eliminates the `send-keys` interruption problem
- **Model defaults updated** — Karo: Opus → Sonnet. Gunshi: Opus (deep reasoning). Ashigaru: Sonnet (uniform tier)
- **Escape escalation disabled for Claude Code** — Phase 2 escalation was interrupting active Claude Code turns; Stop hook handles delivery instead
- **Codex CLI startup prompt** — `get_startup_prompt()` in `cli_adapter.sh` passes initial `[PROMPT]` argument to Codex CLI launch
- **YAML slimming utility** — `scripts/slim_yaml.sh` archives read messages and completed commands

## v3.3.2 — GPT-5.3-Codex-Spark Support

> **New model, same YAML.** Add `model: gpt-5.3-codex-spark` to any Codex agent in `settings.yaml`.

- **Codex `--model` flag support** — `build_cli_command()` now passes `settings.yaml` model config to the Codex CLI via `--model`. Supports `gpt-5.3-codex-spark` and any future Codex models
- **Separate rate limit** — Spark runs on its own rate limit quota, independent of GPT-5.3-Codex. Run both models in parallel across different Ashigaru to **double your effective throughput**
- **Startup display** — `shutsujin_departure.sh` now shows the actual model name (e.g., `codex/gpt-5.3-codex-spark`) instead of the generic effort level

## v3.0 — Multi-CLI

> **Shogun is no longer Claude-only.** Mix and match 4 AI coding CLIs in a single army.

- **Multi-CLI as first-class architecture** — `lib/cli_adapter.sh` dynamically selects CLI per agent. Change one line in `settings.yaml` to swap any worker between Claude Code, Codex, Copilot, or Kimi
- **OpenAI Codex CLI integration** — GPT-5.3-codex with `--dangerously-bypass-approvals-and-sandbox` for true autonomous execution. `--no-alt-screen` makes agent activity visible in tmux
- **CLI bypass flag discovery** — `--full-auto` is NOT fully automatic (it's `-a on-request`). Documented the correct flags for all 4 CLIs
- **Hybrid architecture** — Command layer (Shogun + Karo) stays on Claude Code for Memory MCP and mailbox integration. Worker layer (Ashigaru) is CLI-agnostic
- **Community-contributed CLI adapters** — Thanks to [@yuto-ts](https://github.com/yuto-ts) (cli_adapter.sh), [@circlemouth](https://github.com/circlemouth) (Codex support), [@koba6316](https://github.com/koba6316) (task routing)

## v2.0

- **ntfy bidirectional communication** — Send commands from your phone, receive push notifications for task completion
- **SayTask notifications** — Streak tracking, Eat the Frog, behavioral psychology-driven motivation
- **Pane border task display** — See each agent's current task at a glance on the tmux pane border
- **Shout mode** (default) — Ashigaru shout personalized battle cries after completing tasks. Disable with `--silent`
- **Agent self-watch + escalation (v3.2)** — Each agent monitors its own inbox file with `inotifywait` (zero-polling, instant wake-up). Fallback: `tmux send-keys` short nudge (text/Enter sent separately for Codex CLI). 3-phase escalation: standard nudge (0-2min) → Escape×2+nudge (2-4min) → `/clear` force reset (4min+). Linux FS symlink resolves WSL2 9P inotify issues.
- **Agent self-identification** (`@agent_id`) — Stable identity via tmux user options, immune to pane reordering
- **Battle mode** (`-k` flag) — All-Opus formation for maximum capability
- **Task dependency system** (`blockedBy`) — Automatic unblocking of dependent tasks
