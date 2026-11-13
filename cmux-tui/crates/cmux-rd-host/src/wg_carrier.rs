//! Per-session WireGuard media upgrade for `cmux.rd/1`.
//!
//! The device-hub Noise link remains the admission and authorization boundary. This
//! module only adds an ephemeral WireGuard hop inside that already authenticated link:
//! public keys and fixed `/32` overlay addresses cross reliable rd-link control, while
//! private keys never leave this process. Setup/readiness failures are reported to
//! the caller so it can select the signed WebRTC fallback; media never uses bare
//! rd-link datagrams.

use cmux_rd_link::net::NetSender;
use cmux_wg::{InterfaceAddress, IpNetwork, Priority, WgConfig, WgNet};
use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::io;
use std::net::{IpAddr, Ipv4Addr, SocketAddr};
use std::os::fd::{AsRawFd, RawFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Duration;
use tokio::io::unix::AsyncFd;
use tokio::sync::mpsc as tokio_mpsc;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

pub const VERSION: u8 = 1;
pub const MEDIA_PORT: u16 = 4103;
pub const READY_TIMEOUT: Duration = Duration::from_millis(900);
const QUEUE: usize = 256;
const RD_LINK_MAX: usize = 1152 - cmux_rd_link::SEAL_OVERHEAD;
// IPv6+UDP inside WireGuard (48) plus a conservative WireGuard data header/tag (32).
const WG_OUTER_OVERHEAD: usize = 80;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Host,
    Viewer,
}
impl Role {
    fn local(self) -> Ipv4Addr {
        if matches!(self, Self::Host) {
            Ipv4Addr::new(10, 253, 0, 1)
        } else {
            Ipv4Addr::new(10, 253, 0, 2)
        }
    }
    fn peer(self) -> Ipv4Addr {
        if matches!(self, Self::Host) {
            Ipv4Addr::new(10, 253, 0, 2)
        } else {
            Ipv4Addr::new(10, 253, 0, 1)
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "t", rename_all = "snake_case")]
pub enum Control {
    Offer { version: u8, key: String, address: String, mtu: u16 },
    Answer { version: u8, key: String, address: String, mtu: u16 },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure {
    Unsupported,
    Timeout,
    Malformed,
    Closed,
    Overloaded,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Negotiating,
    Ready,
    Failed(Failure),
}

pub fn control_json(control: &Control) -> Option<Vec<u8>> {
    serde_json::to_vec(control).ok()
}
pub fn parse_control(record: &[u8]) -> Option<Control> {
    serde_json::from_slice(record).ok()
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn unhex32(text: &str) -> Option<[u8; 32]> {
    if text.len() != 64 {
        return None;
    }
    let mut out = [0; 32];
    for (i, byte) in out.iter_mut().enumerate() {
        *byte = u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(out)
}
fn mtu() -> u16 {
    u16::try_from(RD_LINK_MAX.saturating_sub(WG_OUTER_OVERHEAD).max(576)).unwrap_or(u16::MAX)
}
fn keypair() -> (Zeroizing<[u8; 32]>, [u8; 32]) {
    let mut bytes = [0u8; 32];
    if getrandom::fill(&mut bytes).is_err() {
        return (Zeroizing::new(bytes), [0; 32]);
    }
    let secret = StaticSecret::from(bytes);
    let public = PublicKey::from(&secret).to_bytes();
    (Zeroizing::new(secret.to_bytes()), public)
}

/// Negotiation over the existing authenticated rd-link control channel.
pub struct Negotiation {
    role: Role,
    private: Zeroizing<[u8; 32]>,
    public: [u8; 32],
    offered: bool,
    peer: Option<([u8; 32], Ipv4Addr, u16)>,
    answered: bool,
    started: bool,
    started_at: std::time::Instant,
    session: Option<WgSession>,
}
impl Negotiation {
    pub fn new(role: Role) -> Self {
        let (private, public) = keypair();
        Self {
            role,
            private,
            public,
            offered: false,
            peer: None,
            answered: false,
            started: false,
            started_at: std::time::Instant::now(),
            session: None,
        }
    }
    pub fn offer(&mut self) -> Option<Vec<u8>> {
        if self.offered {
            return None;
        }
        self.offered = true;
        control_json(&Control::Offer {
            version: VERSION,
            key: hex(&self.public),
            address: self.role.local().to_string(),
            mtu: mtu(),
        })
    }
    pub fn is_ready(&self) -> bool {
        self.session.as_ref().is_some_and(WgSession::is_ready)
    }
    /// Whether the peer has negotiated WG and packets should be offered to the
    /// overlay while its handshake completes. A failed session returns false,
    /// allowing the caller to continue on authenticated rd-link datagrams.
    pub fn active(&self) -> bool {
        self.peer.is_some() && !matches!(self.state(), State::Failed(_))
    }
    pub fn state(&self) -> State {
        if let Some(session) = &self.session {
            return session.state();
        }
        if self.started_at.elapsed() >= READY_TIMEOUT {
            State::Failed(Failure::Timeout)
        } else {
            State::Negotiating
        }
    }
    pub fn accept(&mut self, record: &[u8], sender: &NetSender) -> bool {
        let Some(control) = parse_control(record) else { return false };
        let (version, key, address, peer_mtu) = match control {
            Control::Offer { version, key, address, mtu } => {
                if self.peer.is_some() {
                    return true;
                }
                let Some(key) = unhex32(&key) else { return true };
                let Ok(address) = address.parse::<Ipv4Addr>() else { return true };
                (version, key, address, mtu)
            }
            Control::Answer { version, key, address, mtu } => {
                if self.peer.is_some() {
                    return true;
                }
                let Some(key) = unhex32(&key) else { return true };
                let Ok(address) = address.parse::<Ipv4Addr>() else {
                    return true;
                };
                (version, key, address, mtu)
            }
        };
        if version != VERSION || address != self.role.peer() || peer_mtu < 576 {
            return true;
        }
        self.peer = Some((key, address, peer_mtu));
        if let Some(bytes) = control_json(&Control::Answer {
            version: VERSION,
            key: hex(&self.public),
            address: self.role.local().to_string(),
            mtu: mtu().min(peer_mtu),
        }) {
            sender.send_control(bytes);
        }
        self.answered = true;
        true
    }
    pub fn start_if_negotiated(&mut self, sender: &NetSender) {
        if self.started || !self.answered {
            return;
        }
        let Some((peer_key, peer_addr, peer_mtu)) = self.peer else { return };
        self.started = true;
        let local = self.role.local();
        let config = WgConfig {
            private_key: self.private.clone(),
            addresses: vec![InterfaceAddress { address: IpAddr::V4(local), prefix: 32 }],
            mtu: mtu().min(peer_mtu),
            peer_public_key: peer_key,
            preshared_key: None,
            allowed_ips: vec![IpNetwork::V4("10.253.0.0/30".parse().expect("fixed WG network"))],
            endpoint: None,
            persistent_keepalive: Some(3),
            peer_addresses: vec![IpAddr::V4(peer_addr)],
            ultra: None,
        };
        self.session = WgSession::start(config, sender.clone(), local, peer_addr);
    }
    pub fn inject(&self, datagram: Vec<u8>) {
        if let Some(session) = &self.session {
            session.inject(datagram);
        }
    }
    pub fn send(&self, datagram: Vec<u8>) -> bool {
        self.session.as_ref().is_some_and(|session| session.send(datagram))
    }
    pub fn receive(&self, out: &mut Vec<Vec<u8>>) {
        if let Some(session) = &self.session {
            session.receive(out);
        }
    }
}

struct WakeFd(RawFd);
impl AsRawFd for WakeFd {
    fn as_raw_fd(&self) -> RawFd {
        self.0
    }
}
impl Drop for WakeFd {
    fn drop(&mut self) {
        // SAFETY: this descriptor is created by `pipe` in this module and owned here.
        unsafe {
            libc::close(self.0);
        }
    }
}

struct RdUnderlay {
    sender: NetSender,
    input: Receiver<Vec<u8>>,
    wake: AsyncFd<WakeFd>,
    pending: VecDeque<Vec<u8>>,
}
impl RdUnderlay {
    fn new(sender: NetSender, input: Receiver<Vec<u8>>, read: RawFd) -> io::Result<Self> {
        Ok(Self { sender, input, wake: AsyncFd::new(WakeFd(read))?, pending: VecDeque::new() })
    }
    fn refill(&mut self) {
        while let Ok(packet) = self.input.try_recv() {
            self.pending.push_back(packet);
        }
    }
}
impl cmux_wg::Underlay for RdUnderlay {
    fn send(&mut self, datagram: &[u8]) {
        self.sender.send_datagram(datagram.to_vec());
    }
    fn has_peer(&self) -> bool {
        true
    }
    fn poll_recv(
        &mut self,
        cx: &mut std::task::Context<'_>,
        buffer: &mut [u8],
    ) -> std::task::Poll<io::Result<cmux_wg::Received>> {
        self.refill();
        if let Some(packet) = self.pending.pop_front() {
            let len = packet.len().min(buffer.len());
            buffer[..len].copy_from_slice(&packet[..len]);
            return std::task::Poll::Ready(Ok(cmux_wg::Received {
                len,
                origin: cmux_wg::Origin { path: cmux_wg::PathId(0), addr: None },
            }));
        }
        let mut ready = match self.wake.poll_read_ready(cx) {
            std::task::Poll::Ready(Ok(guard)) => guard,
            std::task::Poll::Ready(Err(error)) => return std::task::Poll::Ready(Err(error)),
            std::task::Poll::Pending => return std::task::Poll::Pending,
        };
        let fd = self.wake.get_ref().as_raw_fd();
        match ready.try_io(|_| {
            let mut byte = [0u8; 1];
            // SAFETY: `fd` is the read end of our nonblocking wake pipe.
            let result = unsafe { libc::read(fd, byte.as_mut_ptr().cast(), 1) };
            if result == 1 {
                Ok(())
            } else if result < 0 {
                Err(io::Error::last_os_error())
            } else {
                Err(io::Error::new(io::ErrorKind::UnexpectedEof, "rd-link wake pipe closed"))
            }
        }) {
            Ok(Ok(())) => {
                self.refill();
                if self.pending.is_empty() {
                    std::task::Poll::Pending
                } else {
                    self.poll_recv(cx, buffer)
                }
            }
            Ok(Err(_)) | Err(_) => std::task::Poll::Pending,
        }
    }
}

enum Command {
    Send(Vec<u8>),
    Stop,
}
pub struct WgSession {
    commands: tokio_mpsc::Sender<Command>,
    inbound: SyncSender<Vec<u8>>,
    output: Receiver<Vec<u8>>,
    wake_write: RawFd,
    ready: Arc<AtomicBool>,
    failed: Arc<AtomicBool>,
    join: Option<JoinHandle<()>>,
}
impl WgSession {
    fn start(
        config: WgConfig,
        sender: NetSender,
        _local: Ipv4Addr,
        peer: Ipv4Addr,
    ) -> Option<Self> {
        let (input_tx, input_rx) = mpsc::sync_channel(QUEUE);
        let (output_tx, output_rx) = mpsc::sync_channel(QUEUE);
        let (command_tx, mut command_rx) = tokio_mpsc::channel(QUEUE);
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let (read, write) = pipe().ok()?;
        let ready = Arc::new(AtomicBool::new(false));
        let failed = Arc::new(AtomicBool::new(false));
        let ready_flag = Arc::clone(&ready);
        let failed_flag = Arc::clone(&failed);
        let join = std::thread::Builder::new().name("cmux-rd-wg".into()).spawn(move || {
            let runtime = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
                Ok(runtime) => runtime,
                Err(_) => { failed_flag.store(true, Ordering::Release); return; }
            };
            runtime.block_on(async move {
                let underlay = match RdUnderlay::new(sender, input_rx, read) {
                    Ok(underlay) => underlay,
                    Err(_) => { failed_flag.store(true, Ordering::Release); return; }
                };
                let net = match WgNet::start_with_underlay(config, underlay) {
                    Ok(net) => net,
                    Err(_) => { failed_flag.store(true, Ordering::Release); return; }
                };
                let mut socket = match net.bind_datagram(MEDIA_PORT).await {
                    Ok(socket) => socket,
                    Err(_) => { failed_flag.store(true, Ordering::Release); return; }
                };
                let _ = ready_tx.send(());
                if net.wait_for_handshake(READY_TIMEOUT).await.is_err() { failed_flag.store(true, Ordering::Release); return; }
                ready_flag.store(true, Ordering::Release);
                let target = SocketAddr::new(IpAddr::V4(peer), MEDIA_PORT);
                loop {
                    tokio::select! {
                        command = command_rx.recv() => match command {
                            Some(Command::Send(payload)) => { let _ = socket.send_to(&payload, target, Priority::Media).await; }
                            _ => break,
                        },
                        datagram = socket.recv_from() => {
                            let Some((payload, _source)) = datagram else { break };
                            let _ = output_tx.try_send(payload);
                        }
                    }
                }
                net.shutdown().await;
            });
        }).ok()?;
        if ready_rx.recv_timeout(Duration::from_millis(250)).is_err() {
            failed.store(true, Ordering::Release);
        }
        Some(Self {
            commands: command_tx,
            inbound: input_tx,
            output: output_rx,
            wake_write: write,
            ready,
            failed,
            join: Some(join),
        })
    }
    fn is_ready(&self) -> bool {
        self.ready.load(Ordering::Acquire) && !self.failed.load(Ordering::Acquire)
    }
    fn state(&self) -> State {
        if self.is_ready() {
            State::Ready
        } else if self.failed.load(Ordering::Acquire) {
            State::Failed(Failure::Timeout)
        } else {
            State::Negotiating
        }
    }
    fn send(&self, payload: Vec<u8>) -> bool {
        self.is_ready() && self.commands.try_send(Command::Send(payload)).is_ok()
    }
    fn inject(&self, payload: Vec<u8>) {
        if self.inbound.try_send(payload).is_ok() {
            let _ = write_wake(self.wake_write);
        }
    }
    fn receive(&self, out: &mut Vec<Vec<u8>>) {
        while let Ok(payload) = self.output.try_recv() {
            out.push(payload);
        }
    }
}
impl Drop for WgSession {
    fn drop(&mut self) {
        let _ = self.commands.try_send(Command::Stop);
        unsafe {
            libc::close(self.wake_write);
        }
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}
fn pipe() -> io::Result<(RawFd, RawFd)> {
    let mut fds = [0; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    for fd in fds {
        unsafe {
            libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
        }
    }
    Ok((fds[0], fds[1]))
}
fn write_wake(fd: RawFd) -> io::Result<()> {
    let byte = [1u8];
    let result = unsafe { libc::write(fd, byte.as_ptr().cast(), 1) };
    if result == 1 || (result < 0 && io::Error::last_os_error().kind() == io::ErrorKind::WouldBlock)
    {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_round_trip_exposes_public_key_only() {
        let mut negotiation = Negotiation::new(Role::Host);
        let offer = negotiation.offer().expect("first offer");
        let text = std::str::from_utf8(&offer).expect("json");
        assert!(text.contains("\"key\""));
        assert!(!text.contains("private"));
        assert!(parse_control(&offer).is_some());
        assert!(parse_control(br#"{"t":"offer","version":1}"#).is_none());
    }

    #[test]
    fn roles_use_fixed_point_to_point_addresses_and_bounded_mtu() {
        let mut host = Negotiation::new(Role::Host);
        let mut viewer = Negotiation::new(Role::Viewer);
        let host_offer = parse_control(&host.offer().expect("host offer")).expect("host offer");
        let viewer_offer =
            parse_control(&viewer.offer().expect("viewer offer")).expect("viewer offer");
        let Control::Offer { address: host_address, mtu: host_mtu, .. } = host_offer else {
            panic!()
        };
        let Control::Offer { address: viewer_address, mtu: viewer_mtu, .. } = viewer_offer else {
            panic!()
        };
        assert_eq!(host_address, "10.253.0.1");
        assert_eq!(viewer_address, "10.253.0.2");
        assert!(host_mtu >= 576 && host_mtu <= 1152);
        assert_eq!(host_mtu, viewer_mtu);
    }
}
