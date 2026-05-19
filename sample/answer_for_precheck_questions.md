# 事前確認・質問・助言

## 1. 要望の理解

`./ai/request.md` の要望は、「ブラウザエンジンを使わず、Rust でネイティブな軽量 Discord 風チャットアプリを作る」ことです。

現時点では、まず MVP として以下を実現する内容だと理解しています。

- Rust 製のサーバーを作る
- Rust 製のネイティブクライアントアプリを作る
- クライアント 1 とクライアント 2 が同じサーバーに接続し、メッセージを送受信できる
- WebView / Electron / Tauri などのブラウザエンジン前提の UI は使わない

ただし、「Discord」の既存 API や Discord アカウントと連携する意味ではなく、Discord のようなチャット体験を持つ独自アプリを作る、という前提で整理しています。

## 2. 現在のリポジトリ状況

- 現在のブランチ: `master`
- Git 状態: 初回コミット前のリポジトリで、`git log` は `fatal: your current branch 'master' does not have any commits yet` となる
- `git status --short --branch --untracked-files=all`: `## No commits yet on master`
- `git ls-files`: 追跡済みファイルなし
- リモート: `/usr/bin/git remote -v` の出力なし
- 未コミット変更: Git 上は検出されない
- `ai/.gitignore` に `*` があり、`ai/` 配下のファイルは Git 追跡対象外になっている
- リポジトリ直下にアプリ実装、`Cargo.toml`、README、Makefile、CI 設定は見当たらない
- 既存ファイルは主に AI 作業フロー用:
  - `ai/request.md`
  - `ai/run.sh`
  - `ai/utils/repo_guard.py`
  - `ai/utils/git-readonly-wrapper.sh`
  - `ai/ai1/*_instruction.md`
- Rust 環境:
  - `rustc 1.93.0 (254b59607 2026-01-19)`
  - `cargo 1.93.0 (083ac5135 2025-12-15)`
- テスト・ビルド・lint の実行方法:
  - 現時点では Rust プロジェクトが存在しないため未定
  - 実装後に `cargo check`、`cargo test`、`cargo fmt`、`cargo clippy` などを設定する必要がある

今回の事前確認フェーズでは、禁止事項に従い、ビルド・テスト・フォーマット・依存関係追加・実装ファイル作成は行っていません。

## 3. 調査結果

### リポジトリ内で確認したこと

- 既存のサーバー実装、クライアント実装、共通プロトコル、テストは存在しない
- そのため、実装する場合は新規 Rust ワークスペースとして構成するのが自然
- 候補構成:
  - `Cargo.toml`: workspace 定義
  - `crates/common`: クライアント・サーバー共通のメッセージ型
  - `crates/server`: チャットサーバー
  - `crates/client`: ネイティブ GUI クライアント

### 技術選定の調査

- ネイティブ GUI 候補:
  - Slint: 公式サイトでは Rust 向けの宣言的 GUI ツールキットで、Embedded / Desktop / Mobile 向けと説明されている。軽量・ネイティブ志向に合う可能性が高い。
    - https://slint.rs/
    - https://docs.slint.dev/
  - egui / eframe: 公式 GitHub と docs.rs では、Rust 製の即時モード GUI で、Web とネイティブの両方で動くと説明されている。MVP を早く作る用途に向く。
    - https://github.com/emilk/egui
    - https://docs.rs/egui/latest/egui/
  - iced: docs.rs では、シンプルさと型安全性を重視したクロスプラットフォーム GUI ライブラリと説明されている。
    - https://docs.iced.rs/iced/
- サーバー / 非同期処理:
  - Tokio は Rust の非同期ランタイムとして広く使われており、ネットワーク処理の基盤に適している。
    - https://tokio.rs/tokio
  - axum は ergonomic / modular な Web アプリケーションフレームワークで、WebSocket 実装にも使える。
    - https://docs.rs/axum/latest/axum/
    - https://docs.rs/axum/latest/axum/extract/ws/
  - tokio-tungstenite は Tokio 上で WebSocket を扱うクレートで、Rust クライアント側の WebSocket 通信候補になる。
    - https://docs.rs/tokio-tungstenite/latest/tokio_tungstenite/
- シリアライズ:
  - クライアント・サーバー間のメッセージ形式は、MVP では Serde + JSON が扱いやすい。
    - https://serde.rs/json.html

### 実装方針の初期案

- MVP の通信は WebSocket が適している
  - クライアントから送信したメッセージを、サーバーが接続中クライアントへ配信できる
  - HTTP polling より双方向通信に向いている
- MVP では永続化なしのインメモリでもよい
  - ただし、アプリ再起動後も履歴を残すなら SQLite などの永続化設計が必要
- 認証なしで始める場合、任意の表示名だけで接続する形が最小
  - ただし、ユーザー識別・なりすまし・履歴所有者の扱いは後で仕様変更が必要になりやすい

## 4. 実装前に人間へ確認したいこと

1. 「Discord」とは、Discord API 連携ではなく、Discord 風の独自チャットアプリという理解でよいですか？
Yes
2. 初回実装は、同一マシン上で `server`、`client1`、`client2` を起動してメッセージ交換できる MVP でよいですか？
Yes
3. クライアント UI はどの方針がよいですか？
   - C: `iced` で Rust アプリらしい Elm 風アーキテクチャ寄り
4. メッセージ履歴は保存しますか？
   - B: SQLite に保存する
5. ユーザー認証は必要ですか？
   - B: 簡易ログインを入れる
サインアップも必要です。パスワードは平文を保存するのではなく、ソルトを加えてハッシュ化したものを保存します。
6. チャンネルやサーバーの概念は初回から必要ですか？
   - C: Discord 風にサーバー / チャンネル階層まで作る
新規チャンネル作成やチャンネル削除も対応してください。
7. 対象 OS はどれですか？
   - C: 今回の開発環境で動けばよい
ただし、今後はWindowsやmacOSにも対応させるので、OS固有のものと共通のものは分けて実装させてください。
8. サーバーとクライアントは同一リポジトリの Cargo workspace として作ってよいですか？
大丈夫です。
9. 今後 Git 管理する場合、`ai/.gitignore` の `*` によって `ai/` 配下が無視されている一方、アプリ本体はリポジトリ直下に作る想定でよいですか？
Yes

## 5. 実装前の助言

- 共通メッセージ型を `common` crate に分けると、サーバーとクライアントで JSON スキーマのズレを防ぎやすくなります。
採用します。
- 後で永続化や認証を入れる可能性があるなら、最初から `user_id`、`message_id`、`timestamp` をメッセージ構造に含めるのがよいです。
採用します。
- 実装後の検証は、最低限以下が必要です。
  - `cargo check`
  - `cargo test`
  - `cargo fmt --check`
  - 可能なら `cargo clippy -- -D warnings`
  - サーバー 1 台 + クライアント 2 台の手動疎通確認
採用します。

## 6. 次に人間から欲しい判断

次のいずれかを選んでください。

- C案: `iced` + `tokio` + `axum WebSocket` + `serde_json` で作る
- D案: UI ライブラリや永続化、認証、チャンネル仕様を追加で決めてから実装する

