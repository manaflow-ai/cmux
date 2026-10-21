//! Revision negotiation in the hello.
//!
//! Each side advertises the revision it speaks (`api_revision`) and the
//! oldest one it can still translate (`min_api_revision`). The side with the
//! newer revision knows every rule in between, so it translates in both
//! directions: an old client talking to a new server is served by the
//! server, a new client talking to an old server translates for itself.

use serde::{Deserialize, Serialize};

use crate::CompatError;
use crate::compat::Compat;

/// The revision fields one side puts in its hello.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct RevisionHello {
    /// The revision this side reads and writes natively.
    pub api_revision: u32,
    /// The oldest revision this side can translate to and from.
    pub min_api_revision: u32,
}

impl RevisionHello {
    /// The hello for this build.
    pub fn ours(compat: &Compat) -> Self {
        Self { api_revision: compat.current(), min_api_revision: compat.schema().base }
    }
}

/// Who rewrites messages on a connection.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Translator {
    /// Both sides speak the same revision.
    Nobody,
    /// We are newer: translate our outgoing messages down to `peer` and the
    /// peer's incoming messages up from `peer`.
    Us,
    /// The peer is newer and translates for us.
    Peer,
}

/// The outcome of a negotiation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Negotiated {
    /// Our native revision.
    pub ours: u32,
    /// The peer's native revision.
    pub peer: u32,
    /// Who translates.
    pub translator: Translator,
}

/// Decides who translates. A peer that sent no revision (a build from before
/// this system) counts as `legacy`.
pub fn negotiate(
    ours: RevisionHello,
    peer: Option<RevisionHello>,
    legacy: u32,
) -> Result<Negotiated, CompatError> {
    let peer = peer.unwrap_or(RevisionHello { api_revision: legacy, min_api_revision: legacy });
    let translator = match ours.api_revision.cmp(&peer.api_revision) {
        std::cmp::Ordering::Equal => Translator::Nobody,
        std::cmp::Ordering::Greater if peer.api_revision >= ours.min_api_revision => Translator::Us,
        std::cmp::Ordering::Less if ours.api_revision >= peer.min_api_revision => Translator::Peer,
        _ => {
            return Err(CompatError::UnsupportedRevision {
                rev: peer.api_revision,
                base: ours.min_api_revision,
                current: ours.api_revision,
            });
        }
    };
    Ok(Negotiated { ours: ours.api_revision, peer: peer.api_revision, translator })
}

impl Negotiated {
    /// Rewrites a message we send, if we are the translator.
    pub fn outgoing<'a>(
        &self,
        compat: &Compat,
        kind: &str,
        message: &'a [u8],
    ) -> Result<std::borrow::Cow<'a, [u8]>, CompatError> {
        match self.translator {
            Translator::Us => compat.translate(kind, self.ours, self.peer, message),
            _ => Ok(std::borrow::Cow::Borrowed(message)),
        }
    }

    /// Rewrites a message we received, if we are the translator.
    pub fn incoming<'a>(
        &self,
        compat: &Compat,
        kind: &str,
        message: &'a [u8],
    ) -> Result<std::borrow::Cow<'a, [u8]>, CompatError> {
        match self.translator {
            Translator::Us => compat.translate(kind, self.peer, self.ours, message),
            _ => Ok(std::borrow::Cow::Borrowed(message)),
        }
    }
}
