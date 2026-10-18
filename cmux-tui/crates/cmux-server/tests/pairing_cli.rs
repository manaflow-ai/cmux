//! General server enrollment must be available without starting a service.
//! Every subprocess uses an owned, initially empty home and no credentials.

use std::process::{Command, Output, Stdio};

fn command(home: &std::path::Path, args: &[&str]) -> Output {
    command_with_locale(home, args, "en_US.UTF-8")
}

fn command_with_locale(home: &std::path::Path, args: &[&str], locale: &str) -> Output {
    Command::new(env!("CARGO_BIN_EXE_cmux-server"))
        .args(args)
        .env_clear()
        .env("HOME", home)
        .env("USERPROFILE", home)
        .env("LOCALAPPDATA", home.join("local"))
        .env("APPDATA", home.join("roaming"))
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env("XDG_STATE_HOME", home.join("state"))
        .env("XDG_DATA_HOME", home.join("data"))
        .env("CMUX_SERVER_MODE", "user")
        .env("LANG", locale)
        .current_dir(home)
        .stdin(Stdio::null())
        .output()
        .unwrap()
}

#[test]
fn server_pairing_cli_reports_unpaired_without_creating_identity_or_starting_roles() {
    let home = tempfile::tempdir().unwrap();
    let result = command(home.path(), &["pair", "status", "--json"]);
    assert!(result.status.success(), "{}", String::from_utf8_lossy(&result.stderr));
    let value: serde_json::Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(value["state"], "unpaired");
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

#[test]
fn server_pairing_cli_refuses_insecure_api_before_creating_keys_or_contacting_it() {
    let home = tempfile::tempdir().unwrap();
    let result = command(home.path(), &["pair", "--api-origin", "http://127.0.0.1:1", "--json"]);
    assert_eq!(result.status.code(), Some(4), "{}", String::from_utf8_lossy(&result.stderr));
    assert!(result.stdout.is_empty());
    let value: serde_json::Value = serde_json::from_slice(&result.stderr).unwrap();
    assert_eq!(value["error"]["kind"], "rejected");
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

#[test]
fn server_pairing_cli_keeps_unknown_options_as_usage_errors_without_effects() {
    let home = tempfile::tempdir().unwrap();
    let result = command(home.path(), &["pair", "--actor", "user", "--json"]);
    assert_eq!(result.status.code(), Some(2));
    assert!(result.stdout.is_empty());
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

#[test]
fn server_pairing_cli_localizes_human_status_while_json_keeps_its_contract() {
    let home = tempfile::tempdir().unwrap();
    let human = command_with_locale(home.path(), &["pair", "status"], "ja_JP.UTF-8");
    assert!(human.status.success());
    assert_eq!(String::from_utf8(human.stdout).unwrap(), "未ペアリング\n");
    let machine = command_with_locale(home.path(), &["pair", "status", "--json"], "ja_JP.UTF-8");
    assert!(machine.status.success());
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&machine.stdout).unwrap(),
        serde_json::json!({"state":"unpaired"})
    );
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}

#[test]
fn server_pairing_cli_requires_an_idempotency_value_before_a_local_mutation() {
    let home = tempfile::tempdir().unwrap();
    let result = command(home.path(), &["pin", "--clear", "--idempotency-key", "--json"]);
    assert_eq!(result.status.code(), Some(2), "{}", String::from_utf8_lossy(&result.stderr));
    assert!(result.stdout.is_empty());
    assert_eq!(std::fs::read_dir(home.path()).unwrap().count(), 0);
}
