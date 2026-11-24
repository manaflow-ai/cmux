//! A channel's signed pointer: which root manifest is current on a channel (app nightly, web
//! every-merge, cloud-machine, image devbox, ci seed), inside the `cmux-signed-envelope` the web
//! update pointer and the Cloud machine channel already use. The payload:
//!
//! ```json
//! {"purpose": "cmux-cas-pointer", "schema": 1, "channel": "web-every-merge",
//!  "root": "<64 hex>", "size": 123, "commit": "<sha>", "abi": 1, "floor": 42,
//!  "https_base": "https://files.cmux.com/cas/"}
//! ```
//!
//! [`Pointer::open`] checks the signature before reading any field, then the purpose (so a file
//! signed for another kind never opens as a pointer), the channel, and the replay floor: a
//! pointer whose `floor` is below the last one the reader accepted is an old pointer replayed.

use crate::Result;
use crate::id::{Id, unhex};
use cmux_signed_envelope::Key;
use serde::{Deserialize, Serialize};

/// The payload's `purpose`.
pub const PURPOSE: &str = "cmux-cas-pointer";
/// The payload schema this build reads.
pub const SCHEMA: u64 = 1;

/// A channel's current root manifest.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pointer {
    /// [`PURPOSE`].
    pub purpose: String,
    /// [`SCHEMA`].
    pub schema: u64,
    /// The channel it names the root of.
    pub channel: String,
    /// The root manifest's id (hex).
    pub root: String,
    /// The artifact's size.
    pub size: u64,
    /// The commit it was built from.
    pub commit: String,
    /// The artifact's ABI, which a reader checks it can run.
    pub abi: u64,
    /// A number that only grows on a channel; a reader refuses one below the last it accepted.
    pub floor: u64,
    /// Where the chunks' pack files are on HTTPS, the floor every client can reach.
    pub https_base: String,
}

impl Pointer {
    /// The pointer in envelope `body` when one of `keys` signed it, it is for `channel`, and its
    /// floor is at least `min_floor`.
    pub fn open(body: &[u8], keys: &[Key], channel: &str, min_floor: u64) -> Result<Self> {
        let payload = cmux_signed_envelope::open(body, keys)?;
        let pointer: Self = serde_json::from_slice(&payload)
            .map_err(|e| format!("the signed payload is not a cas pointer: {e}"))?;
        if pointer.purpose != PURPOSE {
            return Err(
                format!("the payload is a {} file, not a cas pointer", pointer.purpose).into()
            );
        }
        if pointer.schema != SCHEMA {
            return Err(format!("unknown cas pointer schema {}", pointer.schema).into());
        }
        if pointer.channel != channel {
            return Err(format!("the pointer is for {}, not {channel}", pointer.channel).into());
        }
        if pointer.floor < min_floor {
            return Err(format!(
                "the pointer's floor {} is below {min_floor}: an old pointer replayed",
                pointer.floor
            )
            .into());
        }
        unhex(&pointer.root)?;
        Ok(pointer)
    }

    /// The root manifest's id.
    pub fn root_id(&self) -> Result<Id> {
        unhex(&self.root)
    }
}
