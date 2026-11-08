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
//! `sdk` is the daemon client the `cmux` CLI uses (the cmux SDK), as a C ABI
//! (cmux-sdk-ffi, include/cmux_sdk_ffi.h): the app reaches the daemon through it.
//! `terminal_prediction` is predictive local echo for a terminal whose shell runs
//! on another machine (cmux-terminal-prediction, include/cmux_terminal_prediction.h).

pub mod hover;
pub mod motion;
pub mod terminal_selection;

pub use cmux_action_catalog::ffi as action_catalog;
pub use cmux_agent_pane_policy::ffi as agent_pane_policy;
pub use cmux_cookie_sync::ffi as cookie_sync;
pub use cmux_daemon_conn_core::ffi as daemon_conn;
pub use cmux_daemon_launch_core::ffi as daemon_launch;
pub use cmux_layout_reducer_ffi as layout_reducer;
pub use cmux_palette_ranker::ffi as palette_ranker;
pub use cmux_rd_ffi as rd;
pub use cmux_sdk_ffi as sdk;
pub use cmux_terminal_prediction::ffi as terminal_prediction;
