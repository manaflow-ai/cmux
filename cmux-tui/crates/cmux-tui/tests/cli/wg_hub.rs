//! `wg hub`: readiness, permissions, the control socket and its datagram
//! ports, and cleanup on SIGTERM.

use super::*;

const WG_HUB_TEST_PRIVATE_KEY: &str = "GDYq0RJ4LWL6jJhLMAlM1oHcCTdSiXPMZ4X5D8WzGdw=";
const WG_HUB_TEST_PEER_KEY: &str = "Bo2I0OcpKnXtElGwH6EXV3MwDQctaIrFJ4tDX44DoWs=";

fn write_wg_hub_config(dir: &std::path::Path, mode: u32) -> PathBuf {
    let config = dir.join("wg.conf");
    fs::write(
        &config,
        format!(
            "[Interface]\nPrivateKey = {WG_HUB_TEST_PRIVATE_KEY}\nAddress = 100.64.0.1/32\nMTU = 1200\n\n[Peer]\nPublicKey = {WG_HUB_TEST_PEER_KEY}\nAllowedIPs = 10.0.0.0/8, fd00::/8\nEndpoint = 127.0.0.1:9\n"
        ),
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(mode)).unwrap();
    config
}

#[test]
fn wg_hub_reports_readiness_and_removes_its_socket_on_sigterm() {
    use base64::Engine;

    let dir = TestTempDir::create("wg-hub");
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
    let (contents, peer) = runtime.block_on(async {
        let cmux_wg::testing::LoopbackPair { client, server, server_socket, .. } =
            cmux_wg::testing::loopback_pair().await.unwrap();
        let peer = cmux_wg::WgNet::start(server, server_socket).await.unwrap();
        let encoder = base64::engine::general_purpose::STANDARD;
        let contents = format!(
            "[Interface]\nPrivateKey = {}\nAddress = 10.200.0.1/32\nMTU = 1200\n\n[Peer]\nPublicKey = {}\nAllowedIPs = 10.200.0.0/24, fdcc::/64\nEndpoint = {}\nPersistentKeepalive = 5\n",
            encoder.encode(client.private_key.as_ref()),
            encoder.encode(client.peer_public_key),
            client.endpoint.unwrap(),
        );
        (contents, peer)
    });
    let config = dir.path().join("wg.conf");
    fs::write(&config, contents).unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
    let socket = dir.path().join("hub").join("wg.sock");
    let mut child = Command::new(bin())
        .args(["wg", "hub", "--config"])
        .arg(&config)
        .arg("--socket")
        .arg(&socket)
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();

    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    assert!(
        !line.is_empty(),
        "hub exited before printing readiness: {:?}",
        child.wait_with_output()
    );
    let ready: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
    assert_eq!(ready["event"], "hub-ready", "{line}");
    assert_eq!(ready["socket"], socket.to_str().unwrap(), "{line}");
    assert_eq!(ready["routes"], serde_json::json!(["10.200.0.0/24", "fdcc::/64"]), "{line}");

    let socket_meta = fs::metadata(&socket).unwrap();
    assert!(socket_meta.file_type().is_socket());
    assert_eq!(socket_meta.permissions().mode() & 0o777, 0o600);
    assert_eq!(fs::metadata(socket.parent().unwrap()).unwrap().permissions().mode() & 0o777, 0o700);

    // A live socket must be refused by a second hub.
    let second = Command::new(bin())
        .args(["wg", "hub", "--config"])
        .arg(&config)
        .arg("--socket")
        .arg(&socket)
        .env("LC_ALL", "C")
        .output()
        .unwrap();
    assert!(!second.status.success(), "second hub on a live socket must fail");
    assert!(socket.exists(), "the losing hub must not remove the live socket");

    let pid = i32::try_from(child.id()).unwrap();
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "hub did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "hub exited unsuccessfully after SIGTERM: {status}");
    assert!(!socket.exists(), "hub must remove its socket on exit");
    runtime.block_on(peer.shutdown());
}

/// `wg hub --control`: the readiness line names the control socket, a
/// datagram port bound there relays through the tunnel to the peer and back,
/// and the hub removes both sockets on SIGTERM.
#[test]
fn wg_hub_control_relays_datagrams_through_the_tunnel() {
    use base64::Engine;
    use std::os::unix::net::UnixDatagram;

    let dir = TestTempDir::create("wg-hub-control");
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap();
    let (contents, peer, mut theirs, server_v6) = runtime.block_on(async {
        let cmux_wg::testing::LoopbackPair { client, server, server_socket, server_v6, .. } =
            cmux_wg::testing::loopback_pair().await.unwrap();
        let peer = cmux_wg::WgNet::start(server, server_socket).await.unwrap();
        let theirs = peer.bind_datagram(4103).await.unwrap();
        let encoder = base64::engine::general_purpose::STANDARD;
        let contents = format!(
            "[Interface]\nPrivateKey = {}\nAddress = 10.200.0.1/32, fdcc::1/128\nMTU = 1200\n\n[Peer]\nPublicKey = {}\nAllowedIPs = 10.200.0.0/24, fdcc::/64\nEndpoint = {}\nPersistentKeepalive = 5\n",
            encoder.encode(client.private_key.as_ref()),
            encoder.encode(client.peer_public_key),
            client.endpoint.unwrap(),
        );
        (contents, peer, theirs, server_v6)
    });
    let config = dir.path().join("wg.conf");
    fs::write(&config, contents).unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o600)).unwrap();
    let socket = dir.path().join("hub").join("wg.sock");
    let control = dir.path().join("hub").join("control.sock");
    let mut child = Command::new(bin())
        .args(["wg", "hub", "--config"])
        .arg(&config)
        .arg("--socket")
        .arg(&socket)
        .arg("--control")
        .arg(&control)
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let mut line = String::new();
    stdout.read_line(&mut line).unwrap();
    assert!(!line.is_empty(), "hub exited before readiness: {:?}", child.wait_with_output());
    let ready: serde_json::Value = serde_json::from_str(line.trim()).unwrap();
    assert_eq!(ready["control"], control.to_str().unwrap(), "{line}");
    assert_eq!(fs::metadata(&control).unwrap().permissions().mode() & 0o777, 0o600);

    let mut session = UnixStream::connect(&control).unwrap();
    session.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    session
        .write_all(b"{\"id\":1,\"method\":\"datagram.bind\",\"params\":{\"port\":4103,\"class\":\"media\"}}\n")
        .unwrap();
    let mut replies = BufReader::new(session.try_clone().unwrap());
    let mut reply = String::new();
    replies.read_line(&mut reply).unwrap();
    let reply: serde_json::Value = serde_json::from_str(reply.trim()).unwrap();
    let dgram = PathBuf::from(reply["result"]["socket"].as_str().expect("bound"));
    assert_eq!(fs::metadata(&dgram).unwrap().permissions().mode() & 0o777, 0o600);

    // No PeerAddress in the config: no probes, so no measured path.
    session.write_all(b"{\"id\":2,\"method\":\"path.get\"}\n").unwrap();
    let mut path = String::new();
    replies.read_line(&mut path).unwrap();
    let path: serde_json::Value = serde_json::from_str(path.trim()).unwrap();
    assert_eq!(path["result"]["max_datagram"], 1152, "{path}");
    assert!(path["result"]["path"].is_null(), "{path}");

    let local_path = dir.path().join("client.sock");
    let local = UnixDatagram::bind(&local_path).unwrap();
    local.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let std::net::IpAddr::V6(server) = server_v6 else { panic!("IPv6 fixture") };
    let mut datagram = vec![0, 0, 0, 4];
    datagram.extend_from_slice(&server.octets());
    datagram.extend_from_slice(&4103u16.to_be_bytes());
    datagram.extend_from_slice(b"frame");
    local.send_to(&datagram, &dgram).unwrap();
    let (payload, from) = runtime
        .block_on(async { tokio::time::timeout(Duration::from_secs(10), theirs.recv_from()).await })
        .unwrap()
        .unwrap();
    assert_eq!(payload, b"frame");
    runtime.block_on(theirs.send_to(b"ack", from, cmux_wg::Priority::Interactive)).unwrap();
    let mut buffer = [0u8; 256];
    let len = local.recv(&mut buffer).unwrap();
    assert_eq!(&buffer[..len - 3], &datagram[..datagram.len() - 5], "the header names the peer");
    assert_eq!(&buffer[len - 3..len], b"ack");

    let pid = i32::try_from(child.id()).unwrap();
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    let deadline = Instant::now() + Duration::from_secs(5);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "hub did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "hub exited unsuccessfully after SIGTERM: {status}");
    assert!(!socket.exists() && !control.exists(), "hub must remove its sockets on exit");
    assert!(!dgram.exists(), "hub must remove its datagram sockets on exit");
    drop(theirs);
    runtime.block_on(peer.shutdown());
}

#[test]
fn wg_hub_refuses_a_readable_config_and_missing_options() {
    let dir = TestTempDir::create("wg-hub-perms");
    let config = write_wg_hub_config(dir.path(), 0o644);
    let socket = dir.path().join("wg.sock");
    let output = Command::new(bin())
        .args(["wg", "hub", "--config"])
        .arg(&config)
        .arg("--socket")
        .arg(&socket)
        .env("LC_ALL", "C")
        .output()
        .unwrap();
    assert!(!output.status.success());
    let stderr = String::from_utf8(output.stderr).unwrap();
    assert!(stderr.contains("cannot read WireGuard config"), "{stderr}");
    assert!(!socket.exists());

    let missing = lifecycle_cli(&["wg", "hub", "--config", config.to_str().unwrap()]);
    assert!(!missing.status.success());
    assert!(String::from_utf8(missing.stderr).unwrap().contains("--socket"));

    let help = lifecycle_cli(&["wg", "hub", "--help"]);
    assert!(help.status.success());
    assert!(String::from_utf8(help.stdout).unwrap().starts_with("USAGE: cmux wg hub"));
}
