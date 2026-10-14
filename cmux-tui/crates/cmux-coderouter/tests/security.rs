#[test]
fn panic_payload_is_discarded() {
    if std::env::var_os("CODEROUTER_PANIC_CHILD").is_some() {
        cmux_coderouter::install_panic_hook();
        panic!("test-secret-canary");
    }
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "panic_payload_is_discarded", "--nocapture"])
        .env("CODEROUTER_PANIC_CHILD", "1")
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(!stderr.contains("test-secret-canary"));
    assert!(stderr.contains("security.rs:"));
}

/// The relay's tests keep the install secret out of the Keychain only in a
/// debug build: a release build (what the app ships) ignores the switch.
#[test]
fn a_release_build_ignores_the_ephemeral_install_secret_switch() {
    use std::ffi::OsStr;
    assert!(!cmux_coderouter::ephemeral_install_secret(false, Some(OsStr::new("1"))));
    assert!(cmux_coderouter::ephemeral_install_secret(true, Some(OsStr::new("1"))));
    assert!(!cmux_coderouter::ephemeral_install_secret(true, None));
    assert!(!cmux_coderouter::ephemeral_install_secret(true, Some(OsStr::new("0"))));
}
