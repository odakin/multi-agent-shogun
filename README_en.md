<div align="center">

# multi-agent-shogun

**Command your AI army like a feudal warlord.**

Run 10 AI coding agents in parallel — **Claude Code, OpenAI Codex, GitHub Copilot, Kimi Code** — orchestrated through a samurai-inspired hierarchy with zero coordination overhead.

**Talk Coding, not Vibe Coding. Speak to your phone, AI executes.**

[![GitHub Stars](https://img.shields.io/github/stars/yohey-w/multi-agent-shogun?style=social)](https://github.com/yohey-w/multi-agent-shogun)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v3.5 Dynamic Model Routing](https://img.shields.io/badge/v3.5-Dynamic_Model_Routing-ff6600?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHRleHQgeD0iMCIgeT0iMTIiIGZvbnQtc2l6ZT0iMTIiPuKalTwvdGV4dD48L3N2Zz4=)](https://github.com/yohey-w/multi-agent-shogun)
[![Shell](https://img.shields.io/badge/Shell%2FBash-100%25-green)]()

**English** | [日本語](README.md)

</div>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="Latest translucent command session in the Shogun pane" width="940">
</p>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260208-084602.png" alt="Quick natural-language command in the Shogun pane" width="420">
  <img src="images/company-creed-all-panes.png" alt="Karo and Ashigaru panes reacting in parallel" width="520">
</p>

<p align="center"><i>One Karo (manager) coordinating 7 Ashigaru (workers) + 1 Gunshi (strategist) — real session, no mock data.</i></p>

---

## What is this?

**multi-agent-shogun** is a system that runs multiple AI coding CLI instances simultaneously, orchestrating them like a feudal Japanese army. Supports **Claude Code**, **OpenAI Codex**, **GitHub Copilot**, and **Kimi Code**.

**Why use it?**
- One command spawns 7 AI workers + 1 strategist executing in parallel
- Zero wait time — give your next order while tasks run in the background
- AI remembers your preferences across sessions (Memory MCP)
- Real-time progress on a dashboard

```
        You (上様 / The Lord)
             │
             ▼  Give orders
      ┌─────────────┐
      │   SHOGUN    │  ← Receives your command, delegates instantly
      └──────┬──────┘
             │  YAML + tmux
      ┌──────▼──────┐
      │    KARO     │  ← Distributes tasks to workers
      └──────┬──────┘
             │
    ┌─┬─┬─┬─┴─┬─┬─┬─┬────────┐
    │1│2│3│4│5│6│7│ GUNSHI │  ← 7 workers + 1 strategist
    └─┴─┴─┴─┴─┴─┴─┴────────┘
       ASHIGARU      軍師
```

---

## Why Shogun?

Most multi-agent frameworks burn API tokens on coordination. Shogun doesn't.

| | Claude Code `Task` tool | Claude Code Agent Teams | LangGraph | CrewAI | **multi-agent-shogun** |
|---|---|---|---|---|---|
| **Architecture** | Subagents inside one process | Team lead + teammates (JSON mailbox) | Graph-based state machine | Role-based agents | Feudal hierarchy via tmux |
| **Parallelism** | Sequential (one at a time) | Multiple independent sessions | Parallel nodes (v0.2+) | Limited | **Up to 10 agents, scaled to workload** |
| **Coordination cost** | API calls per Task | Token-heavy (each teammate = separate context) | API + infra (Postgres/Redis) | API + CrewAI platform | **Zero** (YAML + tmux) |
| **Multi-CLI** | Claude Code only | Claude Code only | Any LLM API | Any LLM API | **4 CLIs** (Claude/Codex/Copilot/Kimi) |
| **Observability** | Claude logs only | tmux split-panes or in-process | LangSmith integration | OpenTelemetry | **Live tmux panes** + dashboard |
| **Skill discovery** | None | None | None | None | **Bottom-up auto-proposal** |
| **Setup** | Built into Claude Code | Built-in (experimental) | Heavy (infra required) | pip install | Shell scripts |

### What makes this different

**Zero coordination overhead** — Agents talk through YAML files on disk. The only API calls are for actual work, not orchestration.

**No fake parallelism** — The Karo (manager) analyzes task dependencies and only spawns agents for truly independent work. If a task depends on another's output, they're assigned to the same agent. 3 independent tasks = 3 agents, not 7 agents with 4 idle.

**Full transparency** — Every agent runs in a visible tmux pane. Every instruction, report, and decision is a plain YAML file you can read, diff, and version-control. No black boxes.

---

## Why CLI (Not API)?

Most AI coding tools charge per token. Running multiple Opus-grade agents through the API costs **$100+/hour**. CLI subscriptions flip this:

| | API (Per-Token) | CLI (Flat-Rate) |
|---|---|---|
| **Multiple agents × Opus** | ~$100+/hour | ~$200/month |
| **Cost predictability** | Unpredictable spikes | Fixed monthly bill |
| **Usage anxiety** | Every token counts | Unlimited |
| **Experimentation budget** | Constrained | Deploy freely |

**"Use AI recklessly"** — With flat-rate CLI subscriptions, deploy agents without hesitation. The cost is the same whether they work 1 hour or 24 hours. No more choosing between "good enough" and "thorough" — just run more agents when your workload has independent tasks.

### Multi-CLI Support

Shogun isn't locked to one vendor. The system supports 4 CLI tools, each with unique strengths:

| CLI | Key Strength | Default Model |
|-----|-------------|---------------|
| **Claude Code** | Battle-tested tmux integration, Memory MCP, dedicated file tools (Read/Write/Edit/Glob/Grep) | Claude Sonnet 4.6 |
| **OpenAI Codex** | Sandbox execution, JSONL structured output, `codex exec` headless mode, **per-model `--model` flag** | gpt-5.3-codex / **gpt-5.3-codex-spark** |
| **GitHub Copilot** | Built-in GitHub MCP, 4 specialized agents (Explore/Task/Plan/Code-review), `/delegate` to coding agent | Claude Sonnet 4.6 |
| **Kimi Code** | Free tier available, strong multilingual support | Kimi k2 |

A unified instruction build system generates CLI-specific instruction files from shared templates — one source of truth, zero sync drift. See [Architecture](#instruction-build-system) for details.

---

## Bottom-Up Skill Discovery

This is the feature no other framework has.

As Ashigaru execute tasks, they **automatically identify reusable patterns** and propose them as skill candidates. The Karo aggregates these proposals in `dashboard.md`, and you — the Lord — decide what gets promoted to a permanent skill.

```
Ashigaru finishes a task
    ↓
Notices: "I've done this pattern 3 times across different projects"
    ↓
Reports in YAML:  skill_candidate:
                     found: true
                     name: "api-endpoint-scaffold"
                     reason: "Same REST scaffold pattern used in 3 projects"
    ↓
Appears in dashboard.md → You approve → Skill created in .claude/commands/
    ↓
Any agent can now invoke /api-endpoint-scaffold
```

Skills grow organically from real work — not from a predefined template library. Your skill set becomes a reflection of **your** workflow.

---

## Quick Start

### Windows (WSL2)

<table>
<tr>
<td width="60">

**Step 1**

</td>
<td>

📥 **Download the repository**

[Download ZIP](https://github.com/yohey-w/multi-agent-shogun/archive/refs/heads/main.zip) and extract to `C:\tools\multi-agent-shogun`

*Or use git:* `git clone https://github.com/yohey-w/multi-agent-shogun.git C:\tools\multi-agent-shogun`

</td>
</tr>
<tr>
<td>

**Step 2**

</td>
<td>

🖱️ **Run `install.bat`**

Right-click → "Run as Administrator" (if WSL2 is not installed). Sets up WSL2 + Ubuntu automatically.

</td>
</tr>
<tr>
<td>

**Step 3**

</td>
<td>

🐧 **Open Ubuntu and run** (first time only)

```bash
cd /mnt/c/tools/multi-agent-shogun
./first_setup.sh
```

</td>
</tr>
<tr>
<td>

**Step 4**

</td>
<td>

✅ **Deploy!**

```bash
./shutsujin_departure.sh
```

</td>
</tr>
</table>

#### First-time only: Authentication

After `first_setup.sh`, run these commands once to authenticate:

```bash
# 1. Apply PATH changes
source ~/.bashrc

# 2. OAuth login + Bypass Permissions approval (one command)
claude --dangerously-skip-permissions
#    → Browser opens → Log in with Anthropic account → Return to CLI
#    → "Bypass Permissions" prompt appears → Select "Yes, I accept" (↓ to option 2, Enter)
#    → Type /exit to quit
```

This saves credentials to `~/.claude/` — you won't need to do it again.

#### Daily startup

Open an **Ubuntu terminal** (WSL) and run:

```bash
cd /mnt/c/tools/multi-agent-shogun
./shutsujin_departure.sh
```

<details>
<summary>📱 <b>Mobile Access</b> (click to expand)</summary>

Control your AI army from your phone — bed, café, or bathroom.

**Requirements (all free):** [Tailscale](https://tailscale.com/) + SSH + [Termux](https://termux.dev/)

**Setup:**

1. Install Tailscale on both WSL and your phone
2. In WSL: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscaled & && sudo tailscale up --authkey tskey-auth-XXXXXXXXXXXX && sudo service ssh start`
3. In Termux: `pkg update && pkg install openssh && ssh youruser@your-tailscale-ip`
4. `css` to connect to Shogun, `csm` to see all panes

**Disconnect:** Just swipe Termux closed. tmux sessions survive — agents keep working.

**Voice input:** Use your phone's voice keyboard. The Shogun understands natural language, so speech-to-text typos don't matter.

**Even simpler:** With ntfy configured, send commands directly from the ntfy app — no SSH required.

</details>

---

<details>
<summary>🐧 <b>Linux / macOS</b> (click to expand)</summary>

### First-time setup

```bash
# 1. Clone
git clone https://github.com/yohey-w/multi-agent-shogun.git ~/multi-agent-shogun
cd ~/multi-agent-shogun

# 2. Make scripts executable
chmod +x *.sh

# 3. Run first-time setup
./first_setup.sh
```

### Daily startup

```bash
cd ~/multi-agent-shogun
./shutsujin_departure.sh
```

</details>

<details>
<summary>❓ <b>What is WSL2?</b> (click to expand)</summary>

**WSL2 (Windows Subsystem for Linux)** lets you run Linux inside Windows. This system uses `tmux` (a Linux tool) to manage multiple AI agents, so WSL2 is required on Windows.

**Quick install command** (run PowerShell as Administrator):
```powershell
wsl --install
```

Then restart your computer and run `install.bat`.

</details>

<details>
<summary>📋 <b>Script Reference</b> (click to expand)</summary>

| Script | Purpose | When to run |
|--------|---------|-------------|
| `install.bat` | Windows: WSL2 + Ubuntu setup | First time only |
| `first_setup.sh` | Install tmux, Node.js, Claude Code CLI + Memory MCP config | First time only |
| `shutsujin_departure.sh` | Create tmux sessions + launch CLI + load instructions + start ntfy listener | Daily |
| `scripts/switch_cli.sh` | Live switch agent CLI/model (settings.yaml → /exit → relaunch) | As needed |

</details>

<details>
<summary>🔧 <b>Manual Requirements</b> (click to expand)</summary>

| Requirement | Installation | Notes |
|-------------|-------------|-------|
| WSL2 + Ubuntu | `wsl --install` in PowerShell | Windows only |
| Set Ubuntu as default | `wsl --set-default Ubuntu` | Required for scripts to work |
| tmux | `sudo apt install tmux` | Terminal multiplexer |
| Node.js v20+ | `nvm install 20` | Required for MCP servers |
| Claude Code CLI | `curl -fsSL https://claude.ai/install.sh \| bash` | Official Anthropic CLI (native version recommended; npm version deprecated) |

</details>

---

### After Setup

**10 AI agents** are automatically launched:

| Agent | Role | Count |
|-------|------|-------|
| 🏯 Shogun | Supreme commander — receives your orders | 1 |
| 📋 Karo | Manager — distributes tasks, quality checks | 1 |
| ⚔️ Ashigaru | Workers — execute implementation tasks in parallel | 7 |
| 🧠 Gunshi | Strategist — handles analysis, evaluation, and design | 1 |

Two tmux sessions are created:
- `shogun` — connect here to give commands
- `multiagent` — Karo, Ashigaru, and Gunshi running in the background

---

## How It Works

### Step 1: Connect to the Shogun

After running `shutsujin_departure.sh`, all agents automatically load their instructions and are ready.

Open a new terminal and connect:

```bash
tmux attach-session -t shogun
```

### Step 2: Give your first order

The Shogun is already initialized — just give a command:

```
Research the top 5 JavaScript frameworks and create a comparison table
```

The Shogun will:
1. Write the task to a YAML file
2. Notify the Karo (manager)
3. Return control to you immediately — no waiting!

Meanwhile, the Karo distributes tasks to Ashigaru workers for parallel execution.

### Step 3: Check progress

Open `dashboard.md` in your editor for a real-time status view:

```markdown
## In Progress
| Worker | Task | Status |
|--------|------|--------|
| Ashigaru 1 | Research React | Running |
| Ashigaru 2 | Research Vue | Running |
| Ashigaru 3 | Research Angular | Completed |
```

<details>
<summary><b>Real-World Examples</b> (click to expand)</summary>

**Research sprint:**

```
You: "Research the top 5 AI coding assistants and compare them"

What happens:
1. Shogun delegates to Karo
2. Karo assigns:
   - Ashigaru 1: Research GitHub Copilot
   - Ashigaru 2: Research Cursor
   - Ashigaru 3: Research Claude Code
   - Ashigaru 4: Research Codeium
   - Ashigaru 5: Research Amazon CodeWhisperer
3. All 5 research simultaneously
4. Results compiled in dashboard.md
```

**PoC preparation:**

```
You: "Prepare a PoC for the project on this Notion page: [URL]"

What happens:
1. Karo fetches Notion content via MCP
2. Ashigaru 2: Lists items to verify
3. Ashigaru 3: Investigates technical feasibility
4. Ashigaru 4: Drafts a PoC plan
5. All results compiled in dashboard.md — meeting prep done
```

</details>

---

## Architecture

### Process Model

Each agent runs as an **independent CLI process** in a dedicated tmux pane. No shared memory, no in-process coupling — agents communicate exclusively through YAML files on disk.

```
┌──────────────┐    ┌──────────────────────────────────────┐
│  Session:    │    │  Session: multiagent-teams            │
│  shogun-teams│    │  ┌──────┬────────┬────────┐          │
│              │    │  │ KARO │ ASH 1  │ ASH 2  │          │
│  ┌────────┐  │    │  ├──────┼────────┼────────┤          │
│  │ SHOGUN │  │    │  │ ASH 3│ ASH 4  │ ASH 5  │          │
│  └────────┘  │    │  ├──────┼────────┼────────┤          │
│              │    │  │ ASH 6│ ASH 7  │ GUNSHI │          │
└──────────────┘    │  └──────┴────────┴────────┘          │
                    └──────────────────────────────────────┘
Background processes:
  health_checker.sh  ← 1 process, polls all agents every 30s
  ntfy_listener.sh   ← phone notifications (optional)
```

### 3-Layer Message Delivery

Messages are written to YAML files (persistent, atomic). Wake-up signals are delivered through three independent layers — if one fails, the next catches it.

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: inbox_write.sh                          PUSH (instant)│
│                                                                 │
│  Sender writes message to queue/inbox/{target}.yaml via flock,  │
│  then sends a short "you have mail" nudge via tmux send-keys.   │
│  Message content never travels through tmux — only a signal.    │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: Stop Hook (stop_hook_inbox.sh)          TURN-END      │
│                                                                 │
│  When an agent finishes a turn, the Claude Code Stop Hook       │
│  auto-checks the agent's inbox. If unread messages exist,       │
│  it blocks the stop and feeds them back to the agent.           │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: health_checker.sh                       INSURANCE(30s)│
│                                                                 │
│  A single background process polls all agents every 30 seconds. │
│  Detects stuck agents, retries undelivered nudges, and triggers │
│  post-compaction recovery for agents that lost their context.   │
└─────────────────────────────────────────────────────────────────┘
```

**Delivery guarantee**: If `inbox_write.sh` succeeds (flock + atomic file replace), the message is persisted. At least one of the three layers will ensure the target agent processes it.

### Task Lifecycle

```
You give a command
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│ Shogun writes to queue/shogun_to_karo.yaml (pending)    │
│ → Notifies Karo via inbox_write.sh                      │
│ → Returns control to you immediately                    │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Karo marks command in_progress                          │
│ → Decomposes into subtasks (Bloom routing: L1-3→ASH,    │
│   L4-6→GUNSHI)                                          │
│ → Writes queue/tasks/ashigaru{N}.yaml (assigned)        │
│ → Dispatches via inbox_write.sh                         │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Ashigaru/Gunshi execute and write reports to             │
│ queue/reports/ashigaru{N}_report.yaml                   │
│ → Notify Karo via inbox_write.sh                        │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│ Karo collects all reports, updates dashboard.md         │
│ → Marks command done                                    │
│ → Notifies Shogun → You see results                     │
└─────────────────────────────────────────────────────────┘
```

### Post-Compact Recovery

When an agent's context fills up and is compacted (context lost), it recovers automatically:

- **"Wake = Full Scan"** — Every agent, on startup, scans its task YAML + inbox to rebuild state
- **Ashigaru / Gunshi**: Task YAML (`queue/tasks/{id}.yaml`) is the checkpoint — no separate state file needed
- **Karo**: Dedicated checkpoint protocol — scans all report files + dashboard on every wakeup
- **health_checker.sh**: Detects idle agents with assigned tasks and nudges them back to work

### Instruction Build System

A single source of truth generates CLI-specific instruction files for all 4 supported CLIs:

```
instructions/
├── roles/            ← Role definitions (shogun, karo, ashigaru, gunshi)
├── common/           ← Shared rules (protocol, task_flow, forbidden_actions)
└── cli_specific/     ← CLI-specific tool descriptions
         │
         ▼  build_instructions.sh
instructions/generated/
├── shogun.md             ← Claude Code
├── codex-shogun.md       ← Codex
├── copilot-shogun.md     ← Copilot
└── kimi-shogun.md        ← Kimi K2
    (× 4 roles = 16 generated files)
```

Change a rule once, all CLIs get it. Zero sync drift.

### Design Rationale

| Question | Answer |
|----------|--------|
| **Why a hierarchy?** | Instant response (Shogun delegates immediately), parallel execution (Karo distributes), fault isolation (one Ashigaru failing doesn't affect others) |
| **Why file-based mailbox?** | YAML files survive restarts, `flock` prevents race conditions, agents read their own inbox (no content through tmux = no corruption), easy to debug |
| **Why only Karo updates dashboard?** | Single writer prevents conflicts. Karo has the full picture from all reports |
| **Why `@agent_id`?** | Stable identity via tmux user options, immune to pane reordering. Self-identification: `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'` |

> Core principles are documented in detail: **[docs/philosophy.md](docs/philosophy.md)**

---

## Key Features

### ⚡ 1. Parallel Execution

One command spawns up to 8 parallel tasks:

```
You: "Research 5 MCP servers"
→ 5 Ashigaru start researching simultaneously
→ Results in minutes, not hours
```

### 🔄 2. Non-Blocking Workflow

The Shogun delegates instantly and returns control to you. No waiting for long tasks to finish.

```
You: Command → Shogun: Delegates → You: Give next command immediately
                                       ↓
                       Workers: Execute in background
                                       ↓
                       Dashboard: Shows results
```

### 🧠 3. Cross-Session Memory (Memory MCP)

Your AI remembers your preferences:

```
Session 1: Tell it "I prefer simple approaches"
            → Saved to Memory MCP

Session 2: AI loads memory on startup
            → Stops suggesting complex solutions
```

### 📊 4. Agent Status Check

See which agents are busy or idle — instantly:

```bash
bash scripts/agent_status.sh
```

```
Agent      CLI     Pane      Task ID                    Status     Inbox
---------- ------- --------- -------------------------- ---------- -----
karo       claude  待機中    ---                        ---        0
ashigaru1  codex   稼働中    subtask_042a_research      assigned   0
ashigaru2  codex   待機中    subtask_042b_review        done       0
gunshi     claude  稼働中    subtask_042c_analysis      assigned   0
```

Detection works for both **Claude Code** and **Codex CLI** by checking CLI-specific prompt/spinner patterns. Source `lib/agent_status.sh` in your own scripts.

### 📸 5. Screenshot Integration

```yaml
# Set your screenshot folder in config/settings.yaml
screenshot:
  path: "/mnt/c/Users/YourName/Pictures/Screenshots"
```

Tell the Shogun: "Check the latest screenshot" — AI instantly reads and analyzes your screen captures. Press `Win + Shift + S` to take screenshots on Windows.

### 📁 6. Context Management (4-Layer Architecture)

| Layer | Location | Purpose |
|-------|----------|---------|
| Layer 1: Memory MCP | `memory/shogun_memory.jsonl` | Cross-project, cross-session long-term memory |
| Layer 2: Project | `config/projects.yaml`, `context/{project}.md` | Project-specific information and technical knowledge |
| Layer 3: YAML Queue | `queue/shogun_to_karo.yaml`, `queue/tasks/`, `queue/reports/` | Task management — source of truth for instructions and reports |
| Layer 4: Session | CLAUDE.md, instructions/*.md | Working context (wiped by `/clear`) |

**`/clear` Protocol (Cost Optimization):** As agents work, session context (Layer 4) grows. `/clear` wipes session memory and resets costs. Layers 1–3 persist as files, so nothing is lost. Recovery cost: **~6,800 tokens** (42% improved from v1).

### 📱 7. Phone Notifications (ntfy)

Two-way communication between your phone and the Shogun — no SSH, no server needed.

```
📱 You (from bed)          🏯 Shogun
    │                          │
    │  "Research React 19"     │
    ├─────────────────────────►│
    │    (ntfy message)        │  → Delegates to Karo → Ashigaru work
    │                          │
    │  "✅ cmd_042 complete"   │
    │◄─────────────────────────┤
    │    (push notification)   │
```

**Setup:** Add `ntfy_topic: "shogun-yourname"` to `config/settings.yaml`, install the [ntfy app](https://ntfy.sh) on your phone, subscribe to the same topic. Free, no account required.

<p align="center">
  <img src="images/screenshots/masked/ntfy_saytask_rename.jpg" alt="Bidirectional phone communication" width="300">
  &nbsp;&nbsp;
  <img src="images/screenshots/masked/ntfy_cmd043_progress.jpg" alt="Progress notification" width="300">
</p>
<p align="center"><i>Left: Bidirectional phone ↔ Shogun communication · Right: Real-time progress report from Ashigaru</i></p>

> **⚠️ Security:** Your topic name is your password. Choose a hard-to-guess name and **never share it publicly**.

### 🖼️ 8. Pane Border Task Display

Each tmux pane shows the agent's current task directly on its border:

```
┌ ashigaru1 Sonnet+T VF requirements ──┬ ashigaru3 Opus+T API research ──────┐
│                                      │                                     │
│  Working on SayTask requirements     │  Researching REST API patterns      │
├ ashigaru2 Sonnet ───────────────────┼ ashigaru4 Spark DB schema design ───┤
│                                      │                                     │
│  (idle — waiting for assignment)     │  Designing database schema          │
└──────────────────────────────────────┴─────────────────────────────────────┘
```

Display format: `agent_name Model+T task_summary` — `+T` = Extended Thinking enabled.

### 🔊 9. Shout Mode (Battle Cries)

When an Ashigaru completes a task, it shouts a personalized battle cry in the tmux pane:

```
┌ ashigaru1 (Sonnet) ──────────┬ ashigaru2 (Sonnet) ──────────┐
│                               │                               │
│  ⚔️ 足軽1号、先陣切った！     │  🔥 足軽2号、二番槍の意地！   │
│  八刃一志！                   │  八刃一志！                   │
└───────────────────────────────┴───────────────────────────────┘
```

Disable with `./shutsujin_departure.sh --silent` (saves API tokens).

---

## 🗣️ SayTask — Task Management for People Who Hate Task Management

**Just speak to your phone.** Zero UI. Zero typing. Zero app-opening.

- **Target audience**: People who installed Todoist but stopped opening it after 3 days
- Your enemy isn't other apps — it's doing nothing. The competition is inaction

### How it Works

1. Install the [ntfy app](https://ntfy.sh) (free, no account needed)
2. Speak to your phone: *"dentist tomorrow"*, *"invoice due Friday"*
3. AI auto-organizes → morning notification: *"here's your day"*

```
 🗣️ "Buy milk, dentist tomorrow, invoice due Friday"
       │
       ▼
 ┌──────────────────┐
 │  ntfy → Shogun   │  AI auto-categorize, parse dates, set priorities
 └────────┬─────────┘
          │
          ▼
 ┌──────────────────┐
 │   tasks.yaml     │  Structured storage (local, never leaves your machine)
 └────────┬─────────┘
          │
          ▼
 📱 Morning notification:
    "Today: 🐸 Invoice due · 🦷 Dentist 3pm · 🛒 Buy milk"
```

### Use Cases

- 🛏️ **In bed**: *"Gotta submit the report tomorrow"* — captured before you forget
- 🚗 **While driving**: *"Don't forget the estimate for client A"* — hands-free
- 💻 **Mid-work**: *"Oh, need to buy milk"* — dump it instantly and stay in flow
- 🌅 **Wake up**: Today's tasks already waiting in your notifications
- 🐸 **Eat the Frog**: AI picks your hardest task each morning

### FAQ

**Q: How is this different from other task apps?**
A: You never open an app. Just speak. Most task apps fail because people stop opening them. SayTask removes that step entirely.

**Q: What's the Frog 🐸?**
A: Every morning, AI picks your hardest task — the one you'd rather avoid. Tackle it first or ignore it. Your call.

**Q: Is it free?**
A: Everything is free and open-source. ntfy is free too. No account, no server, no subscription.

**Q: Where is my data stored?**
A: Local YAML files on your machine. Nothing is sent to the cloud.

#### SayTask Notifications

Behavioral psychology-driven motivation through your notification feed:

- **Streak tracking**: Consecutive completion days — leverages loss aversion to sustain momentum
- **Eat the Frog** 🐸: The hardest task of the day triggers a special celebration notification
- **Daily progress**: `12/12 tasks today` — visual completion feedback reinforces the Arbeitslust effect

---

## Model Settings

| Agent | Default Model | Thinking | Role |
|-------|--------------|----------|------|
| Shogun | Opus | **Enabled (high)** | Strategic advisor to the Lord. Use `--shogun-no-thinking` for relay-only mode |
| Karo | Sonnet | Enabled | Task distribution, simple QC, dashboard management |
| Gunshi | Opus | Enabled | Deep analysis, design review, architecture evaluation |
| Ashigaru 1–7 | Sonnet 4.6 | Enabled | Implementation: code, research, file operations |

**Thinking control**: Set `thinking: true/false` per agent in `config/settings.yaml`. Pane borders show `+T` suffix when Thinking is enabled.

**Live model switching**: Use `/shogun-model-switch` to change any agent's CLI type, model, or Thinking setting without restarting the entire system.

### Bloom's Taxonomy → Agent Routing

Tasks are classified using Bloom's Taxonomy and routed to the appropriate **agent**:

| Level | Category | Description | Routed To |
|-------|----------|-------------|-----------|
| L1 | Remember | Recall facts, copy, list | **Ashigaru** |
| L2 | Understand | Explain, summarize, paraphrase | **Ashigaru** |
| L3 | Apply | Execute procedures, implement known patterns | **Ashigaru** |
| L4 | Analyze | Compare, investigate, deconstruct | **Gunshi** |
| L5 | Evaluate | Judge, critique, recommend | **Gunshi** |
| L6 | Create | Design, build, synthesize new solutions | **Gunshi** |

### Task Dependencies (blockedBy)

```yaml
# queue/tasks/ashigaru2.yaml
task:
  task_id: subtask_010b
  blockedBy: ["subtask_010a"]  # Waits for ashigaru1's task to complete
  description: "Integrate the API client built by subtask_010a"
```

When a blocking task completes, the Karo automatically unblocks dependent tasks.

### Dynamic Model Routing (capability_tiers)

Configure **model-level routing within the Ashigaru tier**:

```yaml
# config/settings.yaml
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3       # L1–L3 only: fast, high-volume tasks
  claude-sonnet-4-6:
    max_bloom: 5       # L1–L5: + design evaluation
  claude-opus-4-6:
    max_bloom: 6       # L1–L6: + novel architecture, strategy
```

Skills: `/shogun-model-list` (reference table) and `/shogun-bloom-config` (interactive configurator).

---

## Skills

No skills are included out of the box. Skills emerge organically during operation — you approve candidates from `dashboard.md` as they're discovered. Invoke with `/skill-name`.

### Included Skills (committed to repo)

| Skill | Description |
|-------|-------------|
| `/skill-creator` | Template and guide for creating new skills |
| `/shogun-agent-status` | Show busy/idle status of all agents with task and inbox info |
| `/shogun-model-list` | Reference table: all CLI tools × models × subscriptions × Bloom max level |
| `/shogun-bloom-config` | Interactive configurator: answer 2 questions → get ready-to-paste `capability_tiers` YAML |
| `/shogun-model-switch` | Live CLI/model switching: settings.yaml update → `/exit` → relaunch with correct flags |
| `/shogun-readme-sync` | Keep README.md (Japanese) and README_en.md (English) in sync |

Personal workflow skills grow organically through the bottom-up discovery process and are **not committed to the repo** — every user's workflow is different.

---

## Configuration

### Language

```yaml
# config/settings.yaml
language: ja   # Samurai Japanese only
language: en   # Samurai Japanese + English translation
```

### Screenshot integration

```yaml
# config/settings.yaml
screenshot:
  path: "/mnt/c/Users/YourName/Pictures/Screenshots"
```

Tell the Shogun "check the latest screenshot" and it reads your screen captures for visual context. (`Win+Shift+S` on Windows.)

### ntfy (Phone Notifications)

```yaml
# config/settings.yaml
ntfy_topic: "shogun-yourname"
```

Subscribe to the same topic in the [ntfy app](https://ntfy.sh) on your phone. The listener starts automatically with `shutsujin_departure.sh`.

#### ntfy Authentication (Self-Hosted Servers)

The public ntfy.sh instance requires **no authentication** — the setup above is all you need.

If you run a self-hosted ntfy server with access control enabled, configure authentication:

```bash
# 1. Copy the sample config
cp config/ntfy_auth.env.sample config/ntfy_auth.env

# 2. Edit with your credentials (choose one method)
```

| Method | Config | When to use |
|--------|--------|-------------|
| **Bearer Token** (recommended) | `NTFY_TOKEN=tk_your_token_here` | Self-hosted ntfy with token auth |
| **Basic Auth** | `NTFY_USER=username` + `NTFY_PASS=password` | Self-hosted ntfy with user/password |
| **None** (default) | Leave file empty or don't create it | Public ntfy.sh — no auth needed |

`config/ntfy_auth.env` is excluded from git. See `config/ntfy_auth.env.sample` for details.

---

## MCP Setup Guide

MCP (Model Context Protocol) servers extend Claude's capabilities:

```bash
# 1. Notion - Connect to your Notion workspace
claude mcp add notion -e NOTION_TOKEN=your_token_here -- npx -y @notionhq/notion-mcp-server

# 2. Playwright - Browser automation
claude mcp add playwright -- npx @playwright/mcp@latest
# Note: Run `npx playwright install chromium` first

# 3. GitHub - Repository operations
claude mcp add github -e GITHUB_PERSONAL_ACCESS_TOKEN=your_pat_here -- npx -y @modelcontextprotocol/server-github

# 4. Sequential Thinking - Step-by-step reasoning
claude mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking

# 5. Memory - Cross-session long-term memory (recommended!)
# ✅ Auto-configured by first_setup.sh
claude mcp add memory -e MEMORY_FILE_PATH="$PWD/memory/shogun_memory.jsonl" -- npx -y @modelcontextprotocol/server-memory
```

Verify: `claude mcp list` — all servers should show "Connected".

---

## Advanced

<details>
<summary><b>Script Architecture</b> (click to expand)</summary>

```
┌─────────────────────────────────────────────────────────────────────┐
│                    First-Time Setup (run once)                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  install.bat (Windows)                                              │
│      │                                                              │
│      ├── Check/guide WSL2 installation                              │
│      └── Check/guide Ubuntu installation                            │
│                                                                     │
│  first_setup.sh (run manually in Ubuntu/WSL)                        │
│      │                                                              │
│      ├── Check/install tmux                                         │
│      ├── Check/install Node.js v20+ (via nvm)                      │
│      ├── Check/install Claude Code CLI (native version)             │
│      │       ※ Proposes migration if npm version detected           │
│      └── Configure Memory MCP server                                │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                    Daily Startup (run every day)                     │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  shutsujin_departure.sh                                             │
│      │                                                              │
│      ├──▶ Create tmux sessions                                      │
│      │         • "shogun" session (1 pane)                          │
│      │         • "multiagent" session (9 panes, 3x3 grid)          │
│      │                                                              │
│      ├──▶ Reset queue files and dashboard                           │
│      │                                                              │
│      └──▶ Launch Claude Code on all agents                          │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

</details>

<details>
<summary><b>shutsujin_departure.sh Options</b> (click to expand)</summary>

```bash
./shutsujin_departure.sh              # Default: Full startup
./shutsujin_departure.sh -s           # Session setup only (no CLI launch)
./shutsujin_departure.sh -c           # Clean task queues
./shutsujin_departure.sh -k           # Battle formation: All Ashigaru on Opus
./shutsujin_departure.sh -S           # Silent mode: No battle cries
./shutsujin_departure.sh -t           # Open Windows Terminal tabs
./shutsujin_departure.sh --shogun-no-thinking  # Shogun relay-only mode
./shutsujin_departure.sh -h           # Show help
```

</details>

<details>
<summary><b>Common Workflows</b> (click to expand)</summary>

**Normal daily use:**
```bash
./shutsujin_departure.sh          # Launch everything
tmux attach-session -t shogun     # Connect and give commands
```

**Debug mode (manual control):**
```bash
./shutsujin_departure.sh -s       # Create sessions only

# Manually launch Claude Code on specific agents
tmux send-keys -t shogun:0 'claude --dangerously-skip-permissions' Enter
tmux send-keys -t multiagent:0.0 'claude --dangerously-skip-permissions' Enter
```

**Restart after crash:**
```bash
# Kill existing sessions
tmux kill-session -t shogun
tmux kill-session -t multiagent

# Fresh start
./shutsujin_departure.sh
```

</details>

<details>
<summary><b>Convenient Aliases</b> (click to expand)</summary>

Running `first_setup.sh` automatically adds these aliases to `~/.bashrc`:

```bash
alias csst='cd /mnt/c/tools/multi-agent-shogun && ./shutsujin_departure.sh'
alias css='tmux attach-session -t shogun'      # Connect to Shogun
alias csm='tmux attach-session -t multiagent'  # Connect to Karo + Ashigaru
```

To apply aliases: run `source ~/.bashrc` or restart your terminal.

</details>

---

## File Structure

<details>
<summary><b>Click to expand file structure</b></summary>

```
multi-agent-shogun/
│
│  ┌──────────────── Setup Scripts ────────────────────┐
├── install.bat               # Windows: First-time setup
├── first_setup.sh            # Ubuntu/Mac: First-time setup
├── shutsujin_departure.sh    # Daily deployment (auto-loads instructions)
│  └──────────────────────────────────────────────────┘
│
├── instructions/             # Agent behavior definitions
│   ├── roles/                # Role definitions (source of truth)
│   ├── common/               # Shared rules (protocol, task flow)
│   ├── cli_specific/         # CLI-specific tool descriptions
│   └── generated/            # Built by build_instructions.sh (16 files)
│
├── lib/
│   ├── agent_status.sh       # Shared busy/idle/stuck detection
│   ├── cli_adapter.sh        # Multi-CLI adapter (Claude/Codex/Copilot/Kimi)
│   └── ntfy_auth.sh          # ntfy authentication helper
│
├── scripts/                  # Utility scripts
│   ├── inbox_write.sh        # Write messages to agent inbox (Layer 1)
│   ├── stop_hook_inbox.sh    # Stop hook: inbox check at turn-end (Layer 2)
│   ├── health_checker.sh     # Background health polling (Layer 3)
│   ├── inbox_watcher.sh      # File-watch based inbox detection
│   ├── agent_status.sh       # Show busy/idle status of all agents
│   ├── build_instructions.sh # Generate CLI-specific instruction files
│   ├── update_dashboard.sh   # Generate/update dashboard.md
│   ├── switch_cli.sh         # Live CLI/model switching
│   ├── ntfy.sh               # Send push notifications to phone
│   └── ntfy_listener.sh      # Stream incoming messages from phone
│
├── config/
│   ├── settings.yaml         # Language, ntfy, model settings
│   ├── ntfy_auth.env.sample  # ntfy authentication template
│   └── projects.yaml         # Project registry
│
├── queue/                    # Communication files (YAML mailbox)
│   ├── shogun_to_karo.yaml   # Shogun → Karo commands
│   ├── inbox/                # Per-agent inbox files
│   ├── tasks/                # Per-worker task assignments
│   ├── reports/              # Worker reports
│   └── ntfy_inbox.yaml       # Phone messages (ntfy)
│
├── skills/                   # Reusable skills (committed to repo)
├── templates/                # Report and context templates
├── saytask/                  # SayTask streak tracking
├── memory/                   # Memory MCP persistent storage
├── dashboard.md              # Real-time status board
└── CLAUDE.md                 # System instructions (auto-loaded)
```

</details>

---

## Project Management

This system manages not just its own development, but **all white-collar tasks**. Project folders can be located outside this repository.

```
config/projects.yaml          # Project list (ID, name, path, status only)
projects/<project_id>.yaml    # Full details for each project
```

- **`projects/` is excluded from git** (contains confidential client information)
- Project files (source code, documents, etc.) live in the external folder specified by `path`

```yaml
# config/projects.yaml
projects:
  - id: client_x
    name: "Client X Consulting"
    path: "/mnt/c/Consulting/client_x"
    status: active
```

---

## Troubleshooting

<details>
<summary><b>Using npm version of Claude Code CLI?</b></summary>

The npm version (`npm install -g @anthropic-ai/claude-code`) is officially deprecated. Re-run `first_setup.sh` to detect and migrate to the native version.

</details>

<details>
<summary><b>MCP tools not loading?</b></summary>

MCP tools are lazy-loaded. Search first, then use:
```
ToolSearch("select:mcp__memory__read_graph")
mcp__memory__read_graph()
```

</details>

<details>
<summary><b>Agents asking for permissions?</b></summary>

Agents should start with `--dangerously-skip-permissions`. This is handled automatically by `shutsujin_departure.sh`.

</details>

<details>
<summary><b>Workers stuck?</b></summary>

```bash
tmux attach-session -t multiagent
# Ctrl+B then 0-8 to switch panes
```

</details>

<details>
<summary><b>Agent crashed?</b></summary>

**Do NOT use `css`/`csm` aliases to restart inside an existing tmux session.** These create tmux sessions — running them inside an existing pane causes nesting.

**Correct restart:**
```bash
# Method 1: Run claude directly in the pane
claude --model opus --dangerously-skip-permissions

# Method 2: Karo force-restarts via respawn-pane
tmux respawn-pane -t shogun:0.0 -k 'claude --model opus --dangerously-skip-permissions'
```

</details>

<details>
<summary><b>ntfy not working?</b></summary>

| Problem | Fix |
|---------|-----|
| No notifications on phone | Check topic name matches exactly in `settings.yaml` and ntfy app |
| Listener not starting | Run `bash scripts/ntfy_listener.sh` in foreground to see errors |
| Phone → Shogun not working | Verify listener is running: `pgrep -f ntfy_listener.sh` |
| Messages not reaching Shogun | Check `queue/ntfy_inbox.yaml` — if message is there, Shogun may be busy |
| Changed topic name | Restart listener: `pkill -f ntfy_listener.sh && nohup bash scripts/ntfy_listener.sh &>/dev/null &` |

</details>

---

## tmux Quick Reference

| Command | Description |
|---------|-------------|
| `tmux attach -t shogun` | Connect to the Shogun |
| `tmux attach -t multiagent` | Connect to workers |
| `Ctrl+B` then `0`–`8` | Switch panes |
| `Ctrl+B` then `d` | Detach (agents keep running) |
| `tmux kill-session -t shogun` | Stop the Shogun session |
| `tmux kill-session -t multiagent` | Stop the worker session |

### Mouse Support

`first_setup.sh` automatically configures `set -g mouse on` in `~/.tmux.conf`, enabling intuitive mouse control:

| Action | Description |
|--------|-------------|
| Mouse wheel | Scroll within a pane (view output history) |
| Click a pane | Switch focus between panes |
| Drag pane border | Resize panes |

---

## Contributing

Issues and pull requests are welcome.

- **Bug reports**: Open an issue with reproduction steps
- **Feature ideas**: Open a discussion first
- **Skills**: Skills are personal by design and not included in this repo

See [CHANGELOG.md](CHANGELOG.md) for version history.

## Credits

Based on [Claude-Code-Communication](https://github.com/Akira-Papa/Claude-Code-Communication) by Akira-Papa.

## License

[MIT](LICENSE)

---

<div align="center">

**One command. As many agents as you have independent tasks. Zero coordination cost.**

⭐ Star this repo if you find it useful — it helps others discover it.

</div>
