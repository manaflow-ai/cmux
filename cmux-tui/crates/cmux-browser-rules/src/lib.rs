//! The browser pane's rules, moved out of the cmux macOS app's Swift (cmuxterm-hq
//! `docs/rfd/drafts/why-swift.md`, row "Browser pane hosting": Swift embeds CEF and WebKit, Rust
//! holds the tab, profile, history, link placement and automation rules).
//!
//! Pure but for whether a path exists ([`terminal_links`]): the app reports the facts and applies
//! the result. It reaches the rules through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops in [`ops`]).
//!
//! - [`address`]: rules for a typed address: the IANA top-level domains, the mistyped
//!   top-level domain fix (`HostTypoFixup`) and which failures of an https upgrade load the address
//!   over http (`HTTPSUpgradeFallback`).
//! - [`calculator`]: the omnibox calculator row's arithmetic and its answer text
//!   (`OmniboxCalculator`).
//! - [`links`]: what a link click does (the gesture of a click, the person's
//!   `browser.links.*` mapping), where Chromium's link requests go (`CEFLinkClicks`) and the one
//!   decision for every window Chromium wants to open (`CEFWindowPolicy`).
//! - [`terminal_links`]: where a Cmd-clicked terminal link goes (`TerminalLinkResolver`): the
//!   text trimmed, its `:line:col`, a path that exists or a web host. The one module that reads
//!   the file system (whether a path exists).

pub mod address;
pub mod calculator;
pub mod links;
pub mod ops;
pub mod terminal_links;

#[cfg(test)]
mod address_tests;
#[cfg(test)]
mod calculator_tests;
#[cfg(test)]
mod links_tests;
#[cfg(test)]
mod terminal_links_tests;
