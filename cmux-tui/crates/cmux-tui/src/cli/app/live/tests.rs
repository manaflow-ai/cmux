use std::path::PathBuf;

use super::{Command, RustVerb, parse, recorded_tree, recorded_watch_tree, tool_path};

fn words(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn no_verb_or_help_is_the_usage() {
    assert_eq!(parse(&[]).unwrap(), Command::Help);
    assert_eq!(parse(&words(&["help"])).unwrap(), Command::Help);
    assert_eq!(parse(&words(&["start", "--help"])).unwrap(), Command::Help);
}

#[test]
fn start_takes_a_worktree_and_a_port() {
    assert_eq!(parse(&words(&["start"])).unwrap(), Command::Start { worktree: None, port: None });
    assert_eq!(
        parse(&words(&["start", "--worktree", "/src/wt", "--port=4300"])).unwrap(),
        Command::Start { worktree: Some(PathBuf::from("/src/wt")), port: Some(4300) }
    );
}

#[test]
fn stop_and_status_take_only_a_worktree() {
    assert_eq!(parse(&words(&["stop"])).unwrap(), Command::Stop { worktree: None });
    assert_eq!(
        parse(&words(&["status", "--worktree=/src/wt"])).unwrap(),
        Command::Status { worktree: Some(PathBuf::from("/src/wt")) }
    );
    assert!(parse(&words(&["stop", "--port", "4300"])).is_err());
}

#[test]
fn refuses_unknown_verbs_flags_and_bad_ports() {
    assert!(parse(&words(&["apply"])).is_err());
    assert!(parse(&words(&["start", "--fast"])).is_err());
    assert!(parse(&words(&["start", "--port", "0"])).is_err());
    assert!(parse(&words(&["start", "--port", "http"])).is_err());
    assert!(parse(&words(&["start", "--worktree"])).is_err());
}

#[test]
fn reads_the_tree_the_dev_server_was_started_from() {
    let dir = std::env::temp_dir().join(format!("cmux-live-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("dev-server.tree");
    std::fs::write(&file, "/Users/me/src/cmux:4200\n").unwrap();
    assert_eq!(recorded_tree(&file), Some(PathBuf::from("/Users/me/src/cmux")));
    std::fs::write(&file, "garbage").unwrap();
    assert_eq!(recorded_tree(&file), None);
    assert_eq!(recorded_tree(&dir.join("missing")), None);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn a_short_gui_path_gains_bun_and_homebrew() {
    let path = tool_path(Some("/usr/bin:/bin".into()), Some("/Users/me".into())).unwrap();
    assert_eq!(
        path,
        std::ffi::OsString::from(
            "/usr/bin:/bin:/Users/me/.bun/bin:/opt/homebrew/bin:/usr/local/bin"
        )
    );
    let full = "/Users/me/.bun/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin";
    assert_eq!(tool_path(Some(full.into()), Some("/Users/me".into())), None);
}

#[test]
fn rust_takes_a_build_host_and_a_session_on_start() {
    assert_eq!(
        parse(&words(&[
            "start",
            "--rust",
            "--build-host",
            "build-box",
            "--session=cmux-app-nightly"
        ]))
        .unwrap(),
        Command::Rust {
            verb: RustVerb::Start,
            worktree: None,
            build_host: Some("build-box".to_owned()),
            session: Some("cmux-app-nightly".to_owned()),
        }
    );
    assert_eq!(
        parse(&words(&["status", "--rust"])).unwrap(),
        Command::Rust { verb: RustVerb::Status, worktree: None, build_host: None, session: None }
    );
    assert_eq!(
        parse(&words(&["stop", "--rust", "--worktree", "/src/wt"])).unwrap(),
        Command::Rust {
            verb: RustVerb::Stop,
            worktree: Some(PathBuf::from("/src/wt")),
            build_host: None,
            session: None,
        }
    );
}

#[test]
fn rust_flags_need_rust_and_the_right_verb() {
    assert!(parse(&words(&["start", "--build-host", "h"])).is_err());
    assert!(parse(&words(&["stop", "--rust", "--build-host", "h"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--port", "4300"])).is_err());
    assert!(parse(&words(&["start", "--rust=yes"])).is_err());
}

#[test]
fn chromium_passes_its_start_flags_through_with_the_build_host_first() {
    assert_eq!(
        parse(&words(&[
            "start",
            "--chromium",
            "--src",
            "~/cef/chromium/src",
            "--build-host",
            "builder",
            "--out=out/Debug_GN_arm64",
            "--gpu",
        ]))
        .unwrap(),
        Command::Chromium {
            verb: RustVerb::Start,
            worktree: None,
            args: words(&[
                "--build-host",
                "builder",
                "--src",
                "~/cef/chromium/src",
                "--out",
                "out/Debug_GN_arm64",
                "--gpu",
            ]),
        }
    );
    assert_eq!(
        parse(&words(&["status", "--chromium", "--worktree", "/src/wt"])).unwrap(),
        Command::Chromium {
            verb: RustVerb::Status,
            worktree: Some(PathBuf::from("/src/wt")),
            args: vec![],
        }
    );
}

#[test]
fn chromium_flags_need_chromium_and_start() {
    assert!(parse(&words(&["start", "--src", "/s"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--src", "/s"])).is_err());
    assert!(parse(&words(&["start", "--rust", "--chromium"])).is_err());
    assert!(parse(&words(&["stop", "--chromium", "--out", "out/X"])).is_err());
    assert!(parse(&words(&["start", "--chromium", "--port", "4300"])).is_err());
    assert!(parse(&words(&["start", "--chromium", "--session", "s"])).is_err());
    assert!(parse(&words(&["start", "--chromium=yes"])).is_err());
}

#[test]
fn reads_the_tree_the_rust_loop_watches() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("watch.pid");
    std::fs::write(&file, "4242 /src/my tree\n").unwrap();
    assert_eq!(recorded_watch_tree(&file), Some(PathBuf::from("/src/my tree")));
    std::fs::write(&file, "nope\n").unwrap();
    assert_eq!(recorded_watch_tree(&file), None);
}
