#![cfg(unix)]

use std::fs;
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn write_tool(dir: &Path, name: &str, body: &str) {
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn doctor(tools: &Path, args: &[&str]) -> Output {
    Command::new(bin())
        .args(["remote", "doctor"])
        .args(args)
        .env("PATH", tools)
        .env("LC_ALL", "C")
        .env("LC_MESSAGES", "C")
        .env("LANG", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .output()
        .unwrap()
}

/// A port that was just bound and released refuses connections.
fn closed_port() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.local_addr().unwrap().port()
}

#[test]
fn remote_doctor_help_names_the_command() {
    let tools = tempfile::tempdir().unwrap();
    let output = doctor(tools.path(), &["--help"]);
    assert!(output.status.success(), "{output:?}");
    let help = String::from_utf8(output.stdout).unwrap();
    assert!(help.contains("cmux remote doctor HOST"), "{help}");
}

#[test]
fn remote_doctor_reports_ssh_off_when_tailnet_reaches_but_port_refuses() {
    let tools = tempfile::tempdir().unwrap();
    write_tool(
        tools.path(),
        "tailscale",
        "echo 'pong from peer (100.64.0.9) via DERP(sfo) in 40ms'",
    );
    write_tool(tools.path(), "ssh", "echo 'ssh must not run when TCP fails' >&2; exit 99");
    let port = closed_port().to_string();

    let output = doctor(tools.path(), &["127.0.0.1", "--port", &port, "--json"]);

    assert!(!output.status.success(), "an unreachable SSH port must exit nonzero");
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["tailnet"], "reachable", "{report}");
    assert_eq!(report["tcp"], "refused", "{report}");
    assert_eq!(report["ssh"], "not-tried", "{report}");
    assert_eq!(report["diagnosis"], "ssh-off", "{report}");
}

#[test]
fn remote_doctor_reports_not_on_tailnet_when_tailscale_is_missing() {
    let tools = tempfile::tempdir().unwrap();
    let port = closed_port().to_string();

    let output = doctor(tools.path(), &["127.0.0.1", "--port", &port, "--json"]);

    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["tailnet"], "unavailable", "{report}");
}

#[test]
fn remote_doctor_probes_the_address_an_ssh_config_alias_points_at() {
    let tools = tempfile::tempdir().unwrap();
    let port = closed_port();
    // `ssh -G ALIAS` prints the effective config; any other ssh call fails loudly.
    write_tool(
        tools.path(),
        "ssh",
        &format!(
            "if [ \"$1\" = \"-G\" ]; then printf 'user leo\\nhostname 127.0.0.1\\nport {port}\\n'; exit 0; fi\necho 'ssh must not run when TCP fails' >&2; exit 99"
        ),
    );

    let output = doctor(tools.path(), &["box-alias", "--json"]);

    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["host"], "box-alias", "{report}");
    assert_eq!(report["hostname"], "127.0.0.1", "{report}");
    assert_eq!(report["port"], port, "{report}");
    assert_eq!(report["tcp"], "refused", "{report}");
    assert_eq!(report["diagnosis"], "ssh-off", "{report}");
}
