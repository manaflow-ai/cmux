use super::*;

#[cfg(unix)]
#[test]
fn the_daemon_finds_the_acpmux_socket_where_acpmux_puts_it() {
    let home = Path::new("/Users/me/.cmux/brains/chief/acpmux");
    assert_eq!(daemon_socket(None, home, 501), home.join("acpmux.sock"));
    let long = PathBuf::from(format!("/Users/me/{}", "d".repeat(100)));
    let socket = daemon_socket(None, &long, 501);
    assert!(socket.starts_with("/tmp/acpmux-501/"), "{socket:?}");
    assert_eq!(socket.extension().and_then(|e| e.to_str()), Some("sock"));
}

/// The shared cases (cmux-agent-pane-policy tests/cases/environment.json) the
/// Swift host, the brain host and the Chief run too.
#[cfg(unix)]
#[test]
fn the_daemon_socket_matches_the_shared_cases() {
    let file = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../cmux-agent-pane-policy/tests/cases/environment.json");
    let cases: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(file).unwrap()).unwrap();
    for row in cases["sockets"].as_array().unwrap() {
        let got = daemon_socket(
            None,
            Path::new(row[0].as_str().unwrap()),
            row[1].as_u64().unwrap() as u32,
        );
        assert_eq!(got.to_str(), row[2].as_str(), "home {}", row[0]);
    }
    let configured = cases["configured_sockets"].as_array().unwrap();
    assert!(!configured.is_empty());
    for row in configured {
        let given = row[0].as_str().unwrap();
        let got = daemon_socket(
            Some(given).filter(|g| !g.is_empty()),
            Path::new(row[1].as_str().unwrap()),
            row[2].as_u64().unwrap() as u32,
        );
        assert_eq!(got.to_str(), row[3].as_str(), "configured {given}");
    }
}

#[test]
fn harness_run_tab_runs_the_harness_in_a_new_tab_in_its_folder() {
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        harness_tab_command(&words(&["aider"]), "/b/cmux", Path::new("/repo")),
        words(&[
            "pane", "current", "run", "--", "/b/cmux", "harness", "run", "aider", "--cwd", "/repo"
        ])
    );
    assert_eq!(
        harness_tab_command(&words(&["aider", "--cwd", "/x"]), "/b/cmux", Path::new("/repo")),
        words(&[
            "pane", "current", "run", "--", "/b/cmux", "harness", "run", "aider", "--cwd", "/x"
        ])
    );
}

#[test]
fn chats_open_runs_each_plan_in_a_new_tab_with_values_as_arguments() {
    use acpmux::cli::chats::OpenOutcome;
    use std::collections::BTreeMap;
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    let session = OpenOutcome::Session { session_id: "s_1".into() };
    assert_eq!(
        chat_tab_command(&session, "/b/cmux"),
        words(&["pane", "current", "run", "--", "/b/cmux", "acp", "attach", "s_1"])
    );
    // A folder and a store path that hold shell syntax stay inert values.
    let terminal = OpenOutcome::Terminal {
        argv: words(&["claude", "--resume", "abc"]),
        env: BTreeMap::from([("CLAUDE_CONFIG_DIR".to_owned(), "/h/a $(x)".to_owned())]),
        cwd: PathBuf::from("/r/it's \"here\"; rm -rf ~"),
    };
    assert_eq!(
        chat_tab_command(&terminal, "/b/cmux"),
        words(&[
            "pane",
            "current",
            "run",
            "--",
            "/bin/sh",
            "-c",
            r#"cd "$1" && shift && exec "$@""#,
            "sh",
            "/r/it's \"here\"; rm -rf ~",
            "/usr/bin/env",
            "CLAUDE_CONFIG_DIR=/h/a $(x)",
            "claude",
            "--resume",
            "abc",
        ])
    );
    let read_only = OpenOutcome::ReadOnly { path: PathBuf::from("/h/t.json") };
    assert_eq!(
        chat_tab_command(&read_only, "/b/cmux"),
        words(&["pane", "current", "run", "--", "/usr/bin/less", "--", "/h/t.json"])
    );
}

#[test]
fn open_runs_the_acpmux_tui_in_a_new_tab() {
    let words = |list: &[&str]| list.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
    assert_eq!(
        open_command(&words(&["review"]), "/b/cmux").unwrap(),
        words(&["pane", "current", "run", "--", "/b/cmux", "acp", "attach", "review"])
    );
    assert_eq!(
        open_command(&words(&["--pane", "pane_01", "review"]), "/b/cmux").unwrap(),
        words(&["pane", "pane_01", "run", "--", "/b/cmux", "acp", "attach", "review"])
    );
    assert!(open_command(&words(&[]), "/b/cmux").is_err());
}
