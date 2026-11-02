//! The host and original HTTP reader share one deadline implementation.
pub(super) use cmux_server::deadline::{expired, wait};

#[cfg(all(test, any(target_os = "linux", target_vendor = "apple")))]
#[path = "receiver_deadline_tests.rs"]
mod tests;
