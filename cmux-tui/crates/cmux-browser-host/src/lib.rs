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
pub mod cookie_backups;
pub mod driver;
pub mod egress_proxy;
pub mod egress_scope;
pub mod engines;
pub mod fs_sandbox;
pub mod gate;
#[cfg(unix)]
pub mod headless_activity;
#[cfg(unix)]
pub mod headless_configure;
#[cfg(unix)]
pub mod headless_routes;
#[cfg(unix)]
pub mod headless_source;
pub mod host;
pub mod idle_exit;
pub mod lease;
pub mod locality;
pub mod observe;
pub mod policy;
pub mod private_data_log;
pub mod protocol;
pub mod provider;
#[cfg(unix)]
pub mod provider_engine;
#[cfg(unix)]
pub mod provider_link;
#[cfg(unix)]
pub mod provider_source;
pub mod secrets;
#[cfg(unix)]
pub mod server;
pub mod tab_source;
pub mod vm;
