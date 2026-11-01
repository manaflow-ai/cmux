//! HTTP contract tests: durable browsing must never consume the relay's leased inbox.
use super::*;
use crate::mesh::{Mode, Sender, StartWork, Target};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const ID: &str = "msg_0123456789abcdef0123456789abcdef";

fn receipt(state: &str) -> Value {
    json!({
        "messageId": ID, "state": state, "resolution": "delivered",
        "to": {"teamAddress":"@user_receiver/coordinator", "sessionId":"receiver"},
        "startWork":"information", "createdAt":100,
    })
}

/// A bounded fake server: records precisely one request per supplied response and closes each
/// connection. The join handle is awaited by the test; no daemon or credential command runs.
async fn fake_hub(
    responses: Vec<Value>,
) -> (HttpHub, tokio::task::JoinHandle<Vec<(String, Value)>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let hub = HttpHub::new(&MeshRelayConfig {
        url: format!("http://{}", listener.local_addr().unwrap()),
        token_command: vec!["must-not-run".into()],
        team_messaging: true,
        credential: None,
        control_from: Vec::new(),
    })
    .unwrap();
    *hub.token.lock().await = Some((Arc::new(Zeroizing::new("test-fixture".into())), 0));
    let server = tokio::spawn(async move {
        let mut seen = Vec::new();
        for response in responses {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut bytes = Vec::new();
            let (head_len, body_len) = loop {
                let mut chunk = [0; 1024];
                let n = stream.read(&mut chunk).await.unwrap();
                assert_ne!(n, 0, "request ended before its headers");
                bytes.extend_from_slice(&chunk[..n]);
                if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
                    let headers = String::from_utf8_lossy(&bytes[..end]);
                    let length = headers
                        .lines()
                        .find_map(|line| {
                            let (key, value) = line.split_once(':')?;
                            key.eq_ignore_ascii_case("content-length")
                                .then(|| value.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    break (end + 4, length);
                }
            };
            while bytes.len() < head_len + body_len {
                let mut chunk = [0; 1024];
                let n = stream.read(&mut chunk).await.unwrap();
                assert_ne!(n, 0, "request ended before its body");
                bytes.extend_from_slice(&chunk[..n]);
            }
            let line =
                String::from_utf8_lossy(&bytes[..head_len]).lines().next().unwrap().to_owned();
            let body = if body_len == 0 {
                Value::Null
            } else {
                serde_json::from_slice(&bytes[head_len..head_len + body_len]).unwrap()
            };
            seen.push((line, body));
            let body = response.to_string();
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body,
            );
            stream.write_all(response.as_bytes()).await.unwrap();
        }
        seen
    });
    (hub, server)
}

#[tokio::test]
async fn team_http_send_browse_read_and_acknowledge_use_distinct_paths() {
    tokio::time::timeout(Duration::from_secs(5), async {
        let message = json!({
            "messageId":ID, "kind":"prompt", "body":"release note", "mode":"turn-end",
            "to":{"teamAddress":"@user_receiver/coordinator", "sessionId":"receiver"},
            "from":{"teamAddress":"@user_sender/coordinator"},
            "state":"delivered", "startWork":"information", "createdAt":100,
        });
        let (hub, server) = fake_hub(vec![
            receipt("queued"),
            json!({"messages":[message], "next":100}),
            receipt("read"),
            receipt("acked"),
            receipt("delivered"),
        ])
        .await;
        let sent = hub
            .send(&OutMessage {
                to: Target { team_address: Some("@team/release".into()), ..Target::default() },
                from: Sender { session_id: Some("sender".into()), ..Sender::default() },
                kind: crate::mesh::Kind::Prompt,
                op: None,
                body: "release note".into(),
                mode: Mode::TurnEnd,
                idempotency_key: "team-message-test".into(),
            })
            .await
            .unwrap();
        assert_eq!(sent.start_work, Some(StartWork::Information));
        assert_eq!(sent.to.session_id.as_deref(), Some("receiver"));
        let page =
            hub.team_messages(true, Some("@user_receiver/coordinator"), Some(101)).await.unwrap();
        assert_eq!(page.messages.len(), 1);
        assert_eq!(page.messages[0].body, "release note");
        assert_eq!(page.messages[0].to.session_id.as_deref(), Some("receiver"));
        assert_eq!(page.next, Some(100));
        assert_eq!(hub.read(ID).await.unwrap().state, "read");
        assert_eq!(hub.acknowledge(ID).await.unwrap().state, "acked");
        hub.ack(ID, &Ack::delivered(ID, None)).await.unwrap();
        let seen = server.await.unwrap();
        assert_eq!(seen[0].0, "POST /v1/mesh/messages HTTP/1.1");
        assert_eq!(seen[0].1["to"], json!({"teamAddress":"@team/release"}));
        assert_eq!(seen[0].1["mode"], "turn-end");
        assert!(seen[0].1.get("startWork").is_none(), "only the hub grants work");
        let path = seen[1].0.split_whitespace().nth(1).unwrap();
        let parsed = reqwest::Url::parse(&format!("http://fixture{path}")).unwrap();
        assert_eq!(parsed.path(), "/v1/mesh/messages");
        let query: std::collections::HashMap<_, _> = parsed.query_pairs().into_owned().collect();
        assert_eq!(
            query.get("teamAddress").map(String::as_str),
            Some("@user_receiver/coordinator")
        );
        assert_eq!(query.get("unreadOnly").map(String::as_str), Some("true"));
        assert_eq!(query.get("before").map(String::as_str), Some("101"));
        assert_eq!(seen[2], (format!("POST /v1/mesh/messages/{ID}/read HTTP/1.1"), json!({})));
        assert_eq!(
            seen[3],
            (format!("POST /v1/mesh/messages/{ID}/acknowledge HTTP/1.1"), json!({}))
        );
        assert_eq!(seen[4].0, format!("POST /v1/mesh/messages/{ID}/ack HTTP/1.1"));
        assert_eq!(seen[4].1["state"], "delivered");
    })
    .await
    .expect("bounded fake-hub round trip");
}
