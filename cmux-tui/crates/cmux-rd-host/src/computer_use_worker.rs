//! `cmux-screen-sharing __computer-use-worker`: cmux Computer Use's worker on a Mac whose cmux
//! build embeds no cmux Remote (Release and NIGHTLY). The cmux-tui daemon starts this helper's
//! verified copy with macOS responsibility disclaimed (cmux-tui-core `computer_use_host/macos.rs`),
//! so the Accessibility and Screen Recording grants Computer Use needs are the Screen Sharing
//! helper's, the one app that holds them. Hidden: people and agents never run it.
//!
//! Its stdin and stdout are the daemon's control channel (`cmux_computer_use::worker`, the same
//! protocol as the Linux and Windows `cmux-tui __computer-use-worker`); it serves the agent socket
//! until stdin closes.

use std::sync::Arc;

use cmux_computer_use::desktop::HostServices;
use cmux_computer_use::platform::macos::MacDesktop;
use cmux_computer_use::worker::{self, Platform};

/// The hidden mode word (cmux-tui-core `computer_use_host::WORKER_MODE`).
pub const MODE: &str = "__computer-use-worker";

/// Runs the worker on stdin and stdout; the process exit code.
pub fn run(args: &[String]) -> i32 {
    if !args.is_empty() {
        eprintln!("usage: cmux-screen-sharing {MODE}");
        return 2;
    }
    // The ScreenCaptureKit capture this helper already runs, as the desktop's HostServices
    // (src/mac/cu_host.rs); None falls back to the engine's CoreGraphics capture.
    let host: Option<Arc<dyn HostServices>> = crate::computer_use_host_services();
    run_with(host)
}

/// [`run`] with the desktop's host services given (the helper's own screen capture). AppKit
/// runs on the main thread for the agent cursor (`macos::run_with_app`); the worker runs on its
/// own thread, and its code comes back here when it ends.
pub fn run_with(host: Option<Arc<dyn HostServices>>) -> i32 {
    cmux_computer_use::platform::macos::run_with_app(move || {
        worker::run(
            std::io::BufReader::new(std::io::stdin()),
            std::io::stdout(),
            move || Ok(platform(host)),
            worker::ASK_TIMEOUT,
        )
    })
}

/// The Mac desktop over `host`, with the agent cursor (`macos/overlay.rs`) and the takeover
/// watch (`macos/idle.rs`, the person's HID input).
fn platform(host: Option<Arc<dyn HostServices>>) -> Platform {
    Platform {
        desktop: Arc::new(MacDesktop::new(host)),
        cursor: cmux_computer_use::platform::cursor_overlay(),
        takeover: cmux_computer_use::platform::person_activity(),
    }
}

#[cfg(test)]
#[path = "computer_use_worker_tests.rs"]
mod tests;
