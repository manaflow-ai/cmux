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
    for key in ["short".to_owned(), "x".repeat(129), "control/invalid".into(), "control:é".into()]
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
