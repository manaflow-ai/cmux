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
    /// The session daemon's remote entry (JSON lines).
    Daemon,
    /// The host's sshd on loopback (scp, sftp and rsync with `cmux link`
    /// as ProxyCommand). Cloud hosts only, when their policy allows it.
    Ssh,
}

/// How the stream reaches the peer. Lane 10's UI shows "same network only"
/// while [`DialReply::relay_available`] is false.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathState {
    /// A direct UDP path to the peer carries the stream.
    Direct,
    /// The relay carries the stream (reserved; no relay ships yet).
    Relay,
    /// This install's Freestyle tunnel carries the stream to the host's VPC
    /// endpoint (Cloud hosts).
    Tunnel,
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
    /// No pairing record or Cloud machine names this host.
    UnknownHost,
    /// The peer did not answer on any path.
    Unreachable,
    /// The caller may not reach this host or service (policy or token).
    NotAuthorized,
    /// The host is paused; start it (`cloud.machine.start`) and dial again.
    HostPaused,
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

/// `{"op":"link.cloud_event","event":"removed"|"upsert","host":...,
/// "revision":N}`: a Cloud machine event that cmux-cloud forwards to the
/// link (cloud-client-contract.md 1.7 cache rules 1 and 4). `removed` drops
/// the record and closes open links to that host; `upsert` drops a record
/// older than `revision`. The reply is `{"ok":true}`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CloudEventRequest {
    pub op: CloudEventOp,
    pub event: CloudEvent,
    pub host: String,
    #[serde(default)]
    pub revision: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum CloudEventOp {
    #[serde(rename = "link.cloud_event")]
    CloudEvent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum CloudEvent {
    Removed,
    Upsert,
}

/// The first line on an overlay link stream: `{"service":"daemon"}` to a
/// paired peer, `{"service":...,"link_token":...,"epoch":...}` to a Cloud
/// host (the host checks the token before it serves anything).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceHello {
    pub service: Service,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u64>,
}

impl ServiceHello {
    /// The hello to a paired peer (no token).
    pub fn paired(service: Service) -> Self {
        Self { service, link_token: None, epoch: None }
    }
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
        assert_eq!(line(&ServiceHello::paired(Service::Daemon)), "{\"service\":\"daemon\"}\n");
        let cloud = ServiceHello {
            service: Service::Ssh,
            link_token: Some("tok".into()),
            epoch: Some(3),
        };
        assert_eq!(line(&cloud), "{\"service\":\"ssh\",\"link_token\":\"tok\",\"epoch\":3}\n");
        assert_eq!(
            line(&DialReply::failed(DialError::HostPaused)),
            "{\"ok\":false,\"path_state\":\"unreachable\",\"relay_available\":false,\"error_code\":\"host_paused\"}\n"
        );
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
