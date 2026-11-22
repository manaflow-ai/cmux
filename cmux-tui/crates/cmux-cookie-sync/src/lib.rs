//! Keeps the cmux browser's imported cookies in step with a Chromium-family
//! browser on the same Mac, asked over the app FFI
//! (`include/cmux_cookie_sync.h`, Swift module `CCmuxCookieSyncFFI`, linked
//! through cmux-app-ffi).
//!
//! After the app imports a profile's cookies, it starts a sync on that
//! profile's `Cookies` database. One thread watches the database's
//! directory, reads a private copy after the browser commits, and tells the
//! app which cookie domains changed since the last import; the app
//! re-imports those domains with its own importer (decryption and the
//! browser engine write stay there) and commits. Nothing here decrypts a
//! value, keeps one, or sends anything anywhere: the fingerprint is a hash
//! per host.
//!
//! - [`fingerprint`]: a database's per-host hashes (access times excluded);
//! - [`diff`]: the domains that differ between two fingerprints;
//! - [`baseline`]: the last imported fingerprint, saved per source;
//! - [`schedule`]: the debounce and minimum interval, on an injected clock;
//! - [`engine`]: what a scan reports, and the watching thread (`watch`:
//!   kqueue on macOS, notify elsewhere);
//! - [`ffi`]: the C ABI.

pub mod baseline;
pub mod diff;
pub mod engine;
pub mod ffi;
pub mod fingerprint;
mod hash;
pub mod schedule;
mod watch;

pub use diff::{Diff, diff};
pub use engine::{Config, CookieSync, Core, Cost, Reason, Report, Source};
pub use fingerprint::{Fingerprint, Scan, ScanError, fingerprint};
pub use schedule::Scheduler;
