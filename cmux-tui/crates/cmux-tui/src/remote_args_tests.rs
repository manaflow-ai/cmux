use super::*;

#[test]
fn shorthand_server_start_uses_the_existing_lifecycle() {
    let mut args =
        ["--session", "shorthand-test", "srv", "start", "--ephemeral"].map(str::to_string).to_vec();
    rewrite_server_start(&mut args);
    assert_eq!(args, ["--headless", "--session", "shorthand-test", "--ephemeral"]);
}

#[test]
fn daemon_accepts_native_and_durable_object_relay_registrations() {
    let args = parse_args(
        [
            "--headless",
            "--remote",
            "--relay",
            "relay+wss://relay.example",
            "--relay-slot",
            "native-route-key",
            "--relay-ticket-command",
            "native-ticket-command",
            "--relay",
            "relay+do://worker.example",
            "--relay-slot",
            "do-route-key",
            "--relay-ticket-file",
            "/tmp/do-ticket",
        ]
        .map(str::to_string),
    );

    let relays =
        relay_daemon_options(args.relay_endpoints, args.relay_slots, args.relay_credentials)
            .unwrap();
    assert_eq!(relays.len(), 2);
    assert_eq!(relays[0].endpoint.as_str(), "relay+wss://relay.example");
    assert_eq!(relays[1].endpoint.as_str(), "relay+do://worker.example");
}

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

#[test]
fn inline_relay_ticket_scanner_preserves_command_argument_literals() {
    let args = ["--relay-ticket-command", "helper", "--relay-ticket-command-arg", "--relay-ticket"]
        .map(str::to_string);

    assert!(!has_inline_relay_ticket_argument(&args));
}

#[test]
fn remote_state_directory_enables_remote_daemon_mode() {
    let args = parse_args(["--remote-state-dir", "/tmp/cmux-remote-state"].map(str::to_string));

    assert!(args.remote);
    assert_eq!(args.remote_state_dir, Some(PathBuf::from("/tmp/cmux-remote-state")));
}

#[test]
fn remote_http_enables_remote_daemon_mode() {
    let args = parse_args(["--remote-http", "127.0.0.1:8765"].map(str::to_string));

    assert!(args.remote);
    assert_eq!(args.remote_http.as_deref(), Some("127.0.0.1:8765"));
}

#[test]
fn malformed_relay_endpoint_errors_do_not_echo_credentials() {
    let error = relay_daemon_options(
        vec!["relay+wss://dont-leak-me@[".into()],
        vec!["routing-key".into()],
        vec![RelayCredentialArg::File("/tmp/relay-ticket".into())],
    )
    .expect_err("malformed relay endpoint should fail");

    assert!(!error.to_string().contains("dont-leak-me"));
}
