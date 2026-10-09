//! The host- and attachment-bound half of OSC 52 clipboard reads: the
//! timeout worker, the host's reply path, the daemon's control-response
//! hooks. The broker state machine, the attachment hooks and the
//! connection's replier are in
//! `shared/clipboard_read.rs` (cx-ko2e).

use super::super::shared::clipboard_read::*;
use super::*;

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
