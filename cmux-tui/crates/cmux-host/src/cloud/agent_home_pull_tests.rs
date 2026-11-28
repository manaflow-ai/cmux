use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::Duration;

use serde_json::json;

use super::agent_home_pull::{Job, Outcome, TOKEN_ENV, argv, check_ask, note_for, reply_for, run};

fn job(bin: PathBuf, bound: Duration) -> Job {
    Job {
        origin: "https://platform.test".into(),
        token: "vm-bearer-secret".into(),
        bin,
        user: "cmux".into(),
        bound,
    }
}

/// A stand-in `cmux` that writes its argv and bearer beside itself, then runs `body`.
fn fake_cmux(dir: &tempfile::TempDir, body: &str) -> PathBuf {
    let bin = dir.path().join("cmux");
    let out = dir.path().join("seen");
    std::fs::write(
        &bin,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" \"${TOKEN_ENV}\" > '{}'\n{body}\n",
            out.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&bin, std::fs::Permissions::from_mode(0o755)).unwrap();
    bin
}

#[test]
fn the_ask_takes_no_fields() {
    assert!(check_ask(&json!({})).is_ok());
    assert!(check_ask(&json!(null)).is_ok());
    assert!(check_ask(&json!({"head": "https://evil.test"})).is_err());
    assert!(check_ask(&json!({"user": "root"})).is_err());
}

#[test]
fn the_pull_names_the_platform_and_work_user_and_never_the_bearer() {
    let job = job(PathBuf::from("/opt/cmux/current/bin/cmux"), Duration::from_secs(5));
    let args = argv(&job);
    assert_eq!(
        args,
        ["link", "memory", "pull", "--head", "https://platform.test", "--user", "cmux"]
    );
    assert!(!args.iter().any(|a| a.contains("secret")));
}

#[test]
fn only_exit_one_refuses_the_start() {
    assert_eq!(reply_for(&Outcome::Exited(0), 12), json!({"ok": true, "exit": 0, "ms": 12}));
    let revoked = reply_for(&Outcome::Exited(1), 3);
    assert_eq!(revoked["refuse"], json!(true));
    assert_eq!(revoked["code"], json!("agent_home.not_cleared"));
    for outcome in [Outcome::Exited(2), Outcome::Signaled, Outcome::TimedOut, Outcome::NotStarted] {
        let reply = reply_for(&outcome, 5);
        assert_eq!(
            (reply["ok"].clone(), reply["refuse"].clone()),
            (json!(false), json!(false)),
            "{outcome:?}"
        );
    }
}

#[test]
fn runs_the_pull_with_the_bearer_in_its_env() {
    let dir = tempfile::tempdir().unwrap();
    let bin = fake_cmux(&dir, "exit 0");
    let (outcome, _, _) = run(&job(bin, Duration::from_secs(5)));
    assert_eq!(outcome, Outcome::Exited(0));
    let seen = std::fs::read_to_string(dir.path().join("seen")).unwrap();
    assert_eq!(
        seen,
        "link memory pull --head https://platform.test --user cmux\nvm-bearer-secret\n"
    );
}

#[test]
fn reports_the_pulls_exit() {
    let dir = tempfile::tempdir().unwrap();
    let bin = fake_cmux(&dir, "echo 'could not clear claude/CLAUDE.md' >&2; exit 1");
    let (outcome, ms, tail) = run(&job(bin, Duration::from_secs(5)));
    assert_eq!(outcome, Outcome::Exited(1));
    assert!(tail.contains("could not clear"));
    assert!(note_for(&outcome, ms, &tail).contains("Exited(1)"));
}

#[test]
fn stops_a_pull_past_its_bound() {
    let dir = tempfile::tempdir().unwrap();
    let bin = fake_cmux(&dir, "exec sleep 30");
    let started = std::time::Instant::now();
    let (outcome, ms, _) = run(&job(bin, Duration::from_millis(200)));
    assert_eq!(outcome, Outcome::TimedOut);
    assert!(started.elapsed() < Duration::from_secs(5), "took {ms} ms");
}

#[test]
fn a_missing_binary_does_not_start() {
    let (outcome, _, _) = run(&job(PathBuf::from("/nonexistent/cmux"), Duration::from_secs(1)));
    assert_eq!(outcome, Outcome::NotStarted);
}

#[test]
fn the_journal_line_drops_a_credential_looking_line() {
    let note = note_for(&Outcome::Exited(2), 4, "bad\nAuthorization: Bearer abc\nok");
    assert!(!note.contains("Bearer"));
    assert!(note.contains("bad | ok"));
}
