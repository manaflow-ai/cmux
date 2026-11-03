//! The Cloud start's harness login ops through the C ABI, under
//! `cloud_harness_login::` so the fleet's one-substring test filter selects it.

#[path = "cloud_harness_login_ffi/cases.rs"]
mod cloud_harness_login;

#[path = "cloud_harness_login_ffi/ask_cases.rs"]
mod cloud_ask;
