//! The running link: its local socket (verified callers only) and its
//! overlay listener (paired peers only).

use std::future::Future;
use std::io;
use std::net::SocketAddr;
use std::os::fd::AsRawFd;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};

use cmux_link::dial::{CloudEventRequest, MAX_LINE_BYTES, ReloadRequest, parse_line};
use cmux_link::pairing::Pairings;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};

use super::cloud::{CloudResolver, ConnectInfoSource, apply_cloud_event};
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

    /// Re-read the file and apply it to the overlay; the new view takes
    /// effect only after the overlay accepted it.
    async fn reload<O: Overlay>(&self, overlay: &O) -> io::Result<()> {
        let fresh = Arc::new(Pairings::load(&self.path)?);
        overlay.sync_peers(&fresh).await?;
        *self.current.write().unwrap() = fresh;
        Ok(())
    }
}

/// Overlay streams accepted on the link port, with the peer's key and address.
pub(super) trait OverlayListener: Send + 'static {
    type Stream: AsyncRead + AsyncWrite + Unpin + Send + 'static;
    fn accept(
        &mut self,
    ) -> impl Future<Output = Option<(Self::Stream, [u8; 32], SocketAddr)>> + Send;
}

/// Serve the local socket. Each caller must be this user and
/// signed as cmux (`cmux_link::caller`); others are closed unanswered.
pub(super) async fn serve_local<O: Overlay, S: ConnectInfoSource>(
    listener: UnixListener,
    overlay: Arc<O>,
    peers: Arc<Peers>,
    resolver: Arc<CloudResolver<S>>,
) -> io::Result<()> {
    let mut failures = 0u32;
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => {
                failures = 0;
                stream
            }
            // Descriptor exhaustion persists across accepts; space the
            // retries instead of ending the link.
            Err(_) => {
                failures = failures.saturating_add(1);
                tokio::time::sleep(ACCEPT_RETRY * failures.min(50)).await;
                continue;
            }
        };
        tokio::spawn(serve_local_request(
            stream,
            overlay.clone(),
            peers.clone(),
            resolver.clone(),
        ));
    }
}

/// The first accept retry delay; later ones grow linearly up to 1 s.
const ACCEPT_RETRY: std::time::Duration = std::time::Duration::from_millis(20);

async fn serve_local_request<O: Overlay, S: ConnectInfoSource>(
    mut stream: UnixStream,
    overlay: Arc<O>,
    peers: Arc<Peers>,
    resolver: Arc<CloudResolver<S>>,
) {
    // The signature check calls into the OS; keep it off the async workers.
    let fd = stream.as_raw_fd();
    let verified = tokio::task::spawn_blocking(move || cmux_link::caller::verify_fd(fd)).await;
    if !matches!(verified, Ok(Ok(()))) {
        return;
    }
    let Ok(first) = read_line(&mut stream, MAX_LINE_BYTES).await else { return };
    if let Some(event) = parse_line::<CloudEventRequest>(&first) {
        let ok = apply_cloud_event(&event, &*overlay, &resolver).await;
        let reply = if ok { "{\"ok\":true}\n" } else { "{\"ok\":false}\n" };
        let _ = stream.write_all(reply.as_bytes()).await;
        return;
    }
    if parse_line::<ReloadRequest>(&first).is_some() {
        let ok = peers.reload(&*overlay).await.is_ok();
        let reply = if ok { "{\"ok\":true}\n" } else { "{\"ok\":false}\n" };
        let _ = stream.write_all(reply.as_bytes()).await;
        return;
    }
    let pairings = peers.snapshot();
    serve_dial_line(stream, &first, &*overlay, &pairings, &resolver).await;
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
