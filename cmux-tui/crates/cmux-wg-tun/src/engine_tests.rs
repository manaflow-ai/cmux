//! The engine against a real boringtun peer on loopback UDP, with a datagram
//! socketpair standing in for the utun fd (same framing: a 4-byte address
//! family before each packet).

use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::time::{Duration, Instant as StdInstant};

use base64::Engine as _;
use boringtun::noise::{Tunn, TunnResult};
use x25519_dalek::{PublicKey, StaticSecret};

use super::{StartError, TunEngine};

const WAIT: Duration = Duration::from_secs(5);

fn secret() -> StaticSecret {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).expect("random key");
    StaticSecret::from(bytes)
}

fn b64(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// A minimal IPv4/UDP packet with a valid total length.
fn ipv4(source: Ipv4Addr, destination: Ipv4Addr, payload: &[u8]) -> Vec<u8> {
    let total = 20 + 8 + payload.len();
    let mut packet = vec![0u8; total];
    packet[0] = 0x45;
    packet[2..4].copy_from_slice(&(total as u16).to_be_bytes());
    packet[8] = 64;
    packet[9] = 17;
    packet[12..16].copy_from_slice(&source.octets());
    packet[16..20].copy_from_slice(&destination.octets());
    packet[24..26].copy_from_slice(&((8 + payload.len()) as u16).to_be_bytes());
    packet[28..].copy_from_slice(payload);
    packet
}

fn socketpair() -> (OwnedFd, OwnedFd) {
    let mut fds = [0 as RawFd; 2];
    // SAFETY: `fds` has room for both fds.
    assert_eq!(
        unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_DGRAM, 0, fds.as_mut_ptr()) },
        0
    );
    // SAFETY: fresh fds owned by nothing else.
    unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) }
}

/// One framed packet from the fake utun, or `None` after `wait`.
fn read_frame(fd: RawFd, wait: Duration) -> Option<Vec<u8>> {
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    // SAFETY: one live pollfd.
    if unsafe { libc::poll(&mut poll, 1, wait.as_millis() as libc::c_int) } <= 0 {
        return None;
    }
    let mut buffer = vec![0u8; 70_000];
    // SAFETY: live buffer of its own length.
    let read = unsafe { libc::read(fd, buffer.as_mut_ptr().cast(), buffer.len()) };
    (read > 0).then(|| buffer[..read as usize].to_vec())
}

fn write_frame(fd: RawFd, packet: &[u8]) {
    let mut frame = (libc::AF_INET as u32).to_be_bytes().to_vec();
    frame.extend_from_slice(packet);
    // SAFETY: live buffer of its own length.
    assert_eq!(
        unsafe { libc::write(fd, frame.as_ptr().cast(), frame.len()) },
        frame.len() as isize
    );
}

/// The Cloud gateway's side: a boringtun session on loopback UDP.
struct Gateway {
    tunn: Tunn,
    socket: UdpSocket,
    client: Option<SocketAddr>,
    scratch: Vec<u8>,
}

impl Gateway {
    /// Receives datagrams, answering handshakes, until one decrypts to a
    /// non-empty IP packet.
    fn receive_packet(&mut self) -> Vec<u8> {
        let deadline = StdInstant::now() + WAIT;
        let mut datagram = vec![0u8; 70_000];
        while StdInstant::now() < deadline {
            let Ok((length, from)) = self.socket.recv_from(&mut datagram) else { continue };
            self.client = Some(from);
            let mut input = datagram[..length].to_vec();
            loop {
                match self.tunn.decapsulate(Some(from.ip()), &input, &mut self.scratch) {
                    TunnResult::WriteToNetwork(reply) => {
                        self.socket.send_to(reply, from).expect("gateway send");
                        input.clear();
                        continue;
                    }
                    TunnResult::WriteToTunnelV4(packet, _) if !packet.is_empty() => {
                        return packet.to_vec();
                    }
                    _ => break,
                }
            }
        }
        panic!("gateway received no packet within {WAIT:?}");
    }

    fn send_packet(&mut self, packet: &[u8]) {
        let TunnResult::WriteToNetwork(datagram) = self.tunn.encapsulate(packet, &mut self.scratch)
        else {
            panic!("gateway has no session");
        };
        self.socket.send_to(datagram, self.client.expect("client address")).expect("gateway send");
    }
}

fn start() -> (TunEngine, OwnedFd, OwnedFd, Gateway) {
    let client = secret();
    let gateway = secret();
    let socket = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).expect("gateway socket");
    socket.set_read_timeout(Some(Duration::from_millis(200))).expect("timeout");
    let port = socket.local_addr().expect("address").port();
    let config = format!(
        "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = {}\nAllowedIPs = 10.0.0.0/24\nEndpoint = 127.0.0.1:{port}\n",
        b64(client.as_bytes()),
        b64(PublicKey::from(&gateway).as_bytes()),
    );
    let (engine_side, test_side) = socketpair();
    let engine = TunEngine::start(&config, engine_side.as_raw_fd()).expect("engine starts");
    let tunn = Tunn::new(gateway, PublicKey::from(&client), None, None, 1, None);
    (
        engine,
        engine_side,
        test_side,
        Gateway { tunn, socket, client: None, scratch: vec![0; 70_000] },
    )
}

#[test]
fn packets_cross_the_tunnel_both_ways() {
    let (engine, _engine_side, test_side, mut gateway) = start();
    let ping = ipv4(Ipv4Addr::new(10, 0, 0, 2), Ipv4Addr::new(10, 0, 0, 1), b"ping");
    write_frame(test_side.as_raw_fd(), &ping);
    assert_eq!(
        gateway.receive_packet(),
        ping,
        "the gateway decrypts exactly what utun handed the engine"
    );

    let pong = ipv4(Ipv4Addr::new(10, 0, 0, 1), Ipv4Addr::new(10, 0, 0, 2), b"pong");
    gateway.send_packet(&pong);
    let frame = read_frame(test_side.as_raw_fd(), WAIT).expect("the reply reaches utun");
    assert_eq!(&frame[..4], &(libc::AF_INET as u32).to_be_bytes(), "utun framing");
    assert_eq!(&frame[4..], &pong[..]);

    let stats = engine.stats();
    assert_eq!(stats.tx_bytes, ping.len() as u64);
    assert_eq!(stats.rx_bytes, pong.len() as u64);
    assert!(stats.last_handshake_unix > 0, "a completed handshake is reported");
    engine.stop();
}

#[test]
fn a_packet_from_outside_allowed_ips_is_dropped() {
    let (engine, _engine_side, test_side, mut gateway) = start();
    write_frame(
        test_side.as_raw_fd(),
        &ipv4(Ipv4Addr::new(10, 0, 0, 2), Ipv4Addr::new(10, 0, 0, 1), b"hi"),
    );
    gateway.receive_packet();

    let spoofed = ipv4(Ipv4Addr::new(192, 168, 1, 1), Ipv4Addr::new(10, 0, 0, 2), b"spoof");
    gateway.send_packet(&spoofed);
    let allowed = ipv4(Ipv4Addr::new(10, 0, 0, 1), Ipv4Addr::new(10, 0, 0, 2), b"ok");
    gateway.send_packet(&allowed);
    let frame = read_frame(test_side.as_raw_fd(), WAIT).expect("the allowed packet arrives");
    assert_eq!(&frame[4..], &allowed[..], "the spoofed packet never reached utun");
    assert!(read_frame(test_side.as_raw_fd(), Duration::from_millis(200)).is_none());
    assert_eq!(engine.stats().rx_bytes, allowed.len() as u64);
}

#[test]
fn stop_returns_promptly_on_an_idle_tunnel() {
    let (engine, _engine_side, _test_side, _gateway) = start();
    let began = StdInstant::now();
    engine.stop();
    assert!(
        began.elapsed() < Duration::from_secs(1),
        "stop wakes the thread instead of waiting for a tick"
    );
}

#[test]
fn a_config_without_an_endpoint_is_refused() {
    let config = format!(
        "[Interface]\nPrivateKey = {}\nAddress = 10.0.0.2/32\n\n[Peer]\nPublicKey = {}\nAllowedIPs = 10.0.0.0/24\n",
        b64(secret().as_bytes()),
        b64(PublicKey::from(&secret()).as_bytes()),
    );
    let (engine_side, _test_side) = socketpair();
    assert!(matches!(
        TunEngine::start(&config, engine_side.as_raw_fd()),
        Err(StartError::Endpoint(_))
    ));
}

#[test]
fn malformed_config_is_refused() {
    let (engine_side, _test_side) = socketpair();
    assert!(matches!(
        TunEngine::start("not a config", engine_side.as_raw_fd()),
        Err(StartError::Config(_))
    ));
}

/// The cause of `a_socketpair_is_not_mistaken_for_utun` failing in some runs: on macOS the
/// utun name query (level `SYSPROTO_CONTROL` 2, option `UTUN_OPT_IFNAME` 2) is also
/// `LOCAL_PEERPID` on a local socket, whose handler ignores the level. A socketpair answers it
/// with this process's pid as 4 bytes, and those bytes read as a "name" whenever they are
/// ASCII. nextest runs each test in its own process, so the pid, and the result, changed
/// from run to run.
#[cfg(target_os = "macos")]
#[test]
fn the_utun_name_query_answers_a_local_socket_with_its_peer_pid() {
    let (engine_side, _test_side) = socketpair();
    let mut reply = [0u8; 16];
    let mut length = libc::socklen_t::try_from(reply.len()).unwrap();
    // SAFETY: `reply` is writable for `length` bytes.
    let result = unsafe {
        libc::getsockopt(engine_side.as_raw_fd(), 2, 2, reply.as_mut_ptr().cast(), &mut length)
    };
    assert_eq!(
        result,
        0,
        "the name query fails on a local socket: {}",
        std::io::Error::last_os_error()
    );
    let pid = std::process::id().cast_signed().to_ne_bytes();
    assert_eq!(reply.get(..usize::try_from(length).unwrap()), Some(pid.as_slice()));
}

/// The decision itself, in every process: a local socket is never a kernel control socket,
/// whatever this process's pid is.
#[test]
fn a_socketpair_is_not_a_kernel_control_socket() {
    let (engine_side, _test_side) = socketpair();
    assert!(!crate::utun::is_kernel_control(engine_side.as_raw_fd()));
}

#[test]
fn a_socketpair_is_not_mistaken_for_utun() {
    let (engine_side, _test_side) = socketpair();
    assert!(crate::utun::interface_name(engine_side.as_raw_fd()).is_none());
}
