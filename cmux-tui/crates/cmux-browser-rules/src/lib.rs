//! The browser pane's rules, moved out of the cmux macOS app's Swift (cmuxterm-hq
//! `docs/rfd/drafts/why-swift.md`, row "Browser pane hosting": Swift embeds CEF and WebKit, Rust
//! holds the tab, profile, history, link placement and automation rules).
//!
//! Pure: the app reports the facts and applies the result. It reaches the rules through the app
//! FFI's JSON channel (cmux-layout-reducer-ffi `cmux_layout_reducer_json`, ops in [`ops`]).
//!
//! - [`agent_url`]: the pages an agent-driven tab never loads, shows or scripts
//!   (`AgentURLPolicy`).
//! - [`address`]: rules for a typed address: the IANA top-level domains, the mistyped
//!   top-level domain fix (`HostTypoFixup`) and which failures of an https upgrade load the address
//!   over http (`HTTPSUpgradeFallback`).
//! - [`calculator`]: the omnibox calculator row's arithmetic and its answer text
//!   (`OmniboxCalculator`).
//! - [`download_policy`]: Chrome's automatic downloads rule, per site (`AutomaticDownloadPolicy`).
//! - [`links`]: what a link click does (the gesture of a click, the person's
//!   `browser.links.*` mapping), where Chromium's link requests go (`CEFLinkClicks`) and the one
//!   decision for every window Chromium wants to open (`CEFWindowPolicy`).
//! - [`tab_state`]: the tab state machine, the reducer from an engine's navigation events to
//!   the state the chrome renders (`BrowserTabStateMachine`).
//! - [`password_fill`]: when a tab fills saved passwords, and what it sends Chromium's switch
//!   (`PasswordFillPolicy`, `PasswordFillState`).
//! - [`url_filter`]: an organization's URL blocklist and allowlist in Chrome's filter format
//!   (`BrowserURLFilter`, `BrowserURLFilterRule`).

pub mod address;
pub mod agent_url;
pub mod calculator;
pub mod download_policy;
pub mod links;
pub mod ops;
pub mod password_fill;
pub mod tab_state;
pub mod url_filter;

#[cfg(test)]
mod address_tests;
#[cfg(test)]
mod agent_url_tests;
#[cfg(test)]
mod calculator_tests;
#[cfg(test)]
mod download_policy_tests;
#[cfg(test)]
mod links_tests;
#[cfg(test)]
mod password_fill_tests;
#[cfg(test)]
mod tab_state_tests;
#[cfg(test)]
mod url_filter_tests;
