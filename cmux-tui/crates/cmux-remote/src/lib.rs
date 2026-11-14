//! Native remote runtime for cmux-tui.
//!
//! Without the `host` feature this is the client half only (the iOS app's
//! Cloud carrier), and the daemon's helpers in shared modules go unused.
#![cfg_attr(not(feature = "host"), allow(dead_code))]

#[cfg(feature = "host")]
pub mod acpmux_bridge;
#[cfg(all(unix, feature = "host"))]
pub mod admin;
pub mod bridge;
#[cfg(feature = "host")]
pub mod client;
pub mod connection;
pub mod crypto;
#[cfg(feature = "host")]
pub mod daemon;
mod daemon_error;
pub mod first_dial;
pub mod grant;
#[cfg(feature = "host")]
pub mod http;
pub mod identity;
pub mod link;
#[cfg(all(test, unix))]
mod lock_keeper_tests;
pub mod network_watch;
pub use mux_client::MuxLineClient;
mod mux_carrier_role;
mod mux_client;
mod mux_codec;
mod mux_input;
mod mux_lanes;
pub mod observability;
mod owner_lock;
mod per_lane;
pub mod provider;
pub mod secret_file;
pub mod secrets;
pub mod secure_directory;
pub mod service;
#[cfg(feature = "host")]
pub mod services;
pub mod session;
mod ssh_args;
pub use ssh_artifacts::{
    LinuxPin, PinnedPayload, SSH_PAYLOAD_DOWNLOAD_CAPABILITY,
    SSH_PAYLOAD_MACOS_FROM_CLIENT_CAPABILITY, pinned_linux_payload, pinned_linux_pin,
};
mod ssh_artifacts;
pub mod ssh_bootstrap;
mod ssh_payload_proxy;
#[cfg(all(unix, feature = "host"))]
pub mod unix_socket;
pub mod update_need;
#[cfg(all(feature = "wireguard-transport", feature = "host"))]
pub mod wireguard_hub;
#[cfg(all(feature = "wireguard-transport", feature = "host", unix))]
pub mod wireguard_hub_control;
#[cfg(feature = "host")]
pub mod workspace;
