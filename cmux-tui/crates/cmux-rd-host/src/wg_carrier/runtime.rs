//! One owned WG runtime. Tokio channels wake the underlay; a socket wakes the
//! synchronous rd carrier after decoded media or readiness changes.
use super::*;
use cmux_rd_link::net::NetSender;
use cmux_wg::{Priority, WgConfig, WgNet};
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::os::fd::{AsRawFd, RawFd};
use std::os::unix::net::UnixDatagram;
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{mpsc, Arc};
use std::thread::JoinHandle;
use tokio::sync::{mpsc as channel, Notify};

struct Underlay {
    sender: NetSender,
    input: channel::Receiver<Vec<u8>>,
}
impl cmux_wg::Underlay for Underlay {
    fn send(&mut self, packet: &[u8]) {
        self.sender.send_datagram(packet.to_vec());
    }
    fn has_peer(&self) -> bool {
        true
    }
    fn poll_recv(
        &mut self,
        cx: &mut std::task::Context<'_>,
        buffer: &mut [u8],
    ) -> std::task::Poll<io::Result<cmux_wg::Received>> {
        use std::task::Poll;
        match self.input.poll_recv(cx) {
            Poll::Ready(Some(packet)) if packet.len() <= buffer.len() => {
                buffer[..packet.len()].copy_from_slice(&packet);
                Poll::Ready(Ok(cmux_wg::Received {
                    len: packet.len(),
                    origin: cmux_wg::Origin { path: cmux_wg::PathId(0), addr: None },
                }))
            }
            Poll::Ready(Some(_)) => {
                Poll::Ready(Err(io::Error::new(io::ErrorKind::InvalidData, "oversized WG packet")))
            }
            Poll::Ready(None) => {
                Poll::Ready(Err(io::Error::new(io::ErrorKind::BrokenPipe, "rd-link closed")))
            }
            Poll::Pending => Poll::Pending,
        }
    }
}

pub(super) struct Session {
    input: channel::Sender<Vec<u8>>,
    commands: channel::Sender<Vec<u8>>,
    output: mpsc::Receiver<Vec<u8>>,
    wake: UnixDatagram,
    state: Arc<AtomicU8>,
    stop: Arc<Notify>,
    join: Option<JoinHandle<()>>,
    max_datagram: usize,
}
impl Session {
    pub fn start(
        config: WgConfig,
        sender: NetSender,
        peer: std::net::Ipv4Addr,
    ) -> io::Result<Self> {
        let max_datagram = usize::from(config.mtu) - 48;
        let (input, input_rx) = channel::channel(QUEUE);
        let (commands, mut commands_rx) = channel::channel::<Vec<u8>>(QUEUE);
        let (output_tx, output) = mpsc::sync_channel(QUEUE);
        let (wake, notify) = UnixDatagram::pair()?;
        wake.set_nonblocking(true)?;
        notify.set_nonblocking(true)?;
        let state = Arc::new(AtomicU8::new(0));
        let flag = state.clone();
        let stop = Arc::new(Notify::new());
        let cancel = stop.clone();
        let join = std::thread::Builder::new().name("cmux-rd-wg".into()).spawn(move || {
            let run = || -> io::Result<()> {
                let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build()?;
                runtime.block_on(async {
                    let net = WgNet::start_with_underlay(config, Underlay { sender, input: input_rx }).map_err(io::Error::other)?;
                    let task = async {
                        let mut socket = net.bind_datagram(MEDIA_PORT).await.map_err(io::Error::other)?;
                        net.wait_for_handshake(READY_TIMEOUT).await.map_err(io::Error::other)?;
                        flag.store(1, Ordering::Release);
                        let _ = notify.send(&[1]);
                        let target = SocketAddr::new(IpAddr::V4(peer), MEDIA_PORT);
                        loop {
                            tokio::select! {
                                payload = commands_rx.recv() => {
                                    let Some(payload) = payload else { return Ok::<(), io::Error>(()) };
                                    socket.send_to(&payload, target, Priority::Media).await.map_err(io::Error::other)?;
                                }
                                received = socket.recv_from() => {
                                    let Some((payload, source)) = received else { return Err(io::Error::new(io::ErrorKind::BrokenPipe, "WG port closed")) };
                                    if source == target && output_tx.try_send(payload).is_ok() { let _ = notify.send(&[1]); }
                                }
                            }
                        }
                    };
                    let result = tokio::select! { result = task => result, _ = cancel.notified() => Ok(()) };
                    net.shutdown().await;
                    result
                })
            };
            let _ = run();
            flag.store(2, Ordering::Release);
            let _ = notify.send(&[1]);
        })?;
        Ok(Self { input, commands, output, wake, state, stop, join: Some(join), max_datagram })
    }
    pub fn fd(&self) -> RawFd {
        self.wake.as_raw_fd()
    }
    pub fn ready(&self) -> bool {
        self.state.load(Ordering::Acquire) == 1
    }
    pub fn failed(&self) -> bool {
        self.state.load(Ordering::Acquire) == 2
    }
    pub fn inject(&self, payload: Vec<u8>) {
        let _ = self.input.try_send(payload);
    }
    pub fn send(&self, payload: &[u8]) -> io::Result<()> {
        if !self.ready() {
            return Err(io::Error::new(io::ErrorKind::NotConnected, "WG media is not ready"));
        }
        if payload.len() > self.max_datagram {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "WG media exceeds negotiated MTU",
            ));
        }
        match self.commands.try_send(payload.to_vec()) {
            Ok(()) | Err(channel::error::TrySendError::Full(_)) => Ok(()), // unreliable media drops on overload
            Err(channel::error::TrySendError::Closed(_)) => {
                Err(io::Error::new(io::ErrorKind::BrokenPipe, "WG media closed"))
            }
        }
    }
    pub fn drain(&self, output: &mut Vec<Vec<u8>>) {
        while self.wake.recv(&mut [0; 64]).is_ok() {}
        output.extend(self.output.try_iter());
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.stop.notify_one();
        if let Some(join) = self.join.take() {
            let _ = join.join();
        }
    }
}
