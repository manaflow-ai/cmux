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
//! - [`load_waits`], [`cookie_backups`], [`cookies`], [`tab_watcher`]: the browser automation's
//!   rules (`LoadWaits`, `CookieBackups`, the cookie calls of `WebKitDriver`, `TabWatcher`), ops in
//!   [`automation_ops`].
//! - [`driver`], [`frames`]: a driver call's params and deadline, where its new tab opens and a
//!   tab's frame tree (`DriverParams`, `CallDeadline`, `AutomationTabPlace`, `FrameTree`), ops in
//!   [`automation_ops`].
//! - [`links`]: what a link click does (the gesture of a click, the person's
//!   `browser.links.*` mapping), where Chromium's link requests go (`CEFLinkClicks`) and the one
//!   decision for every window Chromium wants to open (`CEFWindowPolicy`).
//! - [`tab_state`]: the tab state machine, the reducer from an engine's navigation events to
//!   the state the chrome renders (`BrowserTabStateMachine`).

pub mod address;
pub mod automation_ops;
pub mod calculator;
pub mod cookie_backups;
pub mod cookies;
pub mod driver;
pub mod frames;
pub mod links;
pub mod load_waits;
pub mod ops;
pub mod tab_state;
pub mod tab_watcher;

#[cfg(test)]
mod address_tests;
#[cfg(test)]
mod automation_tests;
#[cfg(test)]
mod calculator_tests;
#[cfg(test)]
mod cookie_backups_tests;
#[cfg(test)]
mod cookies_tests;
#[cfg(test)]
mod driver_tests;
#[cfg(test)]
mod frames_tests;
#[cfg(test)]
mod links_tests;
#[cfg(test)]
mod load_waits_tests;
#[cfg(test)]
mod tab_state_tests;
#[cfg(test)]
mod tab_watcher_tests;
