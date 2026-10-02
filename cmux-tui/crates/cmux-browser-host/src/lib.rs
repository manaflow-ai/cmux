//! cmux browser host: the engine-neutral side of agent browser use.
//!
//! Design: `plans/cmux-next/browser-host.md`. The host runs REPL sessions,
//! enforces policy and secrets below the agent's JS VM, and talks to engines
//! through drivers that all speak the driver protocol of PR #15570
//! (`docs/browser-repl/driver-protocol.md`):
//!
//! - [`cdp::CdpDriver`]: Chromium over CDP, for headless Chromium on a pipe
//!   and (later) for in-app CEF tabs relayed over the provider connection.
//! - WebKit tabs are driven by the Swift driver in the app; the host reaches
//!   it through [`provider`] frames.

pub mod cdp;
pub mod driver;
pub mod protocol;
pub mod provider;
