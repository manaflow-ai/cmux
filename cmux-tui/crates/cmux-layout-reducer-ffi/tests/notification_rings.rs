//! The notification rings' rules through the C ABI, under `window_rules::`
//! so the fleet's one-substring test filter selects them with the window
//! handlers' rules.

#[path = "notification_rings_ffi/cases.rs"]
mod window_rules;
