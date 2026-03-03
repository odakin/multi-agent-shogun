# 🏯 戦況報告 — dashboard.md
> 最終更新: 2026-03-03 14:50
> 更新者: gunshi (cmd_285 QC完了)

## 🐸 Frog / ストリーク

| 項目 | 値 |
|------|-----|
| 今日のFrog | （未設定） |
| Frog状態 | — |
| ストリーク | — |
| 今日の完了 | 41 |

## 📋 現在の指令

cmd_244: 家老Haikuモデル切替バグ修正 [qc_pass] / cmd_246: karo.mdスリム化 [done] / cmd_247: shogun.md Haiku対応改善 [qc_pass] / cmd_248: 動的リサイズ+枠線視認性 [qc_pass] / cmd_249: 裁可待ち表示復旧 [qc_pass] / cmd_250: E2Eパイプラインテスト [done] / cmd_251: nudgeバグ修正 [done] / cmd_252: nudge重複制御改善 [done] / cmd_253: 裁可待ち表示改善 [done] / cmd_254: ペイン仕切り線・日本語化 [done] / cmd_255: cmd一覧テーブル表示 [done] / cmd_256: battle_monitor全面再設計 [done] / cmd_257: ashigaru git pushルール [done] / cmd_258: エージェント名消失バグ [done] / cmd_259: git pushポリシー再設計 [done] / cmd_261: 足軽6・7チラつき修正 [done] / cmd_262: bloom_levelモデル切替 [done] / cmd_263: 動的リサイズバグ修正 [done] / cmd_265: Phase自動遷移修正 [done] / cmd_266: battle_monitor表示問題 [done] / cmd_267: 家老停止バグ修正 [done] / cmd_264: Agent Teams時系列調査 [done] / cmd_268: Zenn記事分析 [done] / cmd_269: 家老SPOF解決策比較 [done] / cmd_270: battle_monitor 80列修正 [done] / cmd_271: Opus動的モデル表示 [done] / cmd_272: battle_monitorモックアップ準拠 [done] / cmd_274: ペイン枠名前消失修正 [done] / cmd_273: 動的リサイズ完全実装 [done] / cmd_275: mouse off対応確認 [done] / cmd_276: アクティブペイン名表示修正 [done] / cmd_277: 将軍ナッジ除外 [done] / cmd_278: battle_monitor行截断 [done] / cmd_279: コンテキスト枯渇自動復旧 [done] / cmd_280: battle_monitorグリッド幅適応 [done] / cmd_281: battle_monitorチラツキ解消 [done] / cmd_282: karo.md /clearプロトコル [done] / cmd_283: inbox pruning [done] / cmd_284: 動的リサイズ修正 [in_progress] / cmd_285: 裁可待ち色分け改善 [done]

## ⚔️ 進行中

| 足軽 | タスクID | 状態 | 内容 |
|------|---------|------|------|
| ashigaru1 | （未割当） | idle | — |
| ashigaru2 | （未割当） | idle | — |
| ashigaru3 | （未割当） | idle | — |
| ashigaru4 | （未割当） | idle | — |
| ashigaru5 | （未割当） | idle | — |
| ashigaru6 | （未割当） | idle | — |
| ashigaru7 | （未割当） | idle | — |

**集計**: 実行中 0 / 割当済 0 / 完了 18 / ブロック 0 / 待機 0

**軍師**: 待機中

## 🏆 戦果

| 時刻 | 実行者 | タスクID | 結果 | 詳細 |
|------|--------|---------|------|------|
| 08:24 | gunshi | qc_244 | PASS | 家老Haikuモデル切替バグ修正 |
| 08:28 | gunshi | qc_249 | PASS | 裁可待ちリスト表示復旧 |
| 08:30 | gunshi | qc_247 | PASS | shogun.md Haiku対応改善 |
| 10:25 | gunshi | qc_250 | PASS | E2Eパイプラインテスト Phase 1 |
| 10:42 | gunshi | qc_253 | PASS | 裁可待ち表示視認性改善 (P1-P7全対応) |
| 10:48 | gunshi | qc_252 | PASS | nudge重複制御改善 (FIX-1/FIX-2 + karo.mdフロー図) |
| 10:52 | gunshi | qc_254 | PASS | ペイン仕切り線改善+エージェント名日本語化 |
| 10:58 | gunshi | qc_255 | PASS | cmd一覧テーブル表示実装 |
| 11:02 | gunshi | qc_257 | PASS | ashigaru.md git pushルール追記 |
| 11:08 | gunshi | qc_251 | PASS | inbox_watcher nudgeバグ修正 (ISSUE-1/2/3, 72/72テストPASS) |
| 11:18 | gunshi | qc_256 | PASS | battle_monitor.sh全面再設計 (罫線テーブル・日本語名・2列・feed6行) |
| 11:25 | gunshi | qc_259 | PASS | git pushポリシー再設計 (足軽push禁止・軍師push・redo reset --soft) |
| 11:30 | gunshi | qc_258 | PASS | エージェント名消失バグ修正 (フォールバック・パディング・フリッカー対策・cmd両Dir) |
| 11:40 | gunshi | qc_263 | PASS | 動的リサイズバグ修正 (busyボーナス+2/cycle, push済み) |
| 12:01 | gunshi | qc_262 | PASS | bloom_levelモデル切替実装 (karo.md手順+settings.yaml明示化, commit 8103c1d) |
| 12:05 | gunshi | qc_261 | PASS | 足軽6・7黒背景フリッカー修正 (3層キャッシュ差分更新, commit 9b3f694) |
| 12:12 | gunshi | qc_265 | PASS | Phase自動遷移バグ修正 (Completion 7ステップ+QC割当+Recovery更新, commit 3d85452) |
| 12:16 | gunshi | qc_266 | PASS | battle_monitor新デザイン表示問題 (コード正常・旧PID残存が原因・修正不要) |
| 12:20 | gunshi | qc_267 | PASS | 家老停止バグ根本修正 (BUSY_SINCE 120sタイムアウト+inbox lock修正, commit dfd2523) |
| 12:25 | gunshi | qc_268 | PASS | Zenn記事分析 (奉行設計パターン・比較分析・skill_candidate発見) |
| 12:40 | gunshi | qc_264 | PASS | Agent Teams時系列調査 (6フェーズ時系列+デッドロック機構+5廃止理由+3層配送経緯) |
| 12:55 | gunshi | qc_269 | PASS | 家老SPOF解決策比較 (9案6軸定量比較・推奨:案C/I定期clear+案F inbox pruning+案A奉行新設) |
| 13:00 | gunshi | qc_270 | PASS | battle_monitor 80列表示崩れ修正 (stty fallback 80列+per-line erase+残像消去, commit 2b7ad51) |
| 13:05 | gunshi | qc_271 | PASS | Opus動的モデル表示 (★マーカー+濃青背景+⚡アイコン+黄色太字, commit c2177b9+b14aa38) |
| 13:12 | gunshi | qc_272 | PASS | battle_monitorモックアップ準拠 (4セクション・3列グリッド・80列厳守・累積4commit) |
| 13:18 | gunshi | qc_274 | PASS | ペイン枠名前消失修正 (bold→standout不可視、colour255白化、commit ad5017f) |
| 13:25 | gunshi | qc_273 | PASS | 動的リサイズ完全実装 (直接デルタ+60%収束+idle均等化+windowリサイズ即追従, commit cbaadc4+abc4339) |
| 13:30 | gunshi | qc_275 | PASS | mouse off対応確認 (scripts/内mouse参照ゼロ、コード変更不要、tmuxコマンドベースで動作) |
| 13:35 | gunshi | qc_276 | PASS | アクティブペイン名表示修正 (explicit bg=colour33+text colour16黒on青, commit d12d950) |
| 13:40 | gunshi | qc_277 | PASS | 将軍ナッジ除外 (send_wakeup+escape両方で早期return, commit a231f0a) |
| 13:45 | gunshi | qc_278 | PASS | battle_monitor行截断 (ANSI-aware trim_ansi_line+DECAWM無効, commit 31ce33a) |
| 13:50 | gunshi | qc_279 | PASS | コンテキスト枯渇自動復旧 (capture-pane≤5%→/clear+60sクールダウン, commit a5f6aa3) |
| 14:35 | gunshi | qc_280 | PASS | battle_monitorグリッド幅適応 (動的列数47列→2列/60列+→3列+ASCII罫線, commit 0596c6b) |
| 14:35 | gunshi | qc_281 | PASS | battle_monitorチラツキ解消 (subshell fork排除+/dev/shm tmpfile一括出力, commit d3ccf4b) |
| 14:35 | gunshi | qc_282 | PASS | karo.md /clearプロトコル追記 (案C/I実装・実行条件3+手順6+禁止3, commit e7903fc) |
| 14:45 | gunshi | qc_283 | PASS | inbox pruning (read:true→archive移動+flock保護+atomic write, commit 3a209bb) |
| 14:45 | gunshi | qc_284 | INCOMPLETE | 動的リサイズ修正 (ashigaru1 auto_closed — コミット・レポートなし。再割当必要) |
| 14:50 | gunshi | qc_285 | PASS | 裁可待ち色分け改善 (見出し黄色維持+本文デフォルト色+罫線幅修正, commit 0019cba) |

## 🚨 要対応

- ~~案C/I: Phase完了後の自動/clear実装~~ → **cmd_282で実装完了** (karo.md追記済み, commit e7903fc)
- **cmd_284 s284a 再割当必要** — 動的リサイズ修正。ashigaru1がauto_closedされコミットなし。別足軽に再割当。
- **inbox_write.sh tempfile import順序バグ** — 軍師が緊急修正済み(commit 989c8fe)。s283a時点で混入。
- **奉行(Bugyo)新設の中長期検討** (cmd_268/269結果) — 家老/奉行分離アーキテクチャ。Zenn記事の知見あり。設計判断が必要。

## 💡 スキル化候補

| 発見元 | 内容 | 優先度 |
|--------|------|--------|
| cmd_268 s268a | 奉行（bugyo）ロール設計パターン — 家老から手足業務を分離 | 高 |
| cmd_269 s269e | Phase-based Context Partition — Phase完了後/clearプロトコル設計パターン | 高 |

---
*YAML files are ground truth. This dashboard is secondary.*
