//! cmux Computer Use: the engine agents reach through the cmux Remote
//! Computer Use worker, and the desktops it drives on macOS, Windows and
//! Linux (docs/computer-use/README.md).
//!
//! The split:
//!
//! - [`tools`]: the one tool catalog. acpmux serves it to agents even while
//!   the worker restarts, so `tools/list` never depends on the worker.
//! - [`policy`]: modes, the deny list and saved approvals. One decision
//!   function for every route (local agent, CLI, remote machine).
//! - [`engine`]: runs a call: policy, the person's takeover, the cursor, the
//!   desktop, then the frame pipeline. Calls carry a `call_id`, so a call the
//!   bridge retries after a reconnect never runs twice.
//! - [`desktop`]: the platform trait. Every input is window-scoped and
//!   background-first: no app is activated, the real pointer never moves, and
//!   a route that cannot prove its target refuses instead of guessing.
//! - [`menus`]: whether a background call may open an app's menu, item
//!   matching, and the deny list inside menus.
//! - [`frame`]: redaction of denied windows, downscale, change detection and
//!   PNG encoding, the same on every platform.
//! - [`platform`]: the macOS, Windows and Linux (X11, Wayland, headless)
//!   desktops, behind the `desktop` feature.

pub mod cursor;
pub mod desktop;
pub mod engine;
pub mod frame;
pub mod keys;
pub mod menus;
pub mod policy;
pub mod session;
pub mod tools;
pub mod wire;

#[cfg(feature = "desktop")]
pub mod platform;
#[cfg(feature = "server")]
pub mod server;
#[cfg(feature = "server")]
pub mod worker;

pub use desktop::{Desktop, DesktopError};
pub use engine::{CallContext, Engine, Origin, ToolOutput};
pub use policy::{Mode, PolicyConfig};
