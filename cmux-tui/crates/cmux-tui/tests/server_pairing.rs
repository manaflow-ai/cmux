//! Exercise the shipped cmux surface, rather than only the standalone server.
#![cfg(unix)]

use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};

fn command(home: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg0("cmux")
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env("XDG_STATE_HOME", home.join("state"))
        .env("XDG_DATA_HOME", home.join("data"))
        .env("CMUX_SERVER_MODE", "user")
        .stdin(Stdio::null())
        .current_dir(home)
        .output()
        .unwrap()
}

#[test]
fn server_pairing_public_cmux_mount_reports_status_without_creating_a_server_identity() {
    let home = tempfile::tempdir().unwrap();
    let result = command(home.path(), &["server", "pair", "status", "--json"]);
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["state"], "unpaired");
    let layout = cmux_server::host::layout_for(
        cmux_server_core::InstallMode::User,
        &cmux_server_core::layout::LayoutEnv {
            home: Some(home.path().to_str().unwrap().into()),
            xdg_config_home: Some(home.path().join("config").to_str().unwrap().into()),
            xdg_state_home: Some(home.path().join("state").to_str().unwrap().into()),
            xdg_data_home: Some(home.path().join("data").to_str().unwrap().into()),
            uid: Some(cmux_server::sys::uid()),
            ..Default::default()
        },
    )
    .unwrap();
    assert!(!std::path::Path::new(layout.state.as_str()).join("pairing/identity.json").exists());
}

#[test]
fn server_pairing_public_cmux_mount_preserves_insecure_api_refusal() {
    let home = tempfile::tempdir().unwrap();
    let result =
        command(home.path(), &["server", "pair", "--api-origin", "http://127.0.0.1:1", "--json"]);
    assert_eq!(result.status.code(), Some(4), "{}", String::from_utf8_lossy(&result.stderr));
    assert!(result.stdout.is_empty());
    let value: serde_json::Value = serde_json::from_slice(&result.stderr).unwrap();
    assert_eq!(value["error"]["kind"], "rejected");
}
