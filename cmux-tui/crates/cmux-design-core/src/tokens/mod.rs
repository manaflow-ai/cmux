//! Derived tokens: the density catalog, metrics, frame tone, two-tone, corner flush, group
//! colours and glass, the plus button, omnibar ink and the sidebar toggle glyph (CmuxNextDesign
//! and CmuxNextDesignTokens in the macOS app).
//!
//! Ops: `tokens.NAME`. Each submodule answers the names it owns (each starts with the
//! submodule's name, e.g. `tokens.density_entry`); [`call`] asks them in turn.

use crate::ops::{OpError, OpResult};
use serde_json::Value;

pub mod color;
pub mod corner_flush;
pub mod density;
pub mod frame_tone;
pub mod group;
pub mod metrics;
pub mod omnibar_ink;
pub mod plus_button;
pub mod sidebar_toggle;
pub mod two_tone;

type SubCall = fn(&str, &Value) -> OpResult;

const AREAS: &[SubCall] = &[
    corner_flush::call,
    density::call,
    frame_tone::call,
    group::call,
    metrics::call,
    omnibar_ink::call,
    plus_button::call,
    sidebar_toggle::call,
    two_tone::call,
];

/// Runs `tokens.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    for area in AREAS {
        match area(name, request) {
            Err(OpError::Unknown) => continue,
            other => return other,
        }
    }
    Err(OpError::Unknown)
}
