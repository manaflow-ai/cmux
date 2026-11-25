//! The signed pointer naming a channel's current manifest, inside the `cmux-signed-envelope`
//! the web OTA and the Cloud machine channel already use. Its payload `purpose` is
//! [`PURPOSE`], so a web pointer or a machine channel file never opens as one, nor this as them.

use crate::{Id, Result};
use serde::{Deserialize, Serialize};

/// The payload purpose of a `cas/1` pointer.
pub const PURPOSE: &str = "cmux-cas-pointer";

/// A pointer's payload.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pointer {
    /// [`PURPOSE`].
    pub purpose: String,
    /// The channel, e.g. `web/every-merge`.
    pub channel: String,
    /// The manifest's id.
    pub manifest: Id,
    /// The packs holding its chunks (`packs/<id>.pack`).
    pub packs: Vec<Id>,
    /// A sequence the client never lets go backwards.
    pub sequence: u64,
}

/// The pointer `body` holds, when one of `keys` signed it and it is for `channel`.
pub fn open(body: &[u8], keys: &[cmux_signed_envelope::Key], channel: &str) -> Result<Pointer> {
    let payload = cmux_signed_envelope::open(body, keys)?;
    let p: Pointer = serde_json::from_slice(&payload)?;
    if p.purpose != PURPOSE {
        return Err(format!("payload purpose {:?} is not {PURPOSE}", p.purpose).into());
    }
    if p.channel != channel {
        return Err(format!("pointer is for channel {:?}, not {channel:?}", p.channel).into());
    }
    Ok(p)
}

/// Whether `next` may replace `current`: a higher sequence, or the same manifest.
pub fn newer(current: Option<&Pointer>, next: &Pointer) -> bool {
    current.is_none_or(|c| next.sequence > c.sequence || next.manifest == c.manifest)
}
