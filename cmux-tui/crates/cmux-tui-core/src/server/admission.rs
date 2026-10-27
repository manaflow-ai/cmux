//! Which lines of a connection reach dispatch. A local connection admits
//! every line; the remote entry admits only what its gate allows.

use serde_json::Value;

use super::Mux;

pub(super) trait LineAdmission {
    /// Called once, right after the connection's client is registered.
    /// False closes the connection before its first frame.
    fn registered(&self, _mux: &std::sync::Arc<Mux>, _client: u64) -> bool {
        true
    }

    /// `None` dispatches `line`; `Some(response)` answers it instead, and
    /// nothing parses or dispatches the line.
    fn refusal(&self, line: &str) -> Option<Value>;

    /// Whether a frame may pass at all: frames skip `refusal`, so only an
    /// admission that would admit every line admits them. Without this a
    /// frame is a bad message, whatever the client's record holds.
    fn admits_frames(&self) -> bool {
        false
    }
}

/// The local socket: every line goes to dispatch.
pub(super) struct LocalAdmission;

impl LineAdmission for LocalAdmission {
    fn refusal(&self, _line: &str) -> Option<Value> {
        None
    }

    fn admits_frames(&self) -> bool {
        true
    }
}
