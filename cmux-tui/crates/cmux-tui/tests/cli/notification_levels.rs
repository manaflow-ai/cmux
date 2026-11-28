//! Every level `cmux notification --help` offers is one a real daemon takes:
//! an agent that copies a level from the help gets a notification, not a
//! "bad level" refusal from the server.
use super::super::*;

/// The levels in the help's `[--level a|b|c]`.
fn help_levels(server: &HeadlessServer) -> Vec<String> {
    let help = cli(server, &["notification", "--help"]);
    assert_success(&help);
    let text = String::from_utf8_lossy(&help.stdout).into_owned();
    let start = text.find("[--level ").unwrap_or_else(|| panic!("no --level in help:\n{text}"));
    let rest = &text[start + "[--level ".len()..];
    let end = rest.find(']').unwrap();
    rest[..end].split('|').map(str::to_owned).collect()
}

#[test]
fn every_notification_level_the_help_lists_is_one_the_daemon_takes() {
    let server = HeadlessServer::start("notification-levels");
    let levels = help_levels(&server);
    assert!(levels.len() >= 3, "help lists too few levels: {levels:?}");
    for level in &levels {
        let created = json_cli(
            &server,
            &["notification", "create", "--title", "Build", "--body", "done", "--level", level],
        );
        assert!(
            created.status.success(),
            "--level {level} from the help was refused: {}{}",
            String::from_utf8_lossy(&created.stdout),
            String::from_utf8_lossy(&created.stderr),
        );
    }
    // And the CLI refuses a level the help doesn't list before it reaches the daemon.
    let refused = json_cli(
        &server,
        &["notification", "create", "--title", "Build", "--body", "done", "--level", "success"],
    );
    assert_eq!(refused.status.code(), Some(2), "{}", String::from_utf8_lossy(&refused.stderr));
}
