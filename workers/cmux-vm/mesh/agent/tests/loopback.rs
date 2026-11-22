//! Two WireGuard peers on 127.0.0.1 UDP. The "VM" side is the same Tunnel
//! type with no endpoint: its smoltcp stack answers ICMP echo and runs a TCP
//! line echo on port 8080. The client side runs the real ping/tcp/probe code.

use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

use cmux_mesh_agent::config::Cidr;
use cmux_mesh_agent::ops::{self, PingOptions, ProbeOptions};
use cmux_mesh_agent::tunnel::{TcpStatus, Tunnel, TunnelError, TunnelParams};
use x25519_dalek::{PublicKey, StaticSecret};

const VM: Ipv4Addr = Ipv4Addr::new(10, 128, 16, 5);
const DEVICE: Ipv4Addr = Ipv4Addr::new(100, 64, 0, 1);
const ECHO_PORT: u16 = 8080;

fn secret() -> StaticSecret {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).unwrap();
    StaticSecret::from(bytes)
}

struct Vm {
    endpoint: SocketAddr,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Drop for Vm {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

/// Start the stand-in VM. It drops its first `drop_first` datagrams.
fn start_vm(vm_key: StaticSecret, device_public: [u8; 32], drop_first: usize) -> Vm {
    let mut tunnel = Tunnel::new(TunnelParams {
        private_key: vm_key,
        peer_public_key: device_public,
        endpoint: None,
        bind: "127.0.0.1:0".parse().unwrap(),
        address: Cidr { address: VM, prefix: 32 },
        allowed_ips: vec![Cidr { address: DEVICE, prefix: 32 }],
        mtu: 1280,
        persistent_keepalive: None,
    })
    .unwrap();
    tunnel.drop_next_datagrams(drop_first);
    let endpoint = tunnel.local_addr().unwrap();
    let stop = Arc::new(AtomicBool::new(false));
    let stop_flag = Arc::clone(&stop);
    let thread = std::thread::spawn(move || {
        let mut listeners = vec![tunnel.tcp_listen(ECHO_PORT).unwrap()];
        let mut buffers = std::collections::HashMap::new();
        while !stop_flag.load(Ordering::SeqCst) {
            tunnel.poll(Duration::from_millis(5)).unwrap();
            // Keep one socket listening; serve the rest as line echoes.
            let mut keep = Vec::new();
            for handle in listeners.drain(..) {
                match tunnel.tcp_status(handle) {
                    TcpStatus::Pending => keep.push(handle),
                    TcpStatus::Connected => {
                        let buffer: &mut Vec<u8> = buffers.entry(handle).or_default();
                        tunnel.tcp_recv(handle, buffer);
                        if let Some(end) = buffer.iter().position(|byte| *byte == b'\n') {
                            let line: Vec<u8> = buffer.drain(..=end).collect();
                            tunnel.tcp_send(handle, &line).unwrap();
                        }
                        if tunnel.tcp_eof(handle) {
                            tunnel.tcp_remove(handle);
                            buffers.remove(&handle);
                        } else {
                            keep.push(handle);
                        }
                    }
                    TcpStatus::Failed => {
                        tunnel.tcp_remove(handle);
                        buffers.remove(&handle);
                    }
                }
            }
            // Keep spare listening sockets so overlapping SYNs all find one.
            let pending = keep
                .iter()
                .filter(|handle| tunnel.tcp_status(**handle) == TcpStatus::Pending)
                .count();
            for _ in pending..4 {
                keep.push(tunnel.tcp_listen(ECHO_PORT).unwrap());
            }
            listeners = keep;
        }
    });
    Vm { endpoint, stop, thread: Some(thread) }
}

fn device_tunnel(device_key: StaticSecret, vm_public: [u8; 32], endpoint: SocketAddr) -> Tunnel {
    Tunnel::new(TunnelParams {
        private_key: device_key,
        peer_public_key: vm_public,
        endpoint: Some(endpoint),
        bind: "127.0.0.1:0".parse().unwrap(),
        address: Cidr { address: DEVICE, prefix: 32 },
        allowed_ips: vec!["10.128.16.0/20".parse().unwrap()],
        mtu: 1280,
        persistent_keepalive: Some(25),
    })
    .unwrap()
}

fn pair(drop_first: usize) -> (Vm, Tunnel) {
    let (device_key, vm_key) = (secret(), secret());
    let device_public = PublicKey::from(&device_key).to_bytes();
    let vm_public = PublicKey::from(&vm_key).to_bytes();
    let vm = start_vm(vm_key, device_public, drop_first);
    let tunnel = device_tunnel(device_key, vm_public, vm.endpoint);
    (vm, tunnel)
}

fn json_lines(out: &[u8]) -> Vec<serde_json::Value> {
    String::from_utf8(out.to_vec())
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect()
}

#[test]
fn ping_through_tunnel() {
    let (_vm, mut tunnel) = pair(0);
    let took = tunnel.handshake(Duration::from_secs(10)).unwrap();
    assert!(took < Duration::from_secs(5), "loopback handshake took {took:?}");
    let mut out = Vec::new();
    let options = PingOptions {
        count: 3,
        timeout: Duration::from_secs(2),
        interval: Duration::from_millis(20),
    };
    let received = ops::ping(&mut tunnel, VM, options, &mut out).unwrap();
    assert_eq!(received, 3);
    let lines = json_lines(&out);
    assert_eq!(lines.len(), 4, "3 replies and a summary: {lines:?}");
    for (index, line) in lines[..3].iter().enumerate() {
        assert_eq!(line["seq"], index as u64 + 1);
        assert!(line["rttMs"].as_f64().unwrap() >= 0.0);
    }
    assert_eq!(lines[3]["summary"], true);
    assert_eq!(lines[3]["received"], 3);
}

#[test]
fn ping_unanswered_address_times_out() {
    let (_vm, mut tunnel) = pair(0);
    tunnel.handshake(Duration::from_secs(10)).unwrap();
    let mut out = Vec::new();
    let options = PingOptions {
        count: 1,
        timeout: Duration::from_millis(300),
        interval: Duration::from_millis(10),
    };
    let silent = Ipv4Addr::new(10, 128, 16, 99);
    assert_eq!(ops::ping(&mut tunnel, silent, options, &mut out).unwrap(), 0);
    let lines = json_lines(&out);
    assert_eq!(lines[0]["timeout"], true);
}

#[test]
fn ping_outside_allowed_ips_is_refused() {
    let (_vm, mut tunnel) = pair(0);
    tunnel.handshake(Duration::from_secs(10)).unwrap();
    let options =
        PingOptions { count: 1, timeout: Duration::from_millis(100), interval: Duration::ZERO };
    let result = ops::ping(&mut tunnel, Ipv4Addr::new(8, 8, 8, 8), options, &mut Vec::new());
    assert!(matches!(result, Err(TunnelError::NotRouted(_))), "{result:?}");
}

#[test]
fn tcp_line_echo_through_tunnel() {
    let (_vm, mut tunnel) = pair(0);
    tunnel.handshake(Duration::from_secs(10)).unwrap();
    let mut out = Vec::new();
    let remote = SocketAddrV4::new(VM, ECHO_PORT);
    let ok = ops::tcp(&mut tunnel, remote, Some("hello mesh"), Duration::from_secs(3), &mut out)
        .unwrap();
    assert!(ok);
    let lines = json_lines(&out);
    assert_eq!(lines[0]["received"], "hello mesh");
    assert!(lines[0]["connectMs"].as_f64().is_some());
}

#[test]
fn tcp_closed_port_is_refused() {
    let (_vm, mut tunnel) = pair(0);
    tunnel.handshake(Duration::from_secs(10)).unwrap();
    let mut out = Vec::new();
    let remote = SocketAddrV4::new(VM, 9);
    assert!(!ops::tcp(&mut tunnel, remote, None, Duration::from_secs(3), &mut out).unwrap());
    assert_eq!(json_lines(&out)[0]["error"], "refused");
}

#[test]
fn probe_emits_one_timed_line_per_attempt() {
    let (_vm, mut tunnel) = pair(0);
    tunnel.handshake(Duration::from_secs(10)).unwrap();
    let options = ProbeOptions {
        interval: Duration::from_millis(50),
        duration: Duration::from_millis(500),
        attempt_timeout: Duration::from_millis(300),
    };
    let before = ops::wall_ms();
    let mut out = Vec::new();
    let (attempts, ok) =
        ops::probe(&mut tunnel, SocketAddrV4::new(VM, ECHO_PORT), options, &mut out).unwrap();
    let after = ops::wall_ms();
    assert!((8..=11).contains(&attempts), "attempts {attempts}");
    assert_eq!(ok, attempts);
    let lines = json_lines(&out);
    assert_eq!(lines.len() as u64, attempts + 1);
    for line in &lines[..lines.len() - 1] {
        let t = line["t"].as_u64().unwrap();
        assert!(before <= t && t <= after, "t {t} outside wall clock window");
        assert_eq!(line["ok"], true);
        assert!(line["ms"].as_f64().unwrap() < 300.0);
    }

    // A closed port: every attempt fails with a reset.
    let options = ProbeOptions { duration: Duration::from_millis(200), ..options };
    let mut out = Vec::new();
    let (attempts, ok) =
        ops::probe(&mut tunnel, SocketAddrV4::new(VM, 9), options, &mut out).unwrap();
    assert!(attempts >= 3);
    assert_eq!(ok, 0);
    assert!(json_lines(&out)[..attempts as usize].iter().all(|line| line["ok"] == false));
}

#[test]
fn first_handshake_is_retried_when_lost() {
    // The VM drops the first initiation; the handshake must still finish.
    let (_vm, mut tunnel) = pair(1);
    let took = tunnel.handshake(Duration::from_secs(25)).unwrap();
    assert!(took >= Duration::from_secs(4), "retry came too early: {took:?}");
    assert!(took < Duration::from_secs(12), "retry came too late: {took:?}");
    let options =
        PingOptions { count: 1, timeout: Duration::from_secs(2), interval: Duration::ZERO };
    assert_eq!(ops::ping(&mut tunnel, VM, options, &mut Vec::new()).unwrap(), 1);
}

#[test]
fn handshake_times_out_without_a_peer() {
    let (device_key, vm_key) = (secret(), secret());
    // Nothing listens on this socket's port once it is dropped.
    let unused = std::net::UdpSocket::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let mut tunnel = device_tunnel(device_key, PublicKey::from(&vm_key).to_bytes(), unused);
    let result = tunnel.handshake(Duration::from_millis(400));
    assert!(matches!(result, Err(TunnelError::HandshakeTimeout(_))), "{result:?}");
}
