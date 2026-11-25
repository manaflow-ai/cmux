//! The Cloud start sequencer's ops through the C ABI, under `cloud_sequence::` so the fleet's
//! one-substring test filter selects it.

#[path = "cloud_sequence_ffi/cases.rs"]
mod cloud_sequence;
