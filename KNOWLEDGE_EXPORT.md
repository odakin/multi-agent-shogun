# multi-agent-shogun 知見エクスポート
> 2026-03-02 コード検証セッションで得た設計知見・改善提案・教訓

---

## 目次
1. [システム全体の設計思想](#1-システム全体の設計思想)
2. [アーキテクチャ上の天才的設計判断](#2-アーキテクチャ上の天才的設計判断)
3. [inbox_write.sh — メッセージ永続化層](#3-inbox_writesh--メッセージ永続化層)
4. [inbox_watcher.sh — イベント駆動配信 & エスカレーション](#4-inbox_watchersh--イベント駆動配信--エスカレーション)
5. [cli_adapter.sh — マルチCLI抽象化 & Bloomルーティング](#5-cli_adaptersh--マルチcli抽象化--bloomルーティング)
6. [agent_status.sh & stop_hook — 状態検知と停止制御](#6-agent_statussh--stop_hook--状態検知と停止制御)
7. [発見したバグ（要修正）](#7-発見したバグ要修正)
8. [改善提案（優先度順）](#8-改善提案優先度順)
9. [テストカバレッジの空白地帯](#9-テストカバレッジの空白地帯)
10. [設計パターン集（再利用可能）](#10-設計パターン集再利用可能)
11. [システム上の構造的課題](#11-システム上の構造的課題)
12. [総括](#12-総括)

---

## 1. システム全体の設計思想

### アーキテクチャの核心
将軍制（Shogun→Karo→Ashigaru×7+Gunshi）は**軍事的指揮系統**をLLMマルチエージェントに適用した設計。
特筆すべきは「ポーリングゼロ」の徹底。全通信が**イベント駆動**（inotifywait + tmux nudge）で、
CPU使用率をエージェント数に依存させない。

### タスクライフサイクル
```
cmd_XXX.yaml (将軍が発令)
  → queue/tasks/ashigaruN.yaml (家老が分配)
    → 足軽が実行
      → queue/reports/ashigaruN_report.yaml (完了報告)
        → 軍師QC → 家老集約 → dashboard.md
```
各段階がYAMLファイルで永続化されるため、どの時点で `/clear` が入っても復旧可能。

### 3層の配信保証
メッセージ配信に3つの独立した仕組みが重層的に機能する：
1. **inbox_write.sh の直接nudge** — 書き込み直後に即座配信（ベストエフォート）
2. **stop_hook_inbox.sh のブロック** — エージェントのターン終了時に未読チェック→ブロック
3. **inbox_watcher.sh のエスカレーション** — 上記2つが失敗しても30秒ごとに再試行→段階的強制

この冗長設計により、**単一障害点がない**。

---

## 2. アーキテクチャ上の天才的設計判断

検証を通じて見つけた「これは見事だ」と感じた設計判断7つ。

### 2.1 ダンベル型モデル配置
```
Opus(将軍) → Haiku(家老) → Sonnet(足軽) ← Opus(軍師)
  思考           物流          実行           品質管理
```
高能力モデルを入口(思考)と出口(品質管理)に配置し、中間の物流は安いHaikuに任せる。
「考える仕事」と「配る仕事」を分離し、トークンコストを最適化。

### 2.2 フェーズ事前分解
将軍がcmd発令時に `phases` を事前分解する。家老は再分解せず機械的にフェーズを実行するだけ。
→ ディスパッチャーが「考え込む」ことを構造的に防止。

### 2.3 禁止行動を「文化」として実装
F001〜F004は技術的強制ではなく、指示書に明文化された**ルール+違反例**。
技術的制約（ACLなど）より柔軟で、LLMの文脈理解力を活用している。
コードベースの権限分離よりスケールする（新しいルールの追加がYAML 1行で可能）。

### 2.4 YAMLを「真実の源泉」に
全状態がYAMLファイルに永続化されるため：
- エージェントのcrash → YAML再読み込みで復旧
- `/clear` による文脈消失 → YAML再読み込みで復旧
- セッション間の引き継ぎ → YAML読むだけ
- 人間が直接介入可能 → テキストエディタでYAML編集

### 2.5 inbox_watcherをインフラとして分離
エージェントは「自分でポーリング」しない。外部プロセス(inbox_watcher)がファイル変更を検知し、
必要な時だけ起こす。エージェントがクラッシュしてもwatcherは生き続ける。
watcherがクラッシュしてもYAMLにメッセージは残っている。**お互いが独立**。

### 2.6 メッセージ本文をtmuxに流さない
tmuxに流すのは `inbox3` のような短いnudge文字列のみ。メッセージ本文はYAMLファイル経由。
→ tmuxバッファの文字化け、改行問題、長文切り詰め等を全て回避。
→ シェルインジェクション対策にもなっている。

### 2.7 マルチCLI対応を初日から設計
Claude Code / Codex / Copilot / Kimi を同一アーキテクチャで扱える。
指示書はbuild_instructions.shで正規表現変換して各CLI用に生成。
「後付けの互換層」ではなく「設計時点での抽象化」。

---

## 3. inbox_write.sh — メッセージ永続化層

### 設計の白眉：3層アトミック書き込み

```python
# 1. tmpfile作成（同一ファイルシステム上）
tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(inbox))

# 2. tmpfileに書き込み（元ファイル無傷）
with os.fdopen(tmp_fd, 'w') as f:
    yaml.dump(data, f, allow_unicode=True)

# 3. アトミックリネーム（POSIXカーネル単一syscall）
os.replace(tmp_path, inbox)
```

**なぜ秀逸か:**
- 書き込み途中で電源断 → tmpfileが壊れるだけ、元YAML無傷
- os.replace() は同一FS上でアトミック → 読み手が中途半端なデータを見ることがない
- tmpdir を `/tmp` ではなく YAML と同じディレクトリに配置 → cross-device rename を防止

### 並行制御：flock + リトライ
```bash
flock -w 5 200 || exit 1  # FD200でアドバイザリロック、5秒タイムアウト
# → 3回リトライ × 1秒スリープ = 最大15秒の忍耐
```

- 8並列書き込みテスト (T-010) で**データ欠損ゼロ**を確認済み
- ロックファイルはデータファイルとは分離 (`${INBOX}.lock`)

### オーバーフロー保護の巧妙さ
50メッセージ超過時：**全未読を保持** + 既読は最新30件のみ残す。
→ 配信保証（未読は絶対に消さない）と容量制限を両立。

### セキュリティ：シェルインジェクション不可能
コンテンツは**環境変数経由**でPythonに渡す（シェル展開を経由しない）。
PyYAMLが自動的にYAML特殊文字をエスケープするため、任意の入力が安全に永続化される。

---

## 4. inbox_watcher.sh — イベント駆動配信 & エスカレーション

### inotifywait の使い方とinode置換への対処

```bash
inotifywait -q -t 30 -e modify -e close_write "$INBOX"
# rc=0: イベント発火（即座配信）
# rc=1: inode変更（atomic writeでDELETE_SELF → 再watchが必要）
# rc=2: 30秒タイムアウト（安全弁）
```

**重要な知見**: inbox_write.sh がtmp+renameでアトミック書き込みすると、
元のinodeが消える → inotifywait は `DELETE_SELF` (rc=1) を返す。
これを**イベントとして扱い**、次のループで新inodeを再watchする設計。
rc=1をエラーとして無視すると全メッセージを見落とす。

### 4段階エスカレーション

| フェーズ | 経過時間 | アクション | 対象外 |
|---------|---------|-----------|--------|
| 1 | 0〜120秒 | `inboxN` + Enter | busy中のエージェント |
| 2 | 120〜240秒 | Escape×2 + C-c + `inboxN` | Codex（Escで終了してしまう）、将軍（人間操作中） |
| 3 | 240秒〜 | `/clear` 送信（5分クールダウン） | 将軍（強制クリア禁止） |
| 4 | /clear後 | auto-recovery (task_assigned再送) | cancelled/idleタスク |

### CLI別の適応
- **Codex**: `/clear` → `/new` に変換（Codexに/clearは存在しない）
- **Copilot**: `/clear` → Ctrl-C + restart
- **将軍**: エスカレーション全段階を抑制（人間の作業を邪魔しない）

---

## 5. cli_adapter.sh — マルチCLI抽象化 & Bloomルーティング

### 4CLI統一インターフェース

```
get_cli_type()         → agent_id → claude | codex | copilot | kimi
build_cli_command()    → CLI固有の起動コマンド文字列
get_instruction_file() → CLI固有の指示ファイルパス
get_agent_model()      → 3段階フォールバックでモデル名解決
```

**設計パターン: 3段階フォールバックチェーン**
```
Priority 1: cli.agents.{id}.type (明示設定)
Priority 2: cli.agents.{id}      (文字列ショートハンド)
Priority 3: cli.default           (グローバルデフォルト)
Priority 4: "claude"              (ハードコード安全弁)
```
各レベルでバリデーションし、typo（`claudee`）は次レベルに落とす。

### Bloomルーティング（L1-L6）— 最も洗練された部分

**3フェーズ動的モデル選択:**

1. **能力ティア定義**: `capability_tiers` でモデルごとの `max_bloom` を宣言
2. **推薦モデル選択**: bloom_level ≤ max_bloom のモデルから**最安**を選ぶ
   - コスト優先: ChatGPT Pro (0) > Claude Max (1)
   - サブスクリプション考慮: `available_cost_groups` でユーザーの契約を反映
3. **エージェント発見**: 2段階で空きエージェントを探す
   - Stage 1: 推薦モデルと一致するエージェントからidleを探す
   - Stage 2: モデル不一致でもidleなら使う（キューイングより実行優先）
   - Stage 3: 全員busy → `QUEUE` 返却

**設計哲学**: 「最適なモデルがなくても、空いているエージェントで実行する方がキューで待つより良い」

### thinking制御
```bash
# Claude Code限定：環境変数でthinking無効化
MAX_THINKING_TOKENS=0 claude --model opus ...
```
Codex/Copilot/Kimiはこの機構なし → CLI依存の接頭辞で分岐。

---

## 6. agent_status.sh & stop_hook — 状態検知と停止制御

### busy/idle検知の3層ヒューリスティック

| 層 | 対象 | 信頼度 | 根拠 |
|----|------|--------|------|
| 1. ステータスバー | 最終非空行の `esc to` / `· esc` | 95% | Claude Code処理中のみ表示される決定的シグナル |
| 2. アイドルパターン | `❯` プロンプト、`context left`、`bypass permissions` | 90% | CLI固有のidle表示 |
| 3. テキストマーカー | Working, Thinking, 思考中, 処理中 等 | 80% | スクロールバック残留リスクあり |

**検出順序が重要**: アイドルチェックをビジーマーカーの**前**に実行。
→ プロンプト表示中に古いspinnerテキストが残っていても正しくidle判定。

### stop_hook の無限ループ防止
```bash
if [ "$STOP_HOOK_ACTIVE" = "True" ]; then
    exit 0  # 前回ブロックからの継続 → 今回は許可
fi
```
`stop_hook_active` フラグで2重ブロックを防止。これがないと「未読あり→ブロック→再実行→未読あり→ブロック…」の無限ループ。

### 高速未読カウント
Stop hookは低レイテンシが必須（<100ms）のため、YAML全パースではなく `grep -c 'read: false'` で近似。
- 利点: Pythonの起動コスト（~200ms）を回避
- リスク: コンテンツ内に `read: false` があると誤カウント → 実際には inbox_write の書式制御で回避

---

## 7. 発見したバグ（要修正）

### BUG-1: LAST_CLEAR_TS の早期クリア（重大度: 高）
**場所**: inbox_watcher.sh 975-977行

```bash
sleep 5
LAST_CLEAR_TS=0  # ← /clear送信後5秒でクリア
```

**問題**: Claude Codeの /clear は完了に10〜30秒かかる。5秒でタイマーリセットすると、
次の30秒タイムアウトで「エージェントはidle」と誤判定 → /clear完了前にnudge送信。

**修正案**: `LAST_CLEAR_TS=0` を削除し、300秒クールダウンに自然に任せる。

### BUG-2: Boot Grace PeriodがTimeout Tickに適用されない（重大度: 中）
**場所**: inbox_watcher.sh 900-906行

Grace period（15秒）は `trigger=startup` のみに適用される。
30秒タイムアウト tick は `trigger=timeout` で来るため、起動15秒以内でもnudgeが飛ぶ。

**修正案**: Grace checkを全トリガーに適用する。

### BUG-3: Startup Promptがエスカレーションタイマーをリセットしてしまう（重大度: 中）
**場所**: inbox_watcher.sh 1037-1042行

```bash
FIRST_UNREAD_SEEN=$now  # ← タイマーリセット
```

Startup prompt送信後にエスカレーションタイマーをリセットすると、
プロンプト処理に失敗した場合にPhase 2到達が遅延する。

**修正案**: `FIRST_UNREAD_SEEN` をリセットしない。

### BUG-4: find_agent_for_model の文字列マッチングが脆弱（重大度: 低）
**場所**: cli_adapter.sh 1076行

```bash
[[ " $candidates " == *" $fallback "* ]]
```

`candidates` の末尾に改行がある場合、マッチに失敗する可能性。
配列を使うか、明示的なword boundary checkに変更すべき。

### BUG-5: Codex /new の重複排除フラグが自動リカバリで未リセット（重大度: 低）
**場所**: inbox_watcher.sh `NEW_CONTEXT_SENT` フラグ

Phase 1で `/new` 送信 → フラグ=1 → Phase 3で再度 `/new` が必要 → フラグでスキップされる。

---

## 8. 改善提案（優先度順）

### 優先度A（信頼性直結）

| # | 提案 | 理由 |
|---|------|------|
| A1 | Bloomルーティングのユニットテスト追加 | `get_recommended_model`, `find_agent_for_model`, `validate_subscription_coverage` が**テストゼロ** |
| A2 | stale lockの自動解放 | flock保持プロセスがクラッシュした場合、次のwriterが15秒待つ。30秒以上古いlockfileを強制解放する機構 |
| A3 | get_recommended_model の警告をstderrだけでなく戻り値にも含める | bashで `result=$(...)` するとstderrが見えない。`[WARN]` を明示的にキャプチャする仕組み |

### 優先度B（運用改善）

| # | 提案 | 理由 |
|---|------|------|
| B1 | 設定YAML読み込みキャッシュ | 毎関数呼び出しでPythonプロセス起動+YAMLパース。JSON変換してキャッシュすれば50-100ms/call節約 |
| B2 | メッセージ冪等キー | 同一内容の二重送信を防ぐidempotency key機構 |
| B3 | エージェントリストの動的取得 | agent_status.sh のハードコードされた `AGENTS` 配列を settings.yaml から読む |
| B4 | inbox未読カウントのYAMLメタデータ化 | nudge送信時にPythonで再計算する代わりに、`_metadata.unread_count` を書き込み時に更新 |

### 優先度C（堅牢性向上）

| # | 提案 | 理由 |
|---|------|------|
| C1 | Python例外処理の細分化 | `except Exception` の一括catchを read失敗 / write失敗 に分離 |
| C2 | agent_is_busy_check のsource失敗時にfail-fast | 現状は黙ってフォールバック → busy checkなしで割り当てが起きうる |
| C3 | Phase 2エスカレーションにバックオフ追加 | 5回失敗したら即Phase 3（300秒クールダウンをバイパス） |
| C4 | switch_cli.sh のバックグラウンド実行 | inbox_watcher のメインループをブロックしない |

---

## 9. テストカバレッジの空白地帯

### ユニットテスト（339/339 PASS だが…）

| 関数/領域 | テスト数 | カバレッジ |
|-----------|---------|-----------|
| inbox_write 基本操作 | 12 | 95% |
| cli_adapter 基本API | 51 | 90% |
| **Bloomルーティング全体** | **0** | **0%** ⚠️ |
| **find_agent_for_model** | **0** | **0%** ⚠️ |
| **validate_subscription_coverage** | **0** | **0%** ⚠️ |
| **get_capability_tier** | **0** | **0%** ⚠️ |
| agent_status busy/idle | 15 | 85% |
| stop_hook ブロック判定 | 10 | 80% |

### E2Eテスト

| テスト | 状態 | 備考 |
|-------|------|------|
| TC-BLOOM-001〜006 | SKIP | tmux session `multiagent` が必要。VPS専用 |
| E2E-008 Codex startup | PASS | ただし `/new` 重複排除のエッジケース未テスト |

### 推奨追加テスト
1. `get_recommended_model` — fixtures settings.yaml でL1〜L6の全パスを検証
2. `find_agent_for_model` — tmuxをモックして busy/idle/absent パターン検証
3. 極端に狭いtmux pane（<20文字幅）での busy detection
4. flock タイムアウト動作の検証
5. Python例外パス（書き込み権限なし等）

---

## 10. 設計パターン集（再利用可能）

### パターン1: tmpfile + atomic rename
**用途**: 複数プロセスが読み書きするファイルの安全な更新
```python
tmp_fd, tmp_path = tempfile.mkstemp(dir=same_dir_as_target)
# write to tmp
os.replace(tmp_path, target)  # atomic on same FS
```
**条件**: tmpとtargetが同一ファイルシステム上であること。

### パターン2: 環境変数経由のデータ受け渡し
**用途**: シェルインジェクションの回避
```bash
IW_CONTENT="$user_input" python3 -c "import os; safe = os.environ['IW_CONTENT']"
```
**利点**: シェル展開を一切経由せず、任意のバイト列を安全にPythonに渡せる。

### パターン3: ベストエフォートnudge + 段階的エスカレーション
**用途**: 分散システムでの確実な通知
```
Phase 1: 低コストな通知（失敗してもOK）
Phase 2: より強力な通知（副作用あり）
Phase 3: 強制リセット（最終手段）
```
**原則**: 「Phase 1の失敗を検知して自動昇格」が鍵。手動介入不要。

### パターン4: 3段階フォールバックチェーン
**用途**: 設定値の解決
```
明示設定 → ショートハンド → グローバルデフォルト → ハードコード安全弁
```
**原則**: 各レベルでバリデーション。typoは無視して次レベルへ。

### パターン5: flock + リトライ + タイムアウト
**用途**: ファイルベースの排他制御
```bash
(flock -w 5 200 || exit 1; ...) 200>"$LOCKFILE"
```
**注意**: ロックファイルはデータファイルと分離すること。

### パターン6: inotifwait + inode変更対応
**用途**: ファイル監視でatomic writeを使うシステム
```
rc=0 (modify): イベント → 処理
rc=1 (DELETE_SELF): inode置換 → イベントとして処理 + 再watch
rc=2 (timeout): 安全弁 → 状態チェック
```
**落とし穴**: rc=1をエラーとして無視すると、atomic write後のイベントを全て見落とす。

---

## 11. システム上の構造的課題

検証で見えた、個別バグではなく**構造レベル**の課題。

### 11.1 トークン増幅問題
9エージェント全員が起動時にCLAUDE.md + instructions/*.md を読む。
`/clear` が1回走るたびにコンテキスト再構築コスト発生。
slim_yaml.sh で軽減しているが、根本的にはCLI側の永続コンテキスト機能待ち。

### 11.2 テキストパース依存の限界
busy/idle検知がCLIのpane出力テキストに依存。
Claude Code v3 以降でステータスバーの形式が変わると一斉に壊れる。
**対策案**: Claude Code公式のAgent State APIが出たら移行する設計予定を持っておく。

### 11.3 家老ボトルネックリスク
全タスク配信が家老（Haiku）を経由。家老がwedgeすると全システム停止。
現状はHaikuの高速性で事実上問題化していないが、タスク量が増えた場合に顕在化する可能性。
**対策案**: 家老の操作を純粋な「読み→書き→通知」の機械的操作に限定し、思考を入れない設計で回避中。

### 11.4 分散状態の一貫性
inbox_watcher がクラッシュするとエスカレーションが停止（最大4分のラグ）。
watcher_supervisor.sh で自動再起動するが、再起動中のレースコンディションが未テスト。
YAMLが真実の源泉であるため致命的ではないが、運用上の信頼性は supervisor の品質に依存。

### 11.5 マルチCLIのメンテナンスコスト
4CLI × 4ロール = 16の指示ファイルバリアント。
build_instructions.sh の正規表現1つの誤りが全バリアントに波及。
テストはあるが、「正しい変換結果」のスナップショットテストがない。

---

## 12. 総括

### 本システムの強さ
1. **ポーリングゼロ設計** — イベント駆動で10エージェントでもCPU負荷微小
2. **配信保証の冗長性** — 3層の独立した仕組みで単一障害点なし
3. **YAML永続化** — どの時点でセッションが切れても `/clear` 一発で復旧
4. **CLI非依存の抽象層** — Claude Code / Codex / Copilot / Kimi を透過的に扱える
5. **atomic write徹底** — 並行書き込みでデータ破損ゼロ（339テストで実証）

### 本システムの弱さ
1. **テキストパースの脆弱性** — CLIの表示形式変更で busy/idle 誤判定のリスク
2. **Bloomルーティングのテスト不在** — 最も複雑な部分がテストゼロ
3. **Python起動コスト** — YAML操作のたびにPython起動。高頻度呼び出しで累積
4. **エージェントリストのハードコード** — 拡張時に設定漏れリスク
5. **エスカレーションの微妙なバグ群** — BUG-1〜3は本番運用で顕在化しうる

### 一言
堅牢なプロダクション品質のシステム。発見したバグは「正常系が崩れる」類ではなく、
「エッジケースでの回復が数秒〜数分遅延する」レベル。
最も重要な改善は **Bloomルーティングのテスト追加** と **BUG-1 (LAST_CLEAR_TS) の修正**。

---

> エクスポート日時: 2026-03-02
> 検証者: Claude Opus 4.6（コード検証セッション）
> 対象ブランチ: claude/verify-code-functionality-XlysE
