# cmux-next の端末の TERM

cmux-next の新しい端末は、すべて `TERM=xterm-256color` で始まります。この名前は
すべてのプログラムが知っており、すべての ssh ホスト、VM、コンテナに terminfo
エントリがあります。そのため `clear`、`htop`、`vim`、`tmux`、`less` は、Ghostty
を知らないホストに `ssh` した後も動き、"unknown terminal type" のエラーは出ません。

端末の機能は次の変数で伝わります。

- `COLORTERM=truecolor`: 24 ビットカラーが使えます。
- `TERM_PROGRAM=ghostty` と `TERM_PROGRAM_VERSION`: Neovim などのプログラムは、
  これらから Ghostty の機能を判別します。

Mac に Ghostty.app やその terminfo がインストールされていても、cmux-next は
`xterm-ghostty` を選びません。値はシェルの起動の最初のバイトから同じで、
シェル統合が途中で変えることはありません。

## 別の TERM を選ぶ

`~/.config/cmux/cmux-next.json` の `terminal.term`、または 設定 > 端末 > 互換性 >
端末タイプ (TERM) で設定します。

```json
{ "terminal": { "term": "xterm-ghostty" } }
```

- cmux は、その名前の terminfo エントリが、この Mac で ncurses が探す場所
  (`~/.terminfo`、`/usr/share/terminfo`、`/opt/homebrew/share/terminfo` などの
  システムフォルダ) にインストールされている場合にだけ使います。ない場合、新しい
  端末は `xterm-256color` になり、アプリはその理由をログに書きます。
- `terminal.term` を設定していない場合は、Ghostty の設定にある `term = ...` の行が
  同じ確認のうえで使われます。Ghostty 自身の既定値 (`xterm-ghostty`) は使われません。
- 変更は新しい端末に適用されます。開いている端末は `TERM` をそのまま保ちます。
  cmux が復元、再オープン、再起動する端末は、作成時の `TERM` を保ちます。
  `xterm-ghostty` で作った端末は `xterm-ghostty` のまま戻ります。以前のビルドで
  作った端末は `xterm-256color` で戻ります。
- この設定はエージェントには変更できません。変更できるのはあなただけです。

`xterm-ghostty` を使うと、そのエントリがない ssh ホストでは "unknown terminal
type" と表示されます。そのホストにエントリをインストールする
(`infocmp -x xterm-ghostty | ssh HOST -- tic -x -`) か、既定値のままにしてください。
