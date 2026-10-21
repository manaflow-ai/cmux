#![cfg(unix)]
//! The agent pane's Reply in place (IncomingMessageCard.tsx, #22310) is a cmux agent message
//! like any other: the pane's reply goes through acpmux (`Hub::app_reply_fits`: from the chat
//! the pane shows, to the chat that sent the message it answers, in that message's thread) to
//! the session daemon's `agent.message.send`, as that chat. The store gives it an id, the pump
//! delivers it with the `Reply with` line, `--reply-to` answers it, its sender or the person
//! unsends it and it is in the inbox history. acpmux never prompts the other chat with it
//! directly, and no other origin may send one. Its own binary: the test sets acpmux's process
//! environment (`CMUX_TUI_SOCKET`).

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test agent_message_reply_in_place` selects it.
mod agent_message_reply_in_place {
    use super::harness::{Daemon, delivery};
    use acpmux::config::{Config, StoreMode};
    use acpmux::hub::Hub;
    use acpmux::rpc::Message;
    use acpmux::server::{Origin, serve_connection_with};
    use serde_json::{Value, json};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::sync::mpsc;

    const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");

    /// `f` off the runtime's threads: the daemon calls block.
    async fn blocking<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
        tokio::task::spawn_blocking(f).await.unwrap()
    }

    fn prompt(session: &str, prompt_id: &str, text: &str, provenance: &Value) -> Value {
        json!({"sessionId": session, "prompt": [{"type": "text", "text": text}],
               "_meta": {"acpmux": {"promptId": prompt_id, "provenance": provenance}}})
    }

    /// What the pane sends for chat `from` answering `parent` from chat `to` (direct.ts `reply`).
    fn app_reply(from: &str, to: &str, parent: &Value) -> Value {
        json!({"kind": "agent_message", "from": from, "to": to, "msgId": "m-reply-1",
               "threadId": parent["thread_id"], "replyTo": parent["id"]})
    }

    fn state(message: &Value, recipient: &str) -> String {
        delivery(message, recipient)["state"].as_str().unwrap_or_default().to_owned()
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_reply_in_place_is_a_stored_agent_message_and_goes_nowhere_else() {
        let daemon = Arc::new(blocking(|| Daemon::start_owner_with_acpmux("reply-in-place")).await);
        // SAFETY: the only test in this binary sets them before any agent starts.
        unsafe {
            std::env::remove_var("CMUX_LAUNCH_CREDENTIAL");
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
        let hub = Hub::new(cfg, store);
        let mut local = Client::open_as(&hub, Origin::Local);
        let sender = local.new_session().await;
        let replier = local.new_session().await;
        let unshown = local.new_session().await;
        let d = daemon.clone();
        let (sender_cred, replier_cred) = {
            let (sender, replier, unshown) = (sender.clone(), replier.clone(), unshown.clone());
            blocking(move || {
                let (_, alpha) = d.workspace("alpha");
                for chat in [&sender, &replier, &unshown] {
                    d.place_session(chat, &alpha);
                }
                (d.acp_credential(&sender), d.acp_credential(&replier))
            })
            .await
        };

        // `sender`'s agent messages `replier` (and `unshown`), and the pump hands it to each chat
        // as a prompt with the store's provenance (agent_message_acpmux.rs).
        let d = daemon.clone();
        let (to_replier, to_unshown) = (format!("acp:{replier}"), format!("acp:{unshown}"));
        let recipients = json!([to_replier, to_unshown]);
        let parent = blocking(move || {
            d.sent(Some(&sender_cred), json!({"recipients": recipients, "body": "Rebase on main."}))
        })
        .await;
        let parent_id = parent["id"].as_str().unwrap().to_owned();
        for chat in [&replier, &unshown] {
            let address = format!("acp:{chat}");
            let got = cmux_tui_core::agent_message_prompt::provenance(&parent, &address)
                .unwrap_or_else(|| panic!("no provenance: {parent}"));
            let text = cmux_tui_core::agent_message_prompt::render(std::slice::from_ref(&parent));
            local.call("session/prompt", prompt(chat, &parent_id, &text, &got)).await;
        }

        // The pane shows `replier` and holds `sender` unseen to reply to it (offerChildren).
        let mut app = Client::open_as(&hub, Origin::LocalApp);
        app.call("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;
        app.call("_acpmux/attach", json!({"sessionId": sender, "limit": 0, "visible": false}))
            .await;
        let (from, to) = (format!("acp:{replier}"), format!("acp:{sender}"));
        let reply = app_reply(&from, &to, &parent);
        let answered = app
            .call("session/prompt", prompt(&sender, "m-reply-1", "Rebased; tests pass.", &reply))
            .await;
        let id = answered
            .pointer("/_meta/acpmux/agentMessage/id")
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("the reply got no agent message id: {answered}"))
            .to_owned();
        assert!(id.starts_with("msg_"), "{answered}");

        // Stored as `replier`'s reply in the thread, signed with its own name, and delivered to
        // `sender` by the pump as any agent message is: with the `Reply with` line.
        let info = local.call("_acpmux/info", json!({"sessionId": replier})).await;
        let names: Vec<String> = [&info["title"], &info["name"]]
            .into_iter()
            .filter_map(Value::as_str)
            .map(|n| n.trim().to_owned())
            .chain([replier.clone()])
            .collect();
        let d = daemon.clone();
        let (wait_id, wait_to) = (id.clone(), to.clone());
        let stored = blocking(move || {
            d.wait_for(&wait_id, "delivery", |m| state(m, &wait_to) == "delivered")
        })
        .await;
        assert_eq!(stored["sender"], from.as_str(), "{stored}");
        assert_eq!(stored["in_reply_to"], parent_id.as_str(), "{stored}");
        assert_eq!(stored["thread_id"], parent["thread_id"], "{stored}");
        assert_eq!(stored["body"], "Rebased; tests pass.", "{stored}");
        let signed = stored["sender_name"].as_str().unwrap_or_default().to_owned();
        assert!(names.contains(&signed), "{signed:?} not in {names:?}: {stored}");
        let prompts = daemon.prompts();
        let delivered = prompts
            .iter()
            .find(|p| p["_meta"]["acpmux"]["promptId"] == id.as_str())
            .unwrap_or_else(|| panic!("the pump never delivered {id}: {prompts:?}"));
        assert_eq!(delivered["sessionId"], sender.as_str(), "{delivered}");
        let text = delivered["prompt"][0]["text"].as_str().unwrap_or_default();
        assert!(
            text.contains(&format!("Reply with: cmux agent message --reply-to {id} \"<text>\"")),
            "{text}"
        );
        assert!(text.contains(&format!("In reply to: {parent_id}")), "{text}");
        // acpmux did not prompt `sender` with it itself.
        let direct = local.records(&sender, "user_message").await;
        assert!(
            direct.iter().all(|m| m["promptId"] != "m-reply-1"),
            "prompted directly: {direct:?}"
        );

        // The same reply again is the same message.
        let again = app
            .call("session/prompt", prompt(&sender, "m-reply-1", "Rebased; tests pass.", &reply))
            .await;
        assert_eq!(again.pointer("/_meta/acpmux/agentMessage/id"), Some(&json!(id)), "{again}");

        // Default deny, as #22310: a chat the pane does not show, a bare id for either chat, or
        // any origin but the app pane. Nothing more is stored.
        let refused = [
            (Origin::LocalApp, app_reply(&format!("acp:{unshown}"), &to, &parent)),
            (Origin::LocalApp, app_reply(&replier, &to, &parent)),
            (Origin::LocalApp, app_reply(&from, &sender, &parent)),
            (Origin::LocalApp, app_reply(&from, &format!("acp:{unshown}"), &parent)),
            (Origin::Web, reply.clone()),
            (Origin::Peer, reply.clone()),
        ];
        for (origin, bad) in refused {
            let mut other = Client::open_as(&hub, origin);
            if origin == Origin::LocalApp {
                other.call("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;
            }
            let value =
                other.reply("session/prompt", prompt(&sender, "m-reply-bad", "hi", &bad)).await;
            assert_eq!(
                value.pointer("/error/data/reason"),
                Some(&json!("provenance.origin_refused")),
                "{origin:?} {bad}: {value}"
            );
        }

        // `sender` answers it with `--reply-to`; inbox history holds it; its sender unsends it.
        let d = daemon.clone();
        let (reply_id, replier_address) = (id.clone(), from.clone());
        let (answer, history, mine) = blocking(move || {
            let credential = d.acp_credential(&sender);
            let answer =
                d.sent(Some(&credential), json!({"in_reply_to": reply_id, "body": "Thanks."}));
            let history = d.list(json!({"recipient": format!("acp:{sender}"), "limit": 100}));
            let mine = d.list(json!({"sender": replier_address, "limit": 100}));
            d.withdraw_answers(&sender, "retracted");
            (answer, history, mine)
        })
        .await;
        assert_eq!(answer["in_reply_to"], id.as_str(), "{answer}");
        let answered_to = state(&answer, &from);
        assert!(["queued", "delivered"].contains(&answered_to.as_str()), "{answer}");
        assert!(history.iter().any(|m| m["id"] == id.as_str()), "{history:?}");
        assert_eq!(mine.len(), 1, "a refused reply was stored: {mine:?}");
        let d = daemon.clone();
        let unsend_id = id.clone();
        let unsent = blocking(move || {
            d.mutate("agent.message.unsend", json!({"message_id": unsend_id}), Some(&replier_cred))
        })
        .await;
        assert_eq!(unsent["ok"], true, "{unsent}");
        let outcome = unsent["result"]["value"]["outcomes"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|o| o["recipient"] == to.as_str())
            .and_then(|o| o["outcome"].as_str())
            .unwrap_or_default()
            .to_owned();
        assert_eq!(outcome, "retracted", "{unsent}");
    }

    struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

    impl Client {
        fn open_as(hub: &Arc<Hub>, origin: Origin) -> Self {
            let (in_tx, in_rx) = mpsc::channel(64);
            let (out_tx, out_rx) = mpsc::channel(4096);
            tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
            Self(in_tx, out_rx, 0)
        }

        /// The raw reply to one request (an error is returned, not asserted).
        async fn reply(&mut self, method: &str, params: Value) -> Value {
            self.2 += 1;
            let id = self.2;
            self.0.send(Message::request(id, method, params).to_line()).await.unwrap();
            loop {
                let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                    .await
                    .expect("timed out")
                    .expect("connection closed");
                let value: Value = serde_json::from_str(&line).unwrap();
                if value.get("id") == Some(&json!(id)) {
                    return value;
                }
            }
        }

        async fn call(&mut self, method: &str, params: Value) -> Value {
            let value = self.reply(method, params).await;
            assert!(value.get("error").is_none(), "{method}: {value}");
            value["result"].clone()
        }

        async fn new_session(&mut self) -> String {
            let created = self
                .call("session/new", json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
                .await;
            created["sessionId"].as_str().unwrap().to_owned()
        }

        async fn records(&mut self, session: &str, kind: &str) -> Vec<Value> {
            let page =
                self.call("_acpmux/events", json!({"sessionId": session, "kinds": [kind]})).await;
            page["events"].as_array().unwrap().iter().map(|e| e["msg"].clone()).collect()
        }
    }
}
