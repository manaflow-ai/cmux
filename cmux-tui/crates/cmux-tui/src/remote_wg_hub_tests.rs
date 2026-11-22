use super::*;

#[test]
fn the_token_line_comes_before_the_stdin_config() {
    let mut input: &[u8] = b"tok-4f2a\n[Interface]\nPrivateKey = x\n";
    let token = read_hub_token_line(&mut input).unwrap();
    assert_eq!(token.as_str(), "tok-4f2a");
    assert_eq!(input, b"[Interface]\nPrivateKey = x\n", "the config stays for --config -");
}

#[test]
fn a_stdin_config_is_bounded_and_must_parse() {
    let huge = vec![b'#'; MAX_WIREGUARD_CONFIG_BYTES + 1];
    assert!(read_wireguard_config_stdin(&mut huge.as_slice()).is_err());
    assert!(read_wireguard_config_stdin(&mut &[0xff, 0xfe][..]).is_err());
    assert!(read_wireguard_config_stdin(&mut &b"[Interface]\n"[..]).is_err());
}

#[test]
fn wg_hub_flags_require_config_and_socket() {
    let full = ["hub", "--config", "/tmp/wg.conf", "--socket", "/tmp/wg.sock"].map(str::to_string);
    let flags = parse_wg_hub_flags(&full[1..]).unwrap();
    assert_eq!(flags.config, PathBuf::from("/tmp/wg.conf"));
    assert_eq!(flags.socket, PathBuf::from("/tmp/wg.sock"));
    assert!(!flags.exit_with_parent);
    assert!(!flags.client_token_stdin);
    let tokened = ["--config", "-", "--socket", "s", "--client-token-stdin"].map(str::to_string);
    let tokened = parse_wg_hub_flags(&tokened).unwrap();
    assert!(tokened.client_token_stdin);
    assert_eq!(tokened.config, PathBuf::from("-"));
    let owned = ["--config", "/tmp/wg.conf", "--socket", "/tmp/wg.sock", "--exit-with-parent"]
        .map(str::to_string);
    assert!(parse_wg_hub_flags(&owned).unwrap().exit_with_parent);
    assert!(!flags.probes && flags.control.is_none());
    let measured =
        ["--config", "c", "--socket", "s", "--control", "k", "--probes"].map(str::to_string);
    let measured = parse_wg_hub_flags(&measured).unwrap();
    assert!(measured.probes);
    let sized = ["--config", "c", "--socket", "s", "--send-buffer", "32768"].map(str::to_string);
    assert_eq!(parse_wg_hub_flags(&sized).unwrap().send_buffer, Some(32 * 1024));
    let bad = ["--config", "c", "--socket", "s", "--send-buffer", "lots"].map(str::to_string);
    assert!(parse_wg_hub_flags(&bad).is_err());
    let huge = ["--config", "c", "--socket", "s", "--send-buffer", "8388608"].map(str::to_string);
    assert!(parse_wg_hub_flags(&huge).is_err(), "above 4 MiB is refused");
    let tiny = ["--config", "c", "--socket", "s", "--send-buffer", "1"].map(str::to_string);
    assert!(parse_wg_hub_flags(&tiny).is_err(), "below 16 KiB is refused");
    let floor = ["--config", "c", "--socket", "s", "--send-buffer", "16384"].map(str::to_string);
    assert_eq!(parse_wg_hub_flags(&floor).unwrap().send_buffer, Some(16 * 1024));
    assert_eq!(measured.control, Some(PathBuf::from("k")));
    let missing = ["--config", "/tmp/wg.conf"].map(str::to_string);
    assert!(parse_wg_hub_flags(&missing).is_err());
    let unknown = ["--config", "/tmp/wg.conf", "--socket", "/tmp/s", "--bogus"].map(str::to_string);
    assert!(parse_wg_hub_flags(&unknown).is_err());
    let not_hub = ["frobnicate"].map(str::to_string);
    assert!(run_wg(&not_hub).is_err());
}

#[test]
fn wg_dial_takes_a_hub_a_host_and_a_port() {
    for bad in [
        &["dial"][..],
        &["dial", "--hub", "/tmp/h.sock", "10.0.0.7"],
        &["dial", "--hub", "/tmp/h.sock", "10.0.0.7", "0"],
        &["dial", "--hub", "/tmp/h.sock", "10.0.0.7", "ssh"],
        &["dial", "--socket", "/tmp/h.sock", "10.0.0.7", "22"],
    ] {
        let args = bad.iter().map(|word| (*word).to_owned()).collect::<Vec<_>>();
        assert_eq!(run_wg(&args).unwrap_err().to_string(), WG_DIAL_USAGE, "{bad:?}");
    }
}

/// The bridge speaks SOCKS5 CONNECT to the hub, then carries bytes both ways: a fake
/// hub that echoes gets back what the bridge read from its input.
#[cfg(unix)]
#[tokio::test]
async fn wg_dial_bridges_stdio_through_the_hub() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let directory = tempfile::tempdir().unwrap();
    let hub = directory.path().join("hub.sock");
    let listener = tokio::net::UnixListener::bind(&hub).unwrap();
    let server = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut greeting = [0u8; 2];
        stream.read_exact(&mut greeting).await.unwrap();
        let mut methods = vec![0u8; usize::from(greeting[1])];
        stream.read_exact(&mut methods).await.unwrap();
        stream.write_all(&[5, 0]).await.unwrap();
        let mut request = [0u8; 10];
        stream.read_exact(&mut request).await.unwrap();
        assert_eq!(&request[..4], &[5, 1, 0, 1], "CONNECT to an IPv4 literal");
        assert_eq!(&request[4..], &[10, 0, 0, 7, 0, 22]);
        stream.write_all(&[5, 0, 0, 1, 0, 0, 0, 0, 0, 0]).await.unwrap();
        // Read to the client's half-close, then answer: the bridge must still be listening.
        let mut line = Vec::new();
        stream.read_to_end(&mut line).await.unwrap();
        stream.write_all(&line).await.unwrap();
    });
    let mut output = Vec::new();
    bridge_through_hub(&hub, "10.0.0.7", 22, &b"hello"[..], &mut output).await.unwrap();
    server.await.unwrap();
    assert_eq!(output, b"hello");
}

#[cfg(unix)]
#[tokio::test]
async fn wg_dial_says_when_no_hub_runs() {
    let directory = tempfile::tempdir().unwrap();
    let error = bridge_through_hub(
        &directory.path().join("none.sock"),
        "10.0.0.7",
        22,
        &b""[..],
        Vec::new(),
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("is not reachable"), "{error}");
}

#[cfg(unix)]
#[test]
fn wireguard_hub_start_deadline_is_built_inside_the_runtime() {
    use std::os::unix::fs::PermissionsExt;

    // `wg hub` runs on a plain thread and hands its runtime to the starter.
    // The deadline future used to be built as `block_on`'s argument, where no
    // reactor exists, and every hub start panicked with "there is no reactor
    // running". A literal endpoint keeps DNS out of the test; the start may
    // still fail, and any `Result` is the pass condition.
    let directory = tempfile::tempdir().unwrap();
    let config = directory.path().join("hub.conf");
    fs::write(
        &config,
        "[Interface]\nPrivateKey = yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=\nAddress = 100.64.0.1/32\nMTU = 1200\n\n[Peer]\nPublicKey = xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=\nAllowedIPs = 10.0.0.0/24\nEndpoint = 127.0.0.1:1\n",
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
    let runtime = tokio_runtime().unwrap();
    let started =
        start_wireguard_hub_tunnel(&runtime, &config, HubTunnel::default(), Duration::from_secs(5));
    drop(started);
}
