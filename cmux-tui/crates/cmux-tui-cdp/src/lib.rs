//! Synchronous Chrome DevTools Protocol support for cmux-tui.
//!
//! This crate intentionally stays on `std::thread`, `std::sync::mpsc`,
//! and blocking sockets. The mux runtime is synchronous, and browser
//! panes can be rendered locally or mirrored to attach clients by cmux-tui-core.

mod chrome;
mod client;

pub use chrome::{BrowserMode, Chrome, ChromeLaunchOptions};
pub use client::{
    CdpClient, CdpEvent, CdpKeyEvent, NavigationEntry, NavigationHistory, ScreencastFrame,
    TargetCreated, TargetInfo, discover_browser_ws_url, resolve_browser_ws_url,
};
