use std::path::PathBuf;

use super::{Command, parse, recorded_tree};

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
