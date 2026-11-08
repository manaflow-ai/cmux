//! The worker's agent socket (`cmux-computer-use-v1`): UTF-8 JSON, one
//! object per line. The macOS worker (Swift, in cmux Remote) and the
//! Windows/Linux worker (Rust, `cmux computer-use worker`) both serve it;
//! acpmux's bridge is the only client agents reach it through.
//!
//! ```text
//! -> {"secret":"<hex>"}                       first line, per connection
//! <- {"ok":true,"protocol":1,"capabilities":["cmux-computer-use-v1"]}
//! -> {"id":1,"method":"tools/call","name":"click","arguments":{...},
//!     "session":"<agent session key>","label":"Claude","call_id":"<uuid>"}
//! <- {"id":1,"ok":true,"result":{"is_error":false,"code":null,"body":{...},"image":null,"mime":null}}
//! -> {"id":2,"method":"session/end","session":"..."}
//! -> {"id":3,"method":"status"}
//! ```
//!
//! A refused peer gets `{"ok":false,"error":"refused","reason":R}` and is
//! closed. The secret is per worker launch, in the 0600 `endpoint.json`
//! the host writes for acpmux.

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const PROTOCOL: u32 = 1;
pub const CAPABILITY: &str = "cmux-computer-use-v1";
pub const MAX_LINE: usize = 32 << 20;

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct CallRequest {
    pub id: u64,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub arguments: Value,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub session: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub call_id: Option<String>,
}

/// `endpoint.json`, written 0600 by the host while the worker serves.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub struct Endpoint {
    /// A Unix socket path, or a Windows named pipe (`\\.\pipe\...`).
    pub socket: String,
    pub secret: String,
    #[serde(default)]
    pub pid: Option<u32>,
    #[serde(default)]
    pub protocol: u32,
}

/// Hex for secrets.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(text.get(i..i + 2)?, 16).ok()).collect()
}

/// Constant-time comparison for the secret.
pub fn same_secret(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip_and_secret_compare() {
        let s = [1u8, 0xab, 0xff];
        assert_eq!(unhex(&hex(&s)).unwrap(), s);
        assert!(unhex("abc").is_none() && unhex("zz").is_none());
        assert!(same_secret(&s, &s) && !same_secret(&s, &[1, 0xab]));
    }
}
