//! `cmux --help` for where it runs.
//!
//! The root help lists the app's scopes (chat, chief, window, ...) next to
//! the session's. Where no cmux app answers, or in a cmux-tui pane whose
//! session the reachable app does not own, those scopes cannot act on what
//! the caller sees, so they move under one heading at the end that says so.
//! Nothing is hidden: `cmux <scope> --help` still works for each.

use std::borrow::Cow;

use super::pane_context::{self, Innermost};

/// Root-help scopes that only the cmux app serves (`cli/app.rs` app scopes
/// and the app-routed person verbs). `chief` is not one: with no app it
/// starts its own owner (cli/chief/launch.rs).
pub(super) const APP_ONLY_SCOPES: &[&str] = &[
    "login",
    "chat",
    "avatar",
    "billing",
    "auth",
    "accounts",
    "bookmark",
    "open",
    "window",
    "keybinding",
    "errors",
    "events",
    "app",
    "action",
];

/// Where the app stands for this caller.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum AppPlace {
    /// The app answers and owns the caller's session (or no pane names one).
    Serves,
    /// No cmux app answers.
    Unreachable,
    /// An app answers, but this cmux-tui pane's session is not the app's.
    Outer,
}

/// [`AppPlace`] for this process.
pub(super) fn app_place(app_socket: Option<&std::path::Path>) -> AppPlace {
    let reachable = pane_context::app_reachable(app_socket);
    match (pane_context::innermost(), reachable) {
        (_, false) => AppPlace::Unreachable,
        (Innermost::SessionPane { .. }, true) => AppPlace::Outer,
        _ => AppPlace::Serves,
    }
}

/// The root help for `place`.
pub(super) fn render<'a>(
    help: &'a str,
    place: AppPlace,
    messages: &crate::localization::PaneCliMessages,
) -> Cow<'a, str> {
    match place {
        AppPlace::Serves => Cow::Borrowed(help),
        AppPlace::Unreachable => {
            Cow::Owned(group_app_scopes(help, messages.app_heading_unreachable))
        }
        AppPlace::Outer => Cow::Owned(group_app_scopes(help, messages.app_heading_outer)),
    }
}

enum Line {
    /// `  <app scope>  description`: moves under the heading.
    AppScope,
    /// `  cmux <app scope> …` in the opening examples: dropped, its scope
    /// line says the same under the heading.
    AppExample,
    Other,
}

fn classify(line: &str) -> Line {
    let Some(rest) = line.strip_prefix("  ").filter(|rest| !rest.starts_with(' ')) else {
        return Line::Other;
    };
    let mut words = rest.split_whitespace();
    let first = words.next().unwrap_or_default();
    let is_app = |word: &str| APP_ONLY_SCOPES.contains(&word);
    // A scope row pads its name to the description with at least two spaces.
    let padded = |word: &str| rest.strip_prefix(word).is_some_and(|tail| tail.starts_with("  "));
    if is_app(first) && padded(first) {
        return Line::AppScope;
    }
    if first == "cmux" && words.next().is_some_and(is_app) {
        return Line::AppExample;
    }
    Line::Other
}

/// `help` with every app scope row moved under `heading`, placed after the
/// section that held the last of them, and the app examples dropped.
pub(super) fn group_app_scopes(help: &str, heading: &str) -> String {
    let mut kept: Vec<&str> = Vec::new();
    let mut moved: Vec<&str> = Vec::new();
    let mut insert_at = None;
    let mut pending = false;
    for line in help.split_inclusive('\n') {
        match classify(line.trim_end_matches('\n')) {
            Line::AppScope => {
                moved.push(line);
                pending = true;
            }
            Line::AppExample => {}
            Line::Other => {
                kept.push(line);
                if pending && line.trim().is_empty() {
                    insert_at = Some(kept.len());
                    pending = false;
                }
            }
        }
    }
    if moved.is_empty() {
        return help.to_owned();
    }
    let at = if pending { kept.len() } else { insert_at.unwrap_or(kept.len()) };
    let mut out = String::new();
    for line in kept.iter().take(at) {
        out.push_str(line);
    }
    if !out.ends_with("\n\n") && !out.is_empty() {
        out.push('\n');
    }
    out.push_str(heading);
    out.push('\n');
    for line in &moved {
        out.push_str(line);
    }
    out.push('\n');
    for line in kept.iter().skip(at) {
        out.push_str(line);
    }
    out
}

#[cfg(test)]
mod tests {
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
}
