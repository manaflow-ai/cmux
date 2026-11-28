use super::*;

#[test]
fn only_the_known_agents_install() {
    assert_eq!(agent("claude").unwrap().0, "Claude Code");
    assert_eq!(agent("codex").unwrap().0, "Codex");
    let err = agent("gemini").unwrap_err().to_string();
    assert!(err.contains("installs claude, codex"), "{err}");
}

#[cfg(unix)]
#[test]
fn only_an_executable_file_counts_as_installed() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("claude");
    std::fs::write(&file, "#!/bin/sh\n").unwrap();
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(!is_executable(&file));
    std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(is_executable(&file));
    assert!(!is_executable(dir.path()));
}

#[test]
fn a_failure_names_the_last_line_of_stderr_else_stdout() {
    assert_eq!(last_line(b"warn\nboom\n\n", b"ok"), "boom");
    assert_eq!(last_line(b"  \n", b"step 1\nerror: offline\n"), "error: offline");
    assert_eq!(last_line(b"", b""), "no output");
}

#[tokio::test]
async fn an_unknown_agent_runs_nothing() {
    let mut steps = 0;
    assert!(install("aider", |_, _, _| steps += 1).await.is_err());
    assert_eq!(steps, 0);
}
