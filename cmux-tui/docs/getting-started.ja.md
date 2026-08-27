# cmux-tui の開始

英語版の全ガイドは [getting-started.md](getting-started.md) にあります。

## パッケージのインストールと更新

`cmux` npm パッケージは依存関係を持たないランチャーです。初回起動時にプラット
フォーム用バイナリを取得し、レジストリの sha512 整合性を確認して、macOS では
`~/Library/Caches/cmux-tui-launcher`、Linux では `$XDG_CACHE_HOME/cmux-tui-launcher`
（未設定時は `~/.cache/cmux-tui-launcher`）にバージョン別で保存します。

```bash
npx cmux update           # 最新のプラットフォーム用バイナリを取得
npx cmux update --check   # 更新の有無だけを確認
```

`cmux update` はプラットフォーム用バイナリの通常更新に使います。npm ランチャー自体を
更新する場合は `npx cmux@latest` を使います。前者は npm の `_npx` キャッシュを書き換え
ませんが、後者は cmux 起動前にそのキャッシュへアクセスし、古い状態では
`ENOTEMPTY: directory not empty, rename` で失敗することがあります。

レジストリに接続できない場合は、ランチャーと同じバージョンの tarball をダウンロードし、
ローカルパスからインストールしてください。ランチャーはインストール済みのプラット
フォーム用パッケージを使います。

```bash
npm install -g ./cmux-0.11.0.tgz ./cmux-tui-darwin-arm64-0.11.0.tgz
```

npm のダウンロードキャッシュはランチャーから読み取れません。別の方法として、ランチャー
キャッシュへ直接配置し、`CMUX_TUI_LAUNCHER_CACHE` でそのディレクトリを指定できます。

## npx の ENOTEMPTY エラー

`npx cmux@latest` が npm の処理中に失敗した場合は、npm のキャッシュ場所を確認して
`_npx` だけを削除します。

```bash
npm_cache="$(npm config get cache)"
target="$npm_cache/_npx"
printf '削除対象: %s\n' "$target"
case "$npm_cache" in
  ""|/|"$HOME"|"$HOME/"*) echo "安全でない npm キャッシュパスのため中止します" >&2; exit 1 ;;
esac
read -r -p '続行する場合は yes と入力してください: ' confirm
[ "$confirm" = yes ] || exit 1
rm -rf -- "$target"
npx cmux@latest
```
