#![cfg(unix)]
//! The agent pane's Reply in place (IncomingMessageCard.tsx, #22310) is a cmux agent message
//! like any other. acpmux checks it (`_acpmux/app_reply`, `Hub::app_reply_fits`: from the chat
//! the pane shows, to the chat that sent the message it answers, in that message's thread) and
//! answers it signed; it never prompts the other chat itself. The app, the one connection that
//! may mint a launch credential, mints one for the replying chat and sends `agent.message.send`
//! as that chat (CmuxNextDaemon `AgentReplyClient.swift`). The store checks the reply again (its
//! parent, its thread, the sender's part in it), gives it an id, the pump delivers it with the
//! `Reply with` line, `--reply-to` answers it, its sender unsends it and it is in the inbox
//! history.

#[path = "agent_message_policy/harness.rs"]
mod harness;

/// One module, so `cargo test agent_message_reply_in_place` selects it.
mod agent_message_reply_in_place {
    use super::harness::{Daemon, delivery, refusal};
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

    fn state(message: &Value, recipient: &str) -> String {
        delivery(message, recipient)["state"].as_str().unwrap_or_default().to_owned()
    }

    /// What the app does with acpmux's signed `reply` (AgentReplyClient.swift): mints a launch
    /// credential for the replying chat on its own proven connection, then sends the reply as
    /// that chat under acpmux's key. No recipient: the store sends a reply to its parent's
    /// sender. `thread` stands in for the thread the app sends (acpmux's, unless a test changes
    /// it).
    fn send_as_app(daemon: &Daemon, reply: &Value, thread: &str, in_reply_to: &str) -> Value {
        let session = reply["from"].as_str().unwrap().strip_prefix("acp:").unwrap().to_owned();
        let mut app = daemon.app();
        let minted = app.call("credential.mint", json!({"acp_session": session}));
        assert_eq!(minted["ok"], true, "{minted}");
        let credential = minted["result"]["credential"].as_str().unwrap().to_owned();
        let fields = json!({"in_reply_to": in_reply_to, "thread_id": thread,
                            "body": reply["text"], "sender_name": reply["fromName"]});
        let key = reply["idempotencyKey"].as_str().unwrap();
        app.mutate_as("agent.message.send", fields, &credential, key)
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn a_reply_in_place_is_a_stored_agent_message_and_goes_nowhere_else() {
        let daemon = Arc::new(blocking(|| Daemon::start_owner_with_acpmux("reply-in-place")).await);
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
        acpmux::hub::install_build(acpmux_build_id::build());
        let hub = Hub::new(cfg, store);
        let mut local = Client::open_as(&hub, Origin::Local);
        let sender = local.new_session().await;
        let replier = local.new_session().await;
        let outsider = local.new_session().await;
        let d = daemon.clone();
        let (sender_cred, replier_cred, outsider_cred) = {
            let (sender, replier, outsider) = (sender.clone(), replier.clone(), outsider.clone());
            blocking(move || {
                let (_, alpha) = d.workspace("alpha");
                for chat in [&sender, &replier, &outsider] {
                    d.place_session(chat, &alpha);
                }
                (d.acp_credential(&sender), d.acp_credential(&replier), d.acp_credential(&outsider))
            })
            .await
        };

        // `sender`'s agent messages `replier`, and the pump hands it to the chat as a prompt
        // with the store's provenance (agent_message_acpmux.rs).
        let d = daemon.clone();
        let to_replier = format!("acp:{replier}");
        let parent = blocking(move || {
            d.sent(
                Some(&sender_cred),
                json!({"recipients": [to_replier], "body": "Rebase on main."}),
            )
        })
        .await;
        let parent_id = parent["id"].as_str().unwrap().to_owned();
        let thread = parent["thread_id"].as_str().unwrap().to_owned();
        let address = format!("acp:{replier}");
        let got = cmux_tui_core::agent_message_prompt::provenance(&parent, &address)
            .unwrap_or_else(|| panic!("no provenance: {parent}"));
        let text = cmux_tui_core::agent_message_prompt::render(std::slice::from_ref(&parent));
        local.call("session/prompt", prompt(&replier, &parent_id, &text, &got)).await;

        // The pane shows `replier`; acpmux checks the reply and signs it with the chat's name.
        let mut pane = Client::open_as(&hub, Origin::LocalApp);
        pane.call("_acpmux/attach", json!({"sessionId": replier, "limit": 0})).await;
        let checked = pane
            .call(
                "_acpmux/app_reply",
                json!({"sessionId": replier, "to": sender, "replyTo": parent_id,
                       "threadId": thread, "text": "Rebased; tests pass.", "replyId": "m-reply-1"}),
            )
            .await;
        let reply = checked["reply"].clone();
        assert_eq!(reply["from"], address.as_str(), "{checked}");
        assert!(
            local.records(&sender, "user_message").await.is_empty(),
            "acpmux prompted the sender's chat itself"
        );

        // The app sends it as `replier`: stored as its reply in the thread, signed with its
        // own name, and delivered to `sender` by the pump with the `Reply with` line.
        let d = daemon.clone();
        let (r, t, p) = (reply.clone(), thread.clone(), parent_id.clone());
        let sent = blocking(move || send_as_app(&d, &r, &t, &p)).await;
        assert_eq!(sent["ok"], true, "{sent}");
        let id = sent["result"]["value"]["id"].as_str().unwrap_or_default().to_owned();
        assert!(id.starts_with("msg_"), "{sent}");
        let to = format!("acp:{sender}");
        let d = daemon.clone();
        let (wait_id, wait_to) = (id.clone(), to.clone());
        let stored = blocking(move || {
            d.wait_for(&wait_id, "delivery", |m| state(m, &wait_to) == "delivered")
        })
        .await;
        assert_eq!(stored["sender"], address.as_str(), "{stored}");
        assert_eq!(stored["in_reply_to"], parent_id.as_str(), "{stored}");
        assert_eq!(stored["thread_id"], thread.as_str(), "{stored}");
        assert_eq!(stored["body"], "Rebased; tests pass.", "{stored}");
        assert_eq!(stored["sender_name"], reply["fromName"], "{stored}");
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

        // The same reply again is the same message.
        let d = daemon.clone();
        let (r, t, p) = (reply.clone(), thread.clone(), parent_id.clone());
        let again = blocking(move || send_as_app(&d, &r, &t, &p)).await;
        assert_eq!(again["result"]["value"]["id"], id.as_str(), "{again}");

        // The store checks the reply again: a thread that is not its parent's, a parent it
        // does not hold, and a chat that takes no part in the parent's thread are refused, and
        // none of them is stored.
        let d = daemon.clone();
        let (r, p) = (reply.clone(), parent_id.clone());
        let (wrong_thread, no_parent, not_joined) = blocking(move || {
            let mut other = r.clone();
            other["idempotencyKey"] = json!("acpmux-reply-other-thread");
            let wrong_thread = send_as_app(&d, &other, "msg_0000000000000000000000000a", &p);
            other["idempotencyKey"] = json!("acpmux-reply-no-parent");
            let no_parent = send_as_app(
                &d,
                &other,
                "msg_0000000000000000000000000b",
                "msg_0000000000000000000000000b",
            );
            let outsider_reply = d.mutate(
                "agent.message.send",
                json!({"in_reply_to": p, "body": "Me too."}),
                Some(&outsider_cred),
            );
            (wrong_thread, no_parent, outsider_reply)
        })
        .await;
        let (code, reason) = refusal(&wrong_thread);
        assert_eq!(code, "validation.invalid", "{wrong_thread}");
        assert!(reason.contains(&format!("belongs to thread {thread}")), "{wrong_thread}");
        assert_eq!(refusal(&no_parent).0, "resource.not_found", "{no_parent}");
        assert_eq!(refusal(&not_joined).1, "thread_not_joined", "{not_joined}");

        // `sender` answers it with `--reply-to`; inbox history holds it; its sender unsends it.
        let d = daemon.clone();
        let (reply_id, replier_address, outsider_address) =
            (id.clone(), address.clone(), format!("acp:{outsider}"));
        let (answer, history, mine, theirs) = blocking(move || {
            let credential = d.acp_credential(&sender);
            let answer =
                d.sent(Some(&credential), json!({"in_reply_to": reply_id, "body": "Thanks."}));
            let history = d.list(json!({"recipient": format!("acp:{sender}"), "limit": 100}));
            let mine = d.list(json!({"sender": replier_address, "limit": 100}));
            let theirs = d.list(json!({"sender": outsider_address, "limit": 100}));
            d.withdraw_answers(&sender, "retracted");
            (answer, history, mine, theirs)
        })
        .await;
        assert_eq!(answer["in_reply_to"], id.as_str(), "{answer}");
        let answered_to = state(&answer, &address);
        assert!(["queued", "delivered"].contains(&answered_to.as_str()), "{answer}");
        assert!(history.iter().any(|m| m["id"] == id.as_str()), "{history:?}");
        assert_eq!(mine.len(), 1, "a refused reply was stored: {mine:?}");
        assert!(theirs.is_empty(), "a refused reply was stored: {theirs:?}");
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
