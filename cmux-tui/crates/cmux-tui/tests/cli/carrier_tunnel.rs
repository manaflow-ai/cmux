//! `carrier tunnel` with the real `wg hub`: it attaches to a fake platform,
//! starts the hub against a real WireGuard peer, stays up until SIGTERM, then
//! stops the hub (which removes its socket).

use super::*;

#[test]
fn carrier_tunnel_runs_the_real_hub_until_sigterm() {
    run_until_sigterm(false);
}

/// SIGTERM while a refresh hangs on the VM API: the read is cancelled, the
/// hub stops, and the process ends `tunnel-stopped` with 0, never failed.
#[test]
fn sigterm_during_a_stalled_refresh_stops_cleanly() {
    run_until_sigterm(true);
}

fn run_until_sigterm(stall: bool) {
    use base64::Engine;
    use base64::engine::general_purpose::STANDARD;

    let dir = TestTempDir::create("carrier-tunnel");
    let runtime =
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
    let hits = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let counter = std::sync::Arc::clone(&hits);
    let (peer, keys, origin, vm_api) = runtime.block_on(async {
        let cmux_wg::testing::LoopbackPair { client, server, server_socket, .. } =
            cmux_wg::testing::loopback_pair().await.unwrap();
        let peer = cmux_wg::WgNet::start(server, server_socket).await.unwrap();
        let tunnel = serde_json::json!({
            "tunnel_id": "tun_1", "network_id": "team_1", "mesh_id": "mesh_1",
            "device_id": "dev_1", "address_v4": "10.200.0.1", "address_v6": null,
            "server_public_key": STANDARD.encode(client.peer_public_key),
            "client_config": {
                "endpoint": client.endpoint.unwrap().to_string(),
                "interface_address": "10.200.0.1/32",
                "allowed_ips": ["10.200.0.0/24"],
                "mtu": 1200,
                "persistent_keepalive_seconds": 5,
            },
        });
        let app = axum::Router::new().route(
            "/v1/mesh/nodes/machine_1/attach",
            axum::routing::post(move |body: axum::body::Bytes| {
                let tunnel = tunnel.clone();
                async move {
                    let body: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
                    axum::Json(if body.get("enrollment").is_some() {
                        tunnel
                    } else {
                        serde_json::json!({"mesh_id": "mesh_1"})
                    })
                }
            }),
        );
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let install = cmux_server_core::install_key::InstallKey::generate(
            &cmux_server_core::install_key::SystemRandom::new(),
        )
        .unwrap();
        let keys = serde_json::json!({
            "wg_private_key": STANDARD.encode(client.private_key.as_ref()),
            "install_key": install.pkcs8_base64url(),
        });
        // A VM API that takes every tunnel read and never answers.
        let stalling = axum::Router::new().fallback(move || {
            counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            std::future::pending::<axum::http::StatusCode>()
        });
        let vm_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let vm_api = format!("http://{}", vm_listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(vm_listener, stalling).await.unwrap() });
        (peer, keys, origin, vm_api)
    });

    let socket = dir.path().join("hub").join("wg.sock");
    let mut child = Command::new(bin())
        .args(["carrier", "tunnel", "--machine-id", "machine_1", "--name", "test-mac", "--socket"])
        .arg(&socket)
        .args(["--platform", &origin, "--vm-api", &vm_api])
        .env("CMUX_CARRIER_TUNNEL_REFRESH_MS", if stall { "100" } else { "3600000" })
        .env("CMUX_CLOUD_ACCESS_TOKEN", "tok")
        .env_remove("CMUX_CLOUD_TEAM")
        .env("LC_ALL", "C")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .unwrap();
    writeln!(child.stdin.take().unwrap(), "{keys}").unwrap();
    let (lines, events) = mpsc::channel::<String>();
    let stdout = child.stdout.take().unwrap();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            let _ = lines.send(line);
        }
    });
    let next = |want: &str| loop {
        let line = events.recv_timeout(Duration::from_secs(60)).expect(want);
        let event: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert!(
            !matches!(event["event"].as_str(), Some("tunnel-failed" | "tunnel-unavailable")),
            "{line}"
        );
        if event["event"] == want {
            break event;
        }
    };

    let ready = next("tunnel-ready");
    assert_eq!(ready["socket"], socket.to_str().unwrap());
    assert_eq!(ready["device_id"], "dev_1");
    assert!(fs::metadata(&socket).unwrap().file_type().is_socket(), "the hub bound its socket");
    let mut lock = socket.clone().into_os_string();
    lock.push(".tunnel-lock");
    assert_eq!(fs::metadata(&lock).unwrap().permissions().mode() & 0o777, 0o600);
    // It keeps running: no signal has come.
    std::thread::sleep(Duration::from_millis(500));
    assert!(child.try_wait().unwrap().is_none(), "carrier tunnel exited without a signal");
    if stall {
        let deadline = Instant::now() + Duration::from_secs(10);
        while hits.load(std::sync::atomic::Ordering::SeqCst) == 0 {
            assert!(Instant::now() < deadline, "a refresh in flight");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    let pid = i32::try_from(child.id()).unwrap();
    assert_eq!(unsafe { libc::kill(pid, libc::SIGTERM) }, 0);
    next("tunnel-stopped");
    let deadline = Instant::now() + Duration::from_secs(15);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        assert!(Instant::now() < deadline, "carrier tunnel did not exit after SIGTERM");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(status.success(), "{status}");
    assert!(!socket.exists(), "the stopped hub removed its socket");
    runtime.block_on(peer.shutdown());
}

#[test]
fn carrier_tunnel_help_prints_usage_and_exits_0_and_misuse_exits_64() {
    for flag in ["--help", "-h"] {
        let out = Command::new(bin())
            .args(["carrier", "tunnel", flag])
            .stdin(Stdio::null())
            .output()
            .unwrap();
        assert_eq!(out.status.code(), Some(0), "{flag}");
        let text = String::from_utf8_lossy(&out.stdout);
        assert!(text.starts_with("usage: cmux carrier tunnel --machine-id"), "{flag}: {text}");
    }
    let out = Command::new(bin())
        .args(["carrier", "tunnel", "--bogus"])
        .stdin(Stdio::null())
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(64));
}
