//! The browser pane's rules, moved out of the cmux macOS app's Swift (cmuxterm-hq
//! `docs/rfd/drafts/why-swift.md`, row "Browser pane hosting": Swift embeds CEF and WebKit, Rust
//! holds the tab, profile, history, link placement and automation rules).
//!
//! Pure: the app reports the facts and applies the result. It reaches the rules through the app
//! FFI's JSON channel (cmux-layout-reducer-ffi `cmux_layout_reducer_json`, ops in [`ops`]).
//!
//! - [`address`]: rules for a typed address: the IANA top-level domains, the mistyped
//!   top-level domain fix (`HostTypoFixup`) and which failures of an https upgrade load the address
//!   over http (`HTTPSUpgradeFallback`).
//! - [`calculator`]: the omnibox calculator row's arithmetic and its answer text
//!   (`OmniboxCalculator`).
//! - [`links`]: what a link click does (the gesture of a click, the person's
//!   `browser.links.*` mapping), where Chromium's link requests go (`CEFLinkClicks`) and the one
//!   decision for every window Chromium wants to open (`CEFWindowPolicy`).
//! - [`profiles`]: browser profiles: which profile a new tab gets (`BrowserProfileCascade`), the
//!   profile ids, records and book (naming, ordering, validation, deletion tombstones), a
//!   profile's proxy as the engines take it, the deleted profiles' cleanup and the off-the-record
//!   profiles' lifetime (`OffTheRecordProfiles`).

pub mod address;
pub mod calculator;
pub mod links;
pub mod ops;
pub mod profiles;

#[cfg(test)]
mod address_tests;
#[cfg(test)]
mod calculator_tests;
#[cfg(test)]
mod links_tests;
#[cfg(test)]
mod profiles_tests;
