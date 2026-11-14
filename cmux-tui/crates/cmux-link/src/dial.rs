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

/// The longest control request or reply line.
pub const MAX_LINE_BYTES: usize = 1024;
pub const MAX_LINK_TOKEN_BYTES: usize = 8192;
/// One bounded signed token plus the service/epoch JSON envelope.
pub const MAX_HELLO_BYTES: usize = MAX_LINK_TOKEN_BYTES + 128;

/// The services a link stream can reach.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Service {
    /// The session daemon's remote entry (JSON lines).
    Daemon,
    /// The host's sshd on loopback (scp, sftp and rsync with `cmux link`
    /// as ProxyCommand). Cloud hosts only, when their policy allows it.
    Ssh,
    /// The trusted local socket of a paired server's Chief brain daemon
    /// (full tree). Only the server's owner (`owner_session`); every other
    /// peer is refused.
    OwnerSession,
    /// The machine's agent display as `cmux.rd/1` (the root-only socket
    /// `/run/cmux-rd/desktop.sock`). Cloud hosts only, and only for the
    /// machine's creator: the platform mints it for no one else and the
    /// receiving policy lists it for no other peer.
    Desktop,
    /// The acpmux daemon's loopback WebSocket listener on a paired machine.
    /// The link only carries the bytes: acpmux still checks its listener
    /// token and peer proof on the upgrade, so pairing grants nothing more.
    Acpmux,
    /// Link to link only: the dialing link names the key it serves from now on
    /// ([`RekeyRequest`]), over its old key's session, when it adopts this
    /// machine's node key. A local caller cannot dial it.
    Rekey,
}

/// The one line a link writes after a [`Service::Rekey`] hello: its new
/// WireGuard public key, standard base64 of 32 bytes. The answer is one
/// [`RekeyReply`] line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RekeyRequest {
    pub public_key: String,
}

/// The receiving link's answer to a [`RekeyRequest`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RekeyReply {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The receiving link's own new key, when it adopted one too and still
    /// knew the asking link by its old key: both move in the one exchange.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub public_key: Option<String>,
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

/// Readers ignore unknown fields (unlike the request types): a reply may
/// gain a field such as `error_detail`, and a reader that predates it must
/// still read the typed `error_code`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DialReply {
    pub ok: bool,
    pub path_state: PathState,
    pub relay_available: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_code: Option<DialError>,
    /// What failed, in one line (which lookup, which handshake, the
    /// backend's refusal code): `error_code` keeps the typed retry
    /// contract, this says why. Never a credential.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_detail: Option<String>,
}

/// The longest [`DialReply::error_detail`] in bytes: one display line, so a
/// reply stays far inside [`MAX_LINE_BYTES`].
pub const MAX_ERROR_DETAIL_BYTES: usize = 300;

impl DialReply {
    pub fn connected(path_state: PathState) -> Self {
        Self {
            ok: true,
            path_state,
            relay_available: RELAY_AVAILABLE,
            error_code: None,
            error_detail: None,
        }
    }

    pub fn failed(error: DialError) -> Self {
        Self {
            ok: false,
            path_state: PathState::Unreachable,
            relay_available: RELAY_AVAILABLE,
            error_code: Some(error),
            error_detail: None,
        }
    }

    /// A failure with what failed: control characters dropped, at most
    /// [`MAX_ERROR_DETAIL_BYTES`] (cut on a character boundary).
    pub fn failed_because(error: DialError, detail: &str) -> Self {
        let mut kept = String::new();
        for c in detail.chars().filter(|c| !c.is_control()) {
            if kept.len().saturating_add(c.len_utf8()) > MAX_ERROR_DETAIL_BYTES {
                break;
            }
            kept.push(c);
        }
        let detail = kept.trim();
        Self {
            error_detail: (!detail.is_empty()).then(|| detail.to_owned()),
            ..Self::failed(error)
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

/// The first line on an overlay link stream: `{"service":"daemon"}` to a
/// paired peer, `{"service":...,"link_token":...,"epoch":...}` to a Cloud
/// host (the host checks the token before it serves anything).
#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ServiceHello {
    pub service: Service,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub link_token: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub epoch: Option<u64>,
}

impl std::fmt::Debug for ServiceHello {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ServiceHello")
            .field("service", &self.service)
            .field("has_link_token", &self.link_token.is_some())
            .field("epoch", &self.epoch)
            .finish()
    }
}

impl ServiceHello {
    pub fn parse(line: &str) -> Option<Self> {
        let line = line.strip_suffix('\n').unwrap_or(line);
        if line.len() > MAX_HELLO_BYTES {
            return None;
        }
        let hello: Self = serde_json::from_str(line).ok()?;
        if hello.link_token.as_ref().is_some_and(|token| token.len() > MAX_LINK_TOKEN_BYTES) {
            return None;
        }
        Some(hello)
    }

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
mod tests;
