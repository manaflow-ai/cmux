#![cfg(unix)]
//! acpmux asks the cmux session daemon that `CMUX_TUI_SOCKET` names for a
//! launch credential for each agent's ACP session (`credential.mint
//! {acp_session}`, bead cx-55d27). Since dab1e80a0f8 only the verified cmux
//! app mints, so the daemon refuses acpmux (`credential_owner_only`) and the
//! agent starts without a credential, as it does without a daemon; its
//! messages go out unverified until the app can delegate mint authority.
//! A credential the app mints still sends as its session
//! (agent_message_policy `the_sender_is_the_verified_actor`). Its own binary:
//! the test sets acpmux's process environment.

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
    async fn an_acpmux_agent_starts_without_a_credential_the_daemon_refuses() {
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

        // acpmux is not the verified app: the daemon refuses its mint, and
        // the agent starts without a credential.
        let (_, value) = client.session_env(NAME).await;
        assert_eq!(value, format!("{NAME}="), "acpmux minted a credential: {value}");
        tokio::task::spawn_blocking(move || drop(daemon)).await.unwrap();

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
