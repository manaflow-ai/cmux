//! Reads another browser's data for cmux NEXT's browser import. The daemon serves it as
//! `browser_import.read` (`browser-import-v1`, cmux-tui-core's `resource_router/browser_import.rs`),
//! which only the verified app connection may send.
//!
//! It ports the Swift readers in
//! `Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Parsers/`, rule for rule
//! (`PORT.md` maps each Swift file to its function here); the app switches to it, and those are
//! deleted, in a later step:
//!
//! - [`chromium`]: `Bookmarks`, `History`, the open tabs of a session file (an SNSS command log
//!   of [`pickle`] payloads), the default search engine and the Web Store extensions;
//! - [`arc`]: Arc's `StorableSidebar.json` (Favorites and each space's pinned tabs);
//! - [`firefox`]: `places.sqlite` bookmarks and history, the mozLz4 ([`lz4`]) session store and
//!   `search.json.mozlz4`;
//! - [`safari`]: `Bookmarks.plist`, `History.db` and the Search setting;
//! - [`exported`]: history a browser exports as JSON (Safari, Google Takeout);
//! - [`search`]: a search engine's template cleanup, host and built-in mapping;
//! - [`sqlite`]: the private, read-only copy every database on disk is read from, and the
//!   in-memory open (WAL replayed) of one the app sent;
//! - [`place`] and [`upload`]: a file on disk or in the bytes the app sent from a folder macOS
//!   protects, held in memory and never written to disk;
//! - [`ops`]: the readers `browser_import.read` names, and the folders it refuses ([`ops::protected`]).
//!
//! The app keeps what must stay native: the folder grants, every Keychain read and reading the
//! bytes of a folder macOS protects (Safari's, an app container's), which it sends in memory.
//! Nothing here fetches a Keychain item or writes a source file. Results carry dates as seconds
//! since 2001-01-01 (Foundation's `Date` encoding) and URLs as the source's text, so the app
//! decodes them with its own `Codable` types and `URL(string:)`.

pub mod arc;
pub mod chromium;
pub mod exported;
pub mod firefox;
mod json;
pub mod lz4;
pub mod model;
pub mod ops;
pub mod pickle;
pub mod place;
pub mod safari;
pub mod search;
pub mod sqlite;
pub mod time;
pub mod upload;
pub mod url;

pub use model::{Bookmark, Extension, HistoryEntry, ReadError, SearchEngine, Tab};
