//! [`CloudHostLink`]: the `cmux.terminal.connector/1` link handle of one
//! channel. The server stays the only writer of link state: the handle
//! shares a small record with it, asks for a close there, and gets the
//! channel's one `end` from the server's drain of link events.

use crate::link::Carrier;
use cmux_terminal_iface::{
    BackendError, DEFAULT_WINDOW_BYTES, DataPlane, End, FrameBody, HostLink, Lost,
};
use std::sync::{Arc, Mutex, MutexGuard};

/// What a link handle and the server share for one channel.
#[derive(Debug, Default)]
pub(crate) struct LinkShared {
    /// Frames for the session host, not taken yet (the one `end`).
    frames: Vec<FrameBody>,
    /// The `end` was given: nothing more is accepted or queued.
    ended: bool,
    /// The handle asked for a close that the server did not apply yet.
    close: bool,
}

pub(crate) type LinkHandle = Arc<Mutex<LinkShared>>;

fn lock(handle: &LinkHandle) -> MutexGuard<'_, LinkShared> {
    // A panic while holding the lock leaves plain data; keep serving.
    handle.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// Takes a close the handle asked for (`true` once per ask).
pub(crate) fn take_close(handle: &LinkHandle) -> bool {
    std::mem::take(&mut lock(handle).close)
}

/// Queues the channel's one `end`.
pub(crate) fn end(handle: &LinkHandle, lost: Lost) {
    let mut shared = lock(handle);
    if !std::mem::replace(&mut shared.ended, true) {
        shared.close = false;
        shared.frames.push(FrameBody::End(End::Lost(lost)));
    }
}

/// One link to a Cloud machine's session host. Its bytes move on the
/// carrier socket ([`DataPlane::Socket`]): the app host has no frame stream
/// for this server, so the daemon dials the link's local socket.
pub(crate) struct CloudHostLink {
    carrier: Carrier,
    shared: LinkHandle,
}

impl CloudHostLink {
    pub(crate) fn new(carrier: Carrier, shared: LinkHandle) -> Self {
        Self { carrier, shared }
    }

    /// Asks the server to end the link (applied at its next drain).
    fn ask_close(&self) -> Result<(), BackendError> {
        let mut shared = lock(&self.shared);
        if shared.ended || shared.close {
            return Err(BackendError::not_open());
        }
        shared.close = true;
        Ok(())
    }
}

impl HostLink for CloudHostLink {
    /// `cloud-vm/<machine>#<generation>`: a new id after every reconnect.
    fn channel(&self) -> &str {
        &self.carrier.id
    }

    fn data_plane(&self) -> DataPlane {
        DataPlane::Socket { path: self.carrier.socket.clone() }
    }

    fn window_bytes(&self) -> u32 {
        DEFAULT_WINDOW_BYTES
    }

    fn push(&mut self, frame: FrameBody) -> Result<(), BackendError> {
        if lock(&self.shared).ended {
            return Err(BackendError::not_open());
        }
        match frame {
            // The session host ended the channel: end the link.
            FrameBody::End(_) => self.ask_close(),
            // DataPlane::Socket: the bytes move on the carrier socket.
            FrameBody::Data { .. } | FrameBody::Credit { .. } => Err(BackendError::invalid(
                "this link's bytes move on its carrier socket (DataPlane::Socket)",
            )),
        }
    }

    fn take_frames(&mut self) -> Vec<FrameBody> {
        std::mem::take(&mut lock(&self.shared).frames)
    }

    fn close(&mut self) -> Result<(), BackendError> {
        self.ask_close()
    }
}
