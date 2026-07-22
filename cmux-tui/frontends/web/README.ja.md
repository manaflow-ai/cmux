# cmux-tui ウェブフロントエンド

[English](README.md)

プロトコルv9のWebSocket APIとTypeScript SDKのブラウザ向けエントリだけで、
自然なcmuxクライアントを構築できることを示す小規模なサードパーティー形式の
フロントエンドです。信頼できるワークスペースツリーの表示、アクティブなPTY
サーフェスへのxterm.jsの接続、キーボード入力の転送、ターミナルセル単位の
リサイズ、購読した無効化イベントと通知イベントの反映を行います。

## インストール

このアプリは`file:../../bindings/typescript`を通じて`cmux`を利用し、npmで
公開されたSDKには依存しません。フロントエンドをインストールする前に、ローカル
パッケージをビルドしてください。

```bash
cd ../../bindings/typescript && npm ci && npm run build
cd ../../frontends/web && npm ci
```

## 実行

このディレクトリから2つのターミナルで次のコマンドを実行します。

```bash
~/.local/bin/cmux-tui --headless --session webfront --ws 127.0.0.1:7681 --ws-token change-me
```

```bash
npm run dev
```

`http://localhost:5173`を開き、既定のWebSocket URLのまま接続します。ブラウザと
TUIに同じ6桁のコードが表示されます。TUIでEnterを押して承認します。
`--ws-token <token>`は自動化用の非対話バイパスとして引き続き利用できます。

## スクリーンショット

> スクリーンショット用プレースホルダー — ワークスペースツリー、タブ列、接続済み
> ターミナル、接続状態、通知トーストをここに掲載します。

## この実装で示すもの

- TUI承認ペアリングと任意の静的トークンバイパスを含む、`cmux/browser`の
  `CmuxClient`と`WebSocketTransport`。
- イベントとコマンド応答の混在に対応する、購読開始後のスナップショット取得と
  再調整。
- `attachSurface()`のリプレイとバイトストリームのxterm.jsへの直接入力。
- キーボード、末尾100msでデバウンスする`ResizeObserver`、タブ選択、再接続の
  バックオフ、通知、未読の注意状態。
- 安定した分割IDによる表示と、`set-split-ratio`を使った正確な境界サイズ変更。
- 1つの展開ペインと折りたたまれたタイトル行を持つZellij形式のスタックレイアウト。

## 今後の対応

- ブラウザ固有のattachイベントを利用したブラウザサーフェスの表示。
- 接続プロファイルの保存と、ユーザーが操作できる切断アクション。

## リモートアクセスとワンタップリンク

localhost以外のホストから配信する場合、WebSocket URLは`wss://<hostname>:8443`が既定です。`tailscale serve --https=8443 <ws-port>`などでTLSを前段に置いてください。`?ws=<url>`はアドレスバーから消去され、最後のURLは`localStorage`に保存されます。自動化では`?ws=<url>#token=<token>`を使用します。トークンのフラグメントはHTTPリクエストに含まれず、直ちに消去されて保存されません。
