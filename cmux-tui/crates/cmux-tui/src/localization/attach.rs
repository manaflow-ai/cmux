//! `attach` strings of the CLI catalog (English and Japanese).

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AttachMessages {
    pub(super) help: &'static str,
    pub filtered_subscription_unavailable: &'static str,
    pub remote_attach_queue_full: &'static str,
    pub(super) remote_attach_workers_failed_template: &'static str,
    pub(super) surface_sync_failed_template: &'static str,
    pub(super) surface_sync_unknown_template: &'static str,
    pub(super) surface_sync_attach: &'static str,
    pub(super) surface_sync_resize: &'static str,
    pub(super) surface_sync_operation: &'static str,
    pub(super) unknown_terminal_prefix: &'static str,
    pub(super) unknown_terminal_suffix: &'static str,
    pub(super) ambiguous_terminal_prefix: &'static str,
    pub(super) ambiguous_terminal_suffix: &'static str,
    pub(super) browser_terminal_prefix: &'static str,
    pub(super) browser_terminal_suffix: &'static str,
}

impl AttachMessages {
    pub fn remote_attach_workers_failed(&self, error: &str) -> String {
        self.remote_attach_workers_failed_template.replace("{error}", error)
    }

    pub(super) fn surface_sync_operation(&self, operation: &str) -> &'static str {
        match operation {
            "attach" => self.surface_sync_attach,
            "resize" => self.surface_sync_resize,
            _ => self.surface_sync_operation,
        }
    }

    pub fn surface_sync_failed(&self, surface: u64, operation: &str, error: &str) -> String {
        self.surface_sync_failed_template
            .replace("{surface}", &surface.to_string())
            .replace("{operation}", self.surface_sync_operation(operation))
            .replace("{error}", error)
    }

    pub fn surface_sync_unknown(&self, surface: u64, operation: &str, error: &str) -> String {
        self.surface_sync_unknown_template
            .replace("{surface}", &surface.to_string())
            .replace("{operation}", self.surface_sync_operation(operation))
            .replace("{error}", error)
    }

    pub fn unknown_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.unknown_terminal_prefix, self.unknown_terminal_suffix)
    }

    #[cfg(test)]
    pub fn ambiguous_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.ambiguous_terminal_prefix, self.ambiguous_terminal_suffix)
    }

    #[cfg(test)]
    pub fn browser_not_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.browser_terminal_prefix, self.browser_terminal_suffix)
    }
}

pub(super) const ENGLISH: AttachMessages = AttachMessages {
    help: "USAGE\n  {program} attach [--session <name> | --socket <path>] [--terminal <id>]\n\nAttach this terminal to a running session, or with --terminal show only one\nterminal. Start the session first with `{program} server ensure` or `{program}`.\n\nOPTIONS\n  --session <name>   Session name (default: main)\n  --socket <path>    Exact control socket path\n  --terminal <id>    Show only this terminal (`{program} terminal list`)\n  -h, --help         Show this help\n",
    filtered_subscription_unavailable: "single-terminal attach requires a newer cmux-tui server; restart the session",
    remote_attach_queue_full: "remote surface attach queue is full",
    remote_attach_workers_failed_template: "could not start surface attach workers: {error}",
    surface_sync_failed_template: "surface {surface} {operation} failed; retries are rate-limited: {error}",
    surface_sync_unknown_template: "surface {surface} {operation} outcome is unknown; detach and reconnect before sending more input: {error}",
    surface_sync_attach: "attach",
    surface_sync_resize: "resize",
    surface_sync_operation: "operation",
    unknown_terminal_prefix: "unknown terminal ",
    unknown_terminal_suffix: "; use `cmux terminal list` to list terminal IDs",
    ambiguous_terminal_prefix: "ambiguous terminal reference ",
    ambiguous_terminal_suffix: "; use an unambiguous ID from `cmux terminal list`",
    browser_terminal_prefix: "surface ",
    browser_terminal_suffix: " is a browser, not a terminal",
};

pub(super) const JAPANESE: AttachMessages = AttachMessages {
    help: "使い方\n  {program} attach [--session <名前> | --socket <パス>] [--terminal <id>]\n\n実行中のセッションにこのターミナルを接続します。--terminal を付けると一つのターミナルだけを\n表示します。先に `{program} server ensure` または `{program}` でセッションを開始してください。\n\nオプション\n  --session <名前>   セッション名 (既定: main)\n  --socket <パス>    制御ソケットのパスを指定\n  --terminal <id>    このターミナルだけを表示 (`{program} terminal list`)\n  -h, --help         このヘルプを表示\n",
    filtered_subscription_unavailable: "単一ターミナルへの接続には新しい cmux-tui サーバーが必要です。セッションを再起動してください",
    remote_attach_queue_full: "リモートサーフェス接続キューがいっぱいです",
    remote_attach_workers_failed_template: "リモートサーフェス接続ワーカーを開始できませんでした: {error}",
    surface_sync_failed_template: "サーフェス {surface} の{operation}に失敗しました。再試行は制限されています: {error}",
    surface_sync_unknown_template: "サーフェス {surface} の{operation}結果は不明です。入力を続ける前に切断して再接続してください: {error}",
    surface_sync_attach: "接続",
    surface_sync_resize: "サイズ変更",
    surface_sync_operation: "操作",
    unknown_terminal_prefix: "ターミナル ",
    unknown_terminal_suffix: " が見つかりません。`cmux terminal list` でターミナル ID 一覧を確認してください",
    ambiguous_terminal_prefix: "ターミナル参照 ",
    ambiguous_terminal_suffix: " は曖昧です。`cmux terminal list` に表示される一意の ID を使用してください",
    browser_terminal_prefix: "サーフェス ",
    browser_terminal_suffix: " はブラウザであり、ターミナルではありません",
};
