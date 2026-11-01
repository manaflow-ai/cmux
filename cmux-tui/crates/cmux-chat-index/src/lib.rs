//! Device-wide chat index: read-only adapters for each harness's session store.
//!
//! Each adapter turns one store root into [`ChatEntry`] rows: metadata only
//! (id, title, folder, times, message count, source path). Transcripts stay
//! where the harness wrote them; nothing here writes into a harness store.
//! [`transcript`] reads one chat's turns on demand, never into the index.
//! acpmux owns root discovery, the merged index, the watcher and the RPC.

mod adapters;
mod entry;
mod index;
mod lines;
mod roots;
mod scan;
mod sqlite;
mod stamp;
mod store_file;
mod text;
pub mod time;
pub mod transcript;

#[doc(hidden)]
pub use adapters::forget_codex_reads;
pub use adapters::{PathRole, classify_path, find_opencode_session};
pub use entry::{AdapterKind, ChatEntry, ChatKey, Resume, TitleSource};
pub use index::{ChatChange, ChatIndex, IndexedChat};
pub use roots::{
    ChatRoot, Discovery, DiscoveryInput, Platform, RecordedRoots, RefusedRoot, RootSource,
    RootSpec, default_roots, discover, discover_on,
};
pub use scan::{AdapterConfig, FileRead, RootScan, read_file, scan_root};
pub use stamp::{Change, FileStamp, FileState, HeadPrint, Tally};
pub use text::{title_line, without_client_context};
pub use time::parse_rfc3339_ms;
