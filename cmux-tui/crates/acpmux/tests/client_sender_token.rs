//! The CLI's client sends this host's sender token only to a daemon that lists the `senderToken`
//! feature at `initialize` (`sender_token::FEATURE`). A daemon from before the token keeps what
//! it does not know: its outbox stores a queued send's whole request and its peer link forwards
//! it. Every request leaves through one place (`client.rs` `send_request`), so `session/prompt`,
//! `send --no-wait`'s and `--tag`'s `_acpmux/send_queue`, and any later path are all covered
//! (reviews of #41064 at 8cc17ed2, F2, and 814a7eba, F1).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// No agent starts here: the daemon is a stand-in socket.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::client::Client;
use serde_json::{Value, json};
use std::path::PathBuf;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::mpsc;

/// A stand-in daemon on `path` that lists `features` at `initialize`, answers every request with
/// an empty result, and hands each request after `initialize` to the test, whole.
fn stand_in(path: PathBuf, features: Vec<&'static str>) -> mpsc::Receiver<Value> {
    let (seen, rx) = mpsc::channel(16);
    let listener = UnixListener::bind(&path).unwrap();
    tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (rd, mut wr) = stream.into_split();
        let mut lines = BufReader::new(rd).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            let m: Value = serde_json::from_str(&line).unwrap();
            let Some(id) = m.get("id").cloned() else { continue };
            let result = if m["method"] == "initialize" {
                json!({"protocolVersion": 1, "_meta": {"acpmux": {"features": features}}})
            } else {
                let _ = seen.send(m).await;
                json!({})
            };
            let reply = json!({"jsonrpc": "2.0", "id": id, "result": result});
            wr.write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        }
    });
    rx
}

#[tokio::test]
async fn the_token_goes_only_to_a_daemon_that_takes_it() {
    let token = "c".repeat(64);
    let mux = || json!({"fromAgent": "outbox-relay", "senderToken": token});
    let prompt = || json!({"sessionId": "s", "prompt": [], "_meta": {"acpmux": mux()}});
    let queued = || json!({"request": prompt()});
    for (name, features, kept) in [
        ("old", vec!["promptAccepted"], false),
        ("new", vec!["promptAccepted", "senderToken"], true),
    ] {
        // Short: a socket path has a length limit.
        let path = std::path::Path::new("/tmp")
            .join(format!("acpmux-ct-{name}-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let mut seen = stand_in(path.clone(), features);
        let client = Client::connect_without_caller(&path).await.unwrap();
        for (method, params) in [("_acpmux/send_queue", queued()), ("session/prompt", prompt())] {
            client.request(method, params).await.unwrap();
            let sent = seen.recv().await.unwrap();
            assert_eq!(sent["method"], method, "{name}: {sent}");
            let text = sent.to_string();
            assert_eq!(text.contains(&token), kept, "{name} {method}: {sent}");
            // Only the token goes: the rest of the send is as it was.
            assert!(text.contains("outbox-relay"), "{name} {method}: {sent}");
        }
        drop(client);
        let _ = std::fs::remove_file(&path);
    }
}
