#[test]
fn bwrap_command_scrubs_loader_env() {
    let mut cmd = Command::new("/usr/bin/bwrap");
    cmd.env("LD_PRELOAD", "injected")
        .env("LOCPATH", "injected")
        .env("TMPDIR", "/injected")
        .env("MALLOC_CHECK_", "3")
        .env("PATH", "/usr/bin");
    crate::hub::remote_sandbox::scrub_loader_env(&mut cmd);
    let env = crate::agent::command_env(&cmd);
    assert!(
        !env.iter().any(|(k, _)| matches!(
            k.as_str(),
            "LD_PRELOAD" | "LOCPATH" | "TMPDIR" | "MALLOC_CHECK_"
        ))
    );
    assert!(env.iter().any(|(k, v)| k == "PATH" && v == "/usr/bin"));
}

use super::*;
use std::net::{TcpStream, UdpSocket};
use std::os::unix::ffi::OsStringExt;
use std::os::unix::process::ExitStatusExt;
use std::time::Duration;
fn required() -> Vec<&'static str> {
    "--cwd /work --tmpdir /scratch --home /home/person \
         --claude-tmp-project /claude-tmp/project \
         --claude-project /home/person/.claude/projects/project --proxy-port 3128"
        .split_whitespace()
        .collect()
}
fn argv(extra: &[&str]) -> Vec<OsString> {
    required()
        .into_iter()
        .chain(extra.iter().copied())
        .chain(["--", "/bin/sh", "-c", "printf '%s' \"$1\"", "sh", "a b"])
        .map(OsString::from)
        .collect()
}
#[test]
fn options_canonical_round_trip() {
    let options = parse(argv(&[])).unwrap();
    assert_eq!(options.proxy_port, 3128);
    assert_eq!(options.api, None);
    let paths = [
        &options.paths.cwd,
        &options.paths.tmp,
        &options.paths.home,
        &options.paths.claude_tmp_project,
        &options.paths.claude_project,
    ];
    let mut round_trip = Vec::new();
    for (pair, path) in required().chunks_exact(2).take(5).zip(paths) {
        assert_eq!(path, &PathBuf::from(pair[1]));
        round_trip.extend([OsString::from(pair[0]), path.as_os_str().to_owned()]);
    }
    round_trip.extend([OsString::from("--proxy-port"), options.proxy_port.to_string().into()]);
    round_trip.extend([OsString::from("--"), options.program.into()]);
    round_trip.extend(options.args.into_iter().map(OsString::from));
    assert_eq!(round_trip, argv(&[]));
    assert!(parse(round_trip).is_ok());
    let options = parse(argv(&["--api-port", "31415", "--api-loopback-v4"])).unwrap();
    assert_eq!(options.api, Some("127.0.0.1:31415".parse().unwrap()));
    assert!(parse(argv(&["--api-port", "31415", "--api-loopback-v6"])).is_err());
    assert!(parse(argv(&["--bwrap", "/opt/bwrap"])).is_err());
}
/// A non-loopback API port (a tailnet router such as sr2 :4016) is
/// reachable through the proxy; loopback on that port stays shut.
#[test]
fn remote_api_port_opens_only_that_port_off_loopback() {
    let options = parse(argv(&["--api-remote-port", "4016"])).unwrap();
    assert_eq!(options.api, None);
    let policy = net_policy(&options);
    assert!(proxy::allowed(&policy, "100.120.48.119:4016".parse().unwrap()));
    assert!(!proxy::allowed(&policy, "127.0.0.1:4016".parse().unwrap()));
    assert!(!proxy::allowed(&policy, "100.120.48.119:4017".parse().unwrap()));
    let closed = net_policy(&parse(argv(&[])).unwrap());
    assert!(!proxy::allowed(&closed, "100.120.48.119:4016".parse().unwrap()));
    for bad in [
        vec!["--api-remote-port", "0"],
        vec!["--api-remote-port", "3128"],
        vec!["--api-remote-port", "4016", "--api-remote-port", "4016"],
        vec!["--api-remote-port", "4016", "--api-port", "31415", "--api-loopback-v4"],
    ] {
        assert!(parse(argv(&bad)).is_err(), "{bad:?}");
    }
}
#[test]
fn options_refuse_missing_duplicate_and_unknown_flags() {
    for pair in required().chunks_exact(2) {
        let mut missing = argv(&[]);
        let at = missing.iter().position(|v| v == pair[0]).unwrap();
        missing.drain(at..at + 2);
        assert!(parse(missing).is_err(), "missing {}", pair[0]);
        assert!(parse(argv(pair)).is_err(), "duplicate {}", pair[0]);
    }
    for extra in [
        vec!["--wat", "1"],
        vec!["--proxy-port=3128"],
        vec!["--bwrap", "/a"],
        vec!["--api-port", "31415", "--api-port", "31415", "--api-loopback-v4"],
        vec!["--api-port", "31415", "--api-loopback-v4", "--api-loopback-v4"],
        vec!["--api-port", "31415", "--api-loopback-v6", "--api-loopback-v6"],
        vec!["--api-port", "31415", "--api-loopback-v4", "--api-loopback-v6"],
        vec!["--api-port", "31415"],
        vec!["--api-loopback-v4"],
        vec!["--api-loopback-v6"],
    ] {
        assert!(parse(argv(&extra)).is_err(), "{extra:?}");
    }
    for flag in required().chunks_exact(2).map(|p| p[0]).chain(["--api-port"]) {
        assert!(parse(vec![flag.into()]).is_err(), "{flag} at EOF");
        assert!(parse(vec![flag.into(), "--".into(), "/bin/true".into()]).is_err());
    }
    assert!(parse(Vec::new()).is_err());
    assert!(parse(required().into_iter().map(OsString::from).collect()).is_err());
    let mut missing_program = argv(&[]);
    missing_program.truncate(required().len() + 1);
    assert!(parse(missing_program).is_err());
}
#[test]
fn options_refuse_invalid_values_before_spawn() {
    for index in [1, 3, 5, 7, 9, 13] {
        for bad in ["relative", "", "/a/../b", "/bad\0path"] {
            let mut values = argv(&[]);
            values[index] = bad.into();
            assert!(parse(values).is_err(), "argument {index}: {bad:?}");
        }
    }
    assert!(parse(argv(&["--bwrap", "relative"])).is_err());
    for bad in ["0", "65536", "-1", "+80", " 80", "80x", ""] {
        let mut values = argv(&[]);
        values[11] = bad.into();
        assert!(parse(values).is_err(), "proxy {bad:?}");
        assert!(parse(argv(&["--api-port", bad, "--api-loopback-v4"])).is_err());
    }
    assert!(parse(argv(&["--api-port", "3128", "--api-loopback-v4"])).is_err());
    let mut values = argv(&[]);
    values.push(OsString::from_vec(vec![0xff]));
    assert!(parse(values).is_err());
    let mut values = argv(&[]);
    values.push("arg\0tail".into());
    assert!(parse(values).is_err());
}
fn listener(address: &str) -> (OwnedFd, u16) {
    let listener = TcpListener::bind((address, 0)).unwrap();
    let port = listener.local_addr().unwrap().port();
    (listener.into(), port)
}
fn payload(proxy: u16, api: Option<u16>) -> Vec<u8> {
    format!("{}\n", serde_json::json!({"proxy": proxy, "api": api})).into_bytes()
}
#[test]
fn handoff_accepts_exact_proxy_and_optional_api_listeners() {
    for with_api in [false, true] {
        let (proxy, port) = listener("127.0.0.1");
        let (api, api_port) = listener("127.0.0.1");
        let expected_api = with_api.then_some(api_port);
        let fds = std::iter::once(proxy).chain(with_api.then_some(api)).collect();
        let listeners =
            validate_handoff_for_test(&payload(port, expected_api), fds, port, expected_api)
                .unwrap();
        assert_eq!(listeners.len(), if with_api { 2 } else { 1 });
        assert_eq!(listeners[0].local_addr().unwrap().to_string(), format!("127.0.0.1:{port}"));
        if with_api {
            assert_eq!(listeners[1].local_addr().unwrap().port(), api_port);
        }
    }
}
#[test]
fn handoff_refuses_wrong_counts_ports_and_order() {
    assert!(validate_handoff_for_test(&payload(3128, None), vec![], 3128, None).is_err());
    for count in [1, 2, 3] {
        let (proxy, port) = listener("127.0.0.1");
        let (api, api_port) = listener("127.0.0.1");
        let fds = vec![proxy, api, listener("127.0.0.1").0].into_iter().take(count).collect();
        let expected_api = (count != 2).then_some(api_port);
        assert!(
            validate_handoff_for_test(&payload(port, expected_api), fds, port, expected_api)
                .is_err()
        );
    }
    let (proxy, port) = listener("127.0.0.1");
    let (api, api_port) = listener("127.0.0.1");
    assert!(
        validate_handoff_for_test(
            &payload(port, Some(api_port)),
            vec![api, proxy],
            port,
            Some(api_port)
        )
        .is_err()
    );
    let (fd, port) = listener("127.0.0.1");
    let wrong = if port == 65535 { 65534 } else { port + 1 };
    assert!(validate_handoff_for_test(&payload(wrong, None), vec![fd], wrong, None).is_err());
}
#[test]
fn handoff_refuses_invalid_json_and_mismatched_json_ports() {
    for text in [
        "",
        "{",
        "{}",
        "[]",
        "null",
        "{\"proxy\":PORT}",
        "{\"proxy\":0,\"api\":null}",
        "{\"proxy\":65536,\"api\":null}",
        "{\"proxy\":\"PORT\",\"api\":null}",
        "{\"proxy\":PORT,\"api\":null,\"extra\":1}",
    ] {
        let (fd, port) = listener("127.0.0.1");
        let text = text.replace("PORT", &port.to_string());
        assert!(
            validate_handoff_for_test(text.as_bytes(), vec![fd], port, None).is_err(),
            "{text}"
        );
    }
    let (fd, port) = listener("127.0.0.1");
    let duplicate = format!("{{\"proxy\":{port},\"proxy\":{port},\"api\":null}}\n");
    assert!(validate_handoff_for_test(duplicate.as_bytes(), vec![fd], port, None).is_err());
    let (fd, port) = listener("127.0.0.1");
    assert!(validate_handoff_for_test(&payload(port, Some(port)), vec![fd], port, None).is_err());
}
#[test]
fn handoff_refuses_nonlisteners_and_other_bind_addresses() {
    let file: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
    let udp = UdpSocket::bind("127.0.0.1:0").unwrap();
    let udp_port = udp.local_addr().unwrap().port();
    let tcp = TcpListener::bind("127.0.0.1:0").unwrap();
    let stream =
        TcpStream::connect_timeout(&tcp.local_addr().unwrap(), Duration::from_secs(2)).unwrap();
    let stream_port = stream.local_addr().unwrap().port();
    for (fd, port) in [(file, 3128), (udp.into(), udp_port), (stream.into(), stream_port)] {
        assert!(validate_handoff_for_test(&payload(port, None), vec![fd], port, None).is_err());
    }
    for address in ["0.0.0.0", "127.0.0.2"] {
        let (fd, port) = listener(address);
        assert!(validate_handoff_for_test(&payload(port, None), vec![fd], port, None).is_err());
    }
}
#[test]
fn handoff_refuses_a_listener_from_the_keeper_network_namespace() {
    let (fd, port) = listener("127.0.0.1");
    let notify: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
    let error = validate_handoff_with_notify(&payload(port, None), vec![fd, notify], port, None)
        .expect_err("a host listener must fail the namespace proof");
    assert!(error.contains("network namespace"), "{error}");
}
#[test]
fn handoff_without_notify_fd_is_refused() {
    let (fd, port) = listener("127.0.0.1");
    // Missing notify is rejected before listener validation.
    assert!(validate_handoff_with_notify(&payload(port, None), vec![fd], port, None).is_err());
}

#[test]
fn notify_fd_must_be_a_seccomp_listener() {
    let null: OwnedFd = std::fs::File::open("/dev/null").unwrap().into();
    assert!(validate_notify_fd(null.as_raw_fd()).is_err());
    let event = unsafe { libc::eventfd(0, libc::EFD_CLOEXEC) };
    assert!(event >= 0);
    let event = unsafe { OwnedFd::from_raw_fd(event) };
    assert!(validate_notify_fd(event.as_raw_fd()).is_err());
    let socket: OwnedFd = TcpListener::bind("127.0.0.1:0").unwrap().into();
    assert!(validate_notify_fd(socket.as_raw_fd()).is_err());
}

#[tokio::test]
async fn pidfd_signal_after_reap_is_esrch() {
    let mut child = Command::new("/bin/cat")
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let pinned = open_pidfd(child.id().unwrap());
    drop(child.stdin.take());
    tokio::time::timeout(Duration::from_secs(5), child.wait()).await.unwrap().unwrap();
    let pinned = pinned.expect("relay must pin the child before any reap");
    // A queued termination delivered after reap must address only this dead child.
    assert_eq!(
        signal_pidfd(pinned.as_raw_fd(), libc::SIGTERM).unwrap_err().raw_os_error(),
        Some(libc::ESRCH)
    );
}

#[tokio::test]
async fn signal_relay_stops_after_child_exit() {
    let signals = [
        signal(SignalKind::terminate()).unwrap(),
        signal(SignalKind::interrupt()).unwrap(),
        signal(SignalKind::hangup()).unwrap(),
    ];
    let stop = CancellationToken::new();
    stop.cancel();
    let result = tokio::time::timeout(
        Duration::from_millis(100),
        forward_signals(open_pidfd(std::process::id()).unwrap(), signals, stop),
    )
    .await;
    assert!(result.is_ok(), "signal relay remained alive after child exit");
}

#[test]
fn keeper_to_init_api_contract_has_no_unknown_family_flag() {
    let args = init_prefix(
        Path::new("/usr/bin/acpmux"),
        Vec::new(),
        3,
        8118,
        Some("127.0.0.1:31415".parse().unwrap()),
    )
    .unwrap();
    assert!(!args.iter().any(|arg| arg == "--api-loopback-v4"));
}

#[test]
fn child_exit_status_mapping() {
    for code in [0, 1, 7, 125, 127, 255] {
        assert_eq!(exit_code(ExitStatus::from_raw(code << 8)), code);
    }
    for signal in [libc::SIGTERM, libc::SIGINT, libc::SIGHUP, libc::SIGKILL] {
        assert_eq!(exit_code(ExitStatus::from_raw(signal)), 128 + signal);
    }
    assert_eq!(exit_code(ExitStatus::from_raw(libc::SIGSEGV | 0x80)), 128 + libc::SIGSEGV);
}
