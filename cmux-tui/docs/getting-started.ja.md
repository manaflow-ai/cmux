# cmux-tui の開始

英語版の全ガイドは [getting-started.md](getting-started.md) にあります。

## パッケージのインストールと更新

`cmux` npm パッケージは依存関係を持たないランチャーです。初回起動時にプラット
フォーム用バイナリを取得し、レジストリの sha512 整合性を確認して、macOS では
`~/Library/Caches/cmux-tui-launcher`、Linux では `$XDG_CACHE_HOME/cmux-tui-launcher`
（未設定時は `~/.cache/cmux-tui-launcher`）にバージョン別で保存します。

書き込み可能なキャッシュは起動前に認証済みパッケージメタデータを取得し、公開元のバイナリ
ダイジェストと照合するため、通常のキャッシュヒットでもネットワークを使用します。レジストリが
ダイジェストを提供しない場合は、書き込み可能なキャッシュヒットごとに tarball 全体を検証します。
完全な読み取り専用キャッシュは管理者が用意したものとして扱い、バイナリとマニフェストを検証済み
ならオフラインで起動できます。

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
キャッシュへ直接配置し、`CMUX_TUI_LAUNCHER_CACHE` でそのディレクトリを指定できます。検証済みで
実行権限のあるバイナリは、読み取り専用のランチャーキャッシュからネットワークなしで起動できます。
この場合ランチャーはリースの作成とプルーニングを行わないため、バイナリの実行権限を保ち、キャッシュ管理者が更新してください。

## npx の ENOTEMPTY エラー

`npx cmux@latest` が npm の処理中に失敗した場合は、すべての `npx` プロセスを先に停止してください。
以下のコマンドは回復ロックを取得し、選択したエントリが使用中でないことを確認し、最新のエントリを拒否します。
エラーに出たキャッシュハッシュだけを隔離ディレクトリへ移動し、使用中のキャッシュツリーを削除しません。

```bash
set -eu

npm_cache="$(npm config get cache)"
target="$npm_cache/_npx"
case "$npm_cache" in
  ""|/|.|./*|../*|*/./*|*/../*|*/.|*/..) echo "安全でない npm キャッシュパスのため中止します" >&2; exit 1 ;;
  /*) ;;
  *) echo "相対 npm キャッシュパスのため中止します" >&2; exit 1 ;;
esac
if [ ! -d "$target" ]; then
  echo "npx キャッシュディレクトリがありません: $target" >&2
  exit 1
fi
if [ -L "$target" ]; then
  echo "シンボリックリンクの npx キャッシュディレクトリのため中止します: $target" >&2
  exit 1
fi

lock="$npm_cache/.cmux-npx-recovery.lock"
if ! (umask 077 && mkdir "$lock" 2>/dev/null); then
  echo "別の npx 回復処理が実行中か、このロックを手動で確認する必要があります: $lock" >&2
  exit 1
fi
unlock() {
  rmdir "$lock" 2>/dev/null || true
}
abort() {
  unlock
  exit 1
}
trap unlock EXIT
trap abort HUP INT TERM

printf '利用可能な npx エントリ:\n'
newest_entry=""
newest_mtime=""
entry_mtime() {
  value="$(stat -f %m "$1" 2>/dev/null || true)"
  case "$value" in
    ''|*[!0-9]*) ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
  value="$(stat -c %Y "$1" 2>/dev/null || true)"
  case "$value" in
    ''|*[!0-9]*) return 1 ;;
    *) printf '%s\n' "$value"; return 0 ;;
  esac
}
for candidate in "$target"/*; do
  [ -d "$candidate" ] || continue
  [ ! -L "$candidate" ] || { echo "シンボリックリンクの npx エントリのため中止します: $candidate" >&2; exit 1; }
  name="${candidate##*/}"
  case "$name" in
    ''|*[!A-Za-z0-9_-]*) echo "予期しない npx エントリのため中止します: $candidate" >&2; exit 1 ;;
  esac
  mtime="$(entry_mtime "$candidate")" || {
    echo "npx エントリの時刻を確認できません: $candidate" >&2
    exit 1
  }
  printf '%s\n' "$candidate"
  if [ -z "$newest_mtime" ] || [ "$mtime" -gt "$newest_mtime" ]; then
    newest_entry="$candidate"
    newest_mtime="$mtime"
  fi
done
read -r -p '隔離する npx キャッシュハッシュを正確に入力してください: ' hash
case "$hash" in
  ""|[-.]*|*[!A-Za-z0-9_-]*)
    echo "無効な npx キャッシュハッシュのため中止します" >&2
    exit 1
    ;;
esac
entry="$target/$hash"
if [ ! -d "$entry" ]; then
  echo "npx キャッシュエントリがありません: $hash" >&2
  exit 1
fi
if [ -L "$entry" ]; then
  echo "シンボリックリンクの npx キャッシュエントリのため中止します: $entry" >&2
  exit 1
fi
entry_mtime="$(entry_mtime "$entry")" || {
  echo "選択した npx エントリを確認できません: $entry" >&2
  exit 1
}
if [ "$entry" = "$newest_entry" ] || [ "$entry_mtime" -ge "$newest_mtime" ]; then
  echo "最新の npx エントリは移動しません。エラーに出た古いハッシュを使用してください" >&2
  exit 1
fi
if ! command -v lsof >/dev/null 2>&1; then
  echo "npx エントリが使用中か確認するため lsof が必要です" >&2
  exit 1
fi
assert_entry_inactive() {
  if [ ! -d "$entry" ] || [ -L "$entry" ]; then
    echo "選択した npx エントリが変更されたか、シンボリックリンクになっています: $entry" >&2
    exit 1
  fi
  if open_pids="$(lsof -nP -t +D "$entry" 2>&1)"; then
    [ -z "$open_pids" ] || {
      echo "プロセスが開いている npx エントリのため中止します: $open_pids" >&2
      exit 1
    }
  else
    lsof_status=$?
    if [ "$lsof_status" -ne 1 ] || [ -n "$open_pids" ]; then
      echo "npx エントリが非アクティブだと確認できません: $entry" >&2
      exit 1
    fi
  fi
}
assert_entry_inactive
printf '隔離対象（このエントリだけ）: %s\n' "$entry"
read -r -p '続行する場合は yes と入力してください: ' confirm
[ "$confirm" = yes ] || exit 1
quarantine="$npm_cache/.cmux-npx-quarantine"
if [ -L "$quarantine" ] || { [ -e "$quarantine" ] && [ ! -d "$quarantine" ]; }; then
  echo "安全でない隔離パスのため中止します: $quarantine" >&2
  exit 1
fi
mkdir -p "$quarantine"
destination="$quarantine/${hash}-$(date +%s)-$$"
[ ! -e "$destination" ] || {
  echo "既存の隔離エントリを上書きするため中止します: $destination" >&2
  exit 1
}
# 確認後、隔離へ原子的に移動する直前に再確認します。
assert_entry_inactive
mv "$entry" "$destination"
printf '隔離先: %s\n' "$destination"
npx cmux@latest
```

移動は隔離エントリが残っている間は元に戻せます。すべての `npx` プロセスを停止し、新しいランチャーが動くことを確認してから、通常のファイルマネージャーで隔離エントリを削除してください。
