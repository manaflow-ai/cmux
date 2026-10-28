//! The closed set of error codes the machine agent sends on the wire.

use cmux_tui_machine_agent_protocol::ErrorCode;

/// Every code this agent puts on the wire for a rejected generation or a
/// rejected or closed stream.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum AgentErrorCode {
    Replay,
    Downgrade,
    MigrationInProgress,
    InvalidMigration,
    GenerationMismatch,
    MigrationFailed,
    Busy,
    Migrating,
    InvalidOpen,
    StreamReplay,
    StreamLimit,
    LocalUnavailable,
    UnknownStream,
    FlowControl,
    LocalWrite,
    Closed,
    Eof,
    QueueOverflow,
    LocalRead,
}

impl AgentErrorCode {
    #[cfg(test)]
    pub(super) const ALL: [Self; 19] = [
        Self::Replay,
        Self::Downgrade,
        Self::MigrationInProgress,
        Self::InvalidMigration,
        Self::GenerationMismatch,
        Self::MigrationFailed,
        Self::Busy,
        Self::Migrating,
        Self::InvalidOpen,
        Self::StreamReplay,
        Self::StreamLimit,
        Self::LocalUnavailable,
        Self::UnknownStream,
        Self::FlowControl,
        Self::LocalWrite,
        Self::Closed,
        Self::Eof,
        Self::QueueOverflow,
        Self::LocalRead,
    ];

    pub(super) fn as_str(self) -> &'static str {
        match self {
            Self::Replay => "replay",
            Self::Downgrade => "downgrade",
            Self::MigrationInProgress => "migration_in_progress",
            Self::InvalidMigration => "invalid_migration",
            Self::GenerationMismatch => "generation_mismatch",
            Self::MigrationFailed => "migration_failed",
            Self::Busy => "busy",
            Self::Migrating => "migrating",
            Self::InvalidOpen => "invalid_open",
            Self::StreamReplay => "stream_replay",
            Self::StreamLimit => "stream_limit",
            Self::LocalUnavailable => "local_unavailable",
            Self::UnknownStream => "unknown_stream",
            Self::FlowControl => "flow_control",
            Self::LocalWrite => "local_write",
            Self::Closed => "closed",
            Self::Eof => "eof",
            Self::QueueOverflow => "queue_overflow",
            Self::LocalRead => "local_read",
        }
    }

    #[allow(
        clippy::expect_used,
        reason = "INVARIANT: every as_str value is a short [a-z_] identifier, which \
                  ErrorCode::new accepts; agent_error_codes_are_valid_wire_codes checks each"
    )]
    pub(super) fn wire(self) -> ErrorCode {
        ErrorCode::new(self.as_str()).expect("agent error code is a valid wire code")
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn agent_error_codes_are_valid_wire_codes() {
        let mut seen = HashSet::new();
        for code in AgentErrorCode::ALL {
            assert_eq!(ErrorCode::new(code.as_str()).ok(), Some(code.wire()), "{code:?}");
            assert!(seen.insert(code.as_str()), "{code:?} repeats a wire code");
        }
    }
}
