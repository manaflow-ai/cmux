//! The socket line decode path for cmux-tui/fuzz:
//! the parse steps `handle_connection_frame` runs before any dispatch.

use super::super::Request;
use super::super::api_revision_wire::NegotiatedRevision;
use super::{auth_token, pairing_request};

pub(crate) fn socket_line(data: &[u8]) {
    let Some((&revision, rest)) = data.split_first() else { return };
    let Ok(message) = std::str::from_utf8(rest) else { return };
    let _ = auth_token(message);
    let _ = pairing_request(message);
    let negotiated = NegotiatedRevision::default();
    // An old client's line is upgraded before any parse; a refused revision
    // leaves the line as sent, as on a real connection.
    let _ = negotiated.declare(u32::from(revision));
    let upgraded = negotiated.upgrade_request(message);
    let message: &str = &upgraded;
    if crate::resource_router::parse_resource_line(message).is_some() {
        return;
    }
    let _ = serde_json::from_str::<Request>(message);
}
