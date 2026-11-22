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

/// In process: setting the variable after start leaves `baked()` as built.
#[test]
fn setting_the_env_var_in_process_leaves_the_baked_keys_unchanged() {
    let before = keys::baked();
    // SAFETY: this test binary's tests do not read this variable from
    // other threads; the point is that `baked()` does not read it at all.
    unsafe { std::env::set_var("CMUX_SERVER_RELEASE_KEYS", attacker_spec()) };
    let after = keys::baked();
    unsafe { std::env::remove_var("CMUX_SERVER_RELEASE_KEYS") };
    assert_eq!(before, after);
    assert_eq!(after, keys::parse(BUILD_SPEC.unwrap_or("")).unwrap());
    assert!(after.iter().all(|k| k.id != "attacker"));
}

/// A malformed spec is an error, never a shorter key list: release CI
/// cannot ship a build that silently dropped a key.
#[test]
fn a_malformed_spec_is_rejected_not_truncated() {
    let good = "11".repeat(32);
    assert_eq!(keys::parse("").unwrap(), vec![]);
    assert_eq!(keys::parse("  ").unwrap(), vec![]);
    let two = keys::parse(&format!("current:{good}, next:{}", "AB".repeat(32))).unwrap();
    assert_eq!(two.len(), 2);
    assert_eq!(two[1].public_key, [0xab; 32]);
    for bad in [
        format!("current:{good},bad:12"),
        format!(":{good}"),
        format!("current:{good},"),
        format!("current:{good},,next:{good}"),
        format!("current {good}"),
        format!("current:+{}", "1".repeat(63)),
        format!("current:{}", "g".repeat(64)),
        format!("current:{good},current:{}", "22".repeat(32)),
        format!("cur rent:{good}"),
    ] {
        assert!(keys::parse(&bad).is_err(), "accepted {bad:?}");
    }
}
