//! Synchronous Chrome DevTools Protocol support for cmux-mux.
//!
//! This crate intentionally stays on `std::thread`, `std::sync::mpsc`,
//! and blocking sockets. The mux runtime is synchronous, and browser
//! panes can be rendered locally or mirrored to attach clients by mux-core.

mod chrome;
mod client;

pub use chrome::{default_user_data_dir, find_chrome_binary, Chrome, ChromeLaunchOptions};
pub use client::{
    discover_browser_ws_url, resolve_browser_ws_url, CdpClient, CdpEvent, CdpKeyEvent,
    NavigationEntry, NavigationHistory, ScreencastFrame, TargetCreated, TargetInfo,
};
