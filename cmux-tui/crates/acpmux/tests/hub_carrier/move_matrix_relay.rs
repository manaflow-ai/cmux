//! The session-move matrix's relay arm (RFD 0138): the payload cells of
//! `transfer_cli/move_matrix.rs` (history with an image, model, effort, mode, allow rules, the
//! shared draft, a surface's unsent composer, the queue, a hibernated agent), carried by the hub
//! relay instead of ssh. The cloud side starts each move: A freezes the chat with the target
//! named by its hub key (`transfer_begin {to: {hub}}`), B takes op `move` through its control
//! hook as the hub delivers it, pulls every page from A over the relay and imports the chat under
//! its own guard, and A commits (the harness of `move_over_relay`, with the matrix's payloads).
//!
//! Two directions, both started on the cloud side, whose only link is the relay:
//! - cloud to local: a Mac behind NAT that was away when the move began pulls the whole bundle
//!   inside the freeze (no pre-copy);
//! - cloud to cloud: two cloud machines that both list pre-copy, so the history is staged over
//!   the relay first and only the log's tail crosses it inside the freeze.
//!
//! Every cell is checked before any assertion, so one run names all the red cells
//! (`MATRIX relay-<direction>-<harness> <payload> green|red: why`).
use super::*;

/// The smallest PNG: a 1x1 transparent pixel.
const PNG_B64: &str =
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

/// The modes a person's config names as asking, per family: a chat moved under B's guard runs
/// only in one of them (`web_modes.rs`). Claude Code's `default` and `plan`, the picker
/// harness's two.
const ASKING_MODES: [&str; 4] = ["default", "plan", "normal", "strict"];
/// The Claude rows' mode: one the receiving machine lists as asking. A guarded receive refuses
/// `acceptEdits`, which edits without asking (`transfer_guard.rs` `web_guard_modes`).
const CLAUDE_MODE: &str = "plan";

#[derive(Clone, Copy, PartialEq)]
enum Direction {
    CloudToLocal,
    CloudToCloud,
}

impl Direction {
    fn name(self) -> &'static str {
        match self {
            Direction::CloudToLocal => "cloud-to-local",
            Direction::CloudToCloud => "cloud-to-cloud",
        }
    }

    fn precopy(self) -> bool {
        self == Direction::CloudToCloud
    }

    fn target_host(self) -> &'static str {
        match self {
            Direction::CloudToLocal => "macbook",
            Direction::CloudToCloud => "cloud-b",
        }
    }
}

struct Cells {
    harness: String,
    red: Vec<String>,
}

impl Cells {
    fn check(&mut self, payload: &str, green: bool, why: impl std::fmt::Display) {
        let verdict = if green { "green" } else { "red" };
        eprintln!("MATRIX {} {payload} {verdict}: {why}", self.harness);
        if !green {
            self.red.push(format!("{payload}: {why}"));
        }
    }
}

/// The values a person set: model, effort and mode as `_acpmux/info` reports them, and the
/// allow rules as the chat's log last recorded them (`move_matrix.rs` `chosen`).
fn chosen(info: &Value, events: &[Value]) -> Value {
    let option = |id: &str| {
        info["configOptions"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|o| o["id"] == id)
            .map(|o| o["currentValue"].clone())
            .unwrap_or(Value::Null)
    };
    let rules = events
        .iter()
        .rev()
        .find(|e| e["kind"] == "rules")
        .map(|e| e["msg"]["rules"].clone())
        .unwrap_or(Value::Null);
    json!({
        "model": info.pointer("/models/currentModelId").cloned().unwrap_or_else(|| option("model")),
        "effort": option("effort"),
        "mode": info.get("currentModeId").cloned().unwrap_or(Value::Null),
        "rules": rules,
    })
}

/// Each record's `dir/kind`, in log order.
fn kinds(events: &[Value]) -> Vec<String> {
    events
        .iter()
        .map(|e| {
            format!("{}/{}", e["dir"].as_str().unwrap_or(""), e["kind"].as_str().unwrap_or(""))
        })
        .collect()
}

/// The text of each record of `kind`.
fn texts(events: &[Value], kind: &str) -> Vec<String> {
    events
        .iter()
        .filter(|e| e["kind"] == kind)
        .filter_map(|e| {
            e["msg"]["text"]
                .as_str()
                .or_else(|| e["msg"].pointer("/params/update/content/text").and_then(Value::as_str))
                .map(str::to_owned)
        })
        .collect()
}

fn prompt(id: &str, prompt_id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}],
           "_meta": {"acpmux": {"promptId": prompt_id}}})
}

async fn relay_matrix(
    direction: Direction,
    harness: &str,
    harness_env: Value,
    mode: &str,
    hibernate: bool,
) {
    use acpmux::mesh::InMessage;
    use acpmux::mesh_http::MeshControlFrom;
    use acpmux::server::mesh_relay::{ControlHook as _, MeshControlHook};
    use acpmux::transfer_service::{CarrierDial, ConfiguredTransferGate};

    let _ = HERMETIC;
    let precopy = direction.precopy();
    let mut cells = Cells {
        harness: format!(
            "relay-{}-{harness}{}",
            direction.name(),
            if hibernate { "-h" } else { "" }
        ),
        red: Vec::new(),
    };
    let relay_listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let relay_address = relay_listener.local_addr().unwrap();
    let relay = cmux_relay::Relay::new(cmux_relay::RelayConfig {
        allow_open: true,
        ..cmux_relay::RelayConfig::default()
    })
    .unwrap();
    let (relay_listener, router) = relay.server_parts(relay_listener);
    tokio::spawn(async move {
        let _ = axum::serve(relay_listener, router).await;
    });
    let proxy = Proxy::start(relay_address).await;
    let route = format!("relay+ws://127.0.0.1:{}", proxy.port);
    let (key_a, key_b) = (random_key(), random_key());
    let (a_key, b_key) = (public(&key_a), public(&key_b));
    let fast = Timings {
        control: Duration::from_secs(5),
        handshake: Duration::from_secs(5),
        ..Timings::default()
    };
    let carrier = |key: [u8; 32], peers: Vec<String>| {
        HubCarrier::new(
            Arc::new(FixedTickets { relay: route.clone(), peers, asked: AtomicU64::new(0) }),
            key,
            fast,
        )
    };
    let pids = std::env::temp_dir().join(format!(
        "amx-relay-{}-{harness}-{}-{}",
        direction.name(),
        std::process::id(),
        uuid::Uuid::now_v7()
    ));
    // Both machines run the matrix's harness; a guarded receive takes only a plain agent session
    // id (`transfer_guard.rs`), and under the ask policy a client may pick a mode and rules that
    // ask.
    let machine = |class_log: bool| {
        let mut cfg = config();
        cfg.permission_policy = PermissionPolicy::Ask;
        for profile in cfg.harnesses.values_mut() {
            profile.env.insert("FAKE_SESSION_PREFIX".into(), "fake-session-".into());
            for (k, v) in harness_env.as_object().unwrap() {
                profile.env.insert(k.clone(), v.as_str().unwrap().to_owned());
            }
            if class_log {
                profile.env.insert("FAKE_CLASS_LOG".into(), pids.to_string_lossy().into_owned());
            }
        }
        let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        Hub::new(cfg, store)
    };

    // A, the cloud machine that starts the move, serves its pages on its relay slot.
    let a = machine(true);
    if hibernate {
        a.set_idle_child(Some(Duration::from_secs(1)));
    }
    let carrier_a = carrier(key_a, vec![b_key.clone()]);
    carrier_a.set_transfer_gate(Arc::new(ConfiguredTransferGate::new(&a)));
    a.set_mesh_book_machines(BTreeMap::from([(b_key.clone(), direction.target_host().to_owned())]));
    let nothing = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap();
    let _serving = carrier_a.serve(nothing);
    // B, the target: its carrier and dial as `hub_carrier::start_configured` sets them.
    let b = machine(false);
    let home = dirs::home_dir().expect("a home directory");
    let root = home.join(format!("acpmux-relay-matrix-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&root).unwrap();
    let root = std::fs::canonicalize(&root).unwrap();
    let root_text = root.to_string_lossy().into_owned();
    {
        let mut cfg = b.config.write().await;
        cfg.web_roots = vec![root_text.clone()];
        cfg.web_asking_modes
            .insert("fake".into(), ASKING_MODES.iter().map(|m| (*m).to_owned()).collect());
    }
    b.hub_carrier.set(carrier(key_b, vec![a_key.clone()]));
    b.set_transfer_dial(Arc::new(CarrierDial::new(&b)));
    let ledger = tempfile::tempdir().unwrap();
    let hook = MeshControlHook::new(
        vec![MeshControlFrom {
            daemon_id: String::new(),
            same_user: true,
            ops: vec!["move".into()],
            max_policy: None,
        }],
        Some(ledger.path().join("mesh-controls.json")),
    )
    .with_own_user(Arc::new(|| Some("user-1".to_owned())));

    let mut src = client(a.clone()).await;
    let made =
        src.call(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []})).await;
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let id = id.as_str();

    // History: a reply, and a prompt with an image.
    src.call(method::SESSION_PROMPT, prompt(id, "p-hi", "hi")).await;
    let image = json!({"sessionId": id, "prompt": [
        {"type": "text", "text": "look"},
        {"type": "image", "mimeType": "image/png", "data": PNG_B64}],
        "_meta": {"acpmux": {"promptId": "p-img"}}});
    src.call(method::SESSION_PROMPT, image).await;
    let image_id = {
        use sha2::Digest;
        let bytes = base64::engine::general_purpose::STANDARD.decode(PNG_B64).unwrap();
        format!("{:x}", sha2::Sha256::digest(&bytes))
    };
    let kept =
        call_result(&mut src, "_acpmux/attachment", json!({"sessionId": id, "id": image_id})).await;
    cells.check("image-on-source", kept.is_ok(), format!("{:?}", kept.as_ref().err()));

    // Model, effort, mode and allow rules, as the person picked them.
    let picks = [
        ("session/set_model", json!({"sessionId": id, "modelId": "opus"})),
        (
            "session/set_config_option",
            json!({"sessionId": id, "configId": "effort", "value": "low"}),
        ),
        ("session/set_mode", json!({"sessionId": id, "modeId": mode})),
        (
            "_acpmux/set_rules",
            json!({"sessionId": id, "rules": {"autoDeny": ["delete"], "ask": ["execute"], "default": "ask"}}),
        ),
    ];
    for (m, params) in picks {
        if let Err(e) = call_result(&mut src, m, params).await {
            eprintln!("MATRIX {} setup {m} refused: {e}", cells.harness);
        }
    }
    let info = src.call(method::MUX_INFO, json!({"sessionId": id})).await;
    let before = chosen(&info, &all_events(&mut src, id).await);
    eprintln!("MATRIX {} chosen on source: {before}", cells.harness);

    // Unsent words: the draft and a composer.
    src.call("_acpmux/draft_set", json!({"sessionId": id, "text": "unsent words"})).await;
    let composer = call_result(
        &mut src,
        "_acpmux/composer_set",
        json!({"sessionId": id, "surface": {"id": "main", "name": "Main"}, "text": "half typed"}),
    )
    .await;
    eprintln!("MATRIX {} composer_set on source: {composer:?}", cells.harness);
    let composers_before =
        call_result(&mut src, "_acpmux/composers", json!({"sessionId": id})).await;

    let events_before = all_events(&mut src, id).await;
    let history_before = kinds(&events_before);
    let replies_before = texts(&events_before, "agent_message_chunk");

    if hibernate {
        // The agent goes after a second idle: the move takes a hibernated chat.
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        loop {
            let log = std::fs::read_to_string(&pids).unwrap_or_default();
            let gone = !log.is_empty()
                && log.lines().all(|line| {
                    let pid = serde_json::from_str::<Value>(line).unwrap()["pid"].as_u64().unwrap();
                    !std::path::Path::new(&format!("/proc/{pid}")).exists()
                });
            if gone {
                break;
            }
            assert!(tokio::time::Instant::now() < deadline, "never hibernated: {log}");
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
    } else {
        // A running turn and two queued prompts.
        src.send(method::SESSION_PROMPT, prompt(id, "p-turn", "until-cancel")).await;
        src.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "running").await;
        for (prompt_id, text) in [("p-a", "a"), ("p-b", "b")] {
            src.send(method::SESSION_PROMPT, prompt(id, prompt_id, text)).await;
            src.wait_for(method::MUX_PROMPT_ACCEPTED, |p| {
                p["promptId"] == prompt_id && p["queued"] == true
            })
            .await;
        }
    }

    let control = |message_id: &str, body: &Value| -> InMessage {
        serde_json::from_value(json!({
            "messageId": message_id, "kind": "control", "op": "move", "mode": "now",
            "to": {"daemonId": b_key},
            "from": {"daemonId": a_key, "user": "user-1", "host": "cloud-a"},
            "body": body.to_string(),
        }))
        .unwrap()
    };
    // Cloud to cloud: A prepares the history for B and B stages it over the relay first.
    let (mut begin_params, mut stage_id) = (Value::Null, None);
    if precopy {
        let prepared = src
            .call("_acpmux/transfer_hub", json!({"sessionId": id, "prepare": {"daemon": b_key}}))
            .await;
        let body = json!({"version": 1, "sessionId": id, "stage": {"manifest": prepared}});
        let ack =
            within("B's stage over the relay", hook.control(&b, &control("m-stage", &body))).await;
        let ack = serde_json::to_value(ack.expect("an answer within the hook's wait")).unwrap();
        let staged = ack["result"].as_str().and_then(|r| serde_json::from_str::<Value>(r).ok());
        stage_id = staged.as_ref().and_then(|s| s["stageId"].as_str().map(str::to_owned));
        cells.check("precopy-staged", ack["state"] == "delivered" && stage_id.is_some(), &ack);
        if stage_id.is_some() {
            begin_params =
                json!({"prepareId": prepared["prepareId"], "afterSeq": prepared["afterSeq"]});
        }
    }
    let started = tokio::time::Instant::now();
    let mut begin_request = json!({"sessionId": id, "interrupt": true, "gatesQueueApproval": true,
                                   "to": {"hub": b_key, "host": direction.target_host()}});
    if let Some(extra) = begin_params.as_object() {
        begin_request.as_object_mut().unwrap().extend(extra.clone());
    }
    let begin = src.call("_acpmux/transfer_begin", begin_request).await;
    let mut body = json!({"version": 1, "transferId": begin["transferId"], "sessionId": id,
                          "manifest": begin, "folder": {"cwd": root_text}});
    if let Some(stage_id) = &stage_id {
        body["stageId"] = json!(stage_id);
    }
    let ack = within("B's pull over the relay", hook.control(&b, &control("m-move", &body))).await;
    let ack = serde_json::to_value(ack.expect("an answer within the hook's wait")).unwrap();
    assert_eq!(ack["state"], "delivered", "{ack}");
    let moved: Value = serde_json::from_str(ack["result"].as_str().unwrap()).unwrap();
    let to = json!({"host": direction.target_host(), "via": "hub", "sessionId": id,
                    "cwd": moved["cwd"]});
    let committed = src
        .call(
            "_acpmux/transfer_commit",
            json!({"sessionId": id, "transferId": begin["transferId"], "to": to, "epoch": begin["epoch"]}),
        )
        .await;
    let took = started.elapsed();
    cells.check(
        "moved",
        committed["committed"] == true && moved["sessionId"] == id,
        format!("{took:?} {committed} {}", moved["timings"]),
    );

    let mut dst = client(b.clone()).await;
    let ready = dst
        .call(
            "_acpmux/wait",
            json!({"sessions": [id], "until": ["ready"], "all": true, "timeoutMs": 20000}),
        )
        .await;
    cells.check("settled", ready["timedOut"] == false, &ready);

    // The queue drains on B before the log is read: the cut turn's continuation, then a and b.
    let mut events_after = all_events(&mut dst, id).await;
    if !hibernate {
        let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
        while !texts(&events_after, "user_message").ends_with(&["a".to_owned(), "b".to_owned()])
            && tokio::time::Instant::now() < deadline
        {
            tokio::time::sleep(Duration::from_millis(100)).await;
            events_after = all_events(&mut dst, id).await;
        }
    }
    let history_after = kinds(&events_after);
    cells.check(
        "history",
        history_after.len() >= history_before.len()
            && history_after[..history_before.len()] == history_before[..],
        format!("{} records before, {} after", history_before.len(), history_after.len()),
    );
    let replies_after = texts(&events_after, "agent_message_chunk");
    cells.check(
        "replies",
        replies_after.len() >= replies_before.len()
            && replies_after[..replies_before.len()] == replies_before[..],
        format!("{replies_before:?} -> {replies_after:?}"),
    );
    let image =
        call_result(&mut dst, "_acpmux/attachment", json!({"sessionId": id, "id": image_id})).await;
    cells.check("image-in-history", image.is_ok(), format!("{:?}", image.as_ref().err()));

    let info = dst.call(method::MUX_INFO, json!({"sessionId": id})).await;
    let after = chosen(&info, &events_after);
    for key in ["model", "effort", "mode", "rules"] {
        cells.check(
            key,
            !before[key].is_null() && before[key] == after[key],
            format!("{} -> {}", before[key], after[key]),
        );
    }

    let draft = dst.call("_acpmux/draft_get", json!({"sessionId": id})).await;
    cells.check("draft", draft["draft"] == "unsent words", &draft);
    let composers_after =
        call_result(&mut dst, "_acpmux/composers", json!({"sessionId": id})).await;
    cells.check(
        "composer",
        composers_before
            .as_ref()
            .is_ok_and(|c| c["composers"].as_array().is_some_and(|a| !a.is_empty()))
            && composers_before.as_ref().ok().map(|c| &c["composers"])
                == composers_after.as_ref().ok().map(|c| &c["composers"]),
        format!("{composers_before:?} -> {composers_after:?}"),
    );

    if !hibernate {
        let prompts = texts(&events_after, "user_message");
        cells.check(
            "queue",
            prompts.len() >= 2 && prompts[prompts.len() - 2..] == ["a", "b"],
            format!("{prompts:?}"),
        );
    } else {
        // A hibernated chat answers on the target: its agent resumes from the carried log.
        let answer =
            call_result(&mut dst, method::SESSION_PROMPT, prompt(id, "p-wake", "after")).await;
        let replies = texts(&all_events(&mut dst, id).await, "agent_message_chunk");
        cells.check(
            "hibernated-resume",
            answer.is_ok() && replies.len() > replies_before.len(),
            format!("{answer:?}"),
        );
    }
    let left = src.call(method::MUX_INFO, json!({"sessionId": id})).await;
    cells.check("source-closed", left["status"] == "closed", &left["status"]);
    let _ = std::fs::remove_dir_all(&root);
    let _ = std::fs::remove_file(&pids);
    assert!(cells.red.is_empty(), "red cells for {}: {:#?}", cells.harness, cells.red);
}

fn claude_style() -> Value {
    json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "claude"})
}

fn codex_style() -> Value {
    json!({"FAKE_PICKER": "1", "FAKE_PICKER_MODES": "1", "FAKE_MODELS": "gpt-a,opus"})
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_matrix_cloud_to_local_a_claude_style_chat_moves_with_every_payload() {
    relay_matrix(Direction::CloudToLocal, "claude", claude_style(), CLAUDE_MODE, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_matrix_cloud_to_local_a_codex_style_chat_moves_with_every_payload() {
    relay_matrix(Direction::CloudToLocal, "codex", codex_style(), "strict", false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_matrix_cloud_to_local_a_hibernated_chat_moves_and_resumes() {
    relay_matrix(Direction::CloudToLocal, "claude", claude_style(), CLAUDE_MODE, true).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_matrix_cloud_to_cloud_a_claude_style_chat_moves_with_every_payload() {
    relay_matrix(Direction::CloudToCloud, "claude", claude_style(), CLAUDE_MODE, false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_matrix_cloud_to_cloud_a_codex_style_chat_moves_with_every_payload() {
    relay_matrix(Direction::CloudToCloud, "codex", codex_style(), "strict", false).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_matrix_cloud_to_cloud_a_hibernated_chat_moves_and_resumes() {
    relay_matrix(Direction::CloudToCloud, "claude", claude_style(), CLAUDE_MODE, true).await;
}
