//! `usage` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct UsageRecordingMessages {
    pub usage: &'static str,
    pub unknown_verb: &'static str,
    pub no_home: &'static str,
    pub status_on: &'static str,
    pub status_off: &'static str,
    pub cleared: &'static str,
}

pub(super) const ENGLISH: UsageRecordingMessages = UsageRecordingMessages {
    usage: "usage: cmux usage report|status|path|clear [--days N] [--dir DIR] [--json]\n\nRead what opt-in usage recording kept on this machine. Turn recording on or off\nwith the Usage Recording switch in Settings > Privacy (or `cmux settings set\ndiagnostics.usageRecording true --confirm`). It records the shape of use only:\nwhich kind of tab had the keyboard, action ids and how they started, counts of\nwhat is open, latencies and agent token counts. Never message text, file paths,\nURLs or titles; tab and session ids are hashed with this machine's salt.\n\n  report          Distributions over the window: time in agent chats, browsers and\n                  terminals, hidden-to-return times, chats per hour, most used\n                  actions, latencies, what is open, agent turns and tokens.\n  status          Whether recording is on, since when, the folder and its size.\n  path            The usage folder.\n  clear           Delete everything recorded here (recording stays as it is).\n\n  --days N        The report's window in days (default 7).\n  --dir DIR       The usage folder. Default: CMUX_USAGE_DIR, else\n                  ~/Library/Application Support/cmux/usage (macOS) or\n                  $XDG_STATE_HOME/cmux/usage.\n",
    unknown_verb: "unknown usage verb \"{verb}\"; use report, status, path or clear",
    no_home: "no usage folder: set CMUX_USAGE_DIR or pass --dir",
    status_on: "Usage recording is on (since {since}). {dir}: {files} files, {kb} KB.\n",
    status_off: "Usage recording is off. {dir}: {files} files, {kb} KB. Turn it on in Settings > Privacy > Usage Recording.\n",
    cleared: "Deleted {files} usage files in {dir}.\n",
};

pub(super) const JAPANESE: UsageRecordingMessages = UsageRecordingMessages {
    usage: "使い方: cmux usage report|status|path|clear [--days N] [--dir フォルダ] [--json]\n\nオプトインの利用記録がこのマシンに残した内容を読みます。記録のオンとオフは\n設定 > プライバシー の「利用記録」スイッチ (または `cmux settings set\ndiagnostics.usageRecording true --confirm`) で切り替えます。記録するのは使い方の\n形だけです: どの種類のタブにキーボードがあったか、アクション ID と起動方法、\n開いているものの数、待ち時間、エージェントのトークン数。メッセージ本文、ファイル\nパス、URL、タイトルは記録しません。タブとセッションの ID はこのマシンのソルトで\nハッシュ化します。\n\n  report          期間内の分布: エージェントチャット、ブラウザ、ターミナルでの時間、\n                  非表示から戻るまでの時間、1 時間あたりのチャット数、よく使う\n                  アクション、待ち時間、開いているもの、エージェントのターンとトークン。\n  status          記録がオンか、いつからか、フォルダとそのサイズ。\n  path            利用記録のフォルダ。\n  clear           ここに記録した内容をすべて削除します (記録のオンとオフは変えません)。\n\n  --days N        report の期間 (日数、既定 7)。\n  --dir フォルダ  利用記録のフォルダ。既定: CMUX_USAGE_DIR、なければ\n                  ~/Library/Application Support/cmux/usage (macOS) または\n                  $XDG_STATE_HOME/cmux/usage。\n",
    unknown_verb: "usage の動詞「{verb}」は不明です。report、status、path、clear を使ってください",
    no_home: "利用記録のフォルダがありません: CMUX_USAGE_DIR を設定するか --dir を指定してください",
    status_on: "利用記録はオンです ({since} から)。{dir}: ファイル {files} 個、{kb} KB。\n",
    status_off: "利用記録はオフです。{dir}: ファイル {files} 個、{kb} KB。設定 > プライバシー > 利用記録 でオンにできます。\n",
    cleared: "{dir} の利用記録ファイル {files} 個を削除しました。\n",
};
