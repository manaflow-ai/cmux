//! Synchronous Chrome DevTools Protocol support for cmux-tui.
//!
//! This crate intentionally stays on `std::thread`, `std::sync::mpsc`,
//! and blocking sockets. The mux runtime is synchronous, and browser
//! panes can be rendered locally or mirrored to attach clients by cmux-tui-core.
//!
//! It launches no browser. cmux-tui-core attaches browser surfaces to a
//! cmux-browser provider or to an explicit development endpoint, so no cmux
//! process opens a loopback DevTools port (a page on a Cloud machine could
//! read one; cx-2u5k). The smoke test launches its own Chrome.

// The crash ratchet keeps this crate at zero production panics
// (plans/cmux-next/crash-elimination.md section 6).
#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::unreachable,
        clippy::todo,
        clippy::unimplemented,
        clippy::exit
    )
)]

mod client;

pub use client::{
    CDP_CONNECTION_UNAVAILABLE_MESSAGE, CDP_EVENT_QUEUE_CAPACITY, CDP_EVENT_QUEUE_MAX_BYTES,
    CapturedFrame, CdpClient, CdpEvent, CdpKeyEvent, FrameEpoch, NavigationEntry,
    NavigationHistory, ScreencastFrame, TargetCreated, TargetInfo, discover_browser_ws_url,
    event_retained_bytes, is_connection_unavailable, resolve_browser_ws_url,
};
