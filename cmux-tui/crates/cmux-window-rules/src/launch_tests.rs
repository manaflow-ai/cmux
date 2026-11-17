use super::*;

fn facts(
    snapshot: Option<&str>,
    live_session: Option<&str>,
    shown: Option<&str>,
    listed: &[&str],
    live: &[&str],
) -> SnapshotFacts {
    SnapshotFacts {
        snapshot_session: snapshot.map(str::to_owned),
        live_session: live_session.map(str::to_owned),
        shown: shown.map(str::to_owned),
        listed: listed.iter().map(|id| (*id).to_owned()).collect(),
        live: live.iter().map(|id| (*id).to_owned()).collect(),
    }
}

/// cmuxterm-hq#12660: the defaults named another session's snapshot (its Home
/// workspace shown): the launch drops it and lands on Home as a bare launch does.
#[test]
fn another_sessions_snapshot_is_stale() {
    let other = facts(Some("4cd043ac"), Some("9e1f"), Some("home-a"), &["home-a"], &[]);
    assert_eq!(verdict(&other), Verdict::OtherSession);
    assert!(verdict(&other).is_stale());
}

/// Same session, but the daemon lost the workspaces the window drew (a state reset that kept the registry id).
#[test]
fn a_snapshot_whose_workspaces_the_daemon_lacks_is_stale() {
    let gone = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &[]);
    assert_eq!(verdict(&gone), Verdict::UnknownWorkspaces);
    // The shown one alone is gone: the window drew a workspace the daemon does not have.
    let shown_gone = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &["w2"]);
    assert_eq!(verdict(&shown_gone), Verdict::UnknownWorkspaces);
    // A window record with no shown workspace whose list the daemon lacks entirely.
    let listed_gone = facts(None, Some("s1"), None, &["w1"], &[]);
    assert_eq!(verdict(&listed_gone), Verdict::UnknownWorkspaces);
}

/// A relaunch of the same daemon reopens what was last open, even when some listed workspace ended meanwhile.
#[test]
fn the_daemons_own_snapshot_is_current() {
    let same = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &["w1", "w2"]);
    assert_eq!(verdict(&same), Verdict::Current);
    let one_ended = facts(Some("s1"), Some("s1"), Some("w1"), &["w1", "w2"], &["w1"]);
    assert_eq!(verdict(&one_ended), Verdict::Current);
    assert!(!verdict(&one_ended).is_stale());
}

/// An older daemon's file names no session, and a window that drew nothing has nothing to miss.
#[test]
fn unnamed_sessions_and_empty_windows_compare_nothing() {
    assert_eq!(verdict(&facts(None, Some("s1"), Some("w1"), &["w1"], &["w1"])), Verdict::Current);
    assert_eq!(verdict(&facts(Some("s1"), None, None, &[], &[])), Verdict::Current);
    assert_eq!(verdict(&SnapshotFacts::default()), Verdict::Current);
}
