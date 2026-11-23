//! Errors: `{error: {code, message}}`, and the `auto.*` codes.

use std::fmt;

use serde::{Deserialize, Serialize};

/// Every `auto.*` code the store answers.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ErrorCode {
    /// The write names a holder and epoch that are not current.
    #[serde(rename = "auto.stale_epoch")]
    StaleEpoch,
    /// The caller is not the chat's holder.
    #[serde(rename = "auto.not_holder")]
    NotHolder,
    /// The owner has no Auto machine.
    #[serde(rename = "auto.no_machine")]
    NoMachine,
    /// Auto cannot be switched off while a machine holds the chat.
    #[serde(rename = "auto.held_in_cloud")]
    HeldInCloud,
    /// An append skipped a seq. The envelope carries the store's `lastSeq`.
    #[serde(rename = "auto.seq_gap")]
    SeqGap,
    /// A manifest names chunks that are not stored. The envelope lists them as `missing`.
    #[serde(rename = "auto.snapshot_incomplete")]
    SnapshotIncomplete,
    /// The chat has no snapshot yet.
    #[serde(rename = "auto.no_snapshot")]
    NoSnapshot,
    /// A chunk's bytes do not hash to its name.
    #[serde(rename = "auto.chunk_mismatch")]
    ChunkMismatch,
    /// The chat's snapshot is past the size cap.
    #[serde(rename = "auto.too_large")]
    TooLarge,
    /// Auto was switched off for the chat.
    #[serde(rename = "auto.closed")]
    Closed,
}

impl ErrorCode {
    pub const ALL: [ErrorCode; 10] = [
        ErrorCode::StaleEpoch,
        ErrorCode::NotHolder,
        ErrorCode::NoMachine,
        ErrorCode::HeldInCloud,
        ErrorCode::SeqGap,
        ErrorCode::SnapshotIncomplete,
        ErrorCode::NoSnapshot,
        ErrorCode::ChunkMismatch,
        ErrorCode::TooLarge,
        ErrorCode::Closed,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            ErrorCode::StaleEpoch => "auto.stale_epoch",
            ErrorCode::NotHolder => "auto.not_holder",
            ErrorCode::NoMachine => "auto.no_machine",
            ErrorCode::HeldInCloud => "auto.held_in_cloud",
            ErrorCode::SeqGap => "auto.seq_gap",
            ErrorCode::SnapshotIncomplete => "auto.snapshot_incomplete",
            ErrorCode::NoSnapshot => "auto.no_snapshot",
            ErrorCode::ChunkMismatch => "auto.chunk_mismatch",
            ErrorCode::TooLarge => "auto.too_large",
            ErrorCode::Closed => "auto.closed",
        }
    }

    /// The code a string names; None for any other code (`validation.invalid`, `not_found`).
    pub fn parse(code: &str) -> Option<ErrorCode> {
        ErrorCode::ALL.into_iter().find(|known| known.as_str() == code)
    }

    /// The HTTP status the store answers this code with.
    pub fn status(self) -> u16 {
        match self {
            ErrorCode::NoSnapshot => 404,
            ErrorCode::ChunkMismatch => 400,
            ErrorCode::TooLarge => 413,
            ErrorCode::Closed => 410,
            // `GET /machine` answers 404 for it; `POST /v1/auto-sessions` answers 409.
            ErrorCode::NoMachine
            | ErrorCode::StaleEpoch
            | ErrorCode::NotHolder
            | ErrorCode::HeldInCloud
            | ErrorCode::SeqGap
            | ErrorCode::SnapshotIncomplete => 409,
        }
    }
}

impl fmt::Display for ErrorCode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// `{code, message}`. `code` is kept as text: the store also answers codes that are not
/// `auto.*` (`validation.invalid`, `auth.unauthenticated`, `not_found`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorBody {
    pub code: String,
    #[serde(default)]
    pub message: String,
}

/// An error answer. Beside `error`, in the hand-off routes' shape: `auto.seq_gap` carries the
/// store's `lastSeq` and `auto.snapshot_incomplete` the `missing` chunks.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ErrorEnvelope {
    pub error: ErrorBody,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_seq: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing: Vec<String>,
}

impl ErrorEnvelope {
    pub fn new(code: &str, message: impl Into<String>) -> ErrorEnvelope {
        ErrorEnvelope {
            error: ErrorBody { code: code.to_owned(), message: message.into() },
            last_seq: None,
            missing: Vec::new(),
        }
    }

    /// The `auto.*` code, when the error is one.
    pub fn code(&self) -> Option<ErrorCode> {
        ErrorCode::parse(&self.error.code)
    }
}
