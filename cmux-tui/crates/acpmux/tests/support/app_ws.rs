//! The app's own WebSocket connection to an in-process daemon (`server/local_app.rs`): a
//! loopback listener with this test's LocalApp token, the pane's `Origin`, and `initialize`
//! carrying the token. Upload tests send binary data frames on it (`server/upload_frames.rs`).
#![allow(dead_code)]

use acpmux::hub::Hub;
use acpmux::server::local_app::{LocalAppAuth, token_path};
use acpmux::server::{AGENT_PANE_ORIGIN, WsAuth, bind_ws, serve_ws_with};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio_tungstenite::tungstenite::{Message, client::IntoClientRequest};

type Ws =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// A listener for `hub` that knows a LocalApp token: its URL and the token.
pub struct Listener {
    pub url: String,
    pub token: String,
}

pub async fn listen(hub: &Arc<Hub>) -> Listener {
    let dir: PathBuf = std::env::temp_dir().join(format!("app-ws-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let auth = LocalAppAuth::create(&dir, &[AGENT_PANE_ORIGIN.to_owned()]).unwrap();
    let token = std::fs::read_to_string(token_path(&dir)).unwrap();
    let l = bind_ws("127.0.0.1:0").await.unwrap();
    let url = format!("ws://127.0.0.1:{}/", l.local_addr().unwrap().port());
    let ws_auth = WsAuth { local_app: Some(Arc::new(auth)), peer: None };
    tokio::spawn(serve_ws_with(hub.clone(), l, "tok".into(), ws_auth));
    Listener { url, token }
}

pub struct AppWs {
    ws: Ws,
    next: i64,
    /// What `initialize` answered.
    pub init: Value,
}

impl AppWs {
    /// The app's connection when `app`, else a remote (Web) one with only the listener token.
    pub async fn open(l: &Listener, app: bool) -> Self {
        let mut req = l.url.as_str().into_client_request().unwrap();
        req.headers_mut().insert("authorization", "Bearer tok".parse().unwrap());
        req.headers_mut().insert("origin", AGENT_PANE_ORIGIN.parse().unwrap());
        let (ws, _) = tokio_tungstenite::connect_async(req).await.unwrap();
        let mut c = Self { ws, next: 0, init: Value::Null };
        let meta = if app { json!({"localAppToken": l.token}) } else { json!({}) };
        let params = json!({"protocolVersion": 1, "clientInfo": {"name": "upload-test"},
            "_meta": {"acpmux": meta}});
        c.init = c.call("initialize", params).await;
        c
    }

    pub async fn post(&mut self, m: &str, params: Value) -> i64 {
        self.next += 1;
        let req = json!({"jsonrpc": "2.0", "id": self.next, "method": m, "params": params});
        self.ws.send(Message::Text(req.to_string().into())).await.unwrap();
        self.next
    }

    pub async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.post(m, params).await;
        self.answer(id).await
    }

    /// Sends one binary data frame; answers its request id.
    pub async fn frame(&mut self, session: &str, upload: &str, offset: u64, bytes: &[u8]) -> i64 {
        self.next += 1;
        // `docs/prompt-uploads.md` section 1: "AMUP", the header's length, the header, the bytes.
        let header = json!({"jsonrpc": "2.0", "id": self.next, "method": "_acpmux/file_put_data",
            "params": {"sessionId": session, "uploadId": upload, "offset": offset}})
        .to_string();
        let mut f = Vec::with_capacity(8 + header.len() + bytes.len());
        f.extend_from_slice(b"AMUP");
        f.extend_from_slice(&u32::try_from(header.len()).unwrap().to_be_bytes());
        f.extend_from_slice(header.as_bytes());
        f.extend_from_slice(bytes);
        self.ws.send(Message::Binary(f.into())).await.unwrap();
        self.next
    }

    /// The response to request `id`; anything else in between is skipped.
    pub async fn answer(&mut self, id: i64) -> Value {
        self.answers_until(id).await.pop().unwrap_or_default()
    }

    /// Every response up to and including the one to request `id`, in the order they came.
    pub async fn answers_until(&mut self, id: i64) -> Vec<Value> {
        let mut answers = Vec::new();
        loop {
            let frame = tokio::time::timeout(Duration::from_secs(20), self.ws.next())
                .await
                .unwrap_or_else(|_| panic!("no answer to request {id} in 20 s"))
                .expect("open")
                .unwrap();
            if let Message::Text(t) = frame {
                let v: Value = serde_json::from_str(&t).unwrap();
                let done = v.get("id") == Some(&json!(id));
                if v.get("id").is_some() && v.get("method").is_none() {
                    answers.push(v);
                }
                if done {
                    return answers;
                }
            }
        }
    }
}
