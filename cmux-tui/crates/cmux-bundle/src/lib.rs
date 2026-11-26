//! Data bundles: large state (attachments, history pages, projectionfs blocks, checkpoints) moved as
//! sealed, content-addressed chunks, so the far end asks only for what it lacks, from whichever copy is
//! nearest (the peer, a relay's sealed cache, its own disk).
//!
//! RFD 0142 R7 ("bandwidth assist: sealed chunk cache"), ultra-connectivity design A4 (data bundles)
//! and P11 (content addressing).
//!
//! - [`PairKey`]: two keys derived from a secret only the two ends of a pair hold. A chunk's id is a
//!   BLAKE3 *keyed* hash of its bytes, so equal content has equal ids within a pair and unrelated ids
//!   across pairs: a relay can dedupe within a pair, never across users (convergent encryption is
//!   ruled out for that reason).
//! - [`cdc`]: content-defined chunk boundaries (a gear hash, FastCDC's normalized masks), so an edit or
//!   a re-encode that shifts bytes keeps the unchanged chunks' ids.
//! - [`seal`]: a chunk sealed with ChaCha20-Poly1305 under the pair's seal key. Opening checks the id
//!   again, so a cache, a relay or a disk that returns other bytes is caught.
//! - [`Manifest`]: a bundle's chunk list and root id, in a compact binary form.
//! - [`sync`]: the have/want exchange, sans-io: the sender offers the manifest, the receiver answers
//!   with a bitmap of the chunks it lacks, and only those cross. A bundle the far end already holds
//!   costs one round trip and no chunk bytes.
//! - [`store`]: where sealed chunks live (memory, a directory); a store only ever holds ciphertext.
//!
//! Every wire form starts with a version byte; a decoder refuses a version it does not know with
//! [`Error::Version`], which callers turn into today's plain transfer.

pub mod cdc;
mod error;
mod key;
mod manifest;
pub mod seal;
pub mod store;
pub mod sync;

pub use error::{Error, Result};
pub use key::{ChunkId, PairKey, hex, unhex};
pub use manifest::{ChunkRef, Kind, Manifest};

/// The capability a peer advertises when it speaks this crate's wire forms (version 1).
pub const CAPABILITY: &str = "bundle-v1";
