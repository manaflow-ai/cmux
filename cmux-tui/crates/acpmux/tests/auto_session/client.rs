//! A second connection to a rig's daemon: the app's pane, a chat's own agent, a remote
//! client. Its replies are read apart from the rig's own connection, so a test can see that one
//! request has no answer yet while another runs.

use super::*;

pub struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Client {
    /// A connection that came in as `origin`.
    pub fn connect(hub: &Arc<Hub>, origin: Origin) -> Client {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client { tx, rx, next: 0 }
    }

    /// The local socket with the agent of chat `id` behind it: its first request carries the
    /// chat's own caller token, as the chat's harness and the shells it starts do.
    pub async fn agent_of(hub: &Arc<Hub>, id: &str) -> Client {
        let mut client = Client::connect(hub, Origin::Local);
        let token = acpmux::hub::person::caller_token(id);
        let hello = json!({
            "protocolVersion": 1,
            "clientInfo": {"name": "acpmux-cli", "version": "0.1.0"},
            "_meta": {"acpmux": {"callerSession": {"sessionId": id, "token": token}}},
        });
        client.reply("initialize", hello).await.expect("initialize");
        client
    }

    /// Sends a request and does not wait for its reply.
    pub async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, method, params).to_line()).await.unwrap();
        self.next
    }

    /// The reply to request `id`: its result or its error. None when none came in `within`.
    pub async fn answer(&mut self, id: i64, within: Duration) -> Option<Result<Value, Value>> {
        let reply = async {
            loop {
                let line = self.rx.recv().await.expect("the connection stays open");
                let v: Value = serde_json::from_str(&line).unwrap();
                if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                    return match v.get("error") {
                        Some(error) => Err(error.clone()),
                        None => Ok(v["result"].clone()),
                    };
                }
            }
        };
        tokio::time::timeout(within, reply).await.ok()
    }

    /// The reply to one request.
    pub async fn reply(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.send(method, params).await;
        self.answer(id, Duration::from_secs(60))
            .await
            .unwrap_or_else(|| panic!("no reply to {method}"))
    }
}
