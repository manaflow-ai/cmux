//! `cas/1`: cmux's content-addressed bulk bytes (cmuxterm-hq RFD 0166, "Our own CDN", and its
//! techniques page section 3). It is Braid's (RFD 0164) content-addressed bulk class, not a
//! second transport: the messages ride any byte stream.
//!
//! - **Ids** ([`id`]): `BLAKE3(bytes)` for public artifacts, where global dedup is fine, and
//!   `BLAKE3_keyed(pair or team key, bytes)` for private data, so two users' equal bytes never
//!   share an id ([`IdScheme`]).
//! - **Chunks** ([`cdc`]): FastCDC, 16 KiB minimum, 64 KiB average, 256 KiB maximum, cut per
//!   file so no chunk spans two files. An edit in the middle of an archive moves only the
//!   chunks around it.
//! - **Store** ([`store`]): a chunk is kept zstd-compressed, or raw when zstd gains nothing, in
//!   memory ([`MemStore`]) or on disk ([`DiskStore`], `chunks/<aa>/<id>`). The chunk file format,
//!   the layout and the atomic write are the ones `cmux-session-pack` already used; that crate's
//!   store is now built on this one.
//! - **Verification**: per chunk. A received chunk is hashed whole and kept only under the id it
//!   hashes to, so a lying peer costs at most one chunk (256 KiB) before it is dropped. Bao
//!   (a 16 KiB group outboard) is not vendored in this workspace; a later version adds it to
//!   `DATA` as a field a version 1 peer ignores.
//! - **Trust** ([`manifest`], [`pointer`]): a root [`Manifest`] per artifact, named by
//!   `BLAKE3(manifest bytes)`, and a [`Pointer`] per channel inside a `cmux-signed-envelope`.
//! - **Messages** ([`wire`]): `HAVE`, `WANT`, `DATA`, `NOPE`, each carrying its version. Fields
//!   are tagged, so a newer peer adds fields an older one skips, and a message kind a peer does
//!   not know is answered with `NOPE` naming that kind ([`peer::respond`]): the two ends of a
//!   link can be upgraded in either order and still talk (lockstep).

pub mod cdc;
pub mod id;
pub mod manifest;
pub mod peer;
pub mod pointer;
pub mod store;
pub mod wire;

pub use cdc::{Chunker, Params};
pub use id::{Id, IdScheme, hex, unhex};
pub use manifest::{Entry, Manifest};
pub use peer::{accept, respond, want};
pub use pointer::Pointer;
pub use store::{ChunkStore, DiskStore, MemStore, decode_chunk, encode_chunk, write_atomic};
pub use wire::{Frame, Message, VERSION};

/// This crate's error: a message that says what was read or written and what was wrong with it.
pub type Error = Box<dyn std::error::Error + Send + Sync>;
/// `Result` with [`Error`].
pub type Result<T> = std::result::Result<T, Error>;
