//! Relay <-> Worker wire frames.
//!
//! TEMPORARY HAND-MODELED SUBSET — REPLACE WITH GENERATED CODE.
//! The canonical contract is chatmux `packages/protocol/src/relay.ts`
//! (emitted to `generated/schema/relay-client.schema.json`). A Rust serde
//! emitter is landing in the chatmux protocol codegen alongside the wire-v6
//! pane verbs; once `packages/protocol/generated/rust/` exists, vendor that
//! file here (see the crate README's "Vendored protocol" section) and delete
//! everything in this module except the parse-tolerance helpers.
//!
//! This subset models only what slice 1 (pairing, hello/heartbeat, trust,
//! managed enrollment) sends and receives. Incoming frames are decoded
//! tolerantly, mirroring `parseServerFrame` in the JS relay: an unusable
//! frame is ignored (never a socket close), and unknown frame TYPES pass
//! through so the caller can apply the N/N-1 tolerance rule.

use serde::Serialize;
use serde_json::Value;

use crate::config::ManagedIdentity;

/// Relay wire dialect this build advertises. Workspace/watch/preview frames
/// use v6; lower dialect features remain capability-gated.
pub const ADVERTISED_PROTOCOL_VERSION: u64 = 6;
/// Frame dialect marker (`RelayFrameVersion`, >= 2) on every sent frame.
pub const FRAME_VERSION: u64 = 2;
/// Verbs exist from this dialect on.
pub const EXEC_PROTOCOL_VERSION: u64 = 3;
/// PTY verbs exist from this dialect on.
pub const PTY_PROTOCOL_VERSION: u64 = 4;
/// The pairing ceremony wire (separate from the relay dialect).
pub const PAIRING_WIRE_VERSION: u64 = 1;

pub const CLI_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Test-only override so e2e can provoke the server's upgrade_required path
/// (same env contract as the JS relay).
pub fn advertised_protocol() -> u64 {
    std::env::var("CHATMUX_RELAY_PROTOCOL")
        .ok()
        .filter(|value| !value.is_empty())
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(ADVERTISED_PROTOCOL_VERSION)
}

// ---------------------------------------------------------------------------
// Relay -> Worker
// ---------------------------------------------------------------------------

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloFrame<'a> {
    pub version: u64,
    #[serde(rename = "type")]
    pub frame_type: &'static str,
    pub relay_protocol_version: u64,
    pub cli_version: &'static str,
    pub machine_id: &'a str,
    pub token: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub allowed_roots: Option<&'a Vec<String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub managed_enrollment: Option<&'a ManagedIdentity>,
}

pub fn heartbeat_frame(at_ms: i64) -> Value {
    serde_json::json!({
        "version": FRAME_VERSION,
        "type": "heartbeat",
        "at": at_ms,
    })
}

pub fn set_trust_frame(trust: &str) -> Value {
    serde_json::json!({
        "version": FRAME_VERSION,
        "type": "set_trust",
        "trust": trust,
    })
}

// ---------------------------------------------------------------------------
// Worker -> Relay (tolerant decode)
// ---------------------------------------------------------------------------

#[derive(Debug)]
pub struct HelloAccepted {
    pub relay_protocol_version: u64,
    pub heartbeat_interval_ms: u64,
    pub machine_name: String,
    pub scope: String,
    pub trust: String,
    pub owner_user_id: Option<String>,
    pub managed_session_token: Option<String>,
}

#[derive(Debug)]
pub enum ServerFrame {
    HelloAccepted(HelloAccepted),
    UpgradeRequired {
        min_version: u64,
        message: String,
    },
    HeartbeatAck,
    TrustAck {
        trust: String,
    },
    ActionRequest {
        action_id: String,
        verb: String,
        raw: Value,
    },
    Pty {
        frame_type: String,
        raw: Value,
    },
    Error {
        code: String,
        message: Option<String>,
    },
    /// A v6 workspace frame (workspace_request / fs_watch_open /
    /// fs_watch_close): routed to the workspace module, which decodes it
    /// with the vendored generated types (relay_wire.rs).
    Workspace {
        frame: Value,
    },
    /// A newer server may send frame types this build predates; ignoring
    /// them (once, loudly) is the forward half of the tolerance rule.
    Unknown {
        frame_type: String,
    },
}

fn get_str(frame: &Value, name: &str) -> Option<String> {
    frame.get(name).and_then(Value::as_str).map(str::to_owned)
}

fn get_u64(frame: &Value, name: &str) -> Option<u64> {
    frame.get(name).and_then(Value::as_u64)
}

fn has_supported_version(frame: &Value, minimum: u64) -> bool {
    get_u64(frame, "version")
        .is_some_and(|version| (minimum..=ADVERTISED_PROTOCOL_VERSION).contains(&version))
}

fn minimum_version_for_type(frame_type: &str) -> Option<u64> {
    match frame_type {
        "action_request" => Some(EXEC_PROTOCOL_VERSION),
        "pty_open" | "pty_input" | "pty_resize" | "pty_flow" | "pty_close" | "surface_list" => {
            Some(PTY_PROTOCOL_VERSION)
        }
        "workspace_request" | "fs_watch_open" | "fs_watch_close" => {
            Some(crate::workspace::WORKSPACE_FRAME_VERSION as u64)
        }
        "hello_accepted" | "upgrade_required" | "heartbeat_ack" | "trust_ack" | "error" => {
            Some(FRAME_VERSION)
        }
        _ => None,
    }
}

/// Minimal runtime validator for server frames. Returns `None` only for
/// frames that are not usable at all (the caller ignores them and keeps the
/// socket); unknown types come back as `ServerFrame::Unknown`.
pub fn parse_server_frame(raw: &str) -> Option<ServerFrame> {
    let frame: Value = serde_json::from_str(raw).ok()?;
    let frame_type = frame.get("type").and_then(Value::as_str)?.to_owned();
    if minimum_version_for_type(&frame_type)
        .is_some_and(|minimum| !has_supported_version(&frame, minimum))
    {
        return None;
    }
    match frame_type.as_str() {
        "hello_accepted" => {
            let heartbeat_interval_ms = get_u64(&frame, "heartbeatIntervalMs")
                .filter(|value| (1..=i32::MAX as u64).contains(value))?;
            let relay_protocol_version = get_u64(&frame, "relayProtocolVersion")
                .filter(|value| (FRAME_VERSION..=ADVERTISED_PROTOCOL_VERSION).contains(value))?;
            Some(ServerFrame::HelloAccepted(HelloAccepted {
                relay_protocol_version,
                heartbeat_interval_ms,
                machine_name: get_str(&frame, "machineName")?,
                scope: get_str(&frame, "scope")?,
                trust: get_str(&frame, "trust")?,
                owner_user_id: get_str(&frame, "ownerUserId").filter(|value| !value.is_empty()),
                managed_session_token: get_str(&frame, "managedSessionToken"),
            }))
        }
        "upgrade_required" => Some(ServerFrame::UpgradeRequired {
            min_version: get_u64(&frame, "minVersion")?,
            message: get_str(&frame, "message")?,
        }),
        "heartbeat_ack" => Some(ServerFrame::HeartbeatAck),
        "trust_ack" => {
            let trust = get_str(&frame, "trust")?;
            crate::trust::Trust::parse(&trust)?;
            Some(ServerFrame::TrustAck { trust })
        }
        "action_request" => Some(ServerFrame::ActionRequest {
            action_id: get_str(&frame, "actionId")?,
            verb: get_str(&frame, "verb")?,
            raw: frame,
        }),
        "workspace_request" | "fs_watch_open" | "fs_watch_close" => {
            Some(ServerFrame::Workspace { frame })
        }
        "pty_open" | "pty_input" | "pty_resize" | "pty_flow" | "pty_close" | "surface_list" => {
            Some(ServerFrame::Pty { frame_type, raw: frame })
        }
        "error" => Some(ServerFrame::Error {
            code: get_str(&frame, "code")?,
            message: get_str(&frame, "message"),
        }),
        _ => Some(ServerFrame::Unknown { frame_type }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unreadable_frames_are_ignored_and_unknown_types_pass_through() {
        assert!(parse_server_frame("not json").is_none());
        assert!(parse_server_frame("{\"no\":\"type\"}").is_none());
        assert!(parse_server_frame("[1,2]").is_none());
        let unknown = parse_server_frame("{\"type\":\"brand_new\"}").expect("tolerated");
        assert!(
            matches!(unknown, ServerFrame::Unknown { frame_type } if frame_type == "brand_new")
        );
    }

    #[test]
    fn hello_accepted_requires_the_negotiated_fields() {
        let full = serde_json::json!({
            "version": 2,
            "type": "hello_accepted",
            "relayProtocolVersion": 2,
            "heartbeatIntervalMs": 15000,
            "machineName": "mac",
            "scope": "personal",
            "trust": "supervised",
        });
        let parsed = parse_server_frame(&full.to_string()).expect("parses");
        let ServerFrame::HelloAccepted(hello) = parsed else {
            panic!("wrong variant");
        };
        assert_eq!(hello.heartbeat_interval_ms, 15000);
        assert_eq!(hello.owner_user_id, None);

        let missing = serde_json::json!({
            "type": "hello_accepted",
            "relayProtocolVersion": 2,
            "machineName": "mac",
        });
        assert!(parse_server_frame(&missing.to_string()).is_none());

        let zero_interval = serde_json::json!({
            "type": "hello_accepted",
            "relayProtocolVersion": 2,
            "heartbeatIntervalMs": 0,
            "machineName": "mac",
            "scope": "personal",
            "trust": "supervised",
        });
        assert!(parse_server_frame(&zero_interval.to_string()).is_none());

        for (name, value) in [
            ("version", Value::from(FRAME_VERSION - 1)),
            ("version", Value::from(ADVERTISED_PROTOCOL_VERSION + 1)),
            ("relayProtocolVersion", Value::from(FRAME_VERSION - 1)),
            ("relayProtocolVersion", Value::from(ADVERTISED_PROTOCOL_VERSION + 1)),
            ("heartbeatIntervalMs", Value::from(i32::MAX as u64 + 1)),
        ] {
            let mut invalid = full.clone();
            invalid[name] = value;
            assert!(parse_server_frame(&invalid.to_string()).is_none(), "accepted invalid {name}");
        }

        let mut boundary = full;
        boundary["relayProtocolVersion"] = Value::from(ADVERTISED_PROTOCOL_VERSION);
        boundary["heartbeatIntervalMs"] = Value::from(i32::MAX);
        assert!(parse_server_frame(&boundary.to_string()).is_some());
    }

    #[test]
    fn known_frame_types_require_their_protocol_version() {
        let cases = [
            ("heartbeat_ack", FRAME_VERSION),
            ("action_request", EXEC_PROTOCOL_VERSION),
            ("pty_close", PTY_PROTOCOL_VERSION),
            ("workspace_request", crate::workspace::WORKSPACE_FRAME_VERSION as u64),
        ];
        for (frame_type, minimum) in cases {
            let mut valid = serde_json::json!({"type": frame_type, "version": minimum});
            if frame_type == "action_request" {
                valid["actionId"] = Value::from("action_1");
                valid["verb"] = Value::from("exec");
            }
            assert!(parse_server_frame(&valid.to_string()).is_some());

            let too_old = serde_json::json!({"type": frame_type, "version": minimum - 1});
            assert!(parse_server_frame(&too_old.to_string()).is_none());

            let too_new = serde_json::json!({
                "type": frame_type,
                "version": ADVERTISED_PROTOCOL_VERSION + 1,
            });
            assert!(parse_server_frame(&too_new.to_string()).is_none());
        }
    }

    #[test]
    fn trust_ack_only_accepts_canonical_levels() {
        let good = serde_json::json!({
            "version": FRAME_VERSION,
            "type": "trust_ack",
            "trust": "observe",
        });
        assert!(matches!(
            parse_server_frame(&good.to_string()),
            Some(ServerFrame::TrustAck { .. })
        ));
        let bad = serde_json::json!({
            "version": FRAME_VERSION,
            "type": "trust_ack",
            "trust": "root",
        });
        assert!(parse_server_frame(&bad.to_string()).is_none());
    }

    #[test]
    fn hello_frame_serializes_the_v2_wire_shape() {
        let roots = vec!["/srv".to_owned()];
        let hello = HelloFrame {
            version: FRAME_VERSION,
            frame_type: "hello",
            relay_protocol_version: 2,
            cli_version: CLI_VERSION,
            machine_id: "dev_1",
            token: "tok_1",
            allowed_roots: Some(&roots),
            managed_enrollment: None,
        };
        let encoded = serde_json::to_value(&hello).expect("serializes");
        assert_eq!(encoded.get("type"), Some(&Value::from("hello")));
        assert_eq!(encoded.get("machineId"), Some(&Value::from("dev_1")));
        assert_eq!(encoded.get("allowedRoots"), Some(&serde_json::json!(["/srv"])));
        assert_eq!(encoded.get("managedEnrollment"), None);
    }
}
