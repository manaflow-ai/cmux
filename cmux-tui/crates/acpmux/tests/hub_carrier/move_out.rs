//! A driver reaches the holder through mesh control; the target gets every page over the relay.
use super::*;
use acpmux::mesh::{
    Ack, Heartbeat, HeartbeatReply, HubError, InMessage, MeshHub, OutMessage, Receipt,
};
use acpmux::mesh_http::MeshControlFrom;
use acpmux::server::mesh_relay::{ControlHook, MeshControlHook};
use acpmux::transfer_service::{CarrierDial, ConfiguredTransferGate};
use futures::future::BoxFuture;
use std::path::Path;
use std::sync::Weak;

struct Machine {
    name: &'static str,
    key: String,
    hub: Arc<Hub>,
    _serving: acpmux::hub_carrier::HubServe,
}

impl Machine {
    async fn drive(&self, source: &str, target: &str, flag: &str, id: &str) {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("cli.sock");
        let listener = acpmux::server::bind_unix(&socket).await.unwrap();
        let server = tokio::spawn(acpmux::server::serve_unix(self.hub.clone(), listener));
        let out = within(
            "session move",
            daemon_env::tokio_command(dir.path(), daemon_env::Agents::Deny)
                .env("HOME", dirs::home_dir().unwrap())
                .env("ACPMUX_HOME", dir.path())
                .env("ACPMUX_SOCKET", socket)
                .args(["session", "move", source, "--machine", target, flag, "--json"])
                .output(),
        )
        .await
        .unwrap();
        server.abort();
        assert!(
            out.status.success(),
            "{} moving {source} to {target}: {} {}",
            self.name,
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        let report: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(report["failed"], 0, "{report}");
        let rows = report["moves"].as_array().unwrap();
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!(row["sessionId"], id);
        assert_eq!(row["moved"], true);
        assert_eq!(row["via"], "hub");
        let t = &row["timings"];
        let ms =
            |field: &str| t[field].as_u64().unwrap_or_else(|| panic!("missing {field}: {row}"));
        assert!(ms("beginMs") <= ms("answerMs") && ms("answerMs") <= ms("commitMs"), "{t}");
        assert_eq!(ms("freezeMs"), ms("commitMs") - ms("beginMs"));
        for field in ["dialMs", "pagesMs", "finishMs"] {
            ms(field);
        }
        eprintln!("{} drove {source} -> {target}: {t}", self.name);
    }
}

// A stand-in for the hosted control inbox. It stamps the authenticated sender and returns the
// real control hook's receipt. It cannot serve transfer pages or access another machine's store.
struct Mesh {
    sender: String,
    machines: Arc<BTreeMap<String, (Weak<Hub>, MeshControlHook)>>,
}

impl MeshHub for Mesh {
    fn send<'a>(&'a self, m: &'a OutMessage) -> BoxFuture<'a, Result<Receipt, HubError>> {
        Box::pin(async move {
            m.validate().unwrap();
            let (hub, hook) = &self.machines[m.to.daemon_id.as_ref().unwrap()];
            let message: InMessage = serde_json::from_value(json!({
                "messageId": m.idempotency_key, "kind": m.kind, "op": m.op, "mode": m.mode,
                "to": m.to, "from": {"daemonId": self.sender, "user": "user-1"}, "body": m.body,
            }))
            .unwrap();
            let answer = hook.control(&hub.upgrade().unwrap(), &message).await.unwrap();
            let mut receipt = serde_json::to_value(answer).unwrap();
            receipt["messageId"] = json!(m.idempotency_key);
            Ok(serde_json::from_value(receipt).unwrap())
        })
    }

    fn inbox(&self, _: Duration, _: usize) -> BoxFuture<'_, Result<Vec<InMessage>, HubError>> {
        unreachable!("controls are delivered in send")
    }
    fn ack<'a>(&'a self, _: &'a str, _: &'a Ack) -> BoxFuture<'a, Result<(), HubError>> {
        unreachable!("send returns the final answer")
    }
    fn receipt<'a>(&'a self, _: &'a str) -> BoxFuture<'a, Result<Receipt, HubError>> {
        unreachable!("send returns the final receipt")
    }
    fn heartbeat<'a>(
        &'a self,
        _: &'a Heartbeat,
    ) -> BoxFuture<'a, Result<HeartbeatReply, HubError>> {
        unreachable!("the fixture sets the address book")
    }
}

// Each daemon serves on its own relay slot. A connect ticket pins the target's key
// and names that same slot, as the platform's carrier endpoint does.
struct MachineTickets {
    relay: String,
    slot: String,
    peers: BTreeMap<String, String>,
}

#[async_trait::async_trait]
impl Tickets for MachineTickets {
    async fn register(&self) -> Result<CarrierAnswer, String> {
        Ok(CarrierAnswer {
            relay: self.relay.clone(),
            slot: self.slot.clone(),
            ticket: "open-register".into(),
            expires_at: 0,
            peer_key: None,
            peers: self.peers.keys().cloned().collect(),
        })
    }

    async fn connect(&self, peer: &str) -> Result<CarrierAnswer, String> {
        let slot = self.peers.get(peer).ok_or("machine.not_found")?;
        Ok(CarrierAnswer {
            relay: self.relay.clone(),
            slot: slot.clone(),
            ticket: "open-connect".into(),
            expires_at: 0,
            peer_key: Some(peer.to_owned()),
            peers: Vec::new(),
        })
    }
}

fn queued_replies(events: &[Value]) -> usize {
    events
        .iter()
        .filter(|e| {
            e["kind"] == "agent_message_chunk"
                && e["msg"].pointer("/params/update/content/text").and_then(Value::as_str)
                    == Some("echo: after the move")
        })
        .count()
}

fn machines(relay: &str, root: &Path, state: &Path) -> Vec<Machine> {
    let names = ["machine-a", "machine-b", "machine-c"];
    let keys = names.map(|_| random_key());
    let public_keys = keys.each_ref().map(public);
    let unused = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let mut machines = Vec::new();
    let mut hooks = BTreeMap::new();
    for (i, name) in names.into_iter().enumerate() {
        let mut cfg = config();
        let mut profile = cfg.harnesses.remove("fake").unwrap();
        profile.env.insert("FAKE_SESSION_PREFIX".into(), "fake-session-".into());
        cfg.harnesses.insert("cmux-harness".into(), profile);
        cfg.default_harness = Some("cmux-harness".into());
        cfg.store.mode = StoreMode::Local;
        cfg.web_roots = vec![root.display().to_string()];
        cfg.web_asking_modes.insert("cmux".into(), vec!["normal".into()]);
        let store = acpmux::store::open(&cfg.store, &state.join(name).join("store")).unwrap();
        let hub = Hub::new(cfg, store);
        let peers: BTreeMap<_, _> = public_keys
            .iter()
            .zip(names)
            .enumerate()
            .filter(|(j, _)| *j != i)
            .map(|(_, (key, name))| (key.clone(), name.to_owned()))
            .collect();
        let tickets =
            MachineTickets { relay: relay.into(), slot: name.into(), peers: peers.clone() };
        let carrier = HubCarrier::new(Arc::new(tickets), keys[i], Timings::default());
        hub.set_mesh_book_machines(peers);
        carrier.set_transfer_gate(Arc::new(ConfiguredTransferGate::new(&hub)));
        hub.hub_carrier.set(carrier.clone());
        hub.set_transfer_dial(Arc::new(CarrierDial::new(&hub)));
        let hook = MeshControlHook::new(
            vec![MeshControlFrom {
                daemon_id: String::new(),
                same_user: true,
                ops: vec!["move".into()],
            }],
            Some(state.join(name).join("ledger")),
        )
        .with_own_user(Arc::new(|| Some("user-1".into())));
        let key = public_keys[i].clone();
        hooks.insert(key.clone(), (Arc::downgrade(&hub), hook));
        machines.push(Machine { name, key, hub, _serving: carrier.serve(unused) });
    }
    let hooks = Arc::new(hooks);
    for m in &machines {
        m.hub.mesh.set(Arc::new(Mesh { sender: m.key.clone(), machines: hooks.clone() }));
    }
    machines
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_third_machine_moves_the_chat_and_its_queue_over_the_relay() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let relay =
        cmux_relay::Relay::new(cmux_relay::RelayConfig { allow_open: true, ..Default::default() })
            .unwrap();
    let (listener, router) = relay.server_parts(listener);
    tokio::spawn(async move { axum::serve(listener, router).await.unwrap() });
    let proxy = Proxy::start(address).await;
    let dir =
        tempfile::Builder::new().prefix("ring-").tempdir_in(dirs::home_dir().unwrap()).unwrap();
    let root = dir.path().canonicalize().unwrap();
    // Cargo's hermetic test home can live inside a worktree. Give the chat a plain folder.
    std::fs::write(root.join(".git"), "gitdir: ./absent\n").unwrap();
    let state = tempfile::tempdir().unwrap();
    let machines = machines(&format!("relay+ws://127.0.0.1:{}", proxy.port), &root, state.path());
    let [a, b, c] = machines.as_slice() else { unreachable!() };
    let mut ca = client(a.hub.clone()).await;
    let missing = ca
        .call(
            "_acpmux/transfer_hub",
            json!({"moveOut": b.key, "sessionId": "missing-chat", "to": c.key}),
        )
        .await;
    assert_eq!(missing["moved"], false);
    assert_eq!(missing["sessionId"], "missing-chat");
    assert!(missing["error"].as_str().unwrap().contains("missing-chat"));
    let made = ca
        .call(
            method::SESSION_NEW,
            json!({"cwd":root, "mcpServers":[],
        "_meta":{"acpmux":{"name":"review"}}}),
        )
        .await;
    let id = made["sessionId"].as_str().unwrap();
    let prompt = |key: &str, text: &str| {
        json!({"sessionId":id, "prompt":[{"type":"text","text":text}],
        "_meta":{"acpmux":{"promptId":key}}})
    };
    ca.call(method::SESSION_PROMPT, prompt("first", "first turn")).await;
    // The ACP stand-in supplies the turns. Seed the durable harness files only on A.
    // Every subsequent holder must receive them through the relay.
    let agent = "fake-session-1";
    let journal = Path::new(agent).join("journal.ndjson");
    let history = b"{\"turn\":1}\n";
    let sessions = |name: &str| state.path().join(name).join("store/sessions");
    std::fs::create_dir_all(sessions(a.name).join(agent)).unwrap();
    std::fs::write(sessions(a.name).join(&journal), history).unwrap();
    let header = json!({"type":"session", "id":agent, "cwd":root});
    std::fs::write(sessions(a.name).join("review.jsonl"), format!("{header}\n")).unwrap();
    ca.send(method::SESSION_PROMPT, prompt("live", "until-cancel")).await;
    ca.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
    ca.send(method::SESSION_PROMPT, prompt("queued", "after the move")).await;
    ca.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "queued" && p["queued"] == true)
        .await;

    let bytes = || proxy.bytes.load(Ordering::SeqCst);
    let mut original = all_events(&mut ca, id).await;
    // A guarded import rebinds runnable prompts to the target's peer control.
    for event in &mut original {
        if matches!(event["kind"].as_str(), Some("queued" | "queue_updated" | "turn_started")) {
            event["msg"]["control"] = json!("peer");
        }
        if matches!(event["kind"].as_str(), Some("queued" | "queue_updated" | "user_message"))
            && let Some(meta) = event["msg"].get_mut("_meta").and_then(Value::as_object_mut)
        {
            meta.remove("provenance");
        }
    }
    let before = bytes();
    c.drive("machine-a/review", "machine-b", "--interrupt", id).await;
    assert!(bytes() > before);
    assert_eq!(ca.call(method::MUX_INFO, json!({"sessionId":id})).await["status"], "closed");
    let mut cb = client(b.hub.clone()).await;
    let on_b = within("queued prompt on B", async {
        loop {
            let events = all_events(&mut cb, id).await;
            if queued_replies(&events) > 0 {
                break events;
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
    })
    .await;
    let expected = ["first turn", "until-cancel", "This chat moved ", "after the move"];
    assert_eq!(user_texts(&on_b), expected);
    assert_eq!(std::fs::read(sessions(b.name).join(&journal)).unwrap(), history);
    let before = bytes();
    a.drive(&format!("machine-b/{id}"), "machine-c", "--after-turn", id).await;
    assert!(bytes() > before);
    assert_eq!(cb.call(method::MUX_INFO, json!({"sessionId":id})).await["status"], "closed");
    let mut cc = client(c.hub.clone()).await;
    let on_c = all_events(&mut cc, id).await;
    assert_eq!(user_texts(&on_c), expected);
    assert_eq!(queued_replies(&on_c), 1, "the queued prompt ran once");

    assert_eq!(std::fs::read(sessions(c.name).join(&journal)).unwrap(), history);
    assert!(on_c.starts_with(&original), "the history on A must be the prefix on C");
    assert!(on_c.windows(2).all(|pair| pair[0]["seq"].as_u64() < pair[1]["seq"].as_u64()));
    assert_eq!(on_c.iter().filter(|e| e["kind"] == "transferred_in").count(), 2);
    let before = bytes();
    a.drive(&format!("machine-c/{id}"), "local", "--after-turn", id).await;
    assert!(bytes() > before);
    assert_eq!(user_texts(&all_events(&mut ca, id).await), expected);

    // The original holder-driven CLI reports the very same timing fields.
    a.drive(id, "machine-b", "--after-turn", id).await;
    assert_eq!(user_texts(&all_events(&mut cb, id).await), expected);
}
