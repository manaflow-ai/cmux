//! `catalog.refresh` and `catalog.changed` over a client connection, and the
//! curated models in `_acpmux/models` and `_acpmux/harnesses`.

use acpmux::catalog::{CatalogService, FetchOutcome, Fetcher};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

struct Once(Value);

impl Fetcher for Once {
    fn fetch<'a>(&'a self, _etag: Option<&'a str>) -> BoxFuture<'a, Result<FetchOutcome, String>> {
        let body = serde_json::to_vec(&self.0).unwrap_or_default();
        Box::pin(async move { Ok(FetchOutcome::Body { body, etag: Some("\"v-next\"".into()) }) })
    }
}

fn hub() -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fcodex": {"argv": ["python3", FAKE], "family": "codex"}},
        "defaultHarness": "fcodex",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

struct Client {
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: u64,
    notes: Vec<Value>,
}

impl Client {
    fn connect(hub: &Arc<Hub>) -> Self {
        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::LocalApp));
        Self { tx, rx, next: 1, notes: Vec::new() }
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        let id = self.next;
        self.next += 1;
        self.tx.send(Message::request(id as i64, m, params).to_line()).await.unwrap();
        loop {
            let v = self.recv().await;
            if v.get("id") == Some(&json!(id)) {
                return v["result"].clone();
            }
            self.notes.push(v);
        }
    }

    async fn recv(&mut self) -> Value {
        let line =
            tokio::time::timeout(Duration::from_secs(20), self.rx.recv()).await.unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    async fn notification(&mut self, m: &str) -> Value {
        if let Some(i) = self.notes.iter().position(|n| n["method"] == m) {
            return self.notes.remove(i)["params"].clone();
        }
        loop {
            let v = self.recv().await;
            if v["method"] == m {
                return v["params"].clone();
            }
        }
    }
}

#[tokio::test]
async fn a_refresh_announces_the_new_catalog_to_every_connection() {
    let hub = hub();
    let dir = std::env::temp_dir().join(format!("acpmux-catalog-rpc-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let next = json!({"schemaVersion": 1, "generatedAt": "2099-01-01T00:00:00.000Z", "source": "live",
        "harnesses": [{"id": "codex", "name": "Codex", "brand": "openai", "families": ["codex"], "modelSource": "catalog", "models": [
            {"id": "gpt-curated", "ref": "openai/gpt-curated", "name": "GPT Curated", "shortName": "Curated", "provider": "openai", "fast": true}]}],
        "models": {"openai/gpt-curated": {"name": "GPT Curated", "contextWindow": 400000}},
        "providers": {"openai": {"name": "OpenAI"}}});
    hub.catalog.attach(dir.clone(), Some(Arc::new(Once(next))));
    let mut watcher = Client::connect(&hub);
    let mut caller = Client::connect(&hub);
    // Both connections are up before the change.
    watcher.call("_acpmux/status", json!({})).await;

    let before = caller.call("_acpmux/models", json!({})).await;
    assert_eq!(before["catalog"]["delivery"], "bundled", "{before}");

    let reply = caller.call(acpmux::catalog::RPC_REFRESH, json!({})).await;
    assert_eq!(reply["changed"], true, "{reply}");
    assert_eq!(reply["schemaVersion"], 1);
    assert_eq!(reply["generatedAt"], "2099-01-01T00:00:00.000Z");
    let event = watcher.notification(acpmux::catalog::EVENT_CHANGED).await;
    assert_eq!(event["generatedAt"], "2099-01-01T00:00:00.000Z", "{event}");
    let got = caller.call(acpmux::catalog::RPC_GET, json!({})).await;
    assert_eq!(got["catalog"]["harnesses"][0]["models"][0]["id"], "gpt-curated", "{got}");

    let models = caller.call("_acpmux/models", json!({})).await;
    let fcodex = models["harnesses"]
        .as_array()
        .unwrap()
        .iter()
        .find(|h| h["harness"] == "fcodex")
        .unwrap()
        .clone();
    assert_eq!(fcodex["models"][0]["id"], "gpt-curated", "{models}");
    assert_eq!(fcodex["models"][0]["curated"], true);
    assert_eq!(fcodex["models"][0]["fast"], true);
    assert_eq!(fcodex["models"][0]["contextWindow"], 400000);
    assert_eq!(fcodex["catalog"]["id"], "codex");
    assert_eq!(models["catalog"]["delivery"], "fetched");

    let harnesses = caller.call("_acpmux/harnesses", json!({})).await;
    assert_eq!(harnesses["catalog"]["harnesses"][0]["profiles"], json!(["fcodex"]), "{harnesses}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_hub_starts_from_the_bundled_catalog() {
    let service = CatalogService::new();
    assert_eq!(service.summary()["delivery"], "bundled");
    assert!(!service.current().harnesses.is_empty());
}
