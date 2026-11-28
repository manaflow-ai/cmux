//! The app's Cloud state ops through the C ABI, under `cloud_state::` so the fleet's one-substring
//! test filter selects it.

#[path = "cloud_state_ffi/cases.rs"]
mod cloud_state;
