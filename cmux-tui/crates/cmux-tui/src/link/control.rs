//! The running link: its local socket (verified callers only) and its
//! overlay listener (paired peers only).

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use cmux_link::dial::{MAX_LINE_BYTES, ReloadRequest, parse_line};
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

use super::dial::{Overlay, serve_dial_line};
use super::inbound::serve_inbound;
use super::lines::read_line;

/// The paired peers, re-read from their file on `link.reload`.
pub(super) struct Peers {
    path: PathBuf,
    current: RwLock<Arc<Pairings>>,
}

impl Peers {
    pub(super) fn load(path: PathBuf) -> io::Result<Self> {
        let current = RwLock::new(Arc::new(Pairings::load(&path)?));
        Ok(Self { path, current })
    }

    pub(super) fn snapshot(&self) -> Arc<Pairings> {
        self.current.read().unwrap().clone()
    }

    fn reload(&self) -> io::Result<Arc<Pairings>> {
        let fresh = Arc::new(Pairings::load(&self.path)?);
        *self.current.write().unwrap() = fresh.clone();
        Ok(fresh)
    }
}

/// Overlay streams accepted on the link port, with the peer's key and address.
pub(super) trait OverlayListener: Send + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn accept(
        &mut self,
    ) -> impl Future<Output = Option<(Self::Stream, [u8; 32], SocketAddr)>> + Send;
}

/// Serve the local socket until it fails. Each caller must be this user and
/// signed as cmux (`cmux_link::caller`); others are closed unanswered.
pub(super) async fn serve_local<O: Overlay>(
    listener: UnixListener,
    overlay: Arc<O>,
    peers: Arc<Peers>,
) -> io::Result<()> {
    loop {
        let (stream, _) = listener.accept().await?;
        if cmux_link::caller::verify_fd(stream.as_raw_fd()).is_err() {
            continue;
        }
        tokio::spawn(serve_local_request(stream, overlay.clone(), peers.clone()));
    }
}

async fn serve_local_request<O: Overlay>(mut stream: UnixStream, overlay: Arc<O>, peers: Arc<Peers>) {
    let Ok(first) = read_line(&mut stream, MAX_LINE_BYTES).await else { return };
    if parse_line::<ReloadRequest>(&first).is_some() {
        let ok = match peers.reload() {
            Ok(pairings) => overlay.sync_peers(&pairings).await.is_ok(),
            Err(_) => false,
        };
        let reply = if ok { "{\"ok\":true}\n" } else { "{\"ok\":false}\n" };
        let _ = stream.write_all(reply.as_bytes()).await;
        return;
    }
    let pairings = peers.snapshot();
    serve_dial_line(stream, &first, &*overlay, &pairings).await;
}

/// Serve overlay streams from paired peers. Without a session socket this
/// link only dials, and inbound streams are closed.
pub(super) async fn serve_overlay<L: OverlayListener>(
    mut listener: L,
    peers: Arc<Peers>,
    session_socket: Option<PathBuf>,
) {
    while let Some((stream, key, address)) = listener.accept().await {
        let Some(session_socket) = session_socket.clone() else { continue };
        let pairings = peers.snapshot();
        tokio::spawn(async move {
            let _ = serve_inbound(stream, key, address, &pairings, &session_socket).await;
        });
    }
}
