//! The CLI and PATH an agent's `cmux` resolves to (ask-3b6366d31e: agents
//! kept opening cmux classic next to NEXT).

use std::ffi::OsString;

use super::{cmux_cli_from, with_bundled_first};

const NEXT: &str = "/Applications/cmux NIGHTLY.app/Contents/Resources/bin";

#[test]
fn a_profile_path_never_puts_classics_cmux_before_the_apps() {
    // A preset saved the login PATH, where classic's `cmux` link sits first.
    let own = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin";
    let path = with_bundled_first(
        own,
        Some("/usr/bin:/bin:/Users/p/.cargo/bin".into()),
        Some(NEXT.into()),
    );
    let entries: Vec<&str> = path.split(':').collect();
    assert_eq!(entries[0], NEXT, "the app's CLI comes first: {path}");
    assert_eq!(&entries[1..5], ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]);
    assert!(entries.contains(&"/Users/p/.cargo/bin"), "the login PATH still follows: {path}");
    let unique: std::collections::BTreeSet<&str> = entries.iter().copied().collect();
    assert_eq!(unique.len(), entries.len(), "each directory once: {path}");
}

#[test]
fn without_a_bundle_the_profile_path_still_leads() {
    let path = with_bundled_first("/a:/b", Some("/b:/c".into()), None);
    assert_eq!(path, "/a:/b:/c");
}

#[test]
fn the_daemon_runs_the_apps_own_cli_not_the_one_on_path() {
    let bundled = OsString::from(format!("{NEXT}/cmux"));
    let exists = |p: &std::path::Path| p.to_string_lossy().starts_with(NEXT);
    // No CMUX_BIN: the bundled CLI, never the bare `cmux` (classic's, on a Mac that has it).
    assert_eq!(cmux_cli_from(None, Some(bundled.clone()), exists), bundled);
    assert_eq!(cmux_cli_from(Some("".into()), Some(bundled.clone()), exists), bundled);
    // An explicit CMUX_BIN is the caller's choice and wins.
    assert_eq!(cmux_cli_from(Some("/x/cmux".into()), Some(bundled.clone()), exists), "/x/cmux");
    // A bundle that moved or was deleted falls back to PATH rather than failing.
    assert_eq!(cmux_cli_from(None, Some(bundled), |_| false), "cmux");
    assert_eq!(cmux_cli_from(None, None, exists), "cmux");
}
