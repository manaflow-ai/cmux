//! `usage` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct UsageRecordingMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub no_home: &'static str,
    pub status_on: &'static str,
    pub status_off: &'static str,
    pub cleared: &'static str,
    pub not_sharing: &'static str,
    pub dry_run: &'static str,
    pub nothing_pending: &'static str,
    pub uploaded: &'static str,
    pub upload_refused: &'static str,
    pub cursor_failed: &'static str,
    pub deleted: &'static str,
    pub delete_refused: &'static str,
    pub bad_credential_stdin: &'static str,
    pub no_token: &'static str,
}

pub(super) const ENGLISH: UsageRecordingMessages = UsageRecordingMessages {
    usage: "usage: cmux usage report|status|path|clear [--days N] [--dir DIR] [--json]\n       cmux usage upload [--dry-run] [--dir DIR] [--json]\n       cmux usage delete-shared [--json]\n\nRead what opt-in usage recording kept on this machine. Turn recording on or off\nwith the Usage Recording switch in Settings > Privacy (or `cmux settings set\ndiagnostics.usageRecording true --confirm`). It records the shape of use only:\nwhich kind of tab had the keyboard, action ids and how they started, counts of\nwhat is open, latencies and agent token counts. Never message text, file paths,\nURLs or titles; tab and session ids are hashed with this machine's salt.\n\n  report          Distributions over the window: time in agent chats, browsers and\n                  terminals, hidden-to-return times, chats per hour, most used\n                  actions, latencies, what is open, agent turns and tokens.\n  status          Whether recording is on, since when, the folder and its size.\n  path            The usage folder.\n  clear           Delete everything recorded here (recording stays as it is).\n  upload          Send the records not sent yet to your cmux team. Needs Share Usage\n                  with the Team on in Settings > Privacy on this machine (the app\n                  also uploads by itself, at most every 6 hours). Stops at the first\n                  batch the team refuses and prints its code.\n  delete-shared   Delete every usage record you shared with your team.\n\n  --days N        The report's window in days (default 7).\n  --dir DIR       The usage folder. Default: CMUX_USAGE_DIR, else this\n                  machine's usage folder (`cmux usage path` prints it).\n  --dry-run       upload: print how many records would go and one of them; send\n                  nothing (works with sharing off).\n  --credential-stdin\n                  upload, delete-shared: read {\"platform\", \"credential\"} from stdin\n                  instead of asking the cmux app for a token (the app uses this).\n",
    unknown_verb: "unknown usage verb \"{verb}\"; use report, status, path, clear, upload or delete-shared",
    no_home: "no usage folder: set CMUX_USAGE_DIR or pass --dir",
    status_on: "Usage recording is on (since {since}). {dir}: {files} files, {kb} KB.\n",
    status_off: "Usage recording is off. {dir}: {files} files, {kb} KB. Turn it on in Settings > Privacy > Usage Recording.\n",
    cleared: "Deleted {files} usage files in {dir}.\n",
    not_sharing: "usage sharing is off on this machine: turn on Share Usage with the Team in Settings > Privacy (it needs Record Usage on This Mac), or run `cmux usage upload --dry-run` to see what would go",
    dry_run: "{count} records would go to your team from {dir} (install {install}). The first one:\n{sample}\n",
    nothing_pending: "Nothing new to send from {dir}.\n",
    uploaded: "Sent {records} records to your team in {batches} batches ({accepted} new, {duplicates} already there).\n",
    upload_refused: "sent {records} records, then the team refused the next batch ({reason}); nothing more was sent, and the next upload starts there",
    cursor_failed: "sent {records} records but could not save how far the upload got ({error}); the next upload sends them again and the team counts them once",
    deleted: "Deleted {deleted} usage records you shared with your team.\n",
    delete_refused: "the team refused the delete ({reason})",
    bad_credential_stdin: "--credential-stdin needs one JSON object {\"platform\": URL, \"credential\": TOKEN} on stdin",
    no_token: "the cmux app gave no access token: sign in to cmux first (`cmux login`)",
};

pub(super) const JAPANESE: UsageRecordingMessages = UsageRecordingMessages {
    usage: "使い方: cmux usage report|status|path|clear [--days N] [--dir フォルダ] [--json]\n        cmux usage upload [--dry-run] [--dir フォルダ] [--json]\n        cmux usage delete-shared [--json]\n\nオプトインの利用記録がこのマシンに残した内容を読みます。記録のオンとオフは\n設定 > プライバシー の「利用記録」スイッチ (または `cmux settings set\ndiagnostics.usageRecording true --confirm`) で切り替えます。記録するのは使い方の\n形だけです: どの種類のタブにキーボードがあったか、アクション ID と起動方法、\n開いているものの数、待ち時間、エージェントのトークン数。メッセージ本文、ファイル\nパス、URL、タイトルは記録しません。タブとセッションの ID はこのマシンのソルトで\nハッシュ化します。\n\n  report          期間内の分布: エージェントチャット、ブラウザ、ターミナルでの時間、\n                  非表示から戻るまでの時間、1 時間あたりのチャット数、よく使う\n                  アクション、待ち時間、開いているもの、エージェントのターンとトークン。\n  status          記録がオンか、いつからか、フォルダとそのサイズ。\n  path            利用記録のフォルダ。\n  clear           ここに記録した内容をすべて削除します (記録のオンとオフは変えません)。\n  upload          まだ送っていない記録を cmux のチームに送ります。このマシンの\n                  設定 > プライバシー で「チームと使用状況を共有」がオンである必要が\n                  あります (アプリも 6 時間に一度まで自動で送ります)。チームが拒否した\n                  最初のバッチで止まり、そのコードを表示します。\n  delete-shared   チームと共有した利用記録をすべて削除します。\n\n  --days N        report の期間 (日数、既定 7)。\n  --dir フォルダ  利用記録のフォルダ。既定: CMUX_USAGE_DIR、なければこの\n                  マシンの利用記録フォルダ (`cmux usage path` で表示)。\n  --dry-run       upload: 送る記録の数とその一つを表示し、何も送りません\n                  (共有がオフでも使えます)。\n  --credential-stdin\n                  upload、delete-shared: cmux アプリにトークンを求めず、stdin から\n                  {\"platform\", \"credential\"} を読みます (アプリが使います)。\n",
    unknown_verb: "usage の動詞「{verb}」は不明です。report、status、path、clear、upload、delete-shared を使ってください",
    no_home: "利用記録のフォルダがありません: CMUX_USAGE_DIR を設定するか --dir を指定してください",
    status_on: "利用記録はオンです ({since} から)。{dir}: ファイル {files} 個、{kb} KB。\n",
    status_off: "利用記録はオフです。{dir}: ファイル {files} 個、{kb} KB。設定 > プライバシー > 利用記録 でオンにできます。\n",
    cleared: "{dir} の利用記録ファイル {files} 個を削除しました。\n",
    not_sharing: "このマシンでは利用状況の共有がオフです: 設定 > プライバシー で「チームと使用状況を共有」をオンにしてください (「このMacで使用状況を記録」のオンが必要です)。送る内容は `cmux usage upload --dry-run` で確認できます",
    dry_run: "{dir} から記録 {count} 件をチームに送ります (インストール {install})。最初の一件:\n{sample}\n",
    nothing_pending: "{dir} から送る新しい記録はありません。\n",
    uploaded: "記録 {records} 件を {batches} 回に分けてチームに送りました (新規 {accepted} 件、送信済み {duplicates} 件)。\n",
    upload_refused: "記録 {records} 件を送った後、チームが次のバッチを拒否しました ({reason})。それ以降は送っていません。次の upload はそこから始まります",
    cursor_failed: "記録 {records} 件を送りましたが、どこまで送ったかを保存できませんでした ({error})。次の upload で再送し、チームでは一度だけ数えます",
    deleted: "チームと共有した利用記録 {deleted} 件を削除しました。\n",
    delete_refused: "チームが削除を拒否しました ({reason})",
    bad_credential_stdin: "--credential-stdin には stdin に JSON オブジェクト {\"platform\": URL, \"credential\": トークン} が一つ必要です",
    no_token: "cmux アプリからアクセストークンを得られませんでした: 先に cmux にサインインしてください (`cmux login`)",
};
