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
