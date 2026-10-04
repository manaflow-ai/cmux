//! The v2 request origin gate (plans/cmux-next/request-origin.md). Red
//! commit: only the test hooks exist, as no-ops, so the new tests compile
//! and fail.

#[cfg(test)]
use std::sync::Arc;

#[cfg(test)]
use crate::mux::Mux;

#[cfg(test)]
pub(super) fn set_role_for_test(_mux: &Arc<Mux>, _client: u64, _role: &str) {}

#[cfg(test)]
pub(super) fn set_verified_app_for_test(_mux: &Arc<Mux>, _client: u64, _verified: bool) {}

#[cfg(test)]
pub(super) fn set_peer_key_for_test(_mux: &Arc<Mux>, _client: u64, _peer_key: &str) {}

#[cfg(test)]
pub(super) fn advance_origin_clock_for_test(_mux: &Arc<Mux>, _ms: u64) {}

#[cfg(test)]
pub(super) fn role_for_test(_mux: &Arc<Mux>, _client: u64) -> String {
    "legacy".to_string()
}

#[cfg(all(test, unix))]
#[path = "origin_gate_tests.rs"]
mod tests;

#[cfg(all(test, unix))]
#[path = "client_hello_tests.rs"]
mod client_hello_tests;
