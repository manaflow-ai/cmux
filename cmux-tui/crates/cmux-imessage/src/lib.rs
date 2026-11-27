//! Read-only reader of the macOS Messages database (`~/Library/Messages/chat.db`) for cmux's
//! opt-in Messages mirror.
//!
//! The mirror is off by default and nothing it reads leaves the Mac. This crate only reads: it
//! opens the database with `SQLITE_OPEN_READ_ONLY`, never writes, and never takes a write lock, so
//! Messages.app keeps owning the file. Reading the file needs Full Disk Access for the process
//! that opens it; without it [`Reader::open`] returns [`MirrorError::NotPermitted`] so the UI can
//! ask for the grant.
//!
//! Shapes:
//! - [`Reader::threads`]: conversations (1:1 and group chats), newest activity first.
//! - [`Reader::messages`]: one conversation's messages, oldest first, paged backwards by rowid.
//! - [`Reader::since`]: messages newer than a rowid watermark, for live updates.
//! - [`send::send`]: sends a message to an existing chat through Messages.app (Automation).

mod date;
mod error;
mod model;
mod reader;
pub mod send;
mod typedstream;

pub use date::apple_to_unix_ms;
pub use error::MirrorError;
pub use model::{Attachment, Message, Thread, ThreadPreview};
pub use reader::{Reader, default_database_path};
pub use typedstream::decode_attributed_body;
