use super::*;

/// launchd starts `serve` with none of the app's environment, so the
/// agent's arguments carry the lock directory resolved in the app.
#[test]
fn the_launchd_agent_arguments_carry_the_key_lock_dir() {
    let dir = tempfile::tempdir().unwrap();
    let state = LinkState::open(Some(dir.path().join("link"))).unwrap();
    let arguments = super::super::agent_arguments(&state, &super::super::Flags::new());
    let at = arguments.iter().position(|argument| argument == FLAG).expect("no --key-lock-dir");
    assert_eq!(arguments[at + 1], lock_dir(&state).to_string_lossy());
    assert_eq!(arguments[..2], ["link", "serve"]);
}
