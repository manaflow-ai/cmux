//! Scripted peer transport: slow pages and a repairable prompt refusal.
use acpmux::rpc::{Message, RpcError, method};
use futures_util::{SinkExt, StreamExt};
use serde_json::json;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicBool, AtomicUsize, Ordering},
};
use std::time::Duration;
use tokio::sync::Notify;
use tokio_tungstenite::tungstenite::Message as Ws;

pub struct Peer {
    pub url: String,
    pub pages: Arc<Mutex<Vec<u64>>>,
    pub requested: Arc<Notify>,
    pub reject: Arc<AtomicBool>,
    pub accepted: Arc<AtomicUsize>,
    task: tokio::task::JoinHandle<()>,
}
impl Peer {
    pub async fn new(delay: Duration, sessions: usize) -> Self {
        Self::scripted(delay, sessions, 601, false).await
    }
    pub async fn scripted(delay: Duration, sessions: usize, summary: u64, timeout: bool) -> Self {
        let stall = Arc::new(AtomicBool::new(timeout));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        let pages = Arc::new(Mutex::new(Vec::new()));
        let requested = Arc::new(Notify::new());
        let reject = Arc::new(AtomicBool::new(false));
        let accepted = Arc::new(AtomicUsize::new(0));
        let (seen, note, refusal, delivered) =
            (pages.clone(), requested.clone(), reject.clone(), accepted.clone());
        let task = tokio::spawn(async move {
            let mut connections = tokio::task::JoinSet::new();
            while let Ok((tcp, _)) = listener.accept().await {
                let (seen, note, refusal, delivered) =
                    (seen.clone(), note.clone(), refusal.clone(), delivered.clone());
                let stall = stall.clone();
                connections.spawn(async move {
                    let mut ws = tokio_tungstenite::accept_async(tcp).await.unwrap();
                    while let Some(Ok(Ws::Text(text))) = ws.next().await {
                        let Ok(Message::Request { id, method: m, params }) = Message::parse(&text) else { continue };
                        let p = params.unwrap_or_default();
                        let result = match m.as_str() {
                            method::INITIALIZE => json!({"protocolVersion": 1, "_meta": {"acpmux": {"origin": "peer"}}}),
                            method::MUX_WATCH => json!({"sessions": (0..sessions).map(|i| json!({
                                "sessionId": format!("job-{i}"), "status": "ready", "lastSeq": summary,
                                "lastTurn": {"turnId": "finished"}})).collect::<Vec<_>>()}),
                            method::MUX_EVENTS => {
                                let after = p["afterSeq"].as_u64().unwrap_or(0);
                                seen.lock().unwrap().push(after);
                                note.notify_one();
                                let pause = if after == 256 && stall.swap(false, Ordering::SeqCst) { Duration::from_millis(400) } else { delay };
                                tokio::time::sleep(pause).await;
                                let events: Vec<_> = ((after+1)..=601.min(after+256)).map(|seq| if seq == 601 { json!({"seq": seq, "at": 1, "dir": "mux", "kind": "turn_result", "msg": {"turnId": "finished"}}) } else { json!({
                                    "seq": seq, "at": 1, "dir": "in", "kind": "agent_message_chunk",
                                    "msg": {"params": {"update": {"content": {"text": if seq == 600 {"complete"} else {"."}}}}}
                                }) }).collect();
                                json!({"events": events, "lastSeq": 601, "hasMore": after + 256 < 601})
                            }
                            method::SESSION_PROMPT if refusal.load(Ordering::SeqCst) => {
                                let reply = Message::err(id, RpcError::invalid_params("injected recipient refusal")).to_line();
                                if ws.send(Ws::Text(reply.into())).await.is_err() { break; }
                                continue;
                            }
                            method::SESSION_PROMPT => { delivered.fetch_add(1, Ordering::SeqCst); json!({"stopReason": "end_turn"}) }
                            _ => json!({}),
                        };
                        if ws.send(Ws::Text(Message::ok(id, result).to_line().into())).await.is_err() { break; }
                    }
                });
            }
        });
        Self { url, pages, requested, reject, accepted, task }
    }
    pub async fn read_started(&self) {
        tokio::time::timeout(Duration::from_secs(10), self.requested.notified()).await.unwrap();
    }
    pub async fn connect(&self, daemon: &super::daemon::Daemon) {
        daemon
            .call("_acpmux/peer_add", json!({"name": "scripted", "url": self.url, "wait": true}))
            .await;
    }
}
impl Drop for Peer {
    fn drop(&mut self) {
        self.task.abort();
    }
}
