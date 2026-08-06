//! Native remote runtime for cmux-tui.

#[cfg(test)]
pub(crate) fn test_observation_timeout(timeout: std::time::Duration) -> std::time::Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|scale| *scale > 0)
        .unwrap_or(1);
    timeout.saturating_mul(scale)
}

#[cfg(unix)]
pub mod admin;
#[cfg(feature = "daemon-services")]
pub mod bridge;
#[cfg(feature = "daemon-services")]
pub mod client;
pub mod connection;
pub mod crypto;
pub mod daemon;
#[cfg(feature = "daemon-services")]
pub mod http;
pub mod identity;
pub mod link;
pub mod mux_codec;
#[cfg(feature = "daemon-services")]
mod mux_input;
#[cfg(feature = "daemon-services")]
mod mux_lanes;
pub mod observability;
mod owner_lock;
pub mod provider;
pub mod secret_file;
pub mod secure_directory;
pub mod service;
#[cfg(feature = "daemon-services")]
pub mod services;
pub mod session;
pub mod ssh_bootstrap;
#[cfg(unix)]
mod unix_socket;
#[cfg(feature = "daemon-services")]
pub mod workspace;
