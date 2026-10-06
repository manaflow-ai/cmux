//! Chromium over CDP behind the driver protocol.
//!
//! [`CdpDriver`] maps driver protocol methods to CDP. It runs on any
//! [`CdpConnection`]: [`pipe::HeadlessChromium`] for headless Chromium, and
//! (step c) the provider relay for in-app CEF tabs.

mod browser_pages;
mod capture;
mod connection;
mod cookies;
mod cors;
mod downloads;
mod driver;
mod evaluate;
mod fetch;
mod fetch_runs;
mod input;
pub mod keys;
mod navigation;
mod network;
mod pdf;
#[cfg(unix)]
pub mod pipe;
mod requests;
mod state;

pub use connection::{CdpConnection, CdpEvent, CdpEventHandler, CdpWire, protocol_error};
pub use driver::CdpDriver;
pub use state::{AGENT_WORLD, HOST_WORLD};
