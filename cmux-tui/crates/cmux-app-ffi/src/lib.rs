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
//! `agent_pane_policy` is the agent pane's relay policy (one check per page
//! frame, include/cmux_agent_pane_policy.h).

pub mod hover;
pub mod motion;

pub use cmux_agent_pane_policy::ffi as agent_pane_policy;
pub use cmux_layout_reducer_ffi as layout_reducer;
pub use cmux_palette_ranker::ffi as palette_ranker;
pub use cmux_rd_ffi as rd;
