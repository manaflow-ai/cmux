//! The host and original HTTP reader share one deadline implementation.
pub(super) use cmux_server::deadline::{expired, wait};

#[cfg(all(test, target_os = "linux"))]
#[path = "receiver_deadline_tests.rs"]
mod tests;
