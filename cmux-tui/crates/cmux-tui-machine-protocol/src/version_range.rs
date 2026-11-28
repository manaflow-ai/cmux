//! The machine-provider protocol range and the one refusal a version gap gets (hq RFD 0224, "a
//! protocol range on every link"): each side speaks every version in `PROTOCOL_MIN..=PROTOCOL_MAX`,
//! the hello names that list (`ClientDescriptor::supported_versions`), the provider answers the
//! newest version both speak (`HelloResult::negotiated_version`), and features ride on the
//! capability lists (`ResponseEnvelope::capabilities`, `negotiate_client_capabilities`), never on
//! the version number.
//!
//! No overlap is [`VersionIncompatible`]: a typed refusal that names which side to update, sent
//! on the wire as the provider error code `version.incompatible`. It replaces the serde failure a
//! frame from outside the range used to be. A peer from before the range sends a single version
//! number in every envelope and one entry in `supported_versions`; both still read as that
//! one-version range.

use std::fmt;

use serde::Deserialize;

use crate::{PROTOCOL_VERSION, ProviderError, ProviderErrorCode};

/// The oldest machine-provider version this build still speaks. It goes up only after the
/// inventory shows no provider below it, and never past `PROTOCOL_MAX - 1` once a second version
/// exists, so the build before this one always still talks to it.
pub const PROTOCOL_MIN: u16 = 1;
/// The newest machine-provider version this build speaks.
pub const PROTOCOL_MAX: u16 = PROTOCOL_VERSION;

/// An inclusive protocol range `min..=max`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProtocolRange {
    pub min: u16,
    pub max: u16,
}

impl ProtocolRange {
    /// This build's range.
    pub const OURS: ProtocolRange = ProtocolRange { min: PROTOCOL_MIN, max: PROTOCOL_MAX };

    pub const fn contains(self, version: u16) -> bool {
        self.min <= version && version <= self.max
    }

    /// Every version in the range, newest last: what a hello's `supported_versions` names.
    pub fn versions(self) -> Vec<u16> {
        (self.min..=self.max).collect()
    }

    /// The range a peer's version list spans, or `None` for an empty list. A legacy peer's
    /// one-entry list is the one-version range.
    pub fn spanning(versions: &[u16]) -> Option<ProtocolRange> {
        let min = versions.iter().copied().min()?;
        let max = versions.iter().copied().max()?;
        Some(ProtocolRange { min, max })
    }

    /// The newest version this range holds that the peer also lists.
    pub fn newest_common(self, peer_versions: &[u16]) -> Option<u16> {
        peer_versions.iter().copied().filter(|version| self.contains(*version)).max()
    }
}

impl fmt::Display for ProtocolRange {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.min == self.max {
            write!(formatter, "{}", self.min)
        } else {
            write!(formatter, "{}..={}", self.min, self.max)
        }
    }
}

/// Which side of a refused link has to update.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum UpdateSide {
    /// The peer is older than this build still speaks.
    Peer,
    /// The peer is newer than this build speaks yet.
    This,
    /// The peer named no range (a bare refusal from a provider): either side may be behind.
    Either,
}

impl UpdateSide {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Peer => "peer",
            Self::This => "self",
            Self::Either => "either",
        }
    }
}

/// Two sides of a machine-provider link that share no protocol version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VersionIncompatible {
    pub ours: ProtocolRange,
    /// The peer's range, when it named one.
    pub theirs: Option<ProtocolRange>,
    /// What the peer is: `machine provider` on the client side, `cmux` on the provider side.
    pub peer: &'static str,
}

impl VersionIncompatible {
    pub fn new(ours: ProtocolRange, theirs: Option<ProtocolRange>, peer: &'static str) -> Self {
        Self { ours, theirs, peer }
    }

    pub fn update(&self) -> UpdateSide {
        match self.theirs {
            Some(theirs) if theirs.max < self.ours.min => UpdateSide::Peer,
            Some(_) => UpdateSide::This,
            None => UpdateSide::Either,
        }
    }

    /// The action the refusal offers.
    pub fn action(&self) -> String {
        let this = if self.peer == "cmux" { "this machine provider" } else { "cmux" };
        match self.update() {
            UpdateSide::Peer => format!("update {}", self.peer),
            UpdateSide::This => format!("update {this}"),
            UpdateSide::Either => format!("update {this} or {}", self.peer),
        }
    }

    /// The refusal as a provider error, the frame a provider answers a hello it cannot serve with.
    pub fn to_provider_error(&self) -> ProviderError {
        ProviderError {
            code: ProviderErrorCode::VersionIncompatible,
            message: self.to_string(),
            retryable: false,
        }
    }
}

impl fmt::Display for VersionIncompatible {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let ours = self.ours;
        match self.theirs {
            Some(theirs) => write!(
                formatter,
                "{} speaks machine-provider protocol {theirs} and this build {ours}: no version \
                 in common; {}",
                self.peer,
                self.action()
            ),
            None => write!(
                formatter,
                "{} speaks none of machine-provider protocol {ours}; {}",
                self.peer,
                self.action()
            ),
        }
    }
}

impl std::error::Error for VersionIncompatible {}

/// What a provider answers a hello with: the newest version both sides speak, or the typed
/// refusal. `ours` is the provider's own range (normally [`ProtocolRange::OURS`]).
pub fn negotiate_version(
    ours: ProtocolRange,
    client_versions: &[u16],
) -> Result<u16, VersionIncompatible> {
    ours.newest_common(client_versions).ok_or_else(|| {
        VersionIncompatible::new(ours, ProtocolRange::spanning(client_versions), "cmux")
    })
}

/// Only the `version` of a frame, read before the full envelope so a frame from outside the range
/// is a [`VersionIncompatible`], not a decode error. Every other field is ignored.
#[derive(Debug, Deserialize)]
pub struct VersionPeek {
    pub version: u16,
}

impl VersionPeek {
    /// The refusal for this frame's version, or `None` when `ours` speaks it.
    pub fn check(&self, ours: ProtocolRange, peer: &'static str) -> Option<VersionIncompatible> {
        (!ours.contains(self.version)).then(|| {
            VersionIncompatible::new(
                ours,
                Some(ProtocolRange { min: self.version, max: self.version }),
                peer,
            )
        })
    }
}

#[cfg(test)]
#[path = "version_range_tests.rs"]
mod version_range_tests;
