use super::*;

#[test]
fn daemon_rejects_inline_relay_ticket() {
    const CHILD_ENV: &str = "CMUX_DAEMON_RELAY_TICKET_LOCALE_CHILD";
    if std::env::var_os(CHILD_ENV).is_none() {
        let output = std::process::Command::new(std::env::current_exe().unwrap())
            .arg("remote_args_tests::daemon_rejects_inline_relay_ticket")
            .arg("--exact")
            .arg("--nocapture")
            .env(CHILD_ENV, "1")
            .env("LC_ALL", "ja_JP.UTF-8")
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "Japanese daemon relay-ticket rejection child failed:\nstdout:\n{}\nstderr:\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }

    let marker = "inline-daemon-secret-marker";
    let error = parse_args_result(
        [
            "--headless",
            "--remote",
            "--relay",
            "relay+wss://relay.example",
            "--relay-slot",
            "routing-key",
            "--relay-ticket",
            marker,
        ]
        .map(str::to_string),
    )
    .expect_err("inline daemon relay ticket was accepted");
    assert!(!error.contains(marker));
    assert_eq!(
        error,
        localization::catalog_for_locale("ja_JP.UTF-8").remote_client.inline_relay_ticket_rejected
    );
}
