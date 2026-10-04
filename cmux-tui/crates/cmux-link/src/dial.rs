//! `link.dial` on the link's local socket, and the service hello on an
//! overlay stream.
//!
//! A local caller (the app's sidecar, the CLI) connects to the link's Unix
//! socket and writes one [`DialRequest`] line. The link answers one
//! [`DialReply`] line. On `ok` the same connection carries the stream's bytes
//! from then on (no descriptor passing, so the contract also fits a named
//! pipe). On the overlay the dialing link writes one [`ServiceHello`] line
//! before the caller's bytes; the receiving link reads it, checks the
//! service, and hands the rest to the daemon's remote entry.

use serde::{Deserialize, Serialize};

use crate::stamp::valid_id;

/// The longest request, reply or hello line.
pub const MAX_LINE_BYTES: usize = 1024;

/// The services a link stream can reach. Slice 1 has only the session
/// daemon's remote entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Service {
    Daemon,
}

/// How the stream reaches the peer. Lane 10's UI shows "same network only"
/// while [`DialReply::relay_available`] is false.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathState {
    /// A direct UDP path to the peer carries the stream.
    Direct,
    /// The relay carries the stream (reserved; slice 1 never reports it).
    Relay,
    /// No path reaches the peer.
    Unreachable,
}

/// Slice 1 ships no relay.
pub const RELAY_AVAILABLE: bool = false;

/// `{"op":"link.dial","host":"<install>","service":"daemon"}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DialRequest {
    pub op: DialOp,
    pub host: String,
    pub service: Service,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum DialOp {
    #[serde(rename = "link.dial")]
    Dial,
}

/// Why a dial failed (`error_code`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DialError {
    /// The request line is not a valid `link.dial`.
    BadRequest,
    /// No pairing record names this host.
    UnknownHost,
    /// The peer did not answer on any path.
    Unreachable,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DialReply {
    pub ok: bool,
    pub path_state: PathState,
    pub relay_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<DialError>,
}

impl DialReply {
    pub fn connected(path_state: PathState) -> Self {
        Self { ok: true, path_state, relay_available: RELAY_AVAILABLE, error_code: None }
    }

    pub fn failed(error: DialError) -> Self {
        Self {
            ok: false,
            path_state: PathState::Unreachable,
            relay_available: RELAY_AVAILABLE,
            error_code: Some(error),
        }
    }
}

/// `{"op":"link.reload"}`: re-read the pairing file (sent by `cmux link
/// peer add|remove` to a running link). The reply is `{"ok":true|false}`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReloadRequest {
    pub op: ReloadOp,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReloadOp {
    #[serde(rename = "link.reload")]
    Reload,
}

/// `{"service":"daemon"}`, the first line on an overlay link stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceHello {
    pub service: Service,
}

/// Parse a request line; `host` must be a valid install id.
pub fn parse_request(line: &str) -> Result<DialRequest, DialError> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    if line.len() > MAX_LINE_BYTES {
        return Err(DialError::BadRequest);
    }
    let request: DialRequest = serde_json::from_str(line).map_err(|_| DialError::BadRequest)?;
    if !valid_id(&request.host) {
        return Err(DialError::BadRequest);
    }
    Ok(request)
}

/// One JSON line (with the trailing newline) for any contract frame.
pub fn line<T: Serialize>(frame: &T) -> String {
    let mut text = serde_json::to_string(frame).unwrap_or_else(|_| "{}".to_string());
    text.push('\n');
    text
}

/// Parse a frame line of at most [`MAX_LINE_BYTES`].
pub fn parse_line<T: for<'de> Deserialize<'de>>(line: &str) -> Option<T> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    (line.len() <= MAX_LINE_BYTES).then(|| serde_json::from_str(line).ok()).flatten()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_dial_contract_has_stable_wire_shapes() {
        let request =
            parse_request(r#"{"op":"link.dial","host":"inst_9","service":"daemon"}"#).unwrap();
        assert_eq!(request.host, "inst_9");
        assert_eq!(
            line(&DialReply::connected(PathState::Direct)),
            "{\"ok\":true,\"path_state\":\"direct\",\"relay_available\":false}\n"
        );
        assert_eq!(
            line(&DialReply::failed(DialError::Unreachable)),
            "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"unreachable\"}\n"
        );
        assert_eq!(line(&ServiceHello { service: Service::Daemon }), "{\"service\":\"daemon\"}\n");
    }

    #[test]
    fn bad_dial_requests_are_refused() {
        for bad in [
            r#"{"op":"link.dial","host":"inst","service":"shell"}"#,
            r#"{"op":"link.listen","host":"inst","service":"daemon"}"#,
            r#"{"op":"link.dial","host":"../x","service":"daemon"}"#,
            r#"{"op":"link.dial","host":"inst","service":"daemon","command":"sh"}"#,
        ] {
            assert_eq!(parse_request(bad), Err(DialError::BadRequest), "{bad}");
        }
    }
}
