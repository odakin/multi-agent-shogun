<div align="center">

# multi-agent-shogun

**AIコーディング軍団統率システム — Multi-CLI対応**

*コマンド1つで、10体のAIエージェントが並列稼働 — **Claude Code / OpenAI Codex / GitHub Copilot / Kimi Code** 混成軍*

**Talk Coding — Vibe Codingではなく、スマホに話すだけでAIが実行**

[![GitHub Stars](https://img.shields.io/github/stars/yohey-w/multi-agent-shogun?style=social)](https://github.com/yohey-w/multi-agent-shogun)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![v3.5 Dynamic Model Routing](https://img.shields.io/badge/v3.5-Dynamic_Model_Routing-ff6600?style=flat-square&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxNiIgaGVpZ2h0PSIxNiI+PHRleHQgeD0iMCIgeT0iMTIiIGZvbnQtc2l6ZT0iMTIiPuKalTwvdGV4dD48L3N2Zz4=)](https://github.com/yohey-w/multi-agent-shogun)
[![Shell](https://img.shields.io/badge/Shell%2FBash-100%25-green)]()

[English](README_en.md) | **日本語**

</div>

> 📌 このリポジトリは [yohey-w/multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun) の個人フォークです。
> コアの設計・実装は **yohey-w** によるものです。このフォークでは運用中に発見した改善（health_checker、post-compact recovery 等）を試験的に追加しています。

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260210-190453.png" alt="将軍ペインでの最新半透過セッションキャプチャ" width="940">
</p>

<p align="center">
  <img src="images/screenshots/hero/latest-translucent-20260208-084602.png" alt="将軍ペインでの自然言語コマンド入力" width="420">
  <img src="images/company-creed-all-panes.png" alt="家老と足軽が全ペインで並列反応する様子" width="520">
</p>

<p align="center"><i>家老1体が足軽7体+軍師1体を統率 — 実際の稼働画面、モックデータなし</i></p>

---

## これは何？

**multi-agent-shogun** は、複数のAIコーディングCLIインスタンスを同時に実行し、戦国時代の軍制のように統率するシステムです。**Claude Code**、**OpenAI Codex**、**GitHub Copilot**、**Kimi Code** の4CLIに対応。

**なぜ使うのか？**
- 1つの命令で、7体のAIワーカー+1体の軍師が並列で実行
- 待ち時間なし — タスクがバックグラウンドで実行中も次の命令を出せる
- AIがセッションを跨いであなたの好みを記憶（Memory MCP）
- ダッシュボードでリアルタイム進捗確認

```
      あなた（上様）
           │
           ▼ 命令を出す
    ┌─────────────┐
    │   SHOGUN    │  ← 命令を受け取り、即座に委譲
    └──────┬──────┘
           │ YAMLファイル + tmux
    ┌──────▼──────┐
    │    KARO     │  ← タスクをワーカーに分配
    └──────┬──────┘
           │
  ┌─┬─┬─┬─┴─┬─┬─┬─┬────────┐
  │1│2│3│4│5│6│7│ GUNSHI │  ← 7体のワーカー + 1体の軍師
  └─┴─┴─┴─┴─┴─┴─┴────────┘
     ASHIGARU      軍師
```

---

## なぜ Shogun なのか？

多くのマルチエージェントフレームワークは調整にAPIトークンを浪費する。Shogunはしない。

| | Claude Code `Task`ツール | Claude Code Agent Teams | LangGraph | CrewAI | **multi-agent-shogun** |
|---|---|---|---|---|---|
| **アーキテクチャ** | 1プロセス内のサブエージェント | チームリード＋メイト（JSONメールボックス） | グラフベースステートマシン | ロールベースエージェント | tmuxによる封建階層 |
| **並列性** | 逐次（1つずつ） | 複数の独立セッション | 並列ノード（v0.2+） | 限定的 | **最大10体、ワークロードに応じてスケール** |
| **調整コスト** | TaskごとにAPIコール | トークン大量消費（各メイト＝別コンテキスト） | API＋インフラ（Postgres/Redis） | API＋CrewAIプラットフォーム | **ゼロ**（YAML＋tmux） |
| **マルチCLI** | Claude Codeのみ | Claude Codeのみ | 任意のLLM API | 任意のLLM API | **4 CLI**（Claude/Codex/Copilot/Kimi） |
| **可観測性** | Claudeログのみ | tmux分割ペインまたはインプロセス | LangSmith連携 | OpenTelemetry | **ライブtmuxペイン**＋ダッシュボード |
| **スキル発見** | なし | なし | なし | なし | **ボトムアップ自動提案** |
| **セットアップ** | Claude Code組み込み | 組み込み（実験的） | 重い（インフラ必要） | pip install | シェルスクリプト |

### 何が違うのか

**調整コストゼロ** — エージェント同士はディスク上のYAMLファイルで通信。APIコールは実際の作業にのみ使われ、オーケストレーションには使われない。

**偽の並列化なし** — 家老はタスクの依存関係を分析し、真に独立した作業にのみ並列エージェントを割り当てる。あるタスクが他のタスクの出力に依存する場合、同じエージェントに割り当てる。独立タスク3つ = 3エージェント。7体を起動して4体アイドルにはしない。

**完全な透明性** — 全エージェントがtmuxペインで可視化。全指示・報告・判断がプレーンなYAMLファイルで確認・diff・バージョン管理可能。ブラックボックスなし。

---

## なぜCLI（APIではなく）？

多くのAIコーディングツールはトークン課金。複数のOpusクラスのエージェントをAPIで動かすと **$100+/時間**。CLIサブスクリプションはこれを逆転させる：

| | API（トークン課金） | CLI（定額制） |
|---|---|---|
| **複数エージェント × Opus** | 〜$100+/時間 | 〜$200/月 |
| **コスト予測性** | スパイク発生 | 固定月額 |
| **使用不安** | トークン1つずつ気になる | 無制限 |
| **実験予算** | 制約あり | 自由にデプロイ |

**「AIを贅沢に使え」** — 定額制CLIサブスクリプションなら、躊躇なくエージェントをデプロイ。1時間使っても24時間使ってもコストは同じ。

### マルチCLI対応

Shogunは1つのベンダーに縛られない。4つのCLIツールに対応：

| CLI | 強み | デフォルトモデル |
|-----|-------------|---------------|
| **Claude Code** | tmux連携実績、Memory MCP、専用ファイルツール（Read/Write/Edit/Glob/Grep） | Claude Sonnet 4.6 |
| **OpenAI Codex** | サンドボックス実行、JSONL構造化出力、`codex exec`ヘッドレスモード、**`--model`フラグ** | gpt-5.3-codex / **gpt-5.3-codex-spark** |
| **GitHub Copilot** | 組み込みGitHub MCP、4つの専門エージェント、`/delegate` | Claude Sonnet 4.6 |
| **Kimi Code** | 無料枠あり、多言語サポート | Kimi k2 |

統一インストラクションビルドシステムで、共有テンプレートからCLI固有の指示ファイルを自動生成。詳細は[アーキテクチャ](#インストラクションビルドシステム)を参照。

---

## ボトムアップスキル発見

他のどのフレームワークにもない機能。

足軽がタスクを実行する中で、**再利用可能なパターンを自動的に識別**し、スキル候補として提案。家老が `dashboard.md` に集約し、あなた（上様）が昇格させるか判断する。

```
足軽がタスクを完了
    ↓
気づく:「このパターンを3つのプロジェクトで3回やった」
    ↓
YAMLで報告:  skill_candidate:
                found: true
                name: "api-endpoint-scaffold"
                reason: "同じREST足場パターンを3プロジェクトで使用"
    ↓
dashboard.md に表示 → 承認 → .claude/commands/ にスキル作成
    ↓
どのエージェントも /api-endpoint-scaffold を呼び出せる
```

スキルは実際の作業から有機的に成長する — 事前定義のテンプレートライブラリからではない。

---

## 🚀 クイックスタート

### Windows (WSL2)

<table>
<tr>
<td width="60">

**Step 1**

</td>
<td>

📥 **リポジトリをダウンロード**

[ZIPダウンロード](https://github.com/yohey-w/multi-agent-shogun/archive/refs/heads/main.zip) → `C:\tools\multi-agent-shogun` に展開

*またはgitで:* `git clone https://github.com/yohey-w/multi-agent-shogun.git C:\tools\multi-agent-shogun`

</td>
</tr>
<tr>
<td>

**Step 2**

</td>
<td>

🖱️ **`install.bat` を実行**

右クリック →「管理者として実行」（WSL2未インストールの場合）。WSL2 + Ubuntuを自動セットアップ。

</td>
</tr>
<tr>
<td>

**Step 3**

</td>
<td>

🐧 **Ubuntuを開いて実行**（初回のみ）

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

✅ **出陣！**

```bash
./shutsujin_departure.sh
```

</td>
</tr>
</table>

#### 初回のみ：認証

`first_setup.sh` 実行後、一度だけ認証:

```bash
# 1. PATH変更を反映
source ~/.bashrc

# 2. OAuthログイン + 権限バイパスの承認
claude --dangerously-skip-permissions
#    → ブラウザが開く → Anthropicアカウントでログイン → CLIに戻る
#    → 「Bypass Permissions」が表示 → 「Yes, I accept」を選択（↓で選択肢2、Enter）
#    → /exit で終了
```

認証情報は `~/.claude/` に保存されます。以降は不要です。

#### 毎日の起動

**Ubuntuターミナル** (WSL) を開いて:

```bash
cd /mnt/c/tools/multi-agent-shogun
./shutsujin_departure.sh
```

<details>
<summary>📱 <b>モバイルアクセス</b>（クリックして展開）</summary>

スマホからAI軍団を操作 — ベッド、カフェ、お風呂から。

**必要なもの（すべて無料）:** [Tailscale](https://tailscale.com/) + SSH + [Termux](https://termux.dev/)

**セットアップ:**

1. WSLとスマホの両方にTailscaleをインストール
2. WSLで: `curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscaled & && sudo tailscale up --authkey tskey-auth-XXXXXXXXXXXX && sudo service ssh start`
3. Termuxで: `pkg update && pkg install openssh && ssh youruser@your-tailscale-ip`
4. `css` で将軍に接続、`csm` で全ペイン表示

**切断:** Termuxをスワイプで閉じるだけ。tmuxセッションは生存 — エージェントは稼働し続ける。

**音声入力:** スマホの音声キーボードを使用。将軍は自然言語を理解するので、音声認識のタイポは問題なし。

**さらに簡単に:** ntfy設定済みなら、ntfyアプリから直接コマンド送信可能 — SSH不要。

</details>

---

<details>
<summary>🐧 <b>Linux / macOS</b>（クリックして展開）</summary>

### 初回セットアップ

```bash
# 1. クローン
git clone https://github.com/yohey-w/multi-agent-shogun.git ~/multi-agent-shogun
cd ~/multi-agent-shogun

# 2. スクリプトに実行権限を付与
chmod +x *.sh

# 3. 初回セットアップを実行
./first_setup.sh
```

### 毎日の起動

```bash
cd ~/multi-agent-shogun
./shutsujin_departure.sh
```

</details>

<details>
<summary>❓ <b>WSL2とは？</b>（クリックして展開）</summary>

**WSL2 (Windows Subsystem for Linux)** はWindows上でLinuxを実行する機能。このシステムは `tmux`（Linuxのツール）を使用するため、WindowsではWSL2が必要です。

**インストール**（PowerShellを管理者として実行）:
```powershell
wsl --install
```

その後PCを再起動し、`install.bat` を実行。

</details>

<details>
<summary>📋 <b>スクリプト一覧</b>（クリックして展開）</summary>

| スクリプト | 目的 | 実行タイミング |
|-----------|------|-------------|
| `install.bat` | Windows: WSL2 + Ubuntuセットアップ | 初回のみ |
| `first_setup.sh` | tmux, Node.js, Claude Code CLI + Memory MCP設定 | 初回のみ |
| `shutsujin_departure.sh` | tmuxセッション作成 + CLI起動 + 指示読み込み + ntfyリスナー開始 | 毎日 |
| `scripts/switch_cli.sh` | CLI/モデルのライブ切り替え（settings.yaml → /exit → 再起動） | 必要に応じて |

</details>

<details>
<summary>🔧 <b>手動要件</b>（クリックして展開）</summary>

| 要件 | インストール | 備考 |
|------|------------|------|
| WSL2 + Ubuntu | PowerShellで `wsl --install` | Windowsのみ |
| Ubuntuをデフォルトに設定 | `wsl --set-default Ubuntu` | スクリプト動作に必要 |
| tmux | `sudo apt install tmux` | ターミナルマルチプレクサ |
| Node.js v20+ | `nvm install 20` | MCPサーバに必要 |
| Claude Code CLI | `curl -fsSL https://claude.ai/install.sh \| bash` | 公式Anthropic CLI（ネイティブ版推奨） |

</details>

---

### セットアップ後

**10体のAIエージェント**が自動起動:

| エージェント | 役割 | 数 |
|------------|------|-----|
| 🏯 将軍 | 最高指揮官 — あなたの命令を受ける | 1 |
| 📋 家老 | 管理者 — タスク分配、品質チェック | 1 |
| ⚔️ 足軽 | 実行者 — 実装タスクを並列実行 | 7 |
| 🧠 軍師 | 戦略家 — 分析、評価、設計を担当 | 1 |

2つのtmuxセッションが作成されます:
- `shogun` — ここに接続して命令を出す
- `multiagent` — 家老、足軽、軍師がバックグラウンドで稼働

---

## 📖 基本的な使い方

### Step 1: 将軍に接続

`shutsujin_departure.sh` 実行後、全エージェントは指示を読み込み済み。

新しいターミナルを開いて接続:

```bash
tmux attach-session -t shogun
```

### Step 2: 最初の命令を出す

将軍は初期化済み — そのまま命令を出すだけ:

```
JavaScriptフレームワーク上位5つを調査して比較表を作れ
```

将軍がやること:
1. タスクをYAMLファイルに書く
2. 家老に通知
3. 即座にあなたに制御を返す — 待つ必要なし

その間、家老がタスクを足軽に分配して並列実行。

### Step 3: 進捗を確認

エディタで `dashboard.md` を開くとリアルタイムで状況が見える:

```markdown
## 進行中
| ワーカー | タスク | ステータス |
|---------|-------|----------|
| 足軽1号 | React調査 | 実行中 |
| 足軽2号 | Vue調査 | 実行中 |
| 足軽3号 | Angular調査 | 完了 |
```

<details>
<summary><b>実用例</b>（クリックして展開）</summary>

**リサーチスプリント:**

```
あなた: 「AIコーディングアシスタント上位5つを調査して比較せよ」

何が起きるか:
1. 将軍が家老に委譲
2. 家老が割り当て:
   - 足軽1号: GitHub Copilotを調査
   - 足軽2号: Cursorを調査
   - 足軽3号: Claude Codeを調査
   - 足軽4号: Codeiumを調査
   - 足軽5号: Amazon CodeWhispererを調査
3. 5体が同時に調査
4. 結果がdashboard.mdに集約
```

**PoC準備:**

```
あなた: 「このNotionページのプロジェクトのPoCを準備せよ: [URL]」

何が起きるか:
1. 家老がMCP経由でNotionコンテンツを取得
2. 足軽2号: 検証項目をリストアップ
3. 足軽3号: 技術的実現可能性を調査
4. 足軽4号: PoC計画をドラフト
5. 全結果がdashboard.mdに集約 — 会議準備完了
```

</details>

---

## アーキテクチャ

### プロセスモデル

各エージェントは専用のtmuxペイン内で**独立したCLIプロセス**として動作。共有メモリなし、インプロセス結合なし — 通信はディスク上のYAMLファイルのみ。

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
バックグラウンドプロセス:
  health_checker.sh  ← 1プロセス、全エージェントを30秒間隔でポーリング
  ntfy_listener.sh   ← スマホ通知（オプション）
```

### 3層メッセージ配達

メッセージはYAMLファイルに書き込まれる（永続的、アトミック）。起床シグナルは3つの独立した層で配達 — 1つが失敗しても次がキャッチする。

```
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1: inbox_write.sh                      PUSH（即時）      │
│                                                                 │
│  送信者がqueue/inbox/{target}.yamlにflockで書き込み、            │
│  tmux send-keysで短い「メールあり」nudgeを送信。                 │
│  メッセージ内容はtmuxを通さない — シグナルのみ。                 │
├─────────────────────────────────────────────────────────────────┤
│  Layer 2: Stop Hook (stop_hook_inbox.sh)      TURN-END          │
│                                                                 │
│  エージェントのturn終了時にClaude Code Stop Hookが自動で         │
│  inboxをチェック。未読メッセージがあればstopをブロックし、       │
│  エージェントにフィードバック。                                   │
├─────────────────────────────────────────────────────────────────┤
│  Layer 3: health_checker.sh                   INSURANCE（30秒）  │
│                                                                 │
│  1つのバックグラウンドプロセスが全エージェントを30秒間隔で       │
│  ポーリング。スタック検出、未配達nudgeのリトライ、               │
│  コンパクション後の復旧トリガー。                                 │
└─────────────────────────────────────────────────────────────────┘
```

**配達保証**: `inbox_write.sh` が成功すれば（flock + アトミックファイル置換）メッセージは永続化。3層のうち少なくとも1層がターゲットエージェントへの処理を保証。

### タスクライフサイクル

```
あなたが命令を出す
    │
    ▼
┌─────────────────────────────────────────────────────────┐
│ 将軍がqueue/cmds/cmd_XXX.yamlに書込（pending）           │
│ → inbox_write.sh で家老に通知                           │
│ → 即座にあなたに制御を返す                               │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│ 家老がコマンドをin_progressに更新                        │
│ → サブタスクに分解（Bloomルーティング: L1-3→足軽、       │
│   L4-6→軍師）                                           │
│ → queue/tasks/ashigaru{N}.yamlに書込（assigned）        │
│ → inbox_write.sh で配達                                 │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│ 足軽/軍師が実行し、結果を                                │
│ queue/reports/ashigaru{N}_report.yaml に書込             │
│ → inbox_write.sh で家老に通知                            │
└──────────────────────┬──────────────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────────────┐
│ 家老が全報告を収集、dashboard.md を更新                   │
│ → コマンドをdoneに更新                                   │
│ → 将軍に通知 → あなたが結果を確認                        │
└─────────────────────────────────────────────────────────┘
```

### コンパクション後の復旧

エージェントのコンテキストが満杯になりコンパクション（コンテキスト喪失）が発生した場合、自動復旧:

- **"Wake = Full Scan"** — 全エージェントが起動時にtask YAML + inboxを全スキャンして状態を再構築
- **足軽 / 軍師**: task YAML（`queue/tasks/{id}.yaml`）がそのままチェックポイント — 別の状態ファイル不要
- **家老**: 専用チェックポイントプロトコル — 起動のたびに全報告ファイル + dashboardをスキャン
- **health_checker.sh**: タスクが割り当て済みなのにアイドルなエージェントを検出してnudge

### インストラクションビルドシステム

唯一の正（single source of truth）から4つのCLI向けに指示ファイルを自動生成:

```
instructions/
├── roles/            ← 役割定義（将軍、家老、足軽、軍師）
├── common/           ← 共通ルール（通信プロトコル、タスクフロー、禁止行動）
└── cli_specific/     ← CLI固有のツール説明
         │
         ▼  build_instructions.sh
instructions/generated/
├── shogun.md             ← Claude Code
├── codex-shogun.md       ← Codex
├── copilot-shogun.md     ← Copilot
└── kimi-shogun.md        ← Kimi K2
    (× 4役割 = 16生成ファイル)
```

ルールを1回変更すれば全CLIに反映。同期ドリフトなし。

### 設計の根拠

| 疑問 | 回答 |
|------|------|
| **なぜ階層制？** | 即時応答（将軍が即座に委譲）、並列実行（家老が分配）、障害分離（1体の足軽の失敗が他に影響しない） |
| **なぜファイルベースのメールボックス？** | YAMLファイルは再起動に耐える、`flock`で競合防止、エージェントが自分のinboxを読む（tmux経由のコンテンツなし＝文字化けなし）、デバッグが容易 |
| **なぜ家老だけがdashboardを更新？** | 単一ライターで衝突防止。家老が全報告から全体像を持っている |
| **なぜ`@agent_id`？** | tmuxユーザーオプションによる安定したID、ペイン並び替えに不変。自己識別: `tmux display-message -t "$TMUX_PANE" -p '#{@agent_id}'` |

> 核心思想の詳細: **[docs/philosophy.md](docs/philosophy.md)**

---

## ✨ 主な特徴

### ⚡ 1. 並列実行

1つの命令で最大8つの並列タスクを生成:

```
あなた: 「5つのMCPサーバを調査せよ」
→ 5体の足軽が同時に調査開始
→ 数時間ではなく数分で結果が出る
```

### 🔄 2. ノンブロッキングワークフロー

将軍は即座に委譲して、あなたに制御を返す。長いタスクの完了を待つ必要なし。

```
あなた: 命令 → 将軍: 委譲 → あなた: 次の命令をすぐ出せる
                                    ↓
                    ワーカー: バックグラウンドで実行
                                    ↓
                    ダッシュボード: 結果を表示
```

### 🧠 3. セッション間記憶（Memory MCP）

AIがあなたの好みを記憶:

```
セッション1: 「シンプルな方法が好き」と伝える
            → Memory MCPに保存

セッション2: 起動時にAIがメモリを読み込む
            → 複雑な方法を提案しなくなる
```

### 📊 4. エージェントステータス確認

どのエージェントが稼働中/待機中か即座に確認:

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

**Claude Code** と **Codex CLI** の両方に対応（CLI固有のプロンプト/スピナーパターンを検出）。

### 📸 5. スクリーンショット連携

```yaml
# config/settings.yaml でスクリーンショットフォルダを設定
screenshot:
  path: "/mnt/c/Users/YourName/Pictures/Screenshots"
```

将軍に「最新のスクリーンショットを確認して」と伝えるだけ。Windowsでは `Win + Shift + S` でスクリーンショット。

### 📁 6. コンテキスト管理（4層アーキテクチャ）

| 層 | 場所 | 用途 |
|---|------|------|
| Layer 1: Memory MCP | `memory/shogun_memory.jsonl` | プロジェクト横断・セッション横断の長期記憶 |
| Layer 2: Project | `config/projects.yaml`, `context/{project}.md` | プロジェクト固有の情報と技術知識 |
| Layer 3: YAML Queue | `queue/cmds/`, `queue/tasks/`, `queue/reports/` | タスク管理 — 指示と報告の正 |
| Layer 4: Session | CLAUDE.md, instructions/*.md | ワーキングコンテキスト（`/clear`で消去） |

**`/clear`プロトコル（コスト最適化）:** エージェントが作業するとセッションコンテキスト（Layer 4）が肥大化。`/clear`でセッションメモリをリセット。Layer 1-3はファイルとして永続するため、何も失われない。復旧コスト: **約6,800トークン**（v1から42%改善）。

### 📱 7. スマホ通知（ntfy）

スマホと将軍の双方向通信 — SSH不要、サーバ不要。

```
📱 あなた（ベッドから）      🏯 将軍
    │                          │
    │  「React 19を調査せよ」   │
    ├─────────────────────────►│
    │    (ntfyメッセージ)      │  → 家老に委譲 → 足軽が作業
    │                          │
    │  「✅ cmd_042 完了」     │
    │◄─────────────────────────┤
    │    (プッシュ通知)        │
```

**セットアップ:** `config/settings.yaml` に `ntfy_topic: "shogun-yourname"` を追加、スマホに[ntfyアプリ](https://ntfy.sh)をインストール、同じトピックをサブスクライブ。無料、アカウント不要。

<p align="center">
  <img src="images/screenshots/masked/ntfy_saytask_rename.jpg" alt="スマホ双方向通信" width="300">
  &nbsp;&nbsp;
  <img src="images/screenshots/masked/ntfy_cmd043_progress.jpg" alt="進捗通知" width="300">
</p>
<p align="center"><i>左: スマホ ↔ 将軍の双方向通信 · 右: 足軽からのリアルタイム進捗レポート</i></p>

> **⚠️ セキュリティ:** トピック名がパスワード。推測されにくい名前を選び、**公開しないこと**。

### 🖼️ 8. ペインボーダータスク表示

各tmuxペインのボーダーに現在のタスクを表示:

```
┌ ashigaru1 Sonnet+T VF要件 ────────┬ ashigaru3 Opus+T API調査 ──────────┐
│                                    │                                     │
│  SayTask要件を作業中               │  REST APIパターンを調査中           │
├ ashigaru2 Sonnet ─────────────────┼ ashigaru4 Spark DBスキーマ設計 ────┤
│                                    │                                     │
│  （待機中 — 割り当て待ち）          │  データベーススキーマを設計中       │
└────────────────────────────────────┴─────────────────────────────────────┘
```

表示形式: `エージェント名 モデル+T タスク概要` — `+T` = Extended Thinking有効。

### 🔊 9. シャウトモード（鬨の声）

足軽がタスク完了時に、tmuxペインで個性的な鬨の声を上げる:

```
┌ ashigaru1 (Sonnet) ──────────┬ ashigaru2 (Sonnet) ──────────┐
│                               │                               │
│  ⚔️ 足軽1号、先陣切った！     │  🔥 足軽2号、二番槍の意地！   │
│  八刃一志！                   │  八刃一志！                   │
└───────────────────────────────┴───────────────────────────────┘
```

`./shutsujin_departure.sh --silent` で無効化（APIトークン節約）。

---

## 🗣️ SayTask — タスク管理が嫌いな人のためのタスク管理

**スマホに話しかけるだけ。** UIゼロ。入力ゼロ。アプリを開く動作ゼロ。

- **ターゲット**: Todoistをインストールしたけど3日で開かなくなった人
- あなたの敵は他のアプリじゃない。何もしないこと。競合は無行動

### 仕組み

1. [ntfyアプリ](https://ntfy.sh)をインストール（無料、アカウント不要）
2. スマホに話しかける: *「歯医者 明日」*、*「請求書 金曜まで」*
3. AIが自動整理 → 朝に通知: *「今日の予定です」*

```
 🗣️ 「牛乳買う、歯医者 明日、請求書 金曜まで」
       │
       ▼
 ┌──────────────────┐
 │  ntfy → 将軍     │  AIが自動分類、日付解析、優先度設定
 └────────┬─────────┘
          │
          ▼
 ┌──────────────────┐
 │   tasks.yaml     │  構造化ストレージ（ローカル、端末外に出ない）
 └────────┬─────────┘
          │
          ▼
 📱 朝の通知:
    「今日: 🐸 請求書期限 · 🦷 歯医者3時 · 🛒 牛乳買う」
```

### ユースケース

- 🛏️ **ベッドの中**: *「明日レポート提出しないと」* — 忘れる前にキャプチャ
- 🚗 **運転中**: *「クライアントAの見積もり忘れないで」* — ハンズフリー
- 💻 **仕事中**: *「あ、牛乳買わないと」* — 即座にダンプしてフローに戻る
- 🌅 **起床時**: 今日のタスクが既に通知で待っている
- 🐸 **Eat the Frog**: AIが毎朝一番大変なタスクを選ぶ

### FAQ

**Q: 他のタスクアプリと何が違う？**
A: アプリを開かない。ただ話すだけ。多くのタスクアプリは開かなくなるから失敗する。SayTaskはそのステップ自体を取り除いた。

**Q: 🐸 Frogって何？**
A: 毎朝、AIがあなたの一番大変なタスクを選ぶ — 避けたいやつ。最初に倒す（「Eat the Frog」方式）か無視するか。あなた次第。

**Q: 無料？**
A: すべて無料でオープンソース。ntfyも無料。アカウント不要、サーバ不要。

**Q: データはどこに保存される？**
A: ローカルのYAMLファイル。クラウドには何も送信されない。

#### SayTask通知

行動心理学に基づくモチベーション:

- **ストリーク追跡**: 連続完了日数 — 損失回避を活用してモメンタムを維持
- **Eat the Frog** 🐸: その日の最難タスクを倒すと特別な通知
- **デイリー進捗**: `12/12タスク完了` — 視覚的な達成フィードバック

---

## 🧠 モデル設定

| エージェント | デフォルトモデル | 思考モード | 役割 |
|-------------|----------------|----------|------|
| 将軍 | Opus | **有効（high）** | 殿の参謀。`--shogun-no-thinking` で中継専用モードに |
| 家老 | Sonnet | 有効 | タスク分配、簡易QC、ダッシュボード管理 |
| 軍師 | Opus | 有効 | 深い分析、設計レビュー、アーキテクチャ評価 |
| 足軽1-7 | Sonnet 4.6 | 有効 | 実装: コード、リサーチ、ファイル操作 |

**思考制御**: `config/settings.yaml` でエージェントごとに `thinking: true/false` を設定。ペインボーダーにThinking有効時は `+T` サフィックス表示。

**ライブモデル切替**: `/shogun-model-switch` でCLI種別・モデル・Thinking設定をシステム再起動なしで変更。

### Bloomのタキソノミー → エージェントルーティング

タスクをBloomのタキソノミーで分類し、適切な**エージェント**にルーティング:

| レベル | カテゴリ | 説明 | ルーティング先 |
|--------|---------|------|-------------|
| L1 | 記憶 | 事実の想起、コピー、リスト | **足軽** |
| L2 | 理解 | 説明、要約、言い換え | **足軽** |
| L3 | 適用 | 手順の実行、既知パターンの実装 | **足軽** |
| L4 | 分析 | 比較、調査、分解 | **軍師** |
| L5 | 評価 | 判断、批評、推薦 | **軍師** |
| L6 | 創造 | 設計、構築、新しい解の統合 | **軍師** |

### タスク依存関係（blockedBy）

```yaml
# queue/tasks/ashigaru2.yaml
task:
  task_id: subtask_010b
  blockedBy: ["subtask_010a"]  # 足軽1号のタスク完了を待つ
  description: "subtask_010aで作成したAPIクライアントを統合"
```

ブロッキングタスクが完了すると、家老が自動的に依存タスクをアンブロック。

### Dynamic Model Routing（capability_tiers）

**足軽階層内でのモデルレベルルーティング**を設定:

```yaml
# config/settings.yaml
capability_tiers:
  gpt-5.3-codex-spark:
    max_bloom: 3       # L1-L3のみ: 高速、大量タスク
  claude-sonnet-4-6:
    max_bloom: 5       # L1-L5: + 設計評価
  claude-opus-4-6:
    max_bloom: 6       # L1-L6: + 新規アーキテクチャ、戦略
```

スキル: `/shogun-model-list`（参照テーブル）と `/shogun-bloom-config`（インタラクティブ設定）。

---

## 🛠️ スキル

初期状態ではスキルは含まれていない。運用中にスキルが有機的に発見される — `dashboard.md` の候補をあなたが承認。`/skill-name` で呼び出し。

### 同梱スキル（リポジトリにコミット済み）

| スキル | 説明 |
|--------|------|
| `/skill-creator` | 新スキル作成のテンプレートとガイド |
| `/shogun-agent-status` | 全エージェントの稼働/待機ステータスとタスク・inbox情報表示 |
| `/shogun-model-list` | 参照テーブル: 全CLIツール × モデル × サブスクリプション × Bloom最大レベル |
| `/shogun-bloom-config` | インタラクティブ設定: 2つの質問に答えて → `capability_tiers` YAMLを生成 |
| `/shogun-model-switch` | CLI/モデルのライブ切替: settings.yaml更新 → `/exit` → 正しいフラグで再起動 |
| `/shogun-readme-sync` | README.md(日本語)とREADME_en.md(英語)の同期 |

個人ワークフローのスキルはボトムアップ発見プロセスで成長し、**リポジトリにはコミットしない** — ユーザーごとにワークフローが異なる。

---

## ⚙️ 設定

### 言語

```yaml
# config/settings.yaml
language: ja   # 侍日本語のみ
language: en   # 侍日本語 + 英訳
```

### スクリーンショット連携

```yaml
# config/settings.yaml
screenshot:
  path: "/mnt/c/Users/YourName/Pictures/Screenshots"
```

将軍に「最新のスクリーンショットを確認して」と伝えるだけ。（Windowsでは `Win+Shift+S`）

### ntfy（スマホ通知）

```yaml
# config/settings.yaml
ntfy_topic: "shogun-yourname"
```

スマホの[ntfyアプリ](https://ntfy.sh)で同じトピックをサブスクライブ。リスナーは `shutsujin_departure.sh` で自動起動。

#### ntfy認証（セルフホストサーバ）

公式ntfy.shは**認証不要** — 上記の設定だけでOK。

セルフホストntfyサーバでアクセス制御を有効にしている場合:

```bash
# 1. サンプル設定をコピー
cp config/ntfy_auth.env.sample config/ntfy_auth.env

# 2. 認証情報を編集（方式を選択）
```

| 方式 | 設定 | 用途 |
|------|------|------|
| **Bearerトークン**（推奨） | `NTFY_TOKEN=tk_your_token_here` | セルフホストntfy + トークン認証 |
| **Basic認証** | `NTFY_USER=username` + `NTFY_PASS=password` | セルフホストntfy + ユーザー/パスワード |
| **なし**（デフォルト） | ファイルを空にするか作成しない | 公式ntfy.sh — 認証不要 |

`config/ntfy_auth.env` はgitから除外。詳細は `config/ntfy_auth.env.sample` を参照。

---

## 🔌 MCPセットアップガイド

MCP（Model Context Protocol）サーバでClaudeの機能を拡張:

```bash
# 1. Notion - Notionワークスペースに接続
claude mcp add notion -e NOTION_TOKEN=your_token_here -- npx -y @notionhq/notion-mcp-server

# 2. Playwright - ブラウザ自動化
claude mcp add playwright -- npx @playwright/mcp@latest
# 注: 先に `npx playwright install chromium` を実行

# 3. GitHub - リポジトリ操作
claude mcp add github -e GITHUB_PERSONAL_ACCESS_TOKEN=your_pat_here -- npx -y @modelcontextprotocol/server-github

# 4. Sequential Thinking - 段階的推論
claude mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking

# 5. Memory - セッション横断長期記憶（推奨！）
# ✅ first_setup.sh で自動設定
claude mcp add memory -e MEMORY_FILE_PATH="$PWD/memory/shogun_memory.jsonl" -- npx -y @modelcontextprotocol/server-memory
```

確認: `claude mcp list` — 全サーバが「Connected」と表示されるはず。

---

## 🛠️ 上級者向け

<details>
<summary><b>スクリプトアーキテクチャ</b>（クリックして展開）</summary>

```
┌─────────────────────────────────────────────────────────────────────┐
│                    初回セットアップ（1回のみ）                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  install.bat (Windows)                                              │
│      │                                                              │
│      ├── WSL2インストールの確認/案内                                 │
│      └── Ubuntuインストールの確認/案内                               │
│                                                                     │
│  first_setup.sh (Ubuntu/WSLで手動実行)                              │
│      │                                                              │
│      ├── tmuxの確認/インストール                                     │
│      ├── Node.js v20+の確認/インストール（nvm経由）                  │
│      ├── Claude Code CLIの確認/インストール（ネイティブ版）          │
│      │       ※ npm版検出時はマイグレーション提案                     │
│      └── Memory MCPサーバの設定                                     │
│                                                                     │
├─────────────────────────────────────────────────────────────────────┤
│                    毎日の起動                                        │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  shutsujin_departure.sh                                             │
│      │                                                              │
│      ├──▶ tmuxセッション作成                                        │
│      │         • 「shogun」セッション（1ペイン）                    │
│      │         • 「multiagent」セッション（9ペイン、3×3グリッド）   │
│      │                                                              │
│      ├──▶ キューファイルとダッシュボードをリセット                   │
│      │                                                              │
│      └──▶ 全エージェントでClaude Codeを起動                         │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

</details>

<details>
<summary><b>shutsujin_departure.sh オプション</b>（クリックして展開）</summary>

```bash
./shutsujin_departure.sh              # デフォルト: フルスタートアップ
./shutsujin_departure.sh -s           # セッションセットアップのみ（CLI起動なし）
./shutsujin_departure.sh -c           # タスクキューをクリーン
./shutsujin_departure.sh -k           # 決戦態勢: 全足軽にOpus
./shutsujin_departure.sh -S           # サイレントモード: 鬨の声なし
./shutsujin_departure.sh -t           # Windows Terminalタブを開く
./shutsujin_departure.sh --shogun-no-thinking  # 将軍を中継専用モードに
./shutsujin_departure.sh -h           # ヘルプ表示
```

</details>

<details>
<summary><b>一般的なワークフロー</b>（クリックして展開）</summary>

**通常の毎日の使用:**
```bash
./shutsujin_departure.sh          # 全て起動
tmux attach-session -t shogun     # 接続して命令を出す
```

**デバッグモード（手動制御）:**
```bash
./shutsujin_departure.sh -s       # セッションのみ作成

# 特定のエージェントにClaude Codeを手動起動
tmux send-keys -t shogun:0 'claude --dangerously-skip-permissions' Enter
tmux send-keys -t multiagent:0.0 'claude --dangerously-skip-permissions' Enter
```

**クラッシュ後の再起動:**
```bash
# 既存セッションを終了
tmux kill-session -t shogun
tmux kill-session -t multiagent

# 新規起動
./shutsujin_departure.sh
```

</details>

<details>
<summary><b>便利なエイリアス</b>（クリックして展開）</summary>

`first_setup.sh` が自動的にこれらのエイリアスを `~/.bashrc` に追加:

```bash
alias csst='cd /mnt/c/tools/multi-agent-shogun && ./shutsujin_departure.sh'
alias css='tmux attach-session -t shogun'      # 将軍に接続
alias csm='tmux attach-session -t multiagent'  # 家老+足軽に接続
```

エイリアスの反映: `source ~/.bashrc` またはターミナルを再起動。

</details>

---

## 📁 ファイル構成

<details>
<summary><b>クリックしてファイル構成を展開</b></summary>

```
multi-agent-shogun/
│
│  ┌──────────────── セットアップスクリプト ─────────────┐
├── install.bat               # Windows: 初回セットアップ
├── first_setup.sh            # Ubuntu/Mac: 初回セットアップ
├── shutsujin_departure.sh    # 毎日のデプロイ（指示の自動読み込み）
│  └───────────────────────────────────────────────────┘
│
├── instructions/             # エージェント行動定義
│   ├── roles/                # 役割定義（正）
│   ├── common/               # 共通ルール（通信プロトコル、タスクフロー）
│   ├── cli_specific/         # CLI固有のツール説明
│   └── generated/            # build_instructions.shで生成（16ファイル）
│
├── lib/
│   ├── agent_status.sh       # 稼働/待機/スタック検出（共有）
│   ├── cli_adapter.sh        # マルチCLIアダプタ（Claude/Codex/Copilot/Kimi）
│   └── ntfy_auth.sh          # ntfy認証ヘルパー
│
├── scripts/                  # ユーティリティスクリプト
│   ├── inbox_write.sh        # inboxへのメッセージ書込（Layer 1）
│   ├── stop_hook_inbox.sh    # Stop hook: turn終了時のinboxチェック（Layer 2）
│   ├── health_checker.sh     # バックグラウンドヘルスポーリング（Layer 3）
│   ├── inbox_watcher.sh      # ファイル監視ベースのinbox検出
│   ├── agent_status.sh       # 全エージェントの稼働/待機ステータス表示
│   ├── build_instructions.sh # CLI固有の指示ファイル生成
│   ├── update_dashboard.sh   # dashboard.mdの生成/更新
│   ├── switch_cli.sh         # CLI/モデルのライブ切替
│   ├── ntfy.sh               # スマホにプッシュ通知送信
│   └── ntfy_listener.sh      # スマホからのメッセージ受信
│
├── config/
│   ├── settings.yaml         # 言語、ntfy、モデル設定
│   ├── ntfy_auth.env.sample  # ntfy認証テンプレート
│   └── projects.yaml         # プロジェクト登録
│
├── queue/                    # 通信ファイル（YAMLメールボックス）
│   ├── cmds/                 # 将軍 → 家老コマンド（1ファイル/cmd）
│   ├── inbox/                # エージェント別inboxファイル
│   ├── tasks/                # ワーカー別タスク割り当て
│   ├── reports/              # ワーカー報告
│   └── ntfy_inbox.yaml       # スマホメッセージ（ntfy）
│
├── skills/                   # 再利用可能スキル（リポジトリにコミット済み）
├── templates/                # 報告・コンテキストテンプレート
├── saytask/                  # SayTaskストリーク追跡
├── memory/                   # Memory MCP永続ストレージ
├── dashboard.md              # リアルタイムステータスボード
└── CLAUDE.md                 # システム指示（自動読み込み）
```

</details>

---

## 📂 プロジェクト管理

このシステムは自身の開発だけでなく、**すべてのホワイトカラー業務**を管理する。プロジェクトフォルダはリポジトリ外に配置可能。

```
config/projects.yaml          # プロジェクト一覧（ID、名前、パス、ステータスのみ）
projects/<project_id>.yaml    # 各プロジェクトの詳細
```

- **`projects/` はgitから除外**（機密クライアント情報を含む）
- プロジェクトファイル（ソースコード、ドキュメント等）は `path` で指定した外部フォルダに配置

```yaml
# config/projects.yaml
projects:
  - id: client_x
    name: "クライアントXコンサルティング"
    path: "/mnt/c/Consulting/client_x"
    status: active
```

---

## 🔧 トラブルシューティング

<details>
<summary><b>npm版のClaude Code CLIを使っている？</b></summary>

npm版（`npm install -g @anthropic-ai/claude-code`）は公式に非推奨。`first_setup.sh` を再実行してネイティブ版に移行。

</details>

<details>
<summary><b>MCPツールが読み込まれない？</b></summary>

MCPツールは遅延読み込み。まず検索してから使用:
```
ToolSearch("select:mcp__memory__read_graph")
mcp__memory__read_graph()
```

</details>

<details>
<summary><b>エージェントが権限を求める？</b></summary>

エージェントは `--dangerously-skip-permissions` で起動するべき。これは `shutsujin_departure.sh` が自動処理。

</details>

<details>
<summary><b>ワーカーがスタックしている？</b></summary>

```bash
tmux attach-session -t multiagent
# Ctrl+B → 0-8 でペイン切替
```

</details>

<details>
<summary><b>エージェントがクラッシュした？</b></summary>

**既存tmuxセッション内で `css`/`csm` エイリアスを使わないこと。** これらはセッションを作成するため、既存ペイン内で実行するとネスティングが発生。

**正しい再起動方法:**
```bash
# 方法1: ペイン内で直接claudeを実行
claude --model opus --dangerously-skip-permissions

# 方法2: respawn-paneで強制再起動
tmux respawn-pane -t shogun:0.0 -k 'claude --model opus --dangerously-skip-permissions'
```

</details>

<details>
<summary><b>ntfyが動作しない？</b></summary>

| 問題 | 解決策 |
|------|--------|
| スマホに通知が来ない | `settings.yaml`とntfyアプリでトピック名が完全一致しているか確認 |
| リスナーが起動しない | `bash scripts/ntfy_listener.sh` をフォアグラウンドで実行してエラー確認 |
| スマホ→将軍が動かない | リスナー稼働確認: `pgrep -f ntfy_listener.sh` |
| メッセージが将軍に届かない | `queue/ntfy_inbox.yaml` を確認 — メッセージがあれば将軍がビジー状態かも |
| トピック名を変更した | リスナー再起動: `pkill -f ntfy_listener.sh && nohup bash scripts/ntfy_listener.sh &>/dev/null &` |

</details>

---

## 📚 tmux クイックリファレンス

| コマンド | 説明 |
|---------|------|
| `tmux attach -t shogun` | 将軍に接続 |
| `tmux attach -t multiagent` | ワーカーに接続 |
| `Ctrl+B` → `0`–`8` | ペイン切替 |
| `Ctrl+B` → `d` | デタッチ（エージェントは稼働し続ける） |
| `tmux kill-session -t shogun` | 将軍セッション停止 |
| `tmux kill-session -t multiagent` | ワーカーセッション停止 |

### マウスサポート

`first_setup.sh` が自動的に `~/.tmux.conf` に `set -g mouse on` を設定:

| 操作 | 説明 |
|------|------|
| マウスホイール | ペイン内スクロール（出力履歴表示） |
| ペインをクリック | フォーカス切替 |
| ペインボーダーをドラッグ | ペインリサイズ |

---

## コントリビューション

IssueとPull Requestを歓迎します。

- **バグ報告**: 再現手順付きでIssueを作成
- **機能アイデア**: まずDiscussionを開く
- **スキル**: スキルは設計上パーソナルなもの。リポジトリには含めない

バージョン履歴は [CHANGELOG.md](CHANGELOG.md) を参照。

## 🙏 クレジット

- **[yohey-w/multi-agent-shogun](https://github.com/yohey-w/multi-agent-shogun)** — オリジナルの設計・実装。本リポジトリはそのフォークです。
- **[Akira-Papa/Claude-Code-Communication](https://github.com/Akira-Papa/Claude-Code-Communication)** — エージェント間通信の原型。

## 📄 ライセンス

[MIT](LICENSE)

---

<div align="center">

**コマンド1つ。独立タスクの数だけエージェントを投入。調整コストゼロ。**

⭐ 役に立ったらスターをお願いします — 他の人が見つけやすくなります。

</div>
