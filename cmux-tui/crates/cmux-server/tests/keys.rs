//! Release keys are baked in at build time only (decision SV-R1): the
//! process environment of the running binary never changes which keys it
//! trusts.

use std::process::Command;

use cmux_server::keys;

/// The spec this test crate was built with (the same build environment as
/// the library and the `cmux-server` binary).
const BUILD_SPEC: Option<&str> = option_env!("CMUX_SERVER_RELEASE_KEYS");

fn attacker_spec() -> String {
    format!("attacker:{}", "7a".repeat(32))
}

/// The real binary, started with an attacker key in its environment, still
/// trusts only the build's keys. A build without keys refuses before it
/// fetches or writes anything (exit 7).
#[test]
fn a_runtime_env_var_cannot_add_a_trusted_key() {
    let tmp = tempfile::tempdir().unwrap();
    let root = cmux_server::sys::is_root();
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_cmux-server"));
    cmd.args(["install", "--json", "--channel-url=https://127.0.0.1:9"])
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", tmp.path())
        .env("XDG_DATA_HOME", tmp.path().join("data"))
        .env("XDG_STATE_HOME", tmp.path().join("state"))
        .env("XDG_CONFIG_HOME", tmp.path().join("config"))
        .env("CMUX_SERVER_RELEASE_KEYS", attacker_spec());
    if root {
        cmd.arg("--system");
    } else {
        cmd.env("CMUX_SERVER_MODE", "user");
    }
    let baked = keys::parse(BUILD_SPEC.unwrap_or("")).expect("build spec is valid");
    if !baked.is_empty() {
        // A keyed build: the keys come from the build, not from the env.
        assert!(baked.iter().all(|k| k.id != "attacker"));
        return;
    }
    let out = cmd.output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(out.status.code(), Some(7), "stderr: {stderr}");
    assert!(stderr.contains("no baked release keys"), "stderr: {stderr}");
    // Nothing was written under the temporary home.
    assert!(!tmp.path().join("data").exists(), "install wrote state before refusing");
}
