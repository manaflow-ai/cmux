use serde_json::json;

use super::*;

fn strings(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| value.to_string()).collect()
}

#[test]
fn secret_words_match_in_any_case_and_position() {
    for key in [
        "CMUX_API_TOKEN",
        "cmux_tag_password",
        "Session_Cookie",
        "AWS_SECRET",
        "MY_KEY",
        "X_AUTH",
        "GIT_CREDENTIALS",
    ] {
        assert!(names_secret(key), "{key} must count as a secret");
    }
    for key in ENV_KEYS {
        assert!(!names_secret(key), "allowlisted {key} must not count as a secret");
    }
}

#[test]
fn launch_env_keeps_only_named_keys() {
    let env = [
        ("CMUX_SOCKET_PATH", "/tmp/app.sock"),
        ("COLORTERM", "truecolor"),
        ("CMUX_API_TOKEN", "secret"),
        ("CMUX_SURFACE_ID", "surface"),
        ("PATH", "/usr/bin"),
    ]
    .map(|(key, value)| (key.to_string(), value.to_string()));
    let record = RelaunchRecord::from_launch(Some("/tmp"), None, "/bin/zsh", &env);
    assert_eq!(
        record.env,
        vec![
            ("CMUX_SOCKET_PATH".to_string(), "/tmp/app.sock".to_string()),
            ("COLORTERM".to_string(), "truecolor".to_string()),
        ]
    );
    assert_eq!(record.kind, RelaunchKind::Shell);
    assert_eq!(record.shell_path.as_deref(), Some("/bin/zsh"));
    assert_eq!(record.cwd.as_deref(), Some("/tmp"));
}

#[test]
fn integration_flags_stay_a_shell_and_commands_keep_only_their_basename() {
    let shell =
        |argv: &[&str]| RelaunchRecord::from_launch(None, Some(&strings(argv)), "/bin/sh", &[]);
    let bash = shell(&["/opt/homebrew/bin/bash", "--posix"]);
    assert_eq!(
        (bash.kind, bash.shell_path.as_deref()),
        (RelaunchKind::Shell, Some("/opt/homebrew/bin/bash"))
    );
    assert_eq!(
        shell(&["/usr/local/bin/nu", "--execute", "use ghostty *"]).kind,
        RelaunchKind::Shell
    );
    for argv in [
        &["/bin/zsh", "-lc", "export X=1; make"][..],
        &["/bin/bash", "script.sh"][..],
        &["/usr/local/bin/nu", "--execute", "rm -rf /"][..],
        &["/usr/bin/python3", "-m", "http.server"][..],
    ] {
        let record = shell(argv);
        assert_eq!(record.kind, RelaunchKind::Command, "{argv:?}");
        assert_eq!(record.shell_path, None);
        let expected = Path::new(argv[0]).file_name().unwrap().to_str().unwrap();
        assert_eq!(record.program.as_deref(), Some(expected));
    }
}

#[test]
fn a_relative_launch_directory_is_not_recorded() {
    let record = RelaunchRecord::from_launch(Some("relative/dir"), None, "/bin/sh", &[]);
    assert_eq!(record.cwd, None);
}

/// A reopened terminal gets the TERM new terminals get now (the standard
/// xterm-256color unless the person chose another), never the one an older
/// build recorded: xterm-ghostty from a Mac with Ghostty's terminfo
/// installed broke ssh and older tools (Lawrence 2026-10-28).
#[test]
fn replay_never_restores_a_recorded_term() {
    let tab = json!({"cwd": "/tmp", "relaunch": {"env": {
        "TERM": "xterm-ghostty", "COLORTERM": "truecolor",
    }}});
    let (_, env) = replay(&tab);
    assert_eq!(env, vec![("COLORTERM".to_string(), "truecolor".to_string())]);
}

#[test]
fn replay_drops_a_gone_directory_and_a_term_without_its_terminfo() {
    let tab = json!({
        "cwd": "/nonexistent/relaunch-replay",
        "relaunch": {"env": {
            "TERM": "xterm-ghostty", "TERMINFO": "/nonexistent/terminfo",
            "COLORTERM": "truecolor", "CMUX_API_TOKEN": "secret",
        }},
    });
    let (cwd, env) = replay(&tab);
    assert_eq!(cwd, None);
    assert_eq!(env, vec![("COLORTERM".to_string(), "truecolor".to_string())]);

    let tab = json!({"cwd": "/tmp", "relaunch": {"env": {"TERM_PROGRAM": "ghostty"}}});
    let (cwd, env) = replay(&tab);
    assert_eq!(cwd.as_deref(), Some("/tmp"));
    assert_eq!(env, vec![("TERM_PROGRAM".to_string(), "ghostty".to_string())]);
}
