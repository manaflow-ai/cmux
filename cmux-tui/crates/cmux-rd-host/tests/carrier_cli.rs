//! Versioned worker commands must validate the same schema as legacy aliases.
#![cfg(all(feature = "link", any(target_os = "linux", target_os = "macos")))]
use std::io::Write;
use std::process::{Command, Stdio};

fn run(command: &str, input: &[u8]) -> std::process::Output {
    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-rd"))
        .arg(command)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(input).unwrap();
    child.wait_with_output().unwrap()
}
#[test]
fn wg_cli_versioned_aliases_validate_marker_before_networking() {
    for command in ["serve", "serve-v2", "connect", "connect-v2"] {
        let output = run(command, b"{\"peer_carrier\":\"rd_wg/999\"}\n");
        assert!(!output.status.success());
        let error = String::from_utf8_lossy(&output.stderr);
        assert!(error.contains("unsupported peer_carrier"), "{command}: {error}");
        // Host output is only available after setup has passed validation.
        if command.starts_with("serve") {
            assert!(output.stdout.is_empty());
        }
    }
}
#[test]
fn wg_cli_unknown_version_rejects_before_key_output() {
    for command in ["serve-v999", "connect-v999"] {
        let output = run(command, b"");
        assert!(!output.status.success());
        assert!(output.stdout.is_empty());
        assert!(String::from_utf8_lossy(&output.stderr).contains("unknown command"));
    }
}
