//! Strings of the `cmux server` mount and the `cmux daemon` rename
//! (decision D1), in every supported language. They live here, not in the
//! shared catalog file, which is at its size limit.

/// Messages of `cli/machine_server.rs`.
pub(crate) struct ServerMountText {
    pub server_is_machine_server: &'static str,
    /// `{option}`: the refused global option.
    pub server_global_option_refused: &'static str,
    /// `{verb}`: the old lifecycle verb, run as `cmux daemon {verb}`.
    pub daemon_lifecycle_deprecated: &'static str,
}

static ENGLISH: ServerMountText = ServerMountText {
    server_is_machine_server: "`cmux server` runs this machine as a cmux server (`cmux server --help`); the session daemon is `cmux daemon`",
    server_global_option_refused: "`cmux server` does not take {option}; its only global options are --json and --idempotency-key",
    daemon_lifecycle_deprecated: "`cmux server {verb}` for the session daemon is deprecated; running `cmux daemon {verb}` (use that from now on)",
};

static JAPANESE: ServerMountText = ServerMountText {
    server_is_machine_server: "`cmux server` はこのマシンを cmux サーバーとして動かします（`cmux server --help`）。セッションデーモンは `cmux daemon` です",
    server_global_option_refused: "`cmux server` は {option} を受け付けません。使えるグローバルオプションは --json と --idempotency-key だけです",
    daemon_lifecycle_deprecated: "セッションデーモンの `cmux server {verb}` は非推奨です。`cmux daemon {verb}` として実行します (今後はこちらを使ってください)",
};

/// The messages in the language of [`super::catalog`].
pub(crate) fn server_mount() -> &'static ServerMountText {
    if std::ptr::eq(super::catalog(), &super::JAPANESE) { &JAPANESE } else { &ENGLISH }
}

#[cfg(test)]
fn server_mount_for_locale(locale: &str) -> &'static ServerMountText {
    if std::ptr::eq(super::catalog_for_locale(locale), &super::JAPANESE) {
        &JAPANESE
    } else {
        &ENGLISH
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_language_has_the_mount_messages() {
        let en = super::server_mount_for_locale("en_US.UTF-8");
        let ja = super::server_mount_for_locale("ja_JP.UTF-8");
        assert!(en.daemon_lifecycle_deprecated.contains("cmux daemon {verb}"));
        assert!(ja.daemon_lifecycle_deprecated.contains("cmux daemon {verb}"));
        assert!(ja.server_global_option_refused.contains("{option}"));
        assert_ne!(en.server_is_machine_server, ja.server_is_machine_server);
    }
}
