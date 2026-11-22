//! The machine bootstrap, machine config and create retry ops through the C ABI, under
//! `cloud_bootstrap::` so the fleet's one-substring test filter selects it.

#[path = "cloud_bootstrap_ffi/cases.rs"]
mod cloud_bootstrap;
