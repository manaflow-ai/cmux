//! The peer identity stamp: the first line the link writes on a stream it
//! hands to the daemon's remote entry. Only the link writes it, and the
//! daemon reads it only on its remote entry, after the entry verified that
//! the connecting process is the link ([`crate::caller`]). The peer's own
//! bytes follow the stamp; nothing the peer sends can stand in for it.

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

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct StampLine {
    link_peer: LinkPeer,
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

/// The stamp line for `peer`, without the trailing newline.
pub fn encode(peer: &LinkPeer) -> Result<String, StampError> {
    if !peer.is_valid() {
        return Err(StampError::InvalidId);
    }
    serde_json::to_string(&StampLine { link_peer: peer.clone() }).map_err(|_| StampError::Malformed)
}

/// Parse one stamp line (a trailing newline is allowed).
pub fn parse(line: &str) -> Result<LinkPeer, StampError> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    if line.len() > MAX_STAMP_BYTES {
        return Err(StampError::TooLong);
    }
    let StampLine { link_peer } =
        serde_json::from_str(line).map_err(|_| StampError::Malformed)?;
    if !link_peer.is_valid() {
        return Err(StampError::InvalidId);
    }
    Ok(link_peer)
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

    #[test]
    fn the_stamp_round_trips_through_the_golden_line() {
        assert_eq!(encode(&peer()).unwrap(), GOLDEN);
        assert_eq!(parse(&format!("{GOLDEN}\n")).unwrap(), peer());
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
