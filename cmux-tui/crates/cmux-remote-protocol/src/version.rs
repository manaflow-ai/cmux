//! The remote protocol range every remote link checks (hq RFD 0224, "Versioning: a protocol range on
//! every link"): the frame header's version byte, the relay's `Register` / `Standby` / `Connect` /
//! `Join`, and the daemon's secure-link prelude.
//!
//! Each side speaks `REMOTE_PROTOCOL_MIN..=REMOTE_PROTOCOL_VERSION`. A peer inside that range is
//! served. A peer outside it gets the typed refusal [`VERSION_INCOMPATIBLE`], whose message names
//! the side to update. It is never a bare decode error or a silently dropped link.
//!
//! A peer from before ranges names one version, the one it speaks: [`ProtocolRange::exactly`].

use std::fmt;

/// The oldest remote protocol this build still decodes and serves. It goes up only on purpose, and
/// never past `REMOTE_PROTOCOL_VERSION - 1` once a newer version ships, so the build before always
/// still talks to this one (`version_tests::the_window_keeps_n_minus_1`). 5 is the first version
/// with a range; nothing older shares its frame header.
pub const REMOTE_PROTOCOL_MIN: u8 = 5;

/// The `code` / `errorKind` of a refusal for a peer whose range does not overlap ours. It is the
/// same string as acpmux's `recovery::kind::VERSION_INCOMPATIBLE`.
pub const VERSION_INCOMPATIBLE: &str = "version.incompatible";

/// An inclusive protocol range `min..=max`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProtocolRange {
    pub min: u8,
    pub max: u8,
}

/// Which side a refusal asks to update.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateSide {
    /// The peer is older than this build serves.
    Peer,
    /// The peer is newer than this build speaks.
    This,
}

impl UpdateSide {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Peer => "peer",
            Self::This => "self",
        }
    }
}

impl ProtocolRange {
    /// This build's range.
    pub const fn ours() -> Self {
        Self { min: REMOTE_PROTOCOL_MIN, max: crate::REMOTE_PROTOCOL_VERSION }
    }

    /// A peer that names one version, the one it speaks (every peer from before ranges).
    pub const fn exactly(version: u8) -> Self {
        Self { min: version, max: version }
    }

    /// A peer that names its newest version and, optionally, its oldest. A floor above the newest
    /// is ignored: the peer is taken to speak only the version it names, never more.
    pub fn of_peer(max: u8, min: Option<u8>) -> Self {
        Self { min: min.filter(|min| *min <= max).unwrap_or(max), max }
    }

    pub const fn contains(self, version: u8) -> bool {
        version >= self.min && version <= self.max
    }

    /// The newest version both ranges hold, or `None` when they do not overlap.
    pub fn common(self, other: Self) -> Option<u8> {
        let top = self.max.min(other.max);
        (top >= self.min.max(other.min)).then_some(top)
    }

    /// Checks a peer's range against this one: the version to speak, or the typed refusal.
    pub fn negotiate(self, peer: Self) -> Result<u8, VersionIncompatible> {
        self.common(peer).ok_or(VersionIncompatible { ours: self, theirs: peer })
    }
}

impl fmt::Display for ProtocolRange {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.min == self.max {
            write!(formatter, "{}", self.max)
        } else {
            write!(formatter, "{}..={}", self.min, self.max)
        }
    }
}

/// A peer whose protocol range does not overlap ours.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VersionIncompatible {
    pub ours: ProtocolRange,
    pub theirs: ProtocolRange,
}

impl VersionIncompatible {
    /// Always [`VERSION_INCOMPATIBLE`].
    pub const fn code(&self) -> &'static str {
        VERSION_INCOMPATIBLE
    }

    pub fn update(&self) -> UpdateSide {
        if self.theirs.max < self.ours.min { UpdateSide::Peer } else { UpdateSide::This }
    }

    /// The refusal text, naming `peer` (`the client`, `the daemon`) and the side to update.
    pub fn message(&self, peer: &str, this: &str) -> String {
        let action = match self.update() {
            UpdateSide::Peer => format!("update {peer}"),
            UpdateSide::This => format!("update {this}"),
        };
        format!(
            "{peer} speaks remote protocol {}, {this} speaks {}: no version in common; {action}",
            self.theirs, self.ours
        )
    }
}

impl fmt::Display for VersionIncompatible {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", VERSION_INCOMPATIBLE, self.message("the peer", "this build"))
    }
}

impl std::error::Error for VersionIncompatible {}

#[cfg(test)]
#[path = "version_tests.rs"]
mod version_tests;
