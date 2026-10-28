//! The server side of `terminal-input-while-creating-v1` (cx-wb5.78, `mux::creating_input`):
//! creations register their caller-minted terminal id when the daemon receives them and end it
//! after their commit; `send {terminal_id}` writes to the terminal or queues for a creating one.
//! With `creating-input-streams-v1`, a create sent as a REQUEST frame on stream S binds S to its
//! terminal id when the daemon takes it, so the new pane's keys go as INPUT frames on S, with no
//! JSON and no reply (p05-ipc-153, server/pending_streams.rs).

use super::*;
use crate::mux::creating_input::{InputOverflow, TerminalInputTarget, UnclaimedNotice};
// The server's test build already brings the trait into scope through `super::*`.
#[cfg(not(test))]
use base64::Engine as _;

/// `terminal-input-while-creating-v1`.
pub(super) const TERMINAL_INPUT_WHILE_CREATING_CAPABILITY: &str =
    "terminal-input-while-creating-v1";

impl Command {
    /// The caller-minted host terminal id of a pane or tab creation, normalized to lowercase hex.
    pub(super) fn created_terminal_id(&self) -> Option<String> {
        let id = match self {
            Self::NewTab(params) => params.terminal_id.as_deref(),
            Self::NewPane { terminal_id, .. } => terminal_id.as_deref(),
            Self::Split(params) => params.terminal_id(),
            Self::NewPaneRight(params) => params.terminal_id(),
            _ => None,
        }?;
        crate::terminal_host::TerminalId::from_hex(id).map(|id| id.to_hex())
    }
}

/// `send {terminal_id}`: write to the live terminal, or queue for a creating one. The connection's own
/// event queue gets a `terminal-input-unclaimed` notice if queued bytes are given back.
#[allow(clippy::too_many_arguments)] // the `send` command's fields, plus the connection
pub(super) fn send_to_terminal(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    terminal_id: &str,
    text: Option<String>,
    bytes: Option<String>,
    paste: bool,
) -> anyhow::Result<Value> {
    let terminal_id = crate::terminal_host::TerminalId::from_hex(terminal_id)
        .ok_or_else(|| anyhow::anyhow!("bad request: terminal_id must be 32 hex digits"))?
        .to_hex();
    let mut payload = text.unwrap_or_default().into_bytes();
    if let Some(b64) = bytes {
        payload.extend(base64::engine::general_purpose::STANDARD.decode(b64)?);
    }
    if payload.is_empty() {
        // Nothing to write, but the id must still name a live or creating terminal.
        anyhow::ensure!(
            mux.knows_terminal_input_target(&terminal_id),
            "unknown terminal {terminal_id}"
        );
        return Ok(json!({}));
    }
    let notice = unclaimed_notice(writer.clone());
    let target = mux.write_terminal_input(&terminal_id, client, &payload, paste, 0, notice)?;
    Ok(if target == TerminalInputTarget::Queued { json!({"queued": true}) } else { json!({}) })
}

/// Gives queued bytes back to the connection `writer` sends on, as one
/// `terminal-input-unclaimed` control event.
fn unclaimed_notice(writer: MessageWriter) -> UnclaimedNotice {
    Arc::new(move |terminal_id: &str, bytes: &[u8], reason: &str| {
        send_unclaimed(&writer, terminal_id, bytes, reason);
    })
}

fn send_unclaimed(writer: &MessageWriter, terminal_id: &str, bytes: &[u8], reason: &str) {
    let _ = writer.send_control(&json!({
        "event": "terminal-input-unclaimed",
        "terminal_id": terminal_id,
        "bytes_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
        "reason": reason,
    }));
}

/// `creating-input-streams-v1` (p05-ipc-153): a terminal create sent as a
/// REQUEST frame on stream S != 0 opens S as its new terminal's input
/// stream. A framed IPC grant (capabilities.rs).
pub(super) const CREATING_INPUT_STREAMS_CAPABILITY: &str =
    capabilities::IpcCapability::CreatingInputStreams.name();

/// The terminal creates whose REQUEST frame on stream S != 0 opens S as the
/// new terminal's input stream (server/pending_streams.rs): the creates
/// [`Command::created_terminal_id`] reads a minted id from.
pub(super) const CREATING_STREAM_OPENERS: [&str; 4] =
    ["split", "new-tab", "new-pane", "new-pane-right"];

/// Why a creating stream gives its INPUT back
/// (`terminal-input-unclaimed.reason`, spec/events.md).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum CreatingInputRefusal {
    /// The stream, or its terminal's creating queue, held
    /// [`crate::mux::creating_input::CREATING_INPUT_LIMIT`] bytes.
    Overflow,
    /// The create failed or never bound the stream.
    Failed,
    /// The terminal ended.
    TerminalEnded,
    /// The terminal refused the write.
    WriteFailed,
}

impl CreatingInputRefusal {
    fn reason(self) -> &'static str {
        match self {
            Self::Overflow => "overflow",
            Self::Failed => "failed",
            Self::TerminalEnded => "terminal-ended",
            Self::WriteFailed => "write-failed",
        }
    }
}

impl PendingSurfaceRequest {
    /// A create the daemon took binds the stream its REQUEST frame opened to
    /// the terminal id it minted, before the host starts: INPUT on the
    /// stream joins the id's creating queue from now on, in arrival order,
    /// and waits for no reply. Chrome binds an associated endpoint the same
    /// way: usable at once, its messages queued for the implementation until
    /// it binds (mojo/public/cpp/bindings/lib/multiplex_router.cc,
    /// `ProcessIncomingMessage`).
    pub(super) fn bind_creating_stream(&self) {
        if let Some(stream) = self.frame_call.as_ref().and_then(|call| call.opens()) {
            stream.bind_creating();
        }
    }
}

/// Writes one INPUT frame of a creating stream: queued while its terminal is
/// creating, written once it is live, as `send {terminal_id}` does, with the
/// frame's `flow` (0: none) and no JSON and no reply. A queue the create
/// gives back reaches the connection as `terminal-input-unclaimed`. Runs on
/// the stream's sequence.
pub(super) fn write_stream_input(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    terminal_id: &str,
    bytes: &[u8],
    flow: u64,
) -> Result<(), CreatingInputRefusal> {
    let notice = unclaimed_notice(writer.connection_writer());
    match mux.write_terminal_input(terminal_id, client, bytes, false, flow, notice) {
        Ok(_) => Ok(()),
        Err(error) if error.is::<InputOverflow>() => Err(CreatingInputRefusal::Overflow),
        Err(_) if !mux.knows_terminal_input_target(terminal_id) => {
            Err(CreatingInputRefusal::TerminalEnded)
        }
        Err(_) => Err(CreatingInputRefusal::WriteFailed),
    }
}

/// Gives a creating stream's `bytes` back to the connection `writer` sends
/// on, as one `terminal-input-unclaimed` naming `terminal_id`.
pub(super) fn give_back_creating_input(
    writer: &MessageWriter,
    terminal_id: &str,
    bytes: &[u8],
    refusal: CreatingInputRefusal,
) {
    send_unclaimed(writer, terminal_id, bytes, refusal.reason());
}

#[cfg(all(test, unix))]
#[path = "creating_input_tests.rs"]
mod tests;
