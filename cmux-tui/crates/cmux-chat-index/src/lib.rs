//! Device-wide chat index: read-only adapters for each harness's session store.
//!
//! Each adapter turns one store root into [`ChatEntry`] rows: metadata only
//! (id, title, folder, times, message count, source path). Transcripts stay
//! where the harness wrote them; nothing here writes into a harness store.
//! acpmux owns root discovery, the merged index, the watcher and the RPC.

mod adapters;
mod entry;
mod lines;
mod scan;
mod sqlite;
mod stamp;
mod text;
mod time;

pub use entry::{AdapterKind, ChatEntry, ChatKey, Resume, TitleSource};
pub use scan::{AdapterConfig, FileRead, RootScan, read_file, scan_root};
pub use stamp::{Change, FileStamp, FileState, Tally};
pub use text::title_line;
pub use time::parse_rfc3339_ms;
