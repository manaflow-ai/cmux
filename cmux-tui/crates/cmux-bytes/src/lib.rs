//! The cloud bytes path: how a folder's bytes cross to a machine.
//!
//! - [`classify`] names a file's content kind from its name and first bytes,
//!   so already-compressed data is never compressed again.
//! - [`entropy`] samples a chunk's byte entropy, so incompressible data is
//!   stored without spending a compressor pass on it.
//! - [`cdc`] cuts content-defined chunks; [`cas`] names them by BLAKE3 so a
//!   chunk the receiver (the VM or a cache) already holds is never sent.
//! - [`policy`] picks a codec per chunk: store, or zstd at a level chosen
//!   from link speed and CPU, with a per-kind dictionary when one is trained.
//! - [`frame`] encodes a chunk so its wire size is never more than its raw
//!   size plus a fixed header ([`frame::MAX_OVERHEAD`]): a payload never grows.
//! - [`order`] orders a folder's files for the background fill: manifest,
//!   then hot files, then the rest.
//! - [`serial`] picks the zstd level where a page is compressed, then sent, then the next
//!   (session move's history pages): per kind of data, calibrated on the run.
//! - [`lanes`] schedules frames across priority lanes (manifest, faulted
//!   reads, hot files, background fill).
//! - [`prefetch`] ranks what a chat could read (likelihood per byte), plans it over idle
//!   bandwidth on the fill lane, and measures the first-turn hit rate and bytes held unread.

pub mod cas;
pub mod cdc;
pub mod classify;
pub mod dict;
pub mod entropy;
pub mod frame;
pub mod harness;
pub mod lanes;
pub mod order;
pub mod params;
pub mod policy;
pub mod prefetch;
pub mod serial;

pub use frame::{Encoding, decode, encode};
pub use params::Params;
pub use policy::{Link, Plan, plan_chunk};
