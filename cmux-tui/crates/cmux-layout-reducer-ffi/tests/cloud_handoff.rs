//! The consent session handoff's ops through the C ABI, under `cloud_handoff::` so the fleet's
//! one-substring test filter selects it.

#[path = "cloud_handoff_ffi/cases.rs"]
mod cloud_handoff;
