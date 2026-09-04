//! `WgNet` against a real Linux kernel WireGuard peer.
//!
//! The two-peer loopback harness proves smoltcp talks to smoltcp. This test
//! proves it talks to the implementation cmux Cloud machines actually run: the
//! kernel creates a `wireguard` interface as the server, a plain Tokio TCP
//! listener on that interface's addresses is the "daemon", and `WgNet` dials
//! it over both address families through the tunnel.
//!
//! Needs Linux, passwordless `sudo`, `ip`, and `wg`. Runs only when
//! `CMUX_WG_KERNEL_PEER=1`; otherwise it is a silent no-op so `cargo test`
//! stays hermetic on machines without those privileges.

#![cfg(target_os = "linux")]

use std::net::{IpAddr, SocketAddr};
use std::process::Command;
use std::time::Duration;

use base64::Engine;
use cmux_wg::testing::random_keypair;
use cmux_wg::{Endpoint, InterfaceAddress, IpNetwork, WgNet};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use zeroize::Zeroizing;

const INTERFACE: &str = "wgcmux0";
const TIMEOUT: Duration = Duration::from_secs(8);

fn enabled() -> bool {
    std::env::var_os("CMUX_WG_KERNEL_PEER").is_some_and(|value| value == "1")
}

fn sudo(args: &[&str]) -> String {
    let output = Command::new("sudo").arg("-n").args(args).output().expect("run sudo");
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.status.success(), "sudo {} failed: {text}", args.join(" "));
    text
}

fn diagnostics() -> String {
    let wg = Command::new("sudo").args(["-n", "wg", "show", INTERFACE]).output();
    let link = Command::new("ip").args(["-s", "link", "show", INTERFACE]).output();
    let render = |output: std::io::Result<std::process::Output>| {
        output
            .map(|output| {
                format!(
                    "{}{}",
                    String::from_utf8_lossy(&output.stdout),
                    String::from_utf8_lossy(&output.stderr)
                )
            })
            .unwrap_or_else(|error| error.to_string())
    };
    format!("--- wg show ---\n{}--- ip -s link ---\n{}", render(wg), render(link))
}

/// Deletes the kernel interface even when an assertion fails first.
struct KernelPeer;

impl Drop for KernelPeer {
    fn drop(&mut self) {
        let _ = Command::new("sudo").args(["-n", "ip", "link", "del", INTERFACE]).output();
    }
}

async fn echo_listener(address: SocketAddr) -> u16 {
    let listener = TcpListener::bind(address).await.expect("bind echo listener on the wg address");
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            tokio::spawn(async move {
                let mut buffer = vec![0u8; 16 * 1024];
                while let Ok(count) = stream.read(&mut buffer).await {
                    if count == 0 || stream.write_all(&buffer[..count]).await.is_err() {
                        break;
                    }
                }
            });
        }
    });
    port
}

async fn round_trip(net: &WgNet, target: SocketAddr, payload: &[u8]) -> Result<(), String> {
    let mut stream = tokio::time::timeout(TIMEOUT, net.connect(target))
        .await
        .map_err(|_| format!("connect {target} timed out"))?
        .map_err(|error| format!("connect {target}: {error}"))?;
    stream.write_all(payload).await.map_err(|error| format!("write {target}: {error}"))?;
    let mut received = vec![0u8; payload.len()];
    tokio::time::timeout(TIMEOUT, stream.read_exact(&mut received))
        .await
        .map_err(|_| format!("echo from {target} timed out"))?
        .map_err(|error| format!("read {target}: {error}"))?;
    if received != payload {
        return Err(format!("echo from {target} was corrupted"));
    }
    Ok(())
}

#[tokio::test]
async fn ipv4_and_ipv6_reach_a_kernel_wireguard_peer() {
    if !enabled() {
        eprintln!("CMUX_WG_KERNEL_PEER is not set; skipping the kernel peer test");
        return;
    }
    let (server_private, server_public) = random_keypair();
    let (client_private, client_public) = random_keypair();
    let b64 = base64::engine::general_purpose::STANDARD;

    let key_dir = tempfile::tempdir().unwrap();
    let key_file = key_dir.path().join("server.key");
    std::fs::write(&key_file, b64.encode(server_private)).unwrap();
    let listen_port = {
        let probe = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        probe.local_addr().unwrap().port()
    };

    let server_v4: IpAddr = "10.77.0.1".parse().unwrap();
    let server_v6: IpAddr = "fd77::1".parse().unwrap();
    let client_v4: IpAddr = "10.77.0.2".parse().unwrap();
    let client_v6: IpAddr = "fd77::2".parse().unwrap();

    let _ = Command::new("sudo").args(["-n", "ip", "link", "del", INTERFACE]).output();
    let _peer = KernelPeer;
    sudo(&["ip", "link", "add", INTERFACE, "type", "wireguard"]);
    sudo(&[
        "wg",
        "set",
        INTERFACE,
        "listen-port",
        &listen_port.to_string(),
        "private-key",
        key_file.to_str().unwrap(),
        "peer",
        &b64.encode(client_public),
        "allowed-ips",
        &format!("{client_v4}/32,{client_v6}/128"),
    ]);
    sudo(&["ip", "address", "add", &format!("{server_v4}/24"), "dev", INTERFACE]);
    // CI images often disable IPv6 on new interfaces by sysctl default, and a
    // fresh IPv6 address is tentative for about a second during duplicate
    // address detection; both make a bind fail with EADDRNOTAVAIL.
    let _ = Command::new("sudo")
        .args(["-n", "sysctl", "-q", "-w", &format!("net.ipv6.conf.{INTERFACE}.disable_ipv6=0")])
        .output();
    let _ = Command::new("sudo")
        .args(["-n", "ip", "-6", "address", "add", &format!("{server_v6}/64"), "dev", INTERFACE, "nodad"])
        .output();
    sudo(&["ip", "link", "set", INTERFACE, "up", "mtu", "1200"]);
    let addresses = sudo(&["ip", "address", "show", INTERFACE]);
    eprintln!("{addresses}");
    // Some CI kernels boot with IPv6 disabled; the IPv4 leg is the one that
    // matters against Cloud routes, so IPv6 is exercised only when the
    // interface actually got its address.
    let ipv6_available = addresses.contains(&format!("inet6 {server_v6}"));

    let echo_port = echo_listener(SocketAddr::new(server_v4, 0)).await;
    eprintln!("echo listener bound on {server_v4}:{echo_port}");
    if ipv6_available {
        let echo_port_v6 = echo_listener(SocketAddr::new(server_v6, echo_port)).await;
        assert_eq!(echo_port, echo_port_v6);
    } else {
        eprintln!("IPv6 unavailable on {INTERFACE}; skipping the IPv6 legs");
    }

    let config = cmux_wg::WgConfig {
        private_key: Zeroizing::new(client_private),
        addresses: vec![
            InterfaceAddress { address: client_v4, prefix: 32 },
            InterfaceAddress { address: client_v6, prefix: 128 },
        ],
        mtu: 1200,
        peer_public_key: server_public,
        preshared_key: None,
        allowed_ips: vec![
            IpNetwork::new("10.77.0.0".parse::<IpAddr>().unwrap(), 24).unwrap(),
            IpNetwork::new("fd77::".parse::<IpAddr>().unwrap(), 64).unwrap(),
        ],
        endpoint: Some(Endpoint { host: "127.0.0.1".into(), port: listen_port }),
        persistent_keepalive: Some(5),
    };
    let net = WgNet::start_with_new_socket(config).await.unwrap();

    let payload: Vec<u8> = (0..4096).map(|index| (index % 251) as u8).collect();
    let mut results = Vec::new();
    results.push(round_trip(&net, SocketAddr::new(server_v4, echo_port), &payload).await);
    eprintln!("v4 small: {:?}", results.last());
    results.push(
        round_trip(&net, SocketAddr::new(server_v4, echo_port), &vec![0x5a; 64 * 1024]).await,
    );
    eprintln!("v4 large: {:?}", results.last());
    if ipv6_available {
        results.push(round_trip(&net, SocketAddr::new(server_v6, echo_port), &payload).await);
        eprintln!("v6 small: {:?}", results.last());
        results.push(
            round_trip(&net, SocketAddr::new(server_v6, echo_port), &vec![0x5a; 64 * 1024]).await,
        );
        eprintln!("v6 large: {:?}", results.last());
    }

    let failures: Vec<&String> = results.iter().filter_map(|r| r.as_ref().err()).collect();
    assert!(
        failures.is_empty(),
        "kernel peer round trips failed: {failures:?}\n{}",
        diagnostics()
    );
    net.shutdown().await;
}
