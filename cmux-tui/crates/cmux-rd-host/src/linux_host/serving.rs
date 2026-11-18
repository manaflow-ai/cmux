//! Which account this desktop's host serves (review F1 of #45369).

use crate::Res;

/// Stops the host unit before an identity changes.
pub(super) trait Unit {
    fn stop(&self) -> Res<()>;
}

#[cfg(test)]
#[path = "serving_tests.rs"]
mod tests;
