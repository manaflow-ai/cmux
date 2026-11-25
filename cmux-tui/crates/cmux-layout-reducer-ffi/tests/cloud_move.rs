//! Move to Cloud's ops through the C ABI, under `cloud_move::` so the fleet's one-substring test
//! filter selects it.

#[path = "cloud_move_ffi/cases.rs"]
mod cloud_move;
