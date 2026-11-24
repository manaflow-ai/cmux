//! Every window's last computed layout, kept across restarts so a launch draws the windows
//! already placed instead of recomputing positions and settling. Frames, the split tree and its
//! fractions, the tab strip, the sidebar's width and measured row heights, scroll anchors, the
//! terminal grid, the theme and each pane's last picture. The app measures and draws; every
//! decision is here: what is stored (`model`), how it is read and written and when
//! (`store`), which parts this launch may apply (`usable`), how the cache fits what the daemon
//! says exists without moving survivors (`reconcile`), how much a layout jumped (`shift_score`),
//! and how long the real window waits under stage 0 (`swap`). The C ABI is `ffi`
//! (include/cmux_layout_cache.h).

pub mod ffi;
pub mod model;
pub mod reconcile;
pub mod store;
pub mod swap;
pub mod usable;

pub use model::*;
pub use reconcile::{
    Applied, IdRect, LiveNode, LiveTree, Moved, Transition, TransitionKind, reconcile,
    reconcile_rows, reconcile_strip, shift_score,
};
pub use store::{WriteCoalescer, cache_path, read, write};
pub use swap::{ShellKind, swap_wait_ms};
pub use usable::{NowState, Usable, usable};
