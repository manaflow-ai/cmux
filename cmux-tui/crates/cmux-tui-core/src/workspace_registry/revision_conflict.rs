//! A conditional write whose expected resource revision is no longer current.

/// Raised by every store when a mutation's expected resource revision does not
/// match the committed one. Callers recognize it by type
/// (`crate::resource_router::is_revision_conflict`), never by its message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct RevisionConflict {
    pub expected: u64,
    pub current: u64,
}

impl std::fmt::Display for RevisionConflict {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            formatter,
            "resource revision conflict: expected {}, current {}",
            self.expected, self.current
        )
    }
}

impl std::error::Error for RevisionConflict {}

/// The conflict as the error a store returns.
pub(crate) fn error(expected: u64, current: u64) -> anyhow::Error {
    RevisionConflict { expected, current }.into()
}
