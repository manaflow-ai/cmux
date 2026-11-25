//! The marker line of a respawned terminal (cx-6so.49 L2) and of a reopened
//! archived terminal (ARCHIVE-1), in every
//! supported language. The daemon installs the text of its language into
//! cmux-tui-core before it opens the session.

use cmux_tui_core::terminal_respawn_text::{ENGLISH, TerminalRespawnText};

static JAPANESE: TerminalRespawnText = TerminalRespawnText {
    restored: "\u{2014} セッションを復元しました（前のプロセスは終了しました） \u{2014}",
    restored_command: "\u{2014} セッションを復元しました（前のプロセスは終了しました。実行していたコマンド: {program}） \u{2014}",
    restored_agent: "\u{2014} セッションを復元しました（再開: {command}） \u{2014}",
    restored_last: "\u{2014} セッションを復元しました \u{b7} 最後のコマンド: {command} \u{b7} 終了コード {code} \u{2014}",
    restored_last_no_code: "\u{2014} セッションを復元しました \u{b7} 最後のコマンド: {command} \u{2014}",
    recovered_workspace: "復元されたターミナル",
    stopped: "\u{2014} このタブを閉じたときに {program} を停止しました \u{2014}",
};

fn text_for(catalog: &'static super::Catalog) -> &'static TerminalRespawnText {
    if std::ptr::eq(catalog, &super::JAPANESE) { &JAPANESE } else { &ENGLISH }
}

/// Give the daemon's terminal respawns the text of [`super::catalog`].
pub(crate) fn install() {
    cmux_tui_core::terminal_respawn_text::install(text_for(super::catalog()));
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_language_has_the_respawn_marker() {
        let en = super::text_for(super::super::catalog_for_locale("en_US.UTF-8"));
        let ja = super::text_for(super::super::catalog_for_locale("ja_JP.UTF-8"));
        assert_eq!(en.restored, "\u{2014} session restored (previous process ended) \u{2014}");
        assert!(
            ja.restored_command.contains("{program}") && en.restored_command.contains("{program}")
        );
        assert!(ja.restored_agent.contains("{command}") && en.restored_agent.contains("{command}"));
        assert_ne!(en.restored, ja.restored);
        assert_ne!(en.recovered_workspace, ja.recovered_workspace);
        assert!(ja.stopped.contains("{program}") && en.stopped.contains("{program}"));
        assert_ne!(en.stopped, ja.stopped);
    }

    #[test]
    fn every_language_has_the_last_command_marker() {
        let en = super::text_for(super::super::catalog_for_locale("en_US.UTF-8"));
        let ja = super::text_for(super::super::catalog_for_locale("ja_JP.UTF-8"));
        for last in [en.restored_last, ja.restored_last] {
            assert!(last.contains("{command}") && last.contains("{code}"));
        }
        for last in [en.restored_last_no_code, ja.restored_last_no_code] {
            assert!(last.contains("{command}") && !last.contains("{code}"));
        }
        assert_ne!(en.restored_last, ja.restored_last);
    }
}
