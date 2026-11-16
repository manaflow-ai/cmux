//! Shared pure log filters; the implementation lives in acpmux-core.
pub(crate) use acpmux_core::chat::record::update_repeats::UpdateRepeats;

#[cfg(test)]
use serde_json::Value;
#[cfg(test)]
#[path = "update_repeats_tests.rs"]
mod tests;
