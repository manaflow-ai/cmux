#![cfg(unix)]

use std::fs;
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::{Command, Output};

/// The binary as the npm `cmux` launcher runs it, so output names `cmux`.
/// Tests that check the installed `cmux-tui` name run `bin()` directly.
fn cmux_command() -> Command {
    let mut command = Command::new(bin());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::arg0(&mut command, "cmux");
    command
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn write_tool(dir: &Path, name: &str, body: &str) {
    let path = dir.join(name);
    fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn doctor(tools: &Path, args: &[&str]) -> Output {
    doctor_with_app_cli(tools, &tools.join("no-tailscale-app"), args)
}

/// `app_cli` stands in for the Tailscale app's bundled CLI, which the doctor
/// tries when `tailscale` isn't on PATH. Without it a runner with the app
/// installed would answer for the real tailnet.
fn doctor_with_app_cli(tools: &Path, app_cli: &Path, args: &[&str]) -> Output {
    cmux_command()
        .args(["remote", "doctor"])
        .args(args)
        .env("PATH", tools)
        .env("CMUX_REMOTE_DOCTOR_TAILSCALE_APP_CLI", app_cli)
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
fn remote_doctor_falls_back_to_the_tailscale_app_cli_off_path() {
    let tools = tempfile::tempdir().unwrap();
    let app = tempfile::tempdir().unwrap();
    write_tool(app.path(), "Tailscale", "echo 'pong from peer (100.64.0.9) via DERP(sfo) in 40ms'");
    let port = closed_port().to_string();

    let output = doctor_with_app_cli(
        tools.path(),
        &app.path().join("Tailscale"),
        &["127.0.0.1", "--port", &port, "--json"],
    );

    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["tailnet"], "reachable", "{report}");
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

#[test]
fn remote_doctor_ssh_probe_overrides_config_that_could_change_state() {
    let tools = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port().to_string();
    let argv = tools.path().join("argv");
    write_tool(
        tools.path(),
        "ssh",
        &format!(
            "[ \"$1\" = \"-G\" ] && exit 1\nprintf '%s\\n' \"$@\" > '{}'\nexit 0",
            argv.display()
        ),
    );

    let output = doctor(tools.path(), &["127.0.0.1", "--port", &port, "--json"]);

    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["diagnosis"], "ok", "{report}");
    let argv = fs::read_to_string(argv).unwrap();
    for option in [
        "BatchMode=yes",
        "StrictHostKeyChecking=yes",
        "UpdateHostKeys=no",
        "ControlMaster=no",
        "ControlPath=none",
        "RemoteCommand=none",
        "PermitLocalCommand=no",
        "ForwardAgent=no",
        "ClearAllForwardings=yes",
    ] {
        assert!(argv.lines().any(|line| line == option), "missing {option} in {argv}");
    }
}

#[test]
fn remote_doctor_hands_a_proxied_host_straight_to_ssh() {
    let tools = tempfile::tempdir().unwrap();
    let port = closed_port();
    write_tool(
        tools.path(),
        "ssh",
        &format!(
            "if [ \"$1\" = \"-G\" ]; then printf 'hostname 127.0.0.1\\nport {port}\\nproxyjump bastion\\n'; exit 0; fi\nexit 0"
        ),
    );
    write_tool(
        tools.path(),
        "tailscale",
        "echo 'tailscale must not run for a proxied host' >&2; exit 1",
    );

    let output = doctor(tools.path(), &["behind-bastion", "--json"]);

    assert!(output.status.success(), "{output:?}");
    let report: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(report["tcp"], "proxied", "{report}");
    assert_eq!(report["tailnet"], "not-tried", "{report}");
    assert_eq!(report["diagnosis"], "ok", "{report}");
}
