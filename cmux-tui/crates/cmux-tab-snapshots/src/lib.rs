//! The `tabs` link service, sans-I/O: what the Mac sends so the phone's tab
//! overview shows every card's title, favicon, thumbnail or terminal screen.
//!
//! - [`wire`]: the frames (1-byte kind, then a JSON or binary body).
//! - [`row`]: the manifest row and the partial row a delta carries.
//! - [`store`]: the Mac's content-addressed blob store (sha256, dedupe).
//! - [`producer`]: the Mac's tab state; bumps `rev` only on real change and
//!   answers `resume {rev}` with one delta from a bounded history.
//! - [`session`]: one per connected phone; a pull API that yields the next
//!   frame to write, so the host applies backpressure.
//! - [`mirror`]: a reference phone side used by tests and the bench.
//! - [`stream`]: frames behind their length, for a link channel's byte stream.
//!
//! No socket, thread or clock is used here. Times are passed in by the host.

pub mod hash;
pub mod mirror;
pub mod producer;
pub mod row;
pub mod session;
pub mod store;
pub mod stream;
pub mod wire;

pub use hash::{BlobHash, Mime};
pub use mirror::{Applied, Mirror, MirrorError};
pub use producer::{FaviconInput, ImageInput, Observation, Producer, ScreenInput};
pub use row::{Kind, Row, RowPatch};
pub use session::{RowFilter, Session, SessionError, SessionStats};
pub use store::{BlobStore, StoreStats, StoredBlob};
pub use stream::{Deframer, TooLong, length_prefixed};
pub use wire::{BlobFrame, Delta, Manifest, Message, Resume, Viewport, WireError};
