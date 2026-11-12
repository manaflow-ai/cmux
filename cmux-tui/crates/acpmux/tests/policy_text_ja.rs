//! A refusal for a policy a chat's harness cannot keep (`policy_unenforceable`) reaches the app as
//! its message: in Japanese when the daemon's locale is Japanese, as the CLI's own help is
//! (review of #40790). Its `data` stays the same in every language, for a client that reads the
//! reason.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/), in a Japanese locale.
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().with_env(&[("LANG", "ja_JP.UTF-8")]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{ConnAuth, Origin, serve_connection_authed};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

mod policy_text_ja {
    use super::*;

    /// `session/new` under `policy` on harness `harness` of a daemon with two entries: `lane`
    /// (family `lane`, no mode that asks, no claim) and `unnamed` (the same with no family).
    async fn refusal(harness: &str, policy: &str) -> Value {
        let _ = &HERMETIC;
        let d = std::env::temp_dir().join(format!("ptj-{harness}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(d.join("work")).unwrap();
        let d = std::fs::canonicalize(&d).unwrap();
        let env = json!({"FAKE_ASK_CLAIM": "0"});
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {
                "lane": {"argv": ["python3", FAKE_AGENT], "family": "lane", "env": env},
                "unnamed": {"argv": ["python3", FAKE_AGENT], "env": env},
            },
            "defaultHarness": "lane",
            "permissionPolicy": "approve-all",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub: Arc<Hub> = Hub::new(cfg, store);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, mut out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(
            hub.clone(),
            in_rx,
            out_tx,
            Origin::Local,
            ConnAuth::LocalSocket,
        ));
        let meta = json!({"harness": harness, "policy": policy});
        let params = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": meta}});
        in_tx.send(Message::request(1, "session/new", params).to_line()).await.unwrap();
        let reply = loop {
            let line = tokio::time::timeout(Duration::from_secs(30), out_rx.recv())
                .await
                .expect("an answer in time")
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(1)) {
                break v;
            }
        };
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&d);
        reply
    }

    /// The refusal of a harness with no mode that asks is in Japanese: the policy, the harness,
    /// why and what to do. Its data keeps the reason, the policy and the harness.
    #[tokio::test]
    async fn a_policy_that_cannot_hold_is_refused_in_japanese() {
        let r = refusal("lane", "ask").await;
        assert_eq!(r["error"]["data"]["reason"], json!("policy_unenforceable"), "{r}");
        assert_eq!(r["error"]["data"]["policy"], json!("ask"), "{r}");
        assert_eq!(r["error"]["data"]["harness"], json!("lane"), "{r}");
        let message = r["error"]["message"].as_str().unwrap_or_default();
        for japanese in ["権限ポリシー ask", "ハーネス lane", "チャットは開始されませんでした"]
        {
            assert!(message.contains(japanese), "{japanese:?} in {message}");
        }
        for english in ["cannot be enforced", "did not start", "this agent has no mode"] {
            assert!(!message.contains(english), "{english:?} in {message}");
        }
    }

    /// With no family, the refusal also says, in Japanese, to add `"family"` to the entry.
    #[tokio::test]
    async fn the_family_to_add_is_said_in_japanese() {
        let r = refusal("unnamed", "deny-all").await;
        assert_eq!(r["error"]["data"]["reason"], json!("policy_unenforceable"), "{r}");
        let message = r["error"]["message"].as_str().unwrap_or_default();
        for japanese in ["権限ポリシー deny-all", "\"unnamed\" エントリー", "\"family\""]
        {
            assert!(message.contains(japanese), "{japanese:?} in {message}");
        }
        assert!(!message.contains("cannot be enforced"), "{message}");
    }
}
