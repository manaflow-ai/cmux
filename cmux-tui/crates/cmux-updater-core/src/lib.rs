//! The app updater's decisions, moved out of the Mac app's Swift (CmuxNextUpdater) so every
//! platform's updater asks the same rules and only the installer stays native (cmuxterm-hq
//! docs/rfd/drafts/why-swift.md, "Sparkle and updates": "Rust for appcast, channel, version and
//! watchdog; Swift only installs and relaunches").
//!
//! - [`version`]: Sparkle 2.10's `SUStandardVersionComparator`, the order of `CFBundleVersion`s.
//! - [`system_version`]: a macOS version such as `26.0` (`sparkle:minimumSystemVersion`).
//! - [`appcast`]: the items of a Sparkle appcast, as the app's `XMLParser` read them.
//! - [`select`]: what a feed offers this Mac: the newest item its macOS can run.
//! - [`numeric`]: the numeric order of kept builds and channel tracks.
//! - [`rollback`]: which kept build a rollback goes to, and where a slower ring sends this Mac.
//! - [`ops`]: the JSON requests the app sends over the app FFI (`updater_*`).
//!
//! No I/O: the app fetches the feed and passes its bytes.

pub mod appcast;
pub mod numeric;
pub mod ops;
pub mod rollback;
pub mod select;
pub mod system_version;
pub mod version;
