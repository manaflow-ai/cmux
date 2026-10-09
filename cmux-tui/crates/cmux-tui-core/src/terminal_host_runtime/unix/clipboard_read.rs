//! The host- and attachment-bound half of OSC 52 clipboard reads: the
//! timeout worker, the host's reply path, the daemon's control-response
//! hooks and the connection's replier. The broker state machine is in
//! `shared/clipboard_read.rs` (cx-ko2e).

use super::super::shared::clipboard_read::*;
use super::*;
#[cfg(test)]
use ghostty_vt::ClipboardReadRequest;

impl ClipboardReads {
    /// Starts the timeout worker for `host` (whose broker this is). It
    /// blocks until the earliest deadline or a state change and exits when
    /// the terminal drains.
    pub(super) fn start_timer(&self, host: &Arc<HostShared>) -> std::io::Result<()> {
        let shared = self.shared.clone();
        let host = Arc::downgrade(host);
        thread::Builder::new()
            .name("terminal-host-clipboard".into())
            .spawn(move || shared.run_timer(&host))
            .map(drop)
    }
}

impl ClipboardReadsShared {
    fn run_timer(&self, host: &Weak<HostShared>) {
        let mut state = lock(&self.state);
        loop {
            if state.ended {
                return;
            }
            let Some(deadline) = state.open.as_ref().map(|open| open.deadline) else {
                state = self.clock.wait(&self.changed, state);
                continue;
            };
            let now = self.clock.now();
            if now < deadline {
                state = self.clock.wait_timeout(&self.changed, state, deadline - now);
                continue;
            }
            let Some(open) = state.open.take() else { continue };
            let Some(host) = host.upgrade() else { return };
            // Cancel before the slot can reopen, so the owner sees it ahead
            // of any later request.
            send_cancel(&state.owners, &open, &host.broadcast_lock);
            drop(state);
            let _ = host
                .parser_commands
                .send(ParserCommand::ClipboardReadComplete { token: open.token, text: None });
            drop(host);
            state = lock(&self.state);
        }
    }
}

impl HostShared {
    /// Refuses the open read of a connection that left (see `remove_client`).
    pub(super) fn release_clipboard_owner(&self, client: u64) {
        if let Some(token) = self.clipboard.unregister_owner(&self.term, client) {
            let _ = self
                .parser_commands
                .send(ParserCommand::ClipboardReadComplete { token, text: None });
        }
    }

    /// One `ClipboardReadReply` from `client`. False closes the connection:
    /// it lacks the right or sent a malformed envelope or reply. Stale or
    /// unknown tokens, and tokens another connection was asked about, are
    /// ignored.
    pub(super) fn apply_clipboard_read_reply(
        &self,
        client: u64,
        granted_rights: CapabilityRights,
        frame: &Frame,
        protocol_version: u16,
    ) -> bool {
        if !granted_rights.contains(CapabilityRights::CLIPBOARD_READ)
            || !clipboard_envelope_valid(frame, protocol_version)
        {
            return false;
        }
        let Ok((token, text)) = decode_clipboard_read_reply(&frame.payload) else {
            return false;
        };
        if self.clipboard.take_open(client, token) {
            let _ = self.parser_commands.send(ParserCommand::ClipboardReadComplete { token, text });
        }
        true
    }
}

impl HostAttachment {
    #[cfg(test)]
    pub(crate) fn clipboard_reads_negotiated(&self) -> bool {
        self.control_responses.clipboard_reads_negotiated()
    }

    #[cfg(test)]
    pub(crate) fn negotiate_clipboard_reads_for_test(&self) {
        self.control_responses.negotiate_clipboard_reads_for_test();
    }

    #[cfg(test)]
    pub(crate) fn pending_clipboard_read(&self) -> Option<ClipboardReadRequest> {
        self.control_responses.pending_clipboard_read()
    }

    /// Answers the pending read `token`: `Some(text)` grants, `None`
    /// refuses. False, with nothing sent, when `token` is not pending.
    /// Tests only: production answers go through the broker's replier.
    #[cfg(test)]
    pub(crate) fn complete_clipboard_read(
        &self,
        token: u64,
        text: Option<&[u8]>,
    ) -> std::io::Result<bool> {
        self.clipboard_replier().complete(token, text)
    }

    /// This connection's answering side, for the daemon broker.
    pub(crate) fn clipboard_replier(&self) -> ClipboardReplier {
        ClipboardReplier {
            writer: Arc::downgrade(&self.writer),
            responses: Arc::downgrade(&self.control_responses),
            protocol_version: self.protocol_version,
        }
    }
}

/// Answers one connection's reads without the surface's runtime lock, so
/// the broker may refuse a read on the frame reader thread. It holds the
/// connection weakly: once the attachment is gone it sends nothing, and it
/// never keeps the host socket open.
#[derive(Clone)]
pub(crate) struct ClipboardReplier {
    writer: Weak<Mutex<UnixStream>>,
    responses: Weak<ControlResponses>,
    protocol_version: u16,
}

impl ClipboardReplier {
    /// Answers the pending read `token`: `Some(text)` grants, `None`
    /// refuses. False, with nothing sent, when `token` is not pending
    /// (answered, replaced, or the connection is gone).
    pub(crate) fn complete(&self, token: u64, text: Option<&[u8]>) -> std::io::Result<bool> {
        let (Some(writer), Some(responses)) = (self.writer.upgrade(), self.responses.upgrade())
        else {
            return Ok(false);
        };
        if !responses.take_clipboard_read(token) {
            return Ok(false);
        }
        let reply = encode_clipboard_read_reply(token, text);
        send_host_frame(&writer, self.protocol_version, MessageKind::ClipboardReadReply, &reply)?;
        Ok(true)
    }
}
