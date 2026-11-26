//! `cas/1`, the content-addressed bulk class of RFD 0166 ("Our own CDN").
//!
//! A CDN serves URLs; it cannot see what the client already holds. `cas/1` names every artifact
//! (a web bundle, a binary, a seed) by a [`Manifest`] of [FastCDC](cdc) chunks, so an update moves
//! only `manifest - have` ([`plan::want`]). The chunks live in a local [`Store`] and, as the HTTPS
//! floor, in R2 [pack files](pack) a client reads with coalesced Range GETs. A channel names its
//! current manifest with a [signed pointer](pointer) in the `cmux-signed-envelope` the web OTA
//! and Cloud machine channel already use, and [`assemble`] rebuilds the tree bit-exact, checking
//! every file's hash.
//!
//! Grown from `cmux-session-pack` (`store.rs`, `ship.rs`): the same BLAKE3 ids, zstd chunk files
//! written beside their name and renamed into place, and "ship only what the far end lacks".
//! The differences: ids hash the bytes alone (`BLAKE3(bytes)`, so public artifacts dedup
//! globally) or a team key (`BLAKE3_keyed`, private data, no cross-user equality), and chunk
//! boundaries come from content, not from event lines.

pub mod assemble;
pub mod cdc;
pub mod cold;
pub mod dedup;
pub mod id;
pub mod manifest;
pub mod pack;
pub mod plan;
pub mod pointer;
pub mod public;
pub mod store;

pub use id::Id;
pub use manifest::Manifest;
pub use store::Store;

/// The crate's error: a message is enough for every caller.
pub type Error = Box<dyn std::error::Error + Send + Sync>;
/// `Result` with [`Error`].
pub type Result<T> = std::result::Result<T, Error>;
