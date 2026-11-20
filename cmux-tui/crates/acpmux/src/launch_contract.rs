//! Limits shared by the first-class and legacy machine launch commands.

/// Time for the machine to accept a named start, leaving a second for the CLI to report the
/// result. This is separate from any wait for the first model reply.
pub const NAMED_START_LIMIT: std::time::Duration = std::time::Duration::from_secs(9);
