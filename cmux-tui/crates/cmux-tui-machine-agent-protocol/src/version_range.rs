//! The machine-agent tunnel's protocol range (hq RFD 0224, "a protocol range on every link"):
//! this build reads every envelope version in `PROTOCOL_MIN..=PROTOCOL_MAX` and writes
//! [`crate::PROTOCOL_VERSION`]. A frame from outside the range is [`VersionIncompatible`], a typed
//! refusal naming the side to update, instead of the serde failure it used to be.
//!
//! Capabilities stay out of the tunnel's hello for now: both sides decode with
//! `deny_unknown_fields`, so a new hello field would be refused by every server from before it. A
//! capability list lands once the server reads unknown fields, the same way the machine-provider
//! protocol's envelopes do.

use std::fmt;

use serde::Deserialize;

/// The oldest tunnel version this build still reads; never past `PROTOCOL_MAX - 1` once a second
/// version exists.
pub const PROTOCOL_MIN: u16 = 1;
/// The newest tunnel version this build reads.
pub const PROTOCOL_MAX: u16 = crate::PROTOCOL_VERSION;

/// Whether this build reads tunnel version `version`.
pub const fn speaks(version: u16) -> bool {
    PROTOCOL_MIN <= version && version <= PROTOCOL_MAX
}

/// A tunnel frame whose version this build does not read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct VersionIncompatible {
    /// The version the peer sent.
    pub theirs: u16,
}

impl VersionIncompatible {
    /// `peer` when the peer is older than this build reads, `self` when it is newer.
    pub fn update_side(self) -> &'static str {
        if self.theirs < PROTOCOL_MIN { "peer" } else { "self" }
    }

    pub fn action(self) -> &'static str {
        if self.theirs < PROTOCOL_MIN { "update the cmux server" } else { "update cmux" }
    }
}

impl fmt::Display for VersionIncompatible {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let ours = if PROTOCOL_MIN == PROTOCOL_MAX {
            PROTOCOL_MAX.to_string()
        } else {
            format!("{PROTOCOL_MIN}..={PROTOCOL_MAX}")
        };
        write!(
            formatter,
            "version.incompatible: the peer speaks machine-agent protocol {} and this build {ours}; \
             {}",
            self.theirs,
            self.action()
        )
    }
}

impl std::error::Error for VersionIncompatible {}

/// Only a frame's `version`, read before the strict envelope.
#[derive(Debug, Deserialize)]
pub struct VersionPeek {
    pub version: u16,
}

impl VersionPeek {
    pub fn check(&self) -> Option<VersionIncompatible> {
        (!speaks(self.version)).then_some(VersionIncompatible { theirs: self.version })
    }
}
