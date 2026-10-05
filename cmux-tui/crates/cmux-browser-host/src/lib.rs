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

pub mod automation_input;
pub mod cdp;
pub mod driver;
pub mod engines;
pub mod fs_sandbox;
pub mod gate;
pub mod host;
pub mod lease;
pub mod observe;
pub mod policy;
pub mod protocol;
pub mod provider;
#[cfg(unix)]
pub mod provider_engine;
#[cfg(unix)]
pub mod provider_link;
pub mod secrets;
#[cfg(unix)]
pub mod server;
pub mod vm;
