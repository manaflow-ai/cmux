//! The JSON envelope every text message carries (spec "Wire", plus the TS
//! lane's wire decisions of 2026-10-04 in `/tmp/pane-protocol/ir-changes.md`).
//!
//! Decoding checks shape only: unknown envelope fields are ignored so a newer
//! peer can add optional fields, unknown `t` values are rejected, and ids,
//! subscription ids and sequence numbers must stay at or below 2^53 - 1 so
//! JavaScript peers read them exactly. Whether an op exists and whether its
//! params are valid is the session's check, not the decoder's.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::error::ErrorBody;

/// The largest integer a JavaScript `number` represents exactly.
pub const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

/// Id 0 is reserved for the answer to an `auth` frame.
pub const AUTH_REPLY_ID: u64 = 0;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "lowercase")]
pub enum Envelope {
    Call {
        id: u64,
        op: String,
        #[serde(default = "empty_object")]
        params: Value,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cap: Option<String>,
    },
    Ok {
        id: u64,
        #[serde(default)]
        value: Value,
    },
    Err {
        id: u64,
        code: String,
        message: String,
        retryable: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        details: Option<Map<String, Value>>,
    },
    Sub {
        id: u64,
        stream: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        filter: Option<Map<String, Value>>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cap: Option<String>,
    },
    /// `seq` starts at 1 for each subscription and counts the events sent.
    /// `gap` is true on the first event after the sender dropped events
    /// from a full queue; the receiver should resync.
    Ev {
        sub: u64,
        seq: u64,
        #[serde(default)]
        data: Value,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        gap: bool,
    },
    Unsub {
        sub: u64,
    },
    Cancel {
        id: u64,
    },
    Release {
        handle: String,
    },
    /// Open a byte stream. The peer answers `id` with `ok` or `err`. The
    /// connecting side uses odd stream ids, the accepting side even ones.
    Open {
        id: u64,
        stream: u32,
        op: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        params: Option<Value>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cap: Option<String>,
    },
    Credit {
        stream: u32,
        bytes: u32,
    },
    /// End this side of a byte stream; `code` and `message` mark an abort.
    End {
        stream: u32,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        code: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    /// The first frame on a WebSocket or socket; consumed by the listener.
    Auth {
        token: String,
    },
    /// MessagePort only: the sender is about to close.
    Bye,
}

fn empty_object() -> Value {
    Value::Object(Map::new())
}

/// Which side of a connection a peer is; it picks the parity of the stream
/// ids the peer may open.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    /// The side that dialed: odd stream ids.
    Connecting,
    /// The side that accepted: even stream ids.
    Accepting,
}

impl Role {
    /// Whether `stream` is an id the peer on the other side may open.
    pub fn peer_may_open(self, stream: u32) -> bool {
        match self {
            Self::Connecting => stream.is_multiple_of(2),
            Self::Accepting => stream % 2 == 1,
        }
    }

    /// The first stream id this side opens.
    pub fn first_stream(self) -> u32 {
        match self {
            Self::Connecting => 1,
            Self::Accepting => 2,
        }
    }
}

/// Why a text message is not a valid envelope.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EnvelopeError {
    /// Not JSON, not an object, unknown `t`, or a field of the wrong type.
    Malformed(String),
    /// An id, sub, seq or stream outside 1..=2^53-1 (`ok`/`err` may use id
    /// 0, the auth reply).
    OutOfRange(&'static str),
    /// An op or stream name that is not `<ns>.<family>.<verb>`.
    BadName(String),
}

impl std::fmt::Display for EnvelopeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Malformed(reason) => write!(formatter, "malformed envelope: {reason}"),
            Self::OutOfRange(field) => write!(formatter, "{field} is outside 1..=2^53-1"),
            Self::BadName(name) => write!(formatter, "bad op or stream name {name:?}"),
        }
    }
}

impl std::error::Error for EnvelopeError {}

impl Envelope {
    /// Parse and validate one text message.
    pub fn decode(text: &str) -> Result<Self, EnvelopeError> {
        let envelope: Self = serde_json::from_str(text)
            .map_err(|error| EnvelopeError::Malformed(error.to_string()))?;
        envelope.validate()?;
        Ok(envelope)
    }

    /// Serialize to the JSON text sent on the wire.
    pub fn encode(&self) -> String {
        // Serializing this enum cannot fail: every field is a plain JSON value.
        serde_json::to_string(self).unwrap_or_default()
    }

    pub fn validate(&self) -> Result<(), EnvelopeError> {
        let range = |value: u64, low: u64, field: &'static str| {
            if (low..=MAX_SAFE_INTEGER).contains(&value) {
                Ok(())
            } else {
                Err(EnvelopeError::OutOfRange(field))
            }
        };
        match self {
            Self::Call { id, .. } | Self::Cancel { id } | Self::Sub { id, .. } => {
                range(*id, 1, "id")
            }
            Self::Ok { id, .. } | Self::Err { id, .. } => range(*id, AUTH_REPLY_ID, "id"),
            Self::Open { id, stream, .. } => {
                range(*id, 1, "id")?;
                range(u64::from(*stream), 1, "stream")
            }
            Self::Ev { sub, seq, .. } => {
                range(*sub, 1, "sub")?;
                range(*seq, 1, "seq")
            }
            Self::Unsub { sub } => range(*sub, 1, "sub"),
            Self::Credit { stream, .. } | Self::End { stream, .. } => {
                range(u64::from(*stream), 1, "stream")
            }
            Self::Release { .. } | Self::Auth { .. } | Self::Bye => Ok(()),
        }
    }

    /// An `err` envelope answering call `id`.
    pub fn error(id: u64, body: ErrorBody) -> Self {
        Self::Err {
            id,
            code: body.code,
            message: body.message,
            retryable: body.retryable,
            details: body.details,
        }
    }

    /// The error body of an `err` envelope.
    pub fn error_body(&self) -> Option<ErrorBody> {
        match self {
            Self::Err { code, message, retryable, details, .. } => Some(ErrorBody {
                code: code.clone(),
                message: message.clone(),
                retryable: *retryable,
                details: details.clone(),
            }),
            _ => None,
        }
    }
}

/// `<ns>.<family>.<verb>`: at least three dot-separated labels of
/// `[a-z0-9_-]`, each starting with a letter or digit.
pub fn check_name(name: &str) -> Result<(), EnvelopeError> {
    let labels: Vec<&str> = name.split('.').collect();
    let valid_label = |label: &&str| {
        !label.is_empty()
            && label.as_bytes()[0].is_ascii_alphanumeric()
            && label.bytes().all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'_' | b'-'))
    };
    if name.len() <= 256 && labels.len() >= 3 && labels.iter().all(valid_label) {
        Ok(())
    } else {
        Err(EnvelopeError::BadName(name.to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn call_round_trips_and_defaults_params() {
        let envelope = Envelope::decode(r#"{"t":"call","id":7,"op":"cmux.git.status"}"#).unwrap();
        assert_eq!(
            envelope,
            Envelope::Call { id: 7, op: "cmux.git.status".into(), params: json!({}), cap: None }
        );
        assert_eq!(envelope.encode(), r#"{"t":"call","id":7,"op":"cmux.git.status","params":{}}"#);
    }

    #[test]
    fn rejects_unsafe_ids_and_unknown_kinds() {
        let too_big = format!(r#"{{"t":"cancel","id":{}}}"#, MAX_SAFE_INTEGER + 1);
        assert_eq!(Envelope::decode(&too_big), Err(EnvelopeError::OutOfRange("id")));
        assert_eq!(
            Envelope::decode(r#"{"t":"call","id":0,"op":"a.b.c"}"#),
            Err(EnvelopeError::OutOfRange("id"))
        );
        assert!(Envelope::decode(r#"{"t":"ok","id":0}"#).is_ok());
        assert!(matches!(Envelope::decode(r#"{"t":"nope"}"#), Err(EnvelopeError::Malformed(_))));
        assert!(Envelope::decode(r#"{"t":"err","id":1,"code":"c","message":"m"}"#).is_err());
    }

    #[test]
    fn names_and_parity() {
        assert!(check_name("cmux.git.status").is_ok());
        assert!(check_name("cmux.Git.status").is_err());
        assert!(check_name("cmux.git").is_err());
        assert!(Role::Accepting.peer_may_open(1));
        assert!(!Role::Accepting.peer_may_open(2));
        assert!(Role::Connecting.peer_may_open(2));
    }

    #[test]
    fn error_body_round_trips() {
        let body =
            ErrorBody::new("cmux.git.not_a_repo", "no repo").with_details(json!({"cwd": "/"}));
        let envelope = Envelope::error(3, body.clone());
        assert_eq!(Envelope::decode(&envelope.encode()).unwrap().error_body(), Some(body));
    }
}
