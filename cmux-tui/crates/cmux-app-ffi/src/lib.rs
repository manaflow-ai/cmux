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

pub use cmux_layout_reducer_ffi as layout_reducer;
pub use cmux_rd_ffi as rd;
