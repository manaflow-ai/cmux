//! The engine thread: utun fd <-> boringtun <-> one UDP socket.

use std::fmt;
use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, ToSocketAddrs, UdpSocket};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicI64, AtomicU64, Ordering};
use std::thread::JoinHandle;
use std::time::{SystemTime, UNIX_EPOCH};

use boringtun::noise::{Tunn, TunnResult};
use cmux_wg::{TimerSchedule, WgConfig};
use tokio::time::Instant;
use x25519_dalek::{PublicKey, StaticSecret};

use crate::utun;

/// Largest datagram or utun frame handled: an IP packet of the maximal
/// size plus WireGuard's 32-byte overhead and the 4-byte utun header.
const BUFFER: usize = 65_535 + 64;
/// Packets drained from one fd per wakeup before the other gets a turn.
const BURST: usize = 64;

/// Why the engine did not start.
#[derive(Debug)]
pub enum StartError {
    /// The wg-quick text did not parse.
    Config(String),
    /// The config has no `Endpoint`, or it did not resolve.
    Endpoint(String),
    /// A socket, pipe or thread could not be made.
    Io(io::Error),
}

impl fmt::Display for StartError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Config(reason) => write!(formatter, "invalid WireGuard config: {reason}"),
            Self::Endpoint(reason) => write!(formatter, "WireGuard endpoint: {reason}"),
            Self::Io(error) => write!(formatter, "{error}"),
        }
    }
}

impl std::error::Error for StartError {}

impl From<io::Error> for StartError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// Counters the provider reports to the app.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    /// Bytes of IP packets sent into the tunnel.
    pub tx_bytes: u64,
    /// Bytes of IP packets received from the tunnel and written to utun.
    pub rx_bytes: u64,
    /// Unix seconds of the last completed handshake, `0` when none yet.
    pub last_handshake_unix: i64,
}

#[derive(Default)]
struct Shared {
    stop: AtomicBool,
    network_changed: AtomicBool,
    tx_bytes: AtomicU64,
    rx_bytes: AtomicU64,
    last_handshake_unix: AtomicI64,
}

/// A running tunnel. Dropping it stops the thread.
pub struct TunEngine {
    shared: Arc<Shared>,
    wake: OwnedFd,
    thread: Option<JoinHandle<()>>,
}

impl TunEngine {
    /// Starts the engine on `tun_fd` (borrowed: the caller keeps owning it)
    /// with a completed wg-quick config, and sends the first handshake.
    pub fn start(config: &str, tun_fd: RawFd) -> Result<Self, StartError> {
        let config = WgConfig::parse_wg_quick(config)
            .map_err(|error| StartError::Config(error.to_string()))?;
        let endpoint = resolve(&config)?;
        let socket = bind(endpoint)?;
        utun::set_nonblocking(tun_fd)?;
        let (wake_read, wake_write) = pipe()?;
        let shared = Arc::new(Shared::default());
        let tunn = Tunn::new(
            StaticSecret::from(*config.private_key),
            PublicKey::from(config.peer_public_key),
            config.preshared_key.as_deref().copied(),
            config.persistent_keepalive,
            0,
            None,
        );
        let keepalive = config.persistent_keepalive.is_some_and(|seconds| seconds > 0);
        let mut driver = Driver {
            schedule: TimerSchedule::new(Instant::now(), keepalive),
            tunn,
            config,
            endpoint,
            socket,
            tun_fd,
            wake: wake_read,
            shared: Arc::clone(&shared),
            frame: vec![0; BUFFER],
            datagram: vec![0; BUFFER],
            scratch: vec![0; BUFFER],
        };
        driver.initiate_handshake();
        let thread =
            std::thread::Builder::new().name("cmux-wg-tun".into()).spawn(move || driver.run())?;
        Ok(Self { shared, wake: wake_write, thread: Some(thread) })
    }

    /// The default route changed: rebind the UDP socket and re-handshake.
    pub fn network_changed(&self) {
        self.shared.network_changed.store(true, Ordering::Release);
        self.wake();
    }

    /// The engine's counters.
    pub fn stats(&self) -> Stats {
        Stats {
            tx_bytes: self.shared.tx_bytes.load(Ordering::Relaxed),
            rx_bytes: self.shared.rx_bytes.load(Ordering::Relaxed),
            last_handshake_unix: self.shared.last_handshake_unix.load(Ordering::Relaxed),
        }
    }

    /// Stops the thread and waits for it.
    pub fn stop(mut self) {
        self.halt();
    }

    fn halt(&mut self) {
        self.shared.stop.store(true, Ordering::Release);
        self.wake();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }

    fn wake(&self) {
        let byte = [1u8];
        // SAFETY: writes one byte from a live buffer to our own pipe; a full
        // pipe (EAGAIN) already means the thread will wake.
        unsafe { libc::write(self.wake.as_raw_fd(), byte.as_ptr().cast(), 1) };
    }
}

impl Drop for TunEngine {
    fn drop(&mut self) {
        self.halt();
    }
}

struct Driver {
    tunn: Tunn,
    schedule: TimerSchedule,
    config: WgConfig,
    endpoint: SocketAddr,
    socket: UdpSocket,
    tun_fd: RawFd,
    wake: OwnedFd,
    shared: Arc<Shared>,
    frame: Vec<u8>,
    datagram: Vec<u8>,
    scratch: Vec<u8>,
}

impl Driver {
    fn run(&mut self) {
        loop {
            if self.shared.stop.load(Ordering::Acquire) {
                return;
            }
            if self.shared.network_changed.swap(false, Ordering::AcqRel) {
                self.rebind();
            }
            let mut fds = [
                libc::pollfd { fd: self.tun_fd, events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.socket.as_raw_fd(), events: libc::POLLIN, revents: 0 },
                libc::pollfd { fd: self.wake.as_raw_fd(), events: libc::POLLIN, revents: 0 },
            ];
            let timeout = self.poll_timeout();
            // SAFETY: `fds` is a live array of three pollfd entries.
            let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
            if ready < 0 && io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                return;
            }
            if fds[2].revents != 0 {
                self.drain_wake();
            }
            if fds[0].revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                // NetworkExtension closed the utun fd: the tunnel is gone.
                return;
            }
            if fds[0].revents & libc::POLLIN != 0 {
                self.drain_tun();
            }
            if fds[1].revents & libc::POLLIN != 0 {
                self.drain_socket();
            }
            let now = Instant::now();
            if self.schedule.due(now) {
                if let TunnResult::WriteToNetwork(packet) =
                    self.tunn.update_timers(&mut self.scratch)
                    && send_on(&self.socket, packet)
                {
                    self.rebind();
                }
                self.schedule.on_tick(now);
                self.publish_handshake();
            }
        }
    }

    /// Milliseconds to the next timer tick, or `-1` to wait for an event.
    fn poll_timeout(&self) -> libc::c_int {
        match self.schedule.next_tick() {
            None => -1,
            Some(tick) => {
                let wait = tick.saturating_duration_since(Instant::now());
                // Round up so a wake never lands just before the tick is due.
                wait.as_millis().saturating_add(1).min(i32::MAX as u128) as libc::c_int
            }
        }
    }

    fn drain_wake(&self) {
        let mut sink = [0u8; 64];
        // SAFETY: reads into a live buffer from our own nonblocking pipe.
        while unsafe { libc::read(self.wake.as_raw_fd(), sink.as_mut_ptr().cast(), sink.len()) } > 0
        {
        }
    }

    fn drain_tun(&mut self) {
        let mut rebind = false;
        for _ in 0..BURST {
            let range = match utun::read_packet(self.tun_fd, &mut self.frame) {
                Ok(Some(range)) => range,
                Ok(None) | Err(_) => break,
            };
            let Some(packet) = self.frame.get(range).filter(|packet| !packet.is_empty()) else {
                continue;
            };
            self.shared.tx_bytes.fetch_add(packet.len() as u64, Ordering::Relaxed);
            if let TunnResult::WriteToNetwork(datagram) =
                self.tunn.encapsulate(packet, &mut self.scratch)
            {
                rebind |= send_on(&self.socket, datagram);
            }
            self.schedule.on_activity(Instant::now());
        }
        if rebind {
            self.rebind();
        }
    }

    fn drain_socket(&mut self) {
        let mut rebind = false;
        for _ in 0..BURST {
            let Ok(length) = self.socket.recv(&mut self.datagram) else { break };
            let now = Instant::now();
            let mut source = Some(self.endpoint.ip());
            let Some(mut input) = self.datagram.get(..length) else { break };
            loop {
                match self.tunn.decapsulate(source, input, &mut self.scratch) {
                    TunnResult::WriteToNetwork(reply) => {
                        rebind |= send_on(&self.socket, reply);
                        self.schedule.on_activity(now);
                        // Flush the packets queued behind the handshake.
                        input = &[];
                        source = None;
                        continue;
                    }
                    TunnResult::WriteToTunnelV4(packet, from) => {
                        self.schedule.on_activity(now);
                        deliver(&self.config, self.tun_fd, &self.shared, packet, IpAddr::V4(from));
                    }
                    TunnResult::WriteToTunnelV6(packet, from) => {
                        self.schedule.on_activity(now);
                        deliver(&self.config, self.tun_fd, &self.shared, packet, IpAddr::V6(from));
                    }
                    TunnResult::Done | TunnResult::Err(_) => {}
                }
                break;
            }
        }
        self.publish_handshake();
        if rebind {
            self.rebind();
        }
    }

    fn initiate_handshake(&mut self) {
        if let TunnResult::WriteToNetwork(packet) =
            self.tunn.format_handshake_initiation(&mut self.scratch, false)
        {
            // A failure here is retried by boringtun's handshake timer.
            let _ = send_on(&self.socket, packet);
            self.schedule.on_activity(Instant::now());
        }
    }

    fn rebind(&mut self) {
        if let Ok(endpoint) = resolve(&self.config) {
            self.endpoint = endpoint;
        }
        if let Ok(socket) = bind(self.endpoint) {
            self.socket = socket;
        }
        self.initiate_handshake();
    }

    fn publish_handshake(&self) {
        let (since, ..) = self.tunn.stats();
        if let Some(since) = since {
            let now = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|time| time.as_secs())
                .unwrap_or(0);
            let at = now.saturating_sub(since.as_secs()) as i64;
            self.shared.last_handshake_unix.store(at, Ordering::Relaxed);
        }
    }
}

/// Sends one datagram; `true` when the socket must be rebound because the
/// interface under it went away (Wi-Fi to Ethernet, sleep). A full queue
/// drops the datagram, as a router would.
fn send_on(socket: &UdpSocket, datagram: &[u8]) -> bool {
    match socket.send(datagram) {
        Ok(_) => false,
        Err(error) => {
            !matches!(error.raw_os_error(), Some(libc::ENOBUFS | libc::EAGAIN | libc::EINTR))
        }
    }
}

/// Writes a decrypted packet to utun when its source is one the peer may
/// send from (WireGuard's crypto-key routing); drops it otherwise.
fn deliver(config: &WgConfig, tun_fd: RawFd, shared: &Shared, packet: &[u8], from: IpAddr) {
    if packet.is_empty() || !config.routes_contain(from) {
        return;
    }
    if utun::write_packet(tun_fd, packet).is_ok() {
        shared.rx_bytes.fetch_add(packet.len() as u64, Ordering::Relaxed);
    }
}

/// The endpoint's address, IPv4 first: the Cloud gateway is reached over v4.
fn resolve(config: &WgConfig) -> Result<SocketAddr, StartError> {
    let endpoint =
        config.endpoint.as_ref().ok_or_else(|| StartError::Endpoint("missing Endpoint".into()))?;
    let addresses: Vec<SocketAddr> = (endpoint.host.as_str(), endpoint.port)
        .to_socket_addrs()
        .map_err(|error| StartError::Endpoint(format!("{}: {error}", endpoint.host)))?
        .collect();
    addresses
        .iter()
        .find(|address| address.is_ipv4())
        .or_else(|| addresses.first())
        .copied()
        .ok_or_else(|| StartError::Endpoint(format!("{} has no address", endpoint.host)))
}

fn bind(endpoint: SocketAddr) -> Result<UdpSocket, StartError> {
    let local: SocketAddr = match endpoint {
        SocketAddr::V4(_) => (Ipv4Addr::UNSPECIFIED, 0).into(),
        SocketAddr::V6(_) => (Ipv6Addr::UNSPECIFIED, 0).into(),
    };
    let socket = UdpSocket::bind(local)?;
    socket.connect(endpoint)?;
    socket.set_nonblocking(true)?;
    Ok(socket)
}

fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0 as RawFd; 2];
    // SAFETY: `fds` has room for the two fds pipe(2) writes.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe(2) returned two fresh fds that nothing else owns.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    utun::set_nonblocking(read.as_raw_fd())?;
    utun::set_nonblocking(write.as_raw_fd())?;
    Ok((read, write))
}

#[cfg(test)]
#[path = "engine_tests.rs"]
mod tests;
