# PR をサイドバーに関連付ける

cmux ターミナルまたは Git worktree で GitHub プルリクエストを作成した後に実行します。

```sh
url=$(gh pr create --fill) && cmux pr "$url"
```

`cmux pr 123` も使用できます。git と認証済みの GitHub CLI（`gh auth login`）が必要です。現在のディレクトリのリポジトリを、フォーク元を含む gh のデフォルトリポジトリ設定で確認します。URL が無効、PR が存在しない、取得に失敗、またはリポジトリが一致しない場合、既存のリンクは変更されません。

対象の優先順は `--workspace`、呼び出し元の現在の TTY、`CMUX_WORKSPACE_ID`、呼び出し元 worktree 内のディレクトリを持つ一意のワークスペースです。対象を特定できない場合は `--workspace` の指定を案内して失敗します。選択中のワークスペースを暗黙の対象にしません。`--window` は検索範囲を制限し、フォーカスは変更しません。

```sh
cmux pr https://github.com/owner/repo/pull/123 --workspace workspace:2
cmux pr 124 --workspace workspace:2
cmux pr clear --workspace workspace:2
cmux --json pr 123
```

成功すると既存のクリック可能なサイドバー行が更新されます。表示設定とクリック設定は引き続き適用されます。手動リンクはワークスペースごとに 1 件、現在のセッション中保持されます。同じ指定の繰り返しは冪等です。ブランチ変更、パネル整理、監視処理による削除後も残り、サイドバーのリセット、置換、clear、またはセッション終了で削除されます。同じ PR の監視結果は状態を更新し、行を重複させません。clear は監視処理が独立して検出した PR を非表示にしません。ブランチが監視対象でなくなった手動 PR は `cmux pr 123` を再実行して更新できます。

この機能は Mac のローカル CLI で利用できます。SSH リレーのメソッドは追加しません。詳細は `cmux pr --help` を参照してください。
