use acpmux::{hub::Hub, rpc::Message, server::Origin};
use serde_json::Value;
use std::{sync::Arc, time::Duration};
use tokio::sync::mpsc;

pub struct Connection(mpsc::Sender<String>, mpsc::Receiver<String>);
impl Connection {
    pub fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (tx, input) = mpsc::channel(64);
        let (output, rx) = mpsc::channel(64);
        tokio::spawn(acpmux::server::serve_connection_with(hub.clone(), input, output, origin));
        Self(tx, rx)
    }
    pub async fn call(&mut self, method: &str, params: Value) -> Value {
        self.0.send(Message::request(1, method, params).to_line()).await.unwrap();
        tokio::time::timeout(Duration::from_secs(20), async {
            loop {
                let v: Value = serde_json::from_str(&self.1.recv().await.unwrap()).unwrap();
                if v["id"] == 1 {
                    return v;
                }
            }
        })
        .await
        .unwrap()
    }
    pub async fn result(&mut self, method: &str, params: Value) -> Value {
        let v = self.call(method, params).await;
        assert!(v.get("error").is_none(), "{v}");
        v["result"].clone()
    }
}
