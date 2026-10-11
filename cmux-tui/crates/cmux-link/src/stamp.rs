//! The peer identity stamp: the first line the link writes on a stream it
//! hands to the daemon's remote entry. Only the link writes it, and the
//! daemon reads it only on its remote entry, after the entry verified that
//! the connecting process is the link ([`crate::caller`]). The peer's own
//! bytes follow the stamp; nothing the peer sends can stand in for it.
//!
//! The optional `check` names a control-plane check the link made for this
//! stream ([`StampCheck`]). The link writes it only after the check passed;
//! the daemon records it as the install's good check (the 24 h / 72 h
//! offline limits). A peer cannot set it: the stamp is the first line, the
//! link writes it before any peer byte, and the daemon reads it only there.

use serde::{Deserialize, Serialize};

/// The longest stamp line the daemon reads before it gives up.
pub const MAX_STAMP_BYTES: usize = 1024;

/// The longest identifier in a stamp.
pub const MAX_ID_BYTES: usize = 128;

/// The peer the link verified: the install that owns the WireGuard key the
/// stream came from, and the user and team the pairing record names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinkPeer {
    pub install: String,
    pub user: String,
    pub team: String,
}

/// A control-plane check the link made for this stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StampCheck {
    /// A Cloud host's token verifier accepted a control-plane link token for
    /// this stream (cloud-client-contract.md 1.7). The control plane mints
    /// no token for a revoked install.
    LinkToken,
}

/// One parsed stamp: the verified peer and the check the link made, if any.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Stamp {
    pub peer: LinkPeer,
    pub check: Option<StampCheck>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StampLine {
    link_peer: LinkPeer,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    check: Option<StampCheck>,
}

/// Why a stamp line was refused.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StampError {
    /// Not a JSON object with exactly `link_peer {install, user, team}`.
    Malformed,
    /// An identifier is empty, too long, or uses a character outside
    /// `A-Z a-z 0-9 _ - . :`.
    InvalidId,
    /// The line is longer than [`MAX_STAMP_BYTES`].
    TooLong,
}

impl std::fmt::Display for StampError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Malformed => "malformed link peer stamp",
            Self::InvalidId => "invalid identifier in link peer stamp",
            Self::TooLong => "link peer stamp is too long",
        })
    }
}

impl std::error::Error for StampError {}

/// True for a non-empty identifier of at most [`MAX_ID_BYTES`] bytes from
/// `A-Z a-z 0-9 _ - . :`.
pub fn valid_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_ID_BYTES
        && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"_-.:".contains(&byte))
}

impl LinkPeer {
    /// Every identifier is valid ([`valid_id`]).
    pub fn is_valid(&self) -> bool {
        valid_id(&self.install) && valid_id(&self.user) && valid_id(&self.team)
    }
}

/// The stamp line for `peer`, without the trailing newline. `check` only
/// after that check passed for this stream.
pub fn encode(peer: &LinkPeer, check: Option<StampCheck>) -> Result<String, StampError> {
    if !peer.is_valid() {
        return Err(StampError::InvalidId);
    }
    serde_json::to_string(&StampLine { link_peer: peer.clone(), check })
        .map_err(|_| StampError::Malformed)
}

/// Parse one stamp line (a trailing newline is allowed).
pub fn parse(line: &str) -> Result<Stamp, StampError> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    if line.len() > MAX_STAMP_BYTES {
        return Err(StampError::TooLong);
    }
    let StampLine { link_peer, check } =
        serde_json::from_str(line).map_err(|_| StampError::Malformed)?;
    if !link_peer.is_valid() {
        return Err(StampError::InvalidId);
    }
    Ok(Stamp { peer: link_peer, check })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn peer() -> LinkPeer {
        LinkPeer { install: "inst_1".into(), user: "user_42".into(), team: "team_a".into() }
    }

    /// The golden line both ends agree on.
    pub(crate) const GOLDEN: &str =
        r#"{"link_peer":{"install":"inst_1","user":"user_42","team":"team_a"}}"#;

    /// The golden line of a stream whose link token the host accepted.
    pub(crate) const GOLDEN_CHECKED: &str = r#"{"link_peer":{"install":"inst_1","user":"user_42","team":"team_a"},"check":"link_token"}"#;

    #[test]
    fn the_stamp_round_trips_through_the_golden_line() {
        assert_eq!(encode(&peer(), None).unwrap(), GOLDEN);
        assert_eq!(parse(&format!("{GOLDEN}\n")).unwrap(), Stamp { peer: peer(), check: None });
    }

    #[test]
    fn a_checked_stamp_round_trips_and_an_unknown_check_is_refused() {
        assert_eq!(encode(&peer(), Some(StampCheck::LinkToken)).unwrap(), GOLDEN_CHECKED);
        assert_eq!(
            parse(GOLDEN_CHECKED).unwrap(),
            Stamp { peer: peer(), check: Some(StampCheck::LinkToken) }
        );
        let unknown = r#"{"link_peer":{"install":"i","user":"u","team":"t"},"check":"admin"}"#;
        assert_eq!(parse(unknown), Err(StampError::Malformed));
        let inside = r#"{"link_peer":{"install":"i","user":"u","team":"t","check":"link_token"}}"#;
        assert_eq!(parse(inside), Err(StampError::Malformed));
    }

    #[test]
    fn a_stamp_with_extra_fields_or_bad_ids_is_refused() {
        let extra = r#"{"link_peer":{"install":"i","user":"u","team":"t","admin":true}}"#;
        assert_eq!(parse(extra), Err(StampError::Malformed));
        let outer = r#"{"link_peer":{"install":"i","user":"u","team":"t"},"cmd":"identify"}"#;
        assert_eq!(parse(outer), Err(StampError::Malformed));
        let slash = r#"{"link_peer":{"install":"../x","user":"u","team":"t"}}"#;
        assert_eq!(parse(slash), Err(StampError::InvalidId));
        let empty = r#"{"link_peer":{"install":"","user":"u","team":"t"}}"#;
        assert_eq!(parse(empty), Err(StampError::InvalidId));
        assert_eq!(parse(&"x".repeat(MAX_STAMP_BYTES + 1)), Err(StampError::TooLong));
        assert_eq!(parse(r#"{"cmd":"identify"}"#), Err(StampError::Malformed));
    }
}
