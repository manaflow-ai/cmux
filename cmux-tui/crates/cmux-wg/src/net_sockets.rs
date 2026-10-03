//! The driver's TCP socket setup: ports, connects, listeners and the
//! stream bridges (an `impl` block of [`super::Driver`]).

use super::*;

/// The overlay port of `cmux link` connections (transport.md 12a).
pub(crate) const LINK_PORT: u16 = 4100;
/// A link connection survives a silent peer this long (a phone in the
/// background, a laptop lid closed briefly); its streams then resume
/// without a reconnect.
pub(crate) const LINK_TCP_TIMEOUT: Duration = Duration::from_secs(10 * 60);

/// The TCP user timeout for a connection to or on `port`.
pub(crate) fn user_timeout(port: u16) -> Duration {
    if port == LINK_PORT { LINK_TCP_TIMEOUT } else { TCP_TIMEOUT }
}

impl Driver {
    pub(super) fn allocate_port(&mut self) -> u16 {
        for _ in 0..EPHEMERAL_PORT_COUNT {
            let port = self.next_port;
            self.next_port = if self.next_port >= u16::MAX - 1 {
                FIRST_EPHEMERAL_PORT
            } else {
                self.next_port + 1
            };
            let in_use = self.conns.iter().any(|conn| {
                self.sockets
                    .get::<tcp::Socket>(conn.handle)
                    .local_endpoint()
                    .is_some_and(|endpoint| endpoint.port == port)
            });
            if !in_use {
                return port;
            }
        }
        self.next_port
    }

    /// A socket that gives up after `timeout` without an ACK from the peer.
    pub(super) fn new_socket(timeout: Duration) -> tcp::Socket<'static> {
        let mut socket = tcp::Socket::new(
            tcp::SocketBuffer::new(vec![0u8; SOCKET_BUFFER_BYTES]),
            tcp::SocketBuffer::new(vec![0u8; SOCKET_BUFFER_BYTES]),
        );
        // Keystrokes are latency-bound; the OS dial path disables Nagle too.
        socket.set_nagle_enabled(false);
        socket.set_congestion_control(tcp::CongestionControl::Cubic);
        socket.set_timeout(Some(smoltcp::time::Duration::from_micros(
            u64::try_from(timeout.as_micros()).unwrap_or(u64::MAX),
        )));
        socket.set_keep_alive(Some(smoltcp::time::Duration::from_micros(
            u64::try_from(TCP_KEEP_ALIVE.as_micros()).unwrap_or(u64::MAX),
        )));
        socket
    }

    pub(super) fn begin_connect(
        &mut self,
        remote: SocketAddr,
        reply: oneshot::Sender<Result<WgStream, WgError>>,
    ) {
        if reply.is_closed() {
            return;
        }
        let Some(local_ip) = self.config.local_address_for(remote.ip()) else {
            let _ = reply.send(Err(WgError::NoTunnelAddress(remote.ip())));
            return;
        };
        let port = self.allocate_port();
        let local = SocketAddr::new(local_ip, port);
        let mut socket = Self::new_socket(user_timeout(remote.port()));
        let result = socket.connect(
            self.iface.context(),
            IpEndpoint::new(ip_address(remote.ip()), remote.port()),
            IpListenEndpoint::from(IpEndpoint::new(ip_address(local.ip()), local.port())),
        );
        if let Err(error) = result {
            let _ = reply.send(Err(WgError::Stack(format!("{error}"))));
            return;
        }
        let handle = self.sockets.add(socket);
        let (conn, stream) = self.bridge(handle, local, remote);
        self.conns.push(Conn { pending_stream: Some((Handoff::Connect(reply), stream)), ..conn });
    }

    pub(super) fn begin_listen(&mut self, port: u16) -> Result<WgListener, WgError> {
        if self.listeners.iter().any(|listener| listener.port == port) {
            return Err(WgError::ListenerBusy(port));
        }
        let mut handles = Vec::with_capacity(LISTEN_SPARES);
        for _ in 0..LISTEN_SPARES {
            handles.push(self.listening_socket(port)?);
        }
        let (accept_tx, accept_rx) = mpsc::channel(LISTENER_BACKLOG);
        self.listeners.push(Listener { port, handles, accept: accept_tx });
        Ok(WgListener { port, incoming: accept_rx })
    }

    pub(super) fn listening_socket(&mut self, port: u16) -> Result<SocketHandle, WgError> {
        let mut socket = Self::new_socket(user_timeout(port));
        socket
            .listen(IpListenEndpoint::from(port))
            .map_err(|error| WgError::Stack(format!("{error}")))?;
        Ok(self.sockets.add(socket))
    }

    /// Build the channel pair for a socket: the driver-side [`Conn`] and the
    /// owner-side [`WgStream`].
    pub(super) fn bridge(
        &self,
        handle: SocketHandle,
        local: SocketAddr,
        remote: SocketAddr,
    ) -> (Conn, WgStream) {
        let (inbound_tx, inbound_rx) = mpsc::channel(STREAM_CHANNEL_DEPTH);
        let (outbound_tx, outbound_rx) = mpsc::channel(STREAM_CHANNEL_DEPTH);
        let stream = WgStream {
            local,
            remote,
            inbound: inbound_rx,
            leftover: Bytes::new(),
            outbound: PollSender::new(outbound_tx),
            wake: Arc::clone(&self.wake),
            shutdown_sent: false,
        };
        let conn = Conn {
            handle,
            remote,
            pending_stream: None,
            inbound: Some(inbound_tx),
            outbound: outbound_rx,
            pending_write: None,
            outbound_closed: false,
        };
        (conn, stream)
    }
}
