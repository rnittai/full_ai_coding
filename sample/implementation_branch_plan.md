# 実装ブランチ計画

## 1 ユーザー要望

ブラウザエンジンを使用せず、Rust でネイティブな軽量 Discord 風チャットアプリを作る。サーバーと `iced` クライアントを同一 Cargo workspace に実装し、サインアップ・ログイン、SQLite 永続化、サーバー / チャンネル階層、チャンネル作成・削除、クライアント 2 台でのメッセージ送受信を実現する。

計画上の統合先 goal branch は `goal/native-rust-chat` とする。実際のブランチ作成はこのフェーズでは行わない。

## 2. 作成するブランチ一覧

1. `feature/01-workspace-common`
2. `feature/02-server-storage-auth`
3. `feature/03-server-channels-realtime`
4. `feature/04-iced-client-auth-shell`
5. `feature/05-iced-client-chat-realtime`
6. `feature/06-verification-docs`

## 3. 各ブランチの仕様

### Branch 1: `feature/01-workspace-common`

#### 目的

Rust Cargo workspace の土台を作り、サーバーとクライアントが共有する型、バリデーション、通信 DTO を定義する。後続ブランチが同じデータ構造を使える状態にする。

#### 変更対象

- `Cargo.toml`: new
- `Cargo.lock`: new
- `crates/common/Cargo.toml`: new
- `crates/common/src/lib.rs`: new
- `crates/common/src/ids.rs`: new
- `crates/common/src/models.rs`: new
- `crates/common/src/protocol.rs`: new
- `crates/common/src/validation.rs`: new
- `README.md`: new

#### 主な作業内容

- Cargo workspace を作成する
- `common` crate を作成する
- `UserId`、`ServerId`、`ChannelId`、`MessageId` などの ID 型を定義する
- `UserSummary`、`ServerSummary`、`ChannelSummary`、`ChatMessage` などの共通モデルを定義する
- HTTP API と WebSocket で使う request / response / event DTO を定義する
- ユーザー名、チャンネル名、メッセージ本文の基本バリデーションを実装する
- README にプロジェクト概要と想定コマンドを記載する

#### 含めない作業

- サーバー実装
- SQLite 実装
- 認証実装
- `iced` クライアント実装
- WebSocket 実装
- 実際の疎通確認

#### 検証方法

- `cargo check`
- `cargo test`
- `cargo fmt --check`
- DTO の JSON シリアライズ / デシリアライズ単体テスト
- バリデーション単体テスト

#### リスク・注意点

- 後続ブランチ全体に影響するため、型名と DTO の責務を広げすぎない
- 確定仕様ではない API 詳細は、仮仕様の範囲として最小限に留める
- パスワード本文を DTO の Debug 出力やログに出さない設計を意識する

#### マージ判断基準

- workspace が `cargo check` できる
- `common` crate の単体テストが通る
- 後続のサーバー / クライアントが使う最小 DTO が揃っている
- 実装対象外の機能を先取りしていない

### Branch 2: `feature/02-server-storage-auth`

#### 目的

SQLite 永続化、DB 初期化、サインアップ、ログイン、パスワードハッシュ、認証トークン管理を持つサーバー基盤を実装する。

#### 変更対象

- `Cargo.toml`: edit
- `crates/server/Cargo.toml`: new
- `crates/server/src/main.rs`: new
- `crates/server/src/config.rs`: new
- `crates/server/src/error.rs`: new
- `crates/server/src/db.rs`: new
- `crates/server/src/auth.rs`: new
- `crates/server/src/routes/mod.rs`: new
- `crates/server/src/routes/auth.rs`: new
- `crates/server/src/routes/bootstrap.rs`: new
- `crates/server/src/state.rs`: new
- `crates/server/tests/auth_flow.rs`: new
- `README.md`: edit

#### 主な作業内容

- `server` crate を workspace に追加する
- サーバー設定として host、port、SQLite DB path を扱う
- SQLite 接続とテーブル初期化を実装する
- `users`、`servers`、`channels`、`messages`、`sessions` 相当のテーブルを作成する
- 初期サーバーと初期チャンネルを用意する
- Argon2id 仮仕様に基づくパスワードハッシュ作成と検証を実装する
- `POST /api/signup` を実装する
- `POST /api/login` を実装する
- `GET /api/bootstrap` を実装する
- 認証済み API のためのトークン検証を実装する
- DB と認証の結合テストを追加する

#### 含めない作業

- WebSocket のリアルタイム配信
- チャンネル作成 / 削除 API
- メッセージ送信 API / 保存 API
- GUI クライアント
- サーバー作成 / 削除
- 本番用 TLS

#### 検証方法

- `cargo check`
- `cargo test`
- `cargo fmt --check`
- サインアップ成功の結合テスト
- 重複ユーザー名でサインアップ失敗するテスト
- 正しいパスワードでログイン成功するテスト
- 誤ったパスワードでログイン失敗するテスト
- パスワード平文が DB に保存されないことの確認

#### リスク・注意点

- パスワードや認証トークンをログ出力しない
- 汎用 SHA-256 だけの高速ハッシュに置き換えない
- DB 初期化をアプリ起動時に安全に行う
- 最後の 1 チャンネル削除可否は未確定のため、このブランチでは削除仕様を実装しない

#### マージ判断基準

- サーバーが起動できる
- サインアップ、ログイン、bootstrap がテストで確認できる
- パスワードがソルト付きハッシュとして保存される
- 認証基盤が後続 API / WebSocket で再利用できる

### Branch 3: `feature/03-server-channels-realtime`

#### 目的

サーバー側にチャンネル作成・削除、メッセージ保存、WebSocket によるリアルタイム配信を追加する。

#### 変更対象

- `crates/common/src/protocol.rs`: edit
- `crates/common/src/models.rs`: edit
- `crates/server/src/routes/mod.rs`: edit
- `crates/server/src/routes/channels.rs`: new
- `crates/server/src/routes/messages.rs`: new
- `crates/server/src/ws.rs`: new
- `crates/server/src/hub.rs`: new
- `crates/server/src/db.rs`: edit
- `crates/server/src/state.rs`: edit
- `crates/server/tests/channel_flow.rs`: new
- `crates/server/tests/message_flow.rs`: new
- `README.md`: edit

#### 主な作業内容

- `POST /api/servers/{server_id}/channels` を実装する
- `DELETE /api/channels/{channel_id}` を実装する
- `GET /api/channels/{channel_id}/messages` を実装する
- WebSocket `GET /ws` を実装する
- WebSocket の `subscribe_channel`、`send_message` を実装する
- `message_created`、`channel_created`、`channel_deleted`、`error` イベントを配信する
- メッセージを SQLite に保存してから配信する
- チャンネル作成・削除を接続中クライアントへ通知する
- チャンネル削除時の履歴扱いは仕様書の未確定事項に従い、実装前に確認済みの方針を採用する

#### 含めない作業

- GUI クライアント
- サーバー作成 / 削除
- 権限、ロール、メンバーシップ制御
- 添付ファイル、リアクション、DM
- 大規模配信最適化

#### 検証方法

- `cargo check`
- `cargo test`
- `cargo fmt --check`
- チャンネル作成 API の結合テスト
- チャンネル削除 API の結合テスト
- メッセージ保存の結合テスト
- WebSocket でメッセージが配信される結合テスト
- 未認証 WebSocket 接続が拒否されるテスト
- 不正 JSON でサーバーがクラッシュしないことのテスト

#### リスク・注意点

- WebSocket 接続管理は共有状態が複雑になりやすい
- DB 保存前に配信すると履歴と表示がずれるため、保存成功後に配信する
- チャンネル削除時に購読中クライアントを破綻させない
- 認証済みユーザー以外が WebSocket を使えないようにする

#### マージ判断基準

- 認証済みクライアントが WebSocket 接続できる
- チャンネル作成・削除が DB とイベント配信に反映される
- メッセージが DB に保存され、購読中クライアントへ配信される
- サーバー単体で主要 API / WebSocket の結合テストが通る

### Branch 4: `feature/04-iced-client-auth-shell`

#### 目的

`iced` クライアントの土台、ログイン / サインアップ画面、認証 API 連携、チャット画面の基本レイアウトを実装する。

#### 変更対象

- `Cargo.toml`: edit
- `crates/client/Cargo.toml`: new
- `crates/client/src/main.rs`: new
- `crates/client/src/app.rs`: new
- `crates/client/src/config.rs`: new
- `crates/client/src/api.rs`: new
- `crates/client/src/platform/mod.rs`: new
- `crates/client/src/platform/common.rs`: new
- `crates/client/src/views/mod.rs`: new
- `crates/client/src/views/auth.rs`: new
- `crates/client/src/views/chat_shell.rs`: new
- `crates/client/src/state.rs`: new
- `README.md`: edit

#### 主な作業内容

- `client` crate を workspace に追加する
- `iced` アプリの起動処理を作る
- OS 固有処理を隔離する `platform` モジュールを用意する
- 接続先 URL、ユーザー名、パスワード入力を持つ認証画面を作る
- `POST /api/signup` と `POST /api/login` を呼び出す通信層を作る
- ログイン成功後に `GET /api/bootstrap` を呼び、サーバー / チャンネル一覧を取得する
- チャット画面の基本レイアウトを作る
- 未ログイン時はチャット画面を表示しない
- 通信中、成功、失敗の状態表示を実装する

#### 含めない作業

- WebSocket 接続
- メッセージ送受信
- チャンネル作成 / 削除操作
- メッセージ履歴表示の完成
- デザインの細かな作り込み

#### 検証方法

- `cargo check`
- `cargo test`
- `cargo fmt --check`
- クライアント crate の状態遷移単体テスト
- 手動でログイン / サインアップ画面が起動することを確認
- サーバー起動状態でサインアップ・ログインできることを確認
- ログイン成功後にチャット画面へ遷移することを確認

#### リスク・注意点

- `iced` の非同期処理と UI 状態更新のつなぎ込みで状態が複雑になりやすい
- パスワード入力はマスク表示にする
- 認証トークンを画面やログに出さない
- OS 固有処理を UI や通信層に混ぜない

#### マージ判断基準

- クライアントが起動できる
- サインアップ・ログイン API と連携できる
- ログイン後にサーバー / チャンネル一覧の初期表示ができる
- WebSocket 未実装でも UI が破綻しない

### Branch 5: `feature/05-iced-client-chat-realtime`

#### 目的

`iced` クライアントにチャンネル作成・削除、メッセージ履歴表示、WebSocket リアルタイム送受信を実装し、クライアント 2 台での双方向チャットを完成させる。

#### 変更対象

- `crates/client/src/api.rs`: edit
- `crates/client/src/ws.rs`: new
- `crates/client/src/app.rs`: edit
- `crates/client/src/state.rs`: edit
- `crates/client/src/views/chat_shell.rs`: edit
- `crates/client/src/views/channel_dialog.rs`: new
- `crates/client/src/views/message_list.rs`: new
- `crates/client/src/views/message_input.rs`: new
- `crates/client/tests/client_state.rs`: new
- `README.md`: edit

#### 主な作業内容

- チャンネル選択時にメッセージ履歴を読み込む
- WebSocket 接続を確立する
- チャンネル購読を行う
- メッセージ入力と送信を実装する
- `message_created` を受けてメッセージ一覧を更新する
- チャンネル作成 UI と API 呼び出しを実装する
- チャンネル削除 UI と API 呼び出しを実装する
- `channel_created`、`channel_deleted` を受けてチャンネル一覧を更新する
- 削除されたチャンネルを表示中の場合、別チャンネル選択または未選択状態へ遷移する
- クライアント 1 とクライアント 2 で双方向メッセージ送受信を手動確認する

#### 含めない作業

- サーバー側 API の大きな変更
- 認証方式の変更
- サーバー作成 / 削除
- 権限、ロール、メンバーシップ制御
- 添付ファイルや通知
- Windows / macOS 固有対応

#### 検証方法

- `cargo check`
- `cargo test`
- `cargo fmt --check`
- クライアント状態遷移の単体テスト
- サーバー 1 台 + クライアント 2 台の手動確認
- クライアント 1 のメッセージがクライアント 2 に表示されること
- クライアント 2 のメッセージがクライアント 1 に表示されること
- チャンネル作成が両クライアントに反映されること
- チャンネル削除が両クライアントに反映されること
- サーバー再起動後に履歴が残ること

#### リスク・注意点

- WebSocket 受信タスクと `iced` の状態更新を安全に橋渡しする必要がある
- 接続切断時に UI が固まらないようにする
- 重複イベントで同じメッセージが二重表示されないようにする
- 削除済みチャンネルへの送信を UI 側でも防ぐ

#### マージ判断基準

- 2 クライアントで双方向メッセージ送受信できる
- チャンネル作成・削除がリアルタイムに反映される
- メッセージ履歴が SQLite から再表示される
- クライアント切断や不正状態で致命的クラッシュしない

### Branch 6: `feature/06-verification-docs`

#### 目的

全体の検証、README 整備、手動確認手順の明文化、未確定仮仕様の実装結果整理を行い、goal branch へ統合できる状態にする。

#### 変更対象

- `README.md`: edit
- `docs/manual-test.md`: new
- `docs/architecture.md`: new
- `crates/common/*`: edit
- `crates/server/*`: edit
- `crates/client/*`: edit

#### 主な作業内容

- README にセットアップ、起動方法、検証方法を記載する
- サーバー 1 台 + クライアント 2 台の手動確認手順を `docs/manual-test.md` に記載する
- Cargo workspace 全体の構成を `docs/architecture.md` に記載する
- 仮仕様として採用した項目を実装結果に合わせて整理する
- テスト不足や明らかなエラー処理不足を補う
- `cargo check`、`cargo test`、`cargo fmt --check`、可能なら `cargo clippy -- -D warnings` を実行する
- 手動疎通確認を実施する

#### 含めない作業

- 新規大型機能
- UI ライブラリ変更
- 認証方式の大幅変更
- Windows / macOS 対応の実装
- 本番運用向け TLS や権限管理

#### 検証方法

- `cargo check`
- `cargo test`
- `cargo fmt --check`
- 可能なら `cargo clippy -- -D warnings`
- README 手順どおりにサーバーを起動できること
- README 手順どおりにクライアントを 2 台起動できること
- `docs/manual-test.md` の手順でサインアップ、ログイン、チャンネル作成、メッセージ送受信、チャンネル削除、再起動後履歴確認ができること
- `ai/` 配下の作業フロー用ファイルを壊していないこと

#### リスク・注意点

- このブランチで大きな機能追加を始めるとレビュー不能になる
- ドキュメントと実装がずれないように、実際の起動コマンドを確認してから記載する
- `clippy` が環境や依存都合で実行できない場合は理由を明記する

#### マージ判断基準

- 仕様書の主要要件が満たされている
- 2 クライアントの手動疎通が確認済み
- 必須検証コマンドが成功している、または実行不可の理由が明記されている
- 起動手順と手動確認手順がドキュメント化されている
- goal branch に統合しても後続作業者が再現できる状態になっている

## 4. 依存関係とマージ順序

1. `feature/01-workspace-common`
   - すべての後続ブランチの前提
2. `feature/02-server-storage-auth`
   - `feature/01-workspace-common` に依存
3. `feature/03-server-channels-realtime`
   - `feature/02-server-storage-auth` に依存
4. `feature/04-iced-client-auth-shell`
   - `feature/02-server-storage-auth` 以降で実装しやすい
   - API 契約が固まっていれば `feature/03-server-channels-realtime` と一部並行可能
5. `feature/05-iced-client-chat-realtime`
   - `feature/03-server-channels-realtime` と `feature/04-iced-client-auth-shell` に依存
6. `feature/06-verification-docs`
   - すべての実装ブランチに依存

## 5. 実装前に再確認すべき未確定事項

- パスワードハッシュ方式を Argon2id 仮仕様のまま進めるか
- 最後の 1 チャンネルを削除可能にするか、最低 1 チャンネルを維持するか
- サーバー作成・削除機能は今回対象外のままでよいか
- チャンネル削除時、過去メッセージを物理削除するか、論理削除して履歴を保持するか
- ユーザー名、パスワード、チャンネル名、メッセージ本文の長さ制限を仮仕様のまま進めるか

## 6. 全体リスク

- `iced` と非同期 WebSocket 受信の統合は状態管理が複雑になりやすい
- パスワードハッシュ、認証トークン、ログ出力はセキュリティ事故につながりやすい
- SQLite と WebSocket 配信の順序がずれると、保存済み履歴とリアルタイム表示が不一致になる
- チャンネル削除時の購読解除、表示中チャンネルの扱い、メッセージ送信禁止を揃える必要がある
- 初回コミット前のリポジトリであり、Git 追跡対象や `.gitignore` の扱いを実装時に確認する必要がある
