use super::*;

/// The prelaunched host runs the program the create commits, so it
/// resolves `terminal-frontend-shell-integration-v1` the same way.
#[test]
fn prelaunch_follows_the_frontend_shell_flag() {
    let command: Command = serde_json::from_value(json!({
        "cmd": "new-tab", "env": {"SHELL": "/opt/frontend/bin/zsh"},
    }))
    .unwrap();
    let frontend = PrelaunchRequest::of(&command, true).unwrap();
    assert_eq!(frontend.argv, Some(vec!["/opt/frontend/bin/zsh".to_string()]));
    assert_eq!(PrelaunchRequest::of(&command, false).unwrap().argv, None);
}
