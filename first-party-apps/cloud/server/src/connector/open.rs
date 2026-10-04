//! The server's side of frame links: the `cmux.terminal.connector.open`
//! request after a user connect, its answer, and the frame lines (only the
//! serve loop thread calls these).

use super::frames::CONNECTOR_OPEN;
use crate::api::ControlPlane;
use crate::api::host::HostError;
use crate::link::CONNECTOR_KIND;
use crate::ops::Server;
use cmux_terminal_iface::OpenToken;
use serde_json::{Value, json};

impl<C: ControlPlane> Server<C> {
    /// A connect of `machine` came up and carries the host's open token
    /// (a user run of an `openOps` op): ask the host for a frame link. The
    /// host consumes the token and checks the declaration, the grant and
    /// the kind; without a token nothing is asked (the carrier socket of
    /// the connect answer still works).
    pub(crate) fn request_frame_link(&mut self, machine: &str, open_token: &OpenToken) {
        if open_token.check().is_err() || !self.attach().frames.wants_open(machine) {
            return;
        }
        let params =
            json!({ "kind": CONNECTOR_KIND, "target": machine, "open_token": open_token.as_str() });
        let id = self.host_requests().request_each(CONNECTOR_OPEN, params);
        self.attach_mut().frames.opening(id, machine);
    }

    /// The host's answer to `connector.open` request `id`. A refusal is
    /// logged (the connect stays up on its carrier socket); a channel
    /// starts its pump on the machine's current carrier.
    pub(crate) fn frame_link_answer(&mut self, id: u64, answer: Result<Value, HostError>) {
        let attach = self.attach_mut();
        let Some(machine) = attach.frames.take_opening(id) else { return };
        match answer {
            Ok(value) => {
                attach.supervisor.pump();
                let carrier = attach.supervisor.carrier(&machine).cloned();
                let carrier = carrier.as_ref().map(|c| (c.socket.as_path(), c.generation));
                attach.frames.opened(&machine, &value, carrier);
            }
            Err(error) => eprintln!(
                "cmux-cloud: the host opened no frame link for {machine}: {}: {}",
                error.code, error.message
            ),
        }
    }

    /// Lines of `channel` were dropped (they overflowed during a relay
    /// call): the channel ends, retryable.
    pub(crate) fn frame_overflow(&mut self, channel: &str) {
        let lost = cmux_terminal_iface::Lost::new("frame lines overflowed", true);
        self.attach_mut().frames.close(channel, lost);
    }

    /// One `data`/`credit`/`end` line from the host.
    pub(crate) fn frame_line(&mut self, line: &Value) {
        self.attach_mut().frames.receive(line);
    }

    /// Frame lines for the host: every link's bytes moved as far as the
    /// credit allows. The serve loop takes them after the link events, so
    /// a link that went down has ended its frame links already.
    pub fn take_frame_lines(&mut self) -> Vec<Value> {
        self.attach_mut().frames.take_lines()
    }
}
