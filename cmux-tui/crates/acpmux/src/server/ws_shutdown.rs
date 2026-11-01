//! A latched restart signal shared by the listener and its accepted connections. Unlike
//! the daemon's shutdown Notify, it cannot be missed by a handshake finishing late.

use futures_util::{Sink, SinkExt};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot, watch};
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::CloseFrame};

pub(crate) const DRAIN_BUDGET: Duration = Duration::from_secs(2);
const CLOSE_BUDGET: Duration = Duration::from_secs(1);

#[derive(Clone)]
pub struct WsShutdown {
    requested: watch::Sender<bool>,
    normal: watch::Sender<bool>,
    closing: watch::Sender<bool>,
    listeners: watch::Sender<usize>,
}

impl Default for WsShutdown {
    fn default() -> Self {
        Self {
            requested: watch::channel(false).0,
            normal: watch::channel(false).0,
            closing: watch::channel(false).0,
            listeners: watch::channel(0).0,
        }
    }
}

/// Held from listener startup until its accepted connections finish draining.
pub(super) struct Listener(watch::Sender<usize>);

impl Drop for Listener {
    fn drop(&mut self) {
        self.0.send_modify(|count| *count -= 1);
    }
}

impl WsShutdown {
    /// All listeners share the restart request, but each announces client closure only after
    /// closing its own admission. The guard includes that listener in the daemon's drain.
    pub(super) fn listener(&self) -> (Self, Listener) {
        self.listeners.send_modify(|count| *count += 1);
        let local = Self {
            requested: self.requested.clone(),
            normal: self.normal.clone(),
            closing: watch::channel(false).0,
            listeners: self.listeners.clone(),
        };
        (local, Listener(self.listeners.clone()))
    }

    pub(super) fn is_requested(&self) -> bool {
        *self.requested.borrow()
    }

    /// The daemon bounds this wait before it closes the embedded tailnet node.
    pub(crate) async fn drained(&self) {
        let mut listeners = self.listeners.subscribe();
        let _ = listeners.wait_for(|count| *count == 0).await;
    }

    /// Stop accepting and tell established clients to reconnect, before transport teardown.
    pub fn restart(&self) {
        self.requested.send_replace(true);
    }

    pub(crate) fn close_clients(&self) {
        self.closing.send_replace(true);
    }

    /// Stop admitting listeners and close their clients normally. Each listener
    /// converts the shared latch into its own local writer signal.
    pub(crate) fn normal_shutdown(&self) {
        self.normal.send_replace(true);
        self.close_clients();
    }

    pub(super) async fn normal(&self) {
        let mut state = self.normal.subscribe();
        let _ = state.wait_for(|stopping| *stopping).await;
    }

    pub(super) async fn closing(&self) {
        let mut state = self.closing.subscribe();
        let _ = state.wait_for(|stopping| *stopping).await;
    }

    /// The close code a connection closes with now: 1012 (service restart) only while the
    /// daemon restarts. Read when the close is sent, never taken from which signal a select saw
    /// first. A normal stop also closes clients (`closing`), and a connection can also end by
    /// itself as the daemon stops (its serve loop ends once its reader stopped), so the signal
    /// a select happened to see says nothing about why the daemon stops. The restart latch
    /// (`requested`) is set before any listener closes a client, and a normal stop never sets
    /// it (`daemon.rs`).
    pub(super) fn close_code_restart(&self) -> bool {
        self.is_requested()
    }

    pub(super) async fn requested(&self) {
        let mut state = self.requested.subscribe();
        let _ = state.wait_for(|stopping| *stopping).await;
    }
}

/// Stop admitting for good before clients see 1012. A process the daemon spawns meanwhile
/// (an agent, git) holds a copy of the listening socket from its clone until its exec, and the
/// kernel keeps completing handshakes until the last copy closes, so dropping ours alone could
/// let an immediate retry connect to this dying listener. Linux stops a listening socket on
/// shutdown, whatever copies remain; other systems refuse that, and only the drop applies.
pub(super) fn close_admission(listener: tokio::net::TcpListener) {
    #[cfg(target_os = "linux")]
    {
        use std::os::fd::AsRawFd;
        // SAFETY: shutdown on the listener's own descriptor, open for the whole call.
        unsafe { libc::shutdown(listener.as_raw_fd(), libc::SHUT_RD) };
    }
    drop(listener);
}

/// A connection task owns its reader/writer/watchers even when the listener's bounded drain
/// aborts it. Dropping JoinHandle alone would detach those children.
pub(super) struct Children(Vec<tokio::task::AbortHandle>);

impl Children {
    pub(super) fn new() -> Self {
        Self(Vec::new())
    }

    pub(super) fn track<T>(&mut self, task: &tokio::task::JoinHandle<T>) {
        self.0.push(task.abort_handle());
    }
}

impl Drop for Children {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}

/// Shutdown also interrupts a blocked text send. Sending Close flushes buffered frames, but
/// a client that stopped reading cannot hold daemon handoff beyond CLOSE_BUDGET. A large line
/// goes compressed once the client asked for that (`frame_compress.rs`).
pub(super) async fn write<S>(
    mut sink: S,
    mut outbound: mpsc::Receiver<String>,
    mut stopped: oneshot::Receiver<()>,
    shutdown: WsShutdown,
    wire: std::sync::Arc<crate::frame_compress::Wire>,
) where
    S: Sink<Frame> + Unpin,
{
    tokio::select! {
        biased;
        () = shutdown.normal() => {},
        () = shutdown.closing() => {},
        () = async {
            loop {
                let line = tokio::select! {
                    line = outbound.recv() => line,
                    _ = &mut stopped => None,
                };
                let Some(line) = line else { break };
                let Some(frame) = wire.frame(line).await else { break };
                if sink.send(frame).await.is_err() {
                    break;
                }
            }
        } => {},
    }
    close(&mut sink, shutdown.close_code_restart()).await;
}

pub(super) async fn close<S: Sink<Frame> + Unpin>(sink: &mut S, restarting: bool) {
    let frame = restarting
        .then(|| CloseFrame { code: CloseCode::Restart, reason: "service restarting".into() });
    let _ = tokio::time::timeout(CLOSE_BUDGET, sink.send(Frame::Close(frame))).await;
}

#[cfg(test)]
mod tests;
