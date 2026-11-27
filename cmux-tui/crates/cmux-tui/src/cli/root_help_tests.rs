use super::*;

fn lines_starting(help: &str, prefix: &str) -> usize {
    help.lines().position(|line| line.starts_with(prefix)).unwrap_or(usize::MAX)
}

/// Without the app, each app scope row sits under the app heading, after
/// every session scope; no row is lost and the session scopes stay.
#[test]
fn app_scopes_move_under_the_app_heading_in_both_languages() {
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let catalog = crate::localization::catalog_for_locale(locale);
        let help = catalog.local_server.cmux_root_help;
        let heading = catalog.pane_cli.app_heading_unreachable;
        let grouped = render(help, AppPlace::Unreachable, &catalog.pane_cli);
        let at = lines_starting(&grouped, heading);
        assert!(at != usize::MAX, "{locale}: no heading\n{grouped}");
        for scope in APP_ONLY_SCOPES {
            let row = format!("  {scope} ");
            assert_eq!(
                help.lines().filter(|line| line.starts_with(&row)).count(),
                grouped.lines().filter(|line| line.starts_with(&row)).count(),
                "{locale}: {scope}"
            );
            if help.lines().any(|line| line.starts_with(&row)) {
                assert!(lines_starting(&grouped, &row) > at, "{locale}: {scope} above");
            }
            let example = format!("  cmux {scope} ");
            assert!(!grouped.lines().any(|line| line.starts_with(&example)), "{locale}");
        }
        for scope in ["workspace", "pane", "terminal", "session", "identify", "skill"] {
            let row = format!("  {scope} ");
            assert!(lines_starting(&grouped, &row) < at, "{locale}: {scope} moved");
        }
        assert!(grouped.contains("  cmux identify "), "{locale}");
        assert!(grouped.contains("  cmux skill show "), "{locale}");
        // The closing paragraph still closes the help.
        assert_eq!(help.lines().last(), grouped.lines().last(), "{locale}");
        assert!(!grouped.contains("\n\n\n"), "{locale}: a blank run\n{grouped}");
    }
}

#[test]
fn the_app_serving_its_own_session_keeps_the_help_unchanged() {
    let catalog = crate::localization::catalog_for_locale("en_US.UTF-8");
    let help = catalog.local_server.cmux_root_help;
    assert!(matches!(render(help, AppPlace::Serves, &catalog.pane_cli), Cow::Borrowed(_)));
    let outer = render(help, AppPlace::Outer, &catalog.pane_cli);
    assert!(outer.contains(catalog.pane_cli.app_heading_outer));
}

#[test]
fn only_padded_scope_rows_and_cmux_examples_count() {
    assert!(matches!(classify("  chat          Start a chat"), Line::AppScope));
    assert!(matches!(classify("  cmux chat \"fix\"   Start"), Line::AppExample));
    assert!(matches!(classify("  chat is fun"), Line::Other));
    assert!(matches!(classify("    chat          deeper"), Line::Other));
    assert!(matches!(classify("  chats         Every chat"), Line::Other));
    assert!(matches!(classify("  cmux pane current split"), Line::Other));
}
