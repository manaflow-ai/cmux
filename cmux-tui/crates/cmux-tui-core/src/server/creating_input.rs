//! The server side of `terminal-input-while-creating-v1` (cx-wb5.78, `mux::creating_input`):
//! creations register their caller-minted terminal id when the daemon receives them and end it
//! after their commit; `send {terminal_id}` writes to the terminal or queues for a creating one.

use super::*;
use crate::mux::creating_input::{TerminalInputTarget, UnclaimedNotice};
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
            Self::NewTab { terminal_id, .. } | Self::NewPane { terminal_id, .. } => {
                terminal_id.as_deref()
            }
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
    write_input(mux, client, writer, &terminal_id, &payload, paste)
}

/// Write `payload` to host terminal `terminal_id` (canonical hex), or queue it while the terminal
/// is created or starts (a kept tab's start, #17587). Queued bytes given back reach this
/// connection's event queue as one `terminal-input-unclaimed` notice. The reply says `queued`.
pub(super) fn write_input(
    mux: &Arc<Mux>,
    client: u64,
    writer: &MessageWriter,
    terminal_id: &str,
    payload: &[u8],
    paste: bool,
) -> anyhow::Result<Value> {
    let notice_writer = writer.clone();
    let notice: UnclaimedNotice = Arc::new(move |terminal_id: &str, bytes: &[u8], reason: &str| {
        let _ = notice_writer.send_control(&json!({
            "event": "terminal-input-unclaimed",
            "terminal_id": terminal_id,
            "bytes_base64": base64::engine::general_purpose::STANDARD.encode(bytes),
            "reason": reason,
        }));
    });
    let target = mux.write_terminal_input(terminal_id, client, payload, paste, notice)?;
    Ok(if target == TerminalInputTarget::Queued { json!({"queued": true}) } else { json!({}) })
}
