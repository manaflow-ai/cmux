#![cfg(unix)]

use std::io::Write;
use std::process::{Command, Stdio};

#[test]
fn wg_hub_stdin_config_reaches_the_parser_without_a_secret_file() {
    let directory = tempfile::tempdir().unwrap();
    let marker = "private-material-must-never-appear-in-errors";
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["wg", "hub", "--config", "-", "--socket"])
        .arg(directory.path().join("hub.sock"))
        .env("LANG", "en_US.UTF-8")
        .env("LC_ALL", "en_US.UTF-8")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .take()
        .unwrap()
        .write_all(format!("[Interface]\nPrivateKey = {marker}\n").as_bytes())
        .unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(!output.status.success());
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains("not a valid wg-quick file"),
        "stdin must reach the config parser: {error}"
    );
    assert!(!error.contains(marker));
    assert!(output.stdout.is_empty());
    assert!(!directory.path().join("hub.sock").exists());
}
