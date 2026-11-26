//! The one Rust static library of the cmux macOS app.
//!
//! Every Rust static library carries its own copy of the Rust runtime and its
//! own `rust_eh_personality`. The app also links C++ and the iroh library,
//! and Apple's compact unwind encodes at most three personality routines per
//! image, so a third separate Rust library breaks the link ("Too many
//! personality routines"). The app's in-tree C ABIs therefore ship as one
//! archive: this crate links their crates, whose `#[unsafe(no_mangle)]`
//! functions are the archive's exported symbols, over one Rust runtime.
//! Add a new in-tree C ABI here, never as another static library.
//! `motion` is cmux-motion's C ABI (the spring step and motion tokens);
//! `goo` is its gooey tabs' C ABI (the blob outline, event plans and the
//! drag neck; plans/cmux-next/gooey-tabs.md).
//! `hover` is its hover rules' C ABI (the hover card machine, tooltip hover
//! intent, the safe triangle and the row card's placement).
//! `terminal_selection` is its terminal selection rule's C ABI (Option-drag
//! selects text while a program has the mouse, and the first-use hint).
//! `agent_pane_policy` is the agent pane's relay policy (one check per page
//! frame, include/cmux_agent_pane_policy.h).
//! `action_catalog` is cmux NEXT's action catalog as JSON in the app's language
//! (include/cmux_action_catalog.h), read once at launch.
//! `cookie_sync` tells the app which imported Chrome cookie domains changed
//! (cmux-cookie-sync, include/cmux_cookie_sync.h).
//! `daemon_conn` is the control connection's rules (cmux-daemon-conn-core,
//! include/cmux_daemon_conn.h).
//! `daemon_launch` is how the app starts and keeps its cmux-tui daemon
//! (include/cmux_daemon_launch.h).
//! `health` is the app health model: which part is stuck, its repairs and the
//! status indicator's snapshot (cmux-health-core, include/cmux_health.h).
//! `launch_image` is each window's last committed frame for the launch's first
//! frame (cmux-launch-image, include/cmux_launch_image.h).
//! `pane_pictures` is when a pane's live thumbnail is captured again (cmux-pane-pictures,
//! include/cmux_pane_pictures.h).
//! `screenshots` is the Screenshots pane's rules: what a source lists, the newest-first listing,
//! the sources and where tools save, the page address and the gate (cmux-screenshots,
//! include/cmux_screenshots.h).
//! `sdk` is the daemon client the `cmux` CLI uses (the cmux SDK), as a C ABI
//! (cmux-sdk-ffi, include/cmux_sdk_ffi.h): the app reaches the daemon through it.
//! `terminal_prediction` is predictive local echo for a terminal whose shell runs
//! on another machine (cmux-terminal-prediction, include/cmux_terminal_prediction.h).
//! `url_input` is the typed address-bar policy: what the omnibox, the New Tab
//! field and newTab.submit load or search (cmux-url-input, include/cmux_url_input.h).

//! `keymap` is the keymap layer of app.keyStyle and app.shortcutLayout: list keys
//! per style and shortcut matching per layout (cmux-keymap, include/cmux_keymap.h).
//! `wallpaper` is cmux-wallpaper's C ABI: live wallpapers (the program check and
//! its Metal translation, the scheduler, the Frame packer; include/cmux_wallpaper_ffi.h).
//! `files_lister` is the client of cmux-tui's `__files-lister` child, the DEV
//! build's Files pane reader (include/cmux_files_lister.h).
//! `system_calendar` is the `system_calendar.*` app ops' params, window and
//! answer (include/cmux_system_calendar.h); EventKit stays in the app.
//! `settings` is cmux-next.json's reads (cmux-config's app_ops: the parse,
//! the validation and the defaults; include/cmux_settings.h).
//! `interactivity` is priority by interactivity (cmux-interactivity, include/cmux_interactivity.h): note what the
//! person touches, read the QoS of a class of work.
//! `layout_cache` is every window's last computed layout kept across restarts, so a launch
//! draws it already placed (cmux-layout-cache, include/cmux_layout_cache.h).
//! `agent_client` is the no-I/O agent list client (acpmux-client,
//! include/acpmux_client.h); the app owns and drives its byte connection.
//! `updater` is the macOS app updater's decisions, as JSON ops (the install
//! gate over Sparkle's flow first; include/cmux_updater.h).

/// cbindgen:ignore
pub mod files_lister;
pub mod goo;
pub mod hover;
/// cbindgen:ignore
pub mod interactivity;
pub mod motion;
/// cbindgen:ignore
pub mod settings;
/// cbindgen:ignore
pub mod system_calendar;
pub mod terminal_selection;
/// cbindgen:ignore
pub mod updater;
/// cbindgen:ignore
/// Live wallpapers: its own header (include/cmux_wallpaper_ffi.h, cbindgen-wallpaper.toml),
/// so it stays out of cmux_motion_ffi.h.
pub mod wallpaper;

pub use acpmux_client::ffi as agent_client;
pub use cmux_action_catalog::ffi as action_catalog;
pub use cmux_agent_pane_policy::ffi as agent_pane_policy;
pub use cmux_cookie_sync::ffi as cookie_sync;
pub use cmux_daemon_conn_core::ffi as daemon_conn;
pub use cmux_daemon_launch_core::ffi as daemon_launch;
pub use cmux_health_core::ffi as health;
pub use cmux_keymap::ffi as keymap;
pub use cmux_launch_image::ffi as launch_image;
pub use cmux_launch_record;
pub use cmux_launch_shell::ffi as launch_shell;
pub use cmux_layout_cache::ffi as layout_cache;
pub use cmux_layout_reducer_ffi as layout_reducer;
pub use cmux_palette_ranker::ffi as palette_ranker;
pub use cmux_pane_pictures::ffi as pane_pictures;
pub use cmux_rd_ffi as rd;
pub use cmux_screenshots::ffi as screenshots;
pub use cmux_sdk_ffi as sdk;
pub use cmux_terminal_prediction::ffi as terminal_prediction;
pub use cmux_url_input::ffi as url_input;
