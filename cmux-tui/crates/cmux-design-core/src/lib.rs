//! The design system's rules (RFD why-swift, "Design system" row): what the macOS app's
//! CmuxNextDesign and CmuxNextDesignTokens decided in Swift, moved here so Linux and Windows
//! shells get the same answers. The app keeps the drawing (AppKit views, panels, layers).
//!
//! One module per sub-area. Each answers JSON ops named `AREA.NAME` through [`ops::call`],
//! which the C ABI ([`ffi`], `include/cmux_design.h`, Swift module `CCmuxDesignFFI`)
//! exposes as `cmux_design_call`. A per-frame rule that cannot afford JSON gets a typed
//! function in [`ffi`] instead, next to its module's op.

pub mod dialog;
pub mod ffi;
pub mod hover;
pub mod launch;
pub mod menu;
pub mod motion;
pub mod ops;
pub mod overlay;
pub mod toast;
pub mod tokens;
pub mod wallpaper;
pub mod window;
