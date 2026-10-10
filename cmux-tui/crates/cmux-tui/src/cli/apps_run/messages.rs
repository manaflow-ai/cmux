//! `cmux apps run` messages in English and Japanese (crate::localization
//! picks the language from the locale).

pub(super) struct Messages {
    pub usage: &'static str,
    pub cancelled: &'static str,
    pub cancel_unconfirmed: &'static str,
    pub closed: &'static str,
    pub connect_failed: &'static str,
    pub bad_args: &'static str,
    pub gesture_required: &'static str,
    pub scope_missing: &'static str,
}

static ENGLISH: Messages = Messages {
    usage: "usage: cmux apps run <app> <op> [--args JSON] [--idempotency-key KEY]\n\n  Runs one catalog op of an installed app and prints its result as JSON.\n  Ctrl-C cancels the op (exit 130); a second Ctrl-C exits at once.",
    cancelled: "cancelled",
    cancel_unconfirmed: "cancelled (no confirmation)",
    closed: "the daemon closed the connection before the op answered",
    connect_failed: "cannot connect to the session socket {path}: {error}",
    bad_args: "--args must be a JSON object: {error}",
    gesture_required: "this op needs a user gesture: run it from the app (palette, button or keybinding), not from the CLI",
    scope_missing: "this op is not open to the CLI (destructive or app-only); run it from the app",
};

static JAPANESE: Messages = Messages {
    usage: "使い方: cmux apps run <app> <op> [--args JSON] [--idempotency-key KEY]\n\n  インストール済みアプリのカタログ操作を 1 つ実行し、結果を JSON で表示します。\n  Ctrl-C で操作を取り消します (終了コード 130)。もう一度 Ctrl-C を押すとすぐに終了します。",
    cancelled: "取り消しました",
    cancel_unconfirmed: "取り消しました (確認なし)",
    closed: "操作が応答する前にデーモンが接続を閉じました",
    connect_failed: "セッションソケット {path} に接続できません: {error}",
    bad_args: "--args は JSON オブジェクトにしてください: {error}",
    gesture_required: "この操作にはユーザーの操作が必要です。CLI ではなくアプリ (パレット、ボタン、キー割り当て) から実行してください",
    scope_missing: "この操作は CLI に公開されていません (破壊的な操作またはアプリ専用)。アプリから実行してください",
};

/// The messages for the CLI's language.
pub(super) fn messages() -> &'static Messages {
    let japanese = crate::localization::catalog_for_locale("ja");
    if std::ptr::eq(crate::localization::catalog(), japanese) { &JAPANESE } else { &ENGLISH }
}
