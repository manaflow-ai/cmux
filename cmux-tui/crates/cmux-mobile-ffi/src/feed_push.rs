//! The feed push rules (`cmux-feed-push-core`) for the phones: one call,
//! `feed_push_json(op, request)`, answers the same ops the Mac reaches as
//! `feed_push_<op>` over cmux-layout-reducer-ffi's C ABI. Both call
//! `cmux_feed_push_core::ops::call`, so a banner action cannot send one answer
//! from the Mac and another from the phone.

use std::fmt;

/// Why `feed_push_json` gave no answer.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum FeedPushJsonError {
    /// No feed push op of that name.
    UnknownOperation { operation: String },
    // Not `message`: Kotlin errors extend Throwable, which owns `message`.
    /// The request is not the op's JSON.
    Invalid { detail: String },
}

impl fmt::Display for FeedPushJsonError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownOperation { operation } => write!(f, "unknown feed push op {operation:?}"),
            Self::Invalid { detail } => write!(f, "invalid feed push request: {detail}"),
        }
    }
}

impl std::error::Error for FeedPushJsonError {}

/// Answers one feed push op (`shown_text`, `push_response`, ...): `request`
/// and the answer are the op's JSON.
#[uniffi::export]
pub fn feed_push_json(operation: String, request: String) -> Result<String, FeedPushJsonError> {
    use cmux_feed_push_core::ops::{OpError, call};
    let request: serde_json::Value = serde_json::from_str(&request)
        .map_err(|error| FeedPushJsonError::Invalid { detail: error.to_string() })?;
    match call(&operation, &request) {
        Ok(answer) => Ok(answer.to_string()),
        Err(OpError::Unknown) => Err(FeedPushJsonError::UnknownOperation { operation }),
        Err(OpError::Invalid) => {
            Err(FeedPushJsonError::Invalid { detail: format!("not a {operation} request") })
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answers_like_the_mac_channel() {
        let answer = feed_push_json(
            "answer_for_action".into(),
            r#"{"action":"FEED_REPLY","text":"  hi  "}"#.into(),
        )
        .unwrap();
        let answer: serde_json::Value = serde_json::from_str(&answer).unwrap();
        assert_eq!(answer["value"], serde_json::json!({"text": "hi"}));
    }

    #[test]
    fn refuses_unknown_and_bad_requests() {
        assert_eq!(
            feed_push_json("nope".into(), "{}".into()),
            Err(FeedPushJsonError::UnknownOperation { operation: "nope".into() })
        );
        assert!(matches!(
            feed_push_json("op_reply".into(), "[".into()),
            Err(FeedPushJsonError::Invalid { .. })
        ));
        assert!(matches!(
            feed_push_json("op_reply".into(), "{}".into()),
            Err(FeedPushJsonError::Invalid { .. })
        ));
    }
}
