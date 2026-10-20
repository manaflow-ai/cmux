#![cfg(unix)]
//! An agent acpmux starts carries a launch credential for its own ACP
//! session (bead cx-55d27, PR 4): acpmux mints it from the cmux session
//! daemon that `CMUX_TUI_SOCKET` names (`credential.mint {acp_session}`), so
//! the agent's `cmux agent message` is sent by a verified sender. Without a
//! reachable daemon the agent still starts, without a credential. Its own
//! binary: the test sets acpmux's process environment.

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test agent_message_launch_credential` selects it.
mod agent_message_launch_credential {
    use super::harness::Daemon;
    use acpmux::config::{Config, StoreMode};
    use acpmux::hub::Hub;
    use acpmux::rpc::Message;
    use acpmux::server::{Origin, serve_connection_with};
    use serde_json::{Value, json};
    use std::time::Duration;
    use tokio::sync::mpsc;

    const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");
    const NAME: &str = "CMUX_LAUNCH_CREDENTIAL";

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn an_acpmux_agent_sends_as_its_own_session() {
        let daemon = tokio::task::spawn_blocking(|| Daemon::start_without_acpmux("acp-cred", &[]))
            .await
            .unwrap();
        // SAFETY: the only test in this binary sets them before any agent starts.
        unsafe {
            std::env::remove_var(NAME);
            std::env::set_var("CMUX_TUI_SOCKET", &daemon.socket);
        }
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        // The cmux-tui binary installs acpmux's build id at start (main.rs); so
        // does this in-process hub, or it reports `unstamped`.
        acpmux::hub::install_build(acpmux_build_id::BUILD);
        let hub = Hub::new(cfg, store);
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub, in_rx, out_tx, Origin::Local));
        let mut client = Client(in_tx, out_rx, 0);

        let (session, value) = client.session_env(NAME).await;
        let credential = value.strip_prefix(&format!("{NAME}=")).unwrap_or_default().to_owned();
        assert!(credential.starts_with("cmuxlc1."), "the agent got no launch credential: {value}");
        let (_, socket) = client.session_env("CMUX_TUI_SOCKET").await;
        assert_eq!(socket, format!("CMUX_TUI_SOCKET={}", daemon.socket.display()));

        // The daemon takes the agent's message as sent by its session.
        let sent = tokio::task::spawn_blocking(move || {
            let sent = daemon.sent(
                Some(&credential),
                json!({"recipients": ["acp:someone"], "body": "from an acpmux agent"}),
            );
            drop(daemon);
            sent
        })
        .await
        .unwrap();
        assert_eq!(sent["sender"], format!("acp:{session}"), "{sent}");

        // No daemon on the socket: the agent starts without a credential.
        // SAFETY: as above.
        unsafe { std::env::set_var("CMUX_TUI_SOCKET", "/nonexistent/cmux-acp-cred.sock") };
        let (_, value) = client.session_env(NAME).await;
        assert_eq!(value, format!("{NAME}="), "a credential without a daemon");
    }

    struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

    impl Client {
        /// A new session and its agent's value of `name` (`NAME=value`).
        async fn session_env(&mut self, name: &str) -> (String, String) {
            let (reply, _) = self
                .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
                .await;
            assert!(reply.get("error").is_none(), "{reply}");
            let session = reply["result"]["sessionId"].as_str().unwrap().to_owned();
            let prompt = json!({"sessionId": session,
                "prompt": [{"type": "text", "text": format!("env: {name}")}]});
            let (_, value) = self.call("session/prompt", prompt).await;
            (session, value)
        }

        /// The reply to one request, and the agent text streamed before it.
        async fn call(&mut self, method: &str, params: Value) -> (Value, String) {
            self.2 += 1;
            let id = self.2;
            self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
            let mut text = String::new();
            loop {
                let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                    .await
                    .unwrap()
                    .unwrap();
                let value: Value = serde_json::from_str(&line).unwrap();
                if value.get("id") == Some(&json!(id)) {
                    return (value, text);
                }
                if let Some(t) =
                    value.pointer("/params/update/content/text").and_then(Value::as_str)
                {
                    text.push_str(t);
                }
            }
        }
    }
}
