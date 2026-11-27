//! The screen stream's rules (`cmux-rd-screen`) for the shared Swift packages
//! (Packages/Shared/CmuxVNCWebRTC) on iOS. One call, `screen_json(op,
//! request)`, answers the same `screen_*` ops the Mac reaches over
//! cmux-layout-reducer-ffi's C ABI: both call `cmux_rd_screen::json::respond`,
//! so a rule cannot answer one way on the Mac and another on the phone.
//!
//! JSON, not records: the shared packages take the rules as one injected
//! closure that the Mac fills from CCmuxAppFFI and iOS from this library, and
//! a string in, string out shape is the one both links have.

use std::fmt;

/// Why `screen_json` gave no answer. A refusal the rules make (a bad ticket)
/// is an answer (`{"error": ...}`), not this.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum ScreenJsonError {
    /// No `screen_*` op of that name.
    UnknownOperation { operation: String },
    // Not `message`: Kotlin errors extend Throwable, which owns `message`.
    /// The request is not the op's JSON.
    Invalid { detail: String },
}

impl fmt::Display for ScreenJsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownOperation { operation } => write!(f, "unknown screen op {operation:?}"),
            Self::Invalid { detail } => write!(f, "invalid screen request: {detail}"),
        }
    }
}

impl std::error::Error for ScreenJsonError {}

impl From<cmux_rd_screen::json::JsonError> for ScreenJsonError {
    fn from(error: cmux_rd_screen::json::JsonError) -> Self {
        use cmux_rd_screen::json::JsonError;
        match error {
            JsonError::UnknownOperation(operation) => Self::UnknownOperation { operation },
            JsonError::Invalid(detail) => Self::Invalid { detail },
        }
    }
}

/// Answers one `screen_*` op: `request` and the answer are the op's JSON.
#[uniffi::export]
pub fn screen_json(operation: String, request: String) -> Result<String, ScreenJsonError> {
    let answer = cmux_rd_screen::json::respond(&operation, request.as_bytes())?;
    Ok(answer.to_string())
}

#[cfg(test)]
#[path = "screen_tests.rs"]
mod tests;
