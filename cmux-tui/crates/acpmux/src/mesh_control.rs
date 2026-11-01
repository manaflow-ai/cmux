//! Sender-side lifecycle controls for the shared mesh relay client.
//!
//! Wire contract: cmux-platform openapi 1.3.0 (`POST /v1/mesh/messages`). This module
//! owns control payloads only; the relay client owns HTTP, authentication, inbox leasing,
//! receipts and acknowledgements. A successful enqueue is not successful execution.
//!
//! The receiver in `server/mesh_relay.rs` admits only hub-stamped daemon ids explicitly
//! allowed by the target owner's `meshRelay.controlFrom`, then uses existing peer rules.
//! Claimed user, host, name and session fields never confer authority.

use serde::Serialize;
use serde_json::{Map, Value};
use std::future::Future;
use std::sync::Arc;

const MAX_BODY_BYTES: usize = 64 * 1024;

/// Hub lookup keys. Names remain names until the hub resolves them, refusing ambiguity.
#[derive(Clone, Debug, Serialize)]
#[serde(untagged)]
pub enum Recipient {
    Session {
        #[serde(rename = "sessionId")]
        session_id: String,
    },
    Name {
        name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        host: Option<String>,
    },
    Daemon {
        #[serde(rename = "daemonId")]
        daemon_id: String,
    },
    Host {
        host: String,
    },
}

impl Recipient {
    fn validate(&self) -> Result<(), InvalidControl> {
        let valid = |s: &str| !s.trim().is_empty() && s.chars().count() <= 128;
        let valid = match self {
            Self::Session { session_id } => valid(session_id),
            Self::Name { name, host } => valid(name) && host.as_deref().is_none_or(valid),
            Self::Daemon { daemon_id } => valid(daemon_id),
            Self::Host { host } => valid(host),
        };
        if valid { Ok(()) } else { Err(InvalidControl::Recipient) }
    }
}

/// The body is versioned independently from the hub, which stores it as opaque text.
/// Start params are the existing `session/new` object, including requested policy/mode;
/// the target must authorize those fields. Resume releases held prompts; stop closes
/// the agent without purging the stored session, matching the peer lifecycle commands.
#[derive(Clone, Debug)]
pub enum Command {
    Start { params: Map<String, Value> },
    Resume,
    Stop,
}

impl Command {
    fn wire(&self) -> (&'static str, Value) {
        match self {
            Self::Start { params } => {
                ("start", serde_json::json!({"version": 1, "params": params}))
            }
            Self::Resume => ("resume", serde_json::json!({"version": 1})),
            Self::Stop => ("stop", serde_json::json!({"version": 1})),
        }
    }
}

/// Constructed once and reused after transport failures. No sender identity is accepted
/// from the command: the shared relay client supplies the authenticated sender context.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ControlRequest {
    to: Recipient,
    kind: &'static str,
    op: &'static str,
    body: String,
    mode: &'static str,
    idempotency_key: String,
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum InvalidControl {
    #[error("control recipient fields must contain 1–128 characters")]
    Recipient,
    #[error(
        "control idempotency key must contain 8–128 ASCII letters, digits, '.', '_', ':' or '-'"
    )]
    IdempotencyKey,
    #[error("control body exceeds 64 KiB")]
    BodyTooLarge,
}

impl ControlRequest {
    pub fn new(
        to: Recipient,
        command: Command,
        idempotency_key: String,
    ) -> Result<Self, InvalidControl> {
        to.validate()?;
        if !(8..=128).contains(&idempotency_key.len())
            || !idempotency_key.bytes().all(|b| b.is_ascii_alphanumeric() || b"._:-".contains(&b))
        {
            return Err(InvalidControl::IdempotencyKey);
        }
        let (op, body) = command.wire();
        let body = body.to_string();
        if body.len() > MAX_BODY_BYTES {
            return Err(InvalidControl::BodyTooLarge);
        }
        Ok(Self { to, kind: "control", op, body, mode: "now", idempotency_key })
    }
}

/// Adapter seam for piece 1b's client. Implementations preserve the hub's ambiguity
/// candidates and refusal errors; callers must not retry a different recipient on error.
/// The associated types are the shared client's receipt/error types, not a second copy.
pub trait ControlRelay {
    type Receipt;
    type Error;

    fn enqueue_control(
        &self,
        request: &ControlRequest,
    ) -> impl Future<Output = Result<Self::Receipt, Self::Error>> + Send;
}

/// Submit exactly the validated request. The durable receipt belongs to the relay client;
/// this layer never polls or claims delivery merely because the hub accepted the message.
pub async fn submit<R: ControlRelay>(
    relay: &R,
    request: &ControlRequest,
) -> Result<R::Receipt, R::Error> {
    relay.enqueue_control(request).await
}

/// Adapter over the landed relay client. It deliberately takes the sender context from the
/// daemon, never from a control command or the hub's `from.user` field.
pub struct MeshControlRelay {
    hub: Arc<dyn crate::mesh::MeshHub>,
    sender: crate::mesh::Sender,
}

impl MeshControlRelay {
    pub fn new(hub: Arc<dyn crate::mesh::MeshHub>, sender: crate::mesh::Sender) -> Self {
        Self { hub, sender }
    }
}

impl ControlRelay for MeshControlRelay {
    type Receipt = crate::mesh::Receipt;
    type Error = crate::mesh::HubError;

    fn enqueue_control(
        &self,
        request: &ControlRequest,
    ) -> impl Future<Output = Result<Self::Receipt, Self::Error>> + Send {
        let message = crate::mesh::OutMessage {
            to: request.to.clone().into(),
            from: self.sender.clone(),
            kind: crate::mesh::Kind::Control,
            op: Some(request.op.to_owned()),
            body: request.body.clone(),
            mode: crate::mesh::Mode::Now,
            idempotency_key: request.idempotency_key.clone(),
        };
        async move { self.hub.send(&message).await }
    }
}

impl From<Recipient> for crate::mesh::Target {
    fn from(recipient: Recipient) -> Self {
        match recipient {
            Recipient::Session { session_id } => {
                Self { session_id: Some(session_id), ..Self::default() }
            }
            Recipient::Name { name, host } => Self { name: Some(name), host, ..Self::default() },
            Recipient::Daemon { daemon_id } => {
                Self { daemon_id: Some(daemon_id), ..Self::default() }
            }
            Recipient::Host { host } => Self { host: Some(host), ..Self::default() },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::Mutex;

    #[derive(Debug, PartialEq)]
    enum Refusal {
        Ambiguous(Vec<String>),
        Unknown,
    }

    // Acts as the hub's durable enqueue boundary, not as the receiving daemon. That
    // separation prevents a test receipt from accidentally standing in for authorization.
    #[derive(Default)]
    struct FakeHub {
        queued: Mutex<Vec<Value>>,
    }

    impl ControlRelay for FakeHub {
        type Receipt = Value;
        type Error = Refusal;

        async fn enqueue_control(&self, request: &ControlRequest) -> Result<Value, Refusal> {
            let wire = serde_json::to_value(request).unwrap();
            if wire["to"]["name"] == "duplicate" {
                return Err(Refusal::Ambiguous(vec!["one/s1".into(), "two/s2".into()]));
            }
            if wire["to"]["sessionId"] == "missing" {
                return Err(Refusal::Unknown);
            }
            let mut queued = self.queued.lock().unwrap();
            let index = queued
                .iter()
                .position(|v| v["idempotencyKey"] == wire["idempotencyKey"])
                .unwrap_or_else(|| {
                    queued.push(wire);
                    queued.len() - 1
                });
            Ok(json!({"messageId": format!("message-{index}"), "state": "queued"}))
        }
    }

    #[tokio::test]
    async fn all_controls_enqueue_once_without_claiming_delivery() {
        let hub = FakeHub::default();
        let start = Command::Start {
            params: json!({"cwd": "/project", "_meta": {
                "acpmux": {"harness": "codex", "policy": "ask", "mode": "normal"}
            }})
            .as_object()
            .unwrap()
            .clone(),
        };
        let controls = [
            (Recipient::Host { host: "worker".into() }, start, "start"),
            (Recipient::Session { session_id: "s1".into() }, Command::Resume, "resume"),
            (
                Recipient::Name { name: "review".into(), host: Some("worker".into()) },
                Command::Stop,
                "stop",
            ),
        ];
        for (to, command, op) in controls {
            let request = ControlRequest::new(to, command, format!("control:{op}")).unwrap();
            let receipt = submit(&hub, &request).await.unwrap();
            assert_eq!(receipt["state"], "queued");
            assert_eq!(submit(&hub, &request).await.unwrap(), receipt);
        }
        let queued = hub.queued.lock().unwrap();
        assert_eq!(queued.len(), 3);
        for (row, op) in queued.iter().zip(["start", "resume", "stop"]) {
            assert_eq!(row["kind"], "control");
            assert_eq!(row["op"], op);
            assert_eq!(row["mode"], "now");
            assert!(row.get("from").is_none());
        }
        let body: Value = serde_json::from_str(queued[0]["body"].as_str().unwrap()).unwrap();
        assert_eq!(body["params"]["_meta"]["acpmux"]["policy"], "ask");
        assert_eq!(queued[1]["to"], json!({"sessionId": "s1"}));
        assert_eq!(queued[2]["to"], json!({"name": "review", "host": "worker"}));
    }

    #[tokio::test]
    async fn hub_refusals_keep_candidates_and_never_fall_back() {
        let hub = FakeHub::default();
        let request = ControlRequest::new(
            Recipient::Name { name: "duplicate".into(), host: None },
            Command::Stop,
            "control:ambiguous".into(),
        )
        .unwrap();
        assert_eq!(
            submit(&hub, &request).await,
            Err(Refusal::Ambiguous(vec!["one/s1".into(), "two/s2".into()]))
        );
        let request = ControlRequest::new(
            Recipient::Session { session_id: "missing".into() },
            Command::Resume,
            "control:unknown".into(),
        )
        .unwrap();
        assert_eq!(submit(&hub, &request).await, Err(Refusal::Unknown));
        assert!(hub.queued.lock().unwrap().is_empty());
    }

    #[test]
    fn invalid_controls_are_rejected_before_transport() {
        let recipient = || Recipient::Daemon { daemon_id: "daemon-1".into() };
        for key in
            ["short".to_owned(), "x".repeat(129), "control/invalid".into(), "control:é".into()]
        {
            assert_eq!(
                ControlRequest::new(recipient(), Command::Stop, key).unwrap_err(),
                InvalidControl::IdempotencyKey
            );
        }
        assert!(ControlRequest::new(recipient(), Command::Stop, "A0._:-xy".into()).is_ok());
        assert!(ControlRequest::new(recipient(), Command::Stop, "x".repeat(128)).is_ok());
        let command = Command::Start {
            params: json!({"prompt": "é".repeat(32768)}).as_object().unwrap().clone(),
        };
        assert_eq!(
            ControlRequest::new(recipient(), command, "control:large".into()).unwrap_err(),
            InvalidControl::BodyTooLarge
        );
        assert_eq!(
            ControlRequest::new(
                Recipient::Host { host: String::new() },
                Command::Stop,
                "control:empty".into()
            )
            .unwrap_err(),
            InvalidControl::Recipient
        );
    }
}
