//! The real Native link reaches a VM through its own mesh's userspace gateway.
#![cfg(unix)]

mod native_cloud_gateway_support;

use std::net::{IpAddr, SocketAddr};
use std::time::Duration;

use cmux_link::overlay_addr::overlay_address;
use cmux_wg::testing::{loopback_pair, random_keypair};
use cmux_wg::{InterfaceAddress, IpNetwork, Priority, WgMesh, WgMeshConfig, WgNet, WgPeer};
use native_cloud_gateway_support::{HOST, INSTALL, Link, TaskGuard, bootstrap, broker};
use tokio::io::{AsyncBufReadExt as _, AsyncReadExt as _, AsyncWriteExt as _, BufReader};
use tokio::net::UdpSocket;
use zeroize::Zeroizing;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_cloud_gateway_real_cli_reaches_the_vm_without_backend_gateway_fields() {
    tokio::time::timeout(Duration::from_secs(25), async {
        let mut pair = loopback_pair().await.unwrap();
        pair.server.mtu = 1280;
        let key = *pair.client.private_key;
        let client_public = pair.server.peer_public_key;
        let gateway = pair.server_socket.local_addr().unwrap();
        let tunnel = WgNet::start(pair.server, pair.server_socket).await.unwrap();
        let mut vpc = tunnel.bind_datagram(4101).await.unwrap();
        let vm_socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let vm_udp = vm_socket.local_addr().unwrap();
        let (vm_key, vm_public) = random_keypair();
        let vm = WgMesh::start(WgMeshConfig {
            private_key: Zeroizing::new(vm_key),
            addresses: vec![InterfaceAddress { address: IpAddr::V6(overlay_address(HOST)), prefix: 128 }],
            mtu: 1200,
        }, vm_socket).unwrap();
        vm.add_peer(WgPeer {
            public_key: client_public,
            preshared_key: None,
            allowed_ips: vec![IpNetwork::new(IpAddr::V6(overlay_address(INSTALL)), 128).unwrap()],
            route: None,
            persistent_keepalive: None,
        }).await.unwrap();
        let mut listener = vm.listen(cmux_link::LINK_PORT).await.unwrap();
        let forward = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let client = SocketAddr::new(pair.client_v4, 4101);
        let _forward = TaskGuard(tokio::spawn(async move {
            let mut buffer = [0; 65535];
            loop {
                tokio::select! {
                    packet = vpc.recv_from() => {
                        let Some((packet, _)) = packet else { return };
                        forward.send_to(&packet, vm_udp).await.unwrap();
                    }
                    packet = forward.recv_from(&mut buffer) => {
                        let (length, from) = packet.unwrap();
                        assert_eq!(from, vm_udp);
                        vpc.send_to(&buffer[..length], client, Priority::Interactive).await.unwrap();
                    }
                }
            }
        }));
        let mut link = Link::start(bootstrap(key, pair.client.peer_public_key, gateway));
        let (channel, socket) = link.ready();
        let _broker = TaskGuard(tokio::spawn(broker(channel, vm_public)));
        let _vm = TaskGuard(tokio::spawn(async move {
            let (stream, key) = listener.accept().await.unwrap();
            assert_eq!(key, client_public);
            let mut stream = BufReader::new(stream);
            let mut hello = String::new();
            stream.read_line(&mut hello).await.unwrap();
            let hello: serde_json::Value = serde_json::from_str(&hello).unwrap();
            assert_eq!(hello["service"], "ssh");
            assert_eq!(hello["link_token"], "one-native-dial");
            let mut bytes = [0; 4];
            stream.read_exact(&mut bytes).await.unwrap();
            assert_eq!(&bytes, b"ping");
            stream.get_mut().write_all(b"pong").await.unwrap();
            stream.get_mut().shutdown().await.unwrap();
        }));
        let mut dial = tokio::process::Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        dial.args(["link", "dial", "--host", HOST, "--service", "ssh", "--socket", &socket])
            .env_clear().env("HOME", link.home.path())
            .stdin(std::process::Stdio::piped()).stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped()).kill_on_drop(true);
        let mut child = dial.spawn().unwrap();
        let mut input = child.stdin.take().unwrap();
        input.write_all(b"ping").await.unwrap();
        drop(input);
        let answer = child.wait_with_output().await.unwrap();
        assert!(answer.status.success(), "{}", String::from_utf8_lossy(&answer.stderr));
        assert_eq!(answer.stdout, b"pong");
        let status: serde_json::Value = serde_json::from_slice(&answer.stderr).unwrap();
        assert_eq!(status["path_state"], "tunnel");
        drop(link);
        tunnel.shutdown().await;
    }).await.expect("Native CLI gateway dial timed out");
}
