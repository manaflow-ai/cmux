//! The harness login copy's ops through the C ABI, under `cloud_copy_login::` so the fleet's
//! one-substring test filter selects it.

#[path = "cloud_copy_login_ffi/cases.rs"]
mod cloud_copy_login;
