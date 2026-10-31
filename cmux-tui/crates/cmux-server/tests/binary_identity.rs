//! Release tooling inspects the running binary without an installed server.

use std::collections::BTreeSet;
use std::process::Command;

use cmux_server::cli::{Context, dispatch, parse};
use cmux_server::exec::RecordingExec;
use cmux_server::process::RecordingRunner;
use cmux_server_core::layout::LayoutEnv;
use cmux_server_core::manifest::TrustedKey;
use serde_json::{Value, json};

const BUILD_KEYS: Option<&str> = option_env!("CMUX_SERVER_RELEASE_KEYS");

fn query(keys: Vec<TrustedKey>) -> Value {
    let runner = RecordingRunner::new();
    let exec = RecordingExec::default();
    let context = Context {
        runner: &runner,
        fetcher: None,
        exec: &exec,
        keys,
        running_cmux: "7.8.9-preview".to_owned(),
        reexec_guard: None,
        // No home, user id, app bundle or service layout exists.
        env: LayoutEnv::default(),
        now_ms: 0,
    };
    let args = parse(&["status".into(), "--binary-only".into(), "--json".into()]).unwrap();
    let result = dispatch(&context, &args).unwrap();
    assert!(runner.commands().is_empty(), "binary inspection cannot query services");
    result.json
}

#[test]
fn status_binary_identity_reports_the_running_version_and_raw_key_fingerprints() {
    let keys = vec![
        TrustedKey { id: "next".into(), public_key: [0x22; 32] },
        TrustedKey { id: "current".into(), public_key: [0x11; 32] },
    ];
    let result = query(keys);
    assert_eq!(
        result,
        json!({
            "schema": 1,
            "kind": "cmux.server.binary",
            "version": "7.8.9-preview",
            "target": cmux_server::host::TARGET,
            "release_keys": [
                {"id": "current", "sha256": "02d449a31fbb267c8f352e9968a79e3e5fc95c1bbeaa502fd6454ebde5a4bedc"},
                {"id": "next", "sha256": "9f72ea0cf49536e3c66c787f705186df9a4378083753ae9536d65b3ad7fcddc4"}
            ]
        })
    );
}

#[test]
fn status_binary_identity_does_not_invent_keys_or_release_readiness() {
    let result = query(Vec::new());
    assert_eq!(result["release_keys"], json!([]));
    assert!(result.get("ready").is_none());
    assert!(result.get("activation_authorized").is_none());
}

#[test]
fn status_binary_identity_flag_never_applies_to_an_install() {
    assert!(parse(&["install".into(), "--binary-only".into(), "--json".into()]).is_err());
}

#[test]
fn status_binary_identity_real_binary_needs_no_host_state_and_ignores_runtime_keys() {
    let directory = tempfile::tempdir().unwrap();
    let run = |override_keys: bool| {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-server"));
        command
            .args(["status", "--binary-only", "--json"])
            .env_clear()
            .current_dir(directory.path());
        if override_keys {
            command.env("CMUX_SERVER_RELEASE_KEYS", format!("attacker:{}", "7a".repeat(32)));
        }
        let output = command.output().unwrap();
        assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
        serde_json::from_slice::<Value>(&output.stdout).unwrap()
    };
    let actual = run(false);
    assert_eq!(run(true), actual, "runtime environment cannot change baked trust roots");
    assert_eq!(actual["schema"], 1);
    assert_eq!(actual["kind"], "cmux.server.binary");
    assert_eq!(actual["version"], cmux_server::cli::running_version());
    assert_eq!(actual["target"], cmux_server::host::TARGET);
    let expected: BTreeSet<_> = cmux_server::keys::parse(BUILD_KEYS.unwrap_or(""))
        .unwrap()
        .into_iter()
        .map(|key| key.id)
        .collect();
    let reported: BTreeSet<_> = actual["release_keys"]
        .as_array()
        .unwrap()
        .iter()
        .map(|key| key["id"].as_str().unwrap().to_owned())
        .collect();
    assert_eq!(reported, expected);
    assert_eq!(std::fs::read_dir(directory.path()).unwrap().count(), 0);
}
