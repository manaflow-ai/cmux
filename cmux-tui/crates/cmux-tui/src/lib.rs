//! Client-side session catalog model.
//!
//! Runtime startup and UI wiring remain in the `cmux-tui` binary. This library
//! keeps the phase-one discovery, identity, and per-window state seams separate
//! from the independent session-owner change.

pub mod catalog_client_state;
pub mod catalog_transport;
pub mod device_session_catalog;
