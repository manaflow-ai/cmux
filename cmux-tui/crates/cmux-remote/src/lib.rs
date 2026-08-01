//! Native remote runtime for cmux-tui.
//!
//! The `daemon-services` feature carries everything that only a host runs: the
//! workspace service, the service handlers built on it, and the local bridge.
//! It pulls in libghostty-vt for the server-side terminal model, which is a Zig
//! build. A client -- notably a mobile one -- needs none of that to dial a
//! daemon, so building without the feature leaves the carrier, the
//! authenticated session, and `WorkspaceClient` intact with no Zig toolchain in
//! the picture.

#[cfg(unix)]
pub mod admin;
#[cfg(feature = "daemon-services")]
pub mod bridge;
pub mod client;
pub mod connection;
pub mod crypto;
pub mod daemon;
pub mod http;
pub mod identity;
pub mod link;
pub mod message;
// The mux attach path belongs to the daemon. A client-only build keeps the
// error types these expose through `ServicesError` but reaches none of the
// codec itself.
#[cfg_attr(not(feature = "daemon-services"), allow(dead_code))]
mod mux_codec;
#[cfg_attr(not(feature = "daemon-services"), allow(dead_code))]
mod mux_input;
#[cfg_attr(not(feature = "daemon-services"), allow(dead_code))]
mod mux_lanes;
pub mod observability;
pub mod provider;
pub mod service;
#[cfg(feature = "daemon-services")]
pub mod services;
pub mod session;
pub mod ssh_bootstrap;
#[cfg(feature = "daemon-services")]
pub mod workspace;
