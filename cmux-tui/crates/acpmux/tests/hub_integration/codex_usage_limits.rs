//! A Codex chat's plan usage limits (`codex_app_server/usage_limits.rs`): the app-server's
//! `account/rateLimits/updated` becomes the session detail's `usageLimits`, in the shape a
//! Claude chat's take, for the composer ring and Session Info. The fake app-server is
//! tests/fake_codex_app_server.py ("codex-limits").

use super::codex_processes::{chat, codex_hub};
use super::*;

#[tokio::test]
async fn a_codex_chat_keeps_its_accounts_usage_limits() {
    let (hub, mut c, root) = codex_hub().await;
    let quiet = chat(&mut c, "hello").await;
    let info = c.request(method::MUX_INFO, json!({"sessionId": quiet})).await.unwrap();
    // Nothing reported is nothing: no zero.
    assert!(info["usageLimits"].is_null(), "{info}");

    let id = chat(&mut c, "codex-limits").await;
    let want = json!({
        "windows": [
            {"id": "session", "usedPercent": 22.0, "windowMins": 300, "resetsAt": 1_790_000_000},
            {"id": "weekly", "usedPercent": 90.0, "windowMins": 10080, "resetsAt": 1_790_500_000},
        ],
        "plan": "pro",
        "credits": {"balance": "56766"},
    });
    let info = c.request(method::MUX_INFO, json!({"sessionId": id})).await.unwrap();
    assert_eq!(info["usageLimits"], want, "{info}");
    // The open pane's copy: one whole `mux` record per change, none for the quiet chat.
    let records = |id: &str| -> Vec<Value> {
        hub.events(id, 0, 10_000)
            .unwrap()
            .iter()
            .filter(|e| e.dir == "mux" && e.kind == "usage_limits")
            .map(|e| e.msg["usageLimits"].clone())
            .collect()
    };
    assert!(records(&quiet).is_empty());
    assert_eq!(records(&id).last(), Some(&want));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}
