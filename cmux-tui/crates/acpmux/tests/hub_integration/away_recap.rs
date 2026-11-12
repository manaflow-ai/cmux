//! Session recap (`hub/away_recap.rs`): a chat the person comes back to after
//! 5+ minutes away gets a `mux` `recap` record, asked of the running Claude
//! Code as a transcript-free `side_question` while the person is away, or, with
//! no Claude Code process to ask, made by the harness's small model from the
//! chat's recent turns; never sent to the chat's agent as a prompt.

use super::fork_through::claude_setup;
use super::*;

const ANSWER: &str = "Goal: make the parser tolerate missing fields. Next: open foo.rs.";

struct Away {
    hub: Arc<Hub>,
    c: TestClient,
    id: String,
    clock: Arc<acpmux::clock::ManualClock>,
    log: std::path::PathBuf,
}

/// A Claude chat with `turns` finished turns, shown by its client, on a manual clock.
async fn chat(turns: usize, env: &[(&str, &str)]) -> Away {
    chat_viewed(turns, env, true).await
}

/// The same, `viewed` by a person's client (`_acpmux/view`) or only driven, as an agent drives one.
async fn chat_viewed(turns: usize, env: &[(&str, &str)], viewed: bool) -> Away {
    let root = std::env::temp_dir().join(format!("acpmux-recap-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let log = root.join("controls");
    let log_s = log.to_string_lossy().into_owned();
    let mut env: Vec<(&str, &str)> = env.to_vec();
    env.push(("FAKE_CLAUDE_CONTROL_LOG", &log_s));
    env.push(("FAKE_CLAUDE_SIDE_ANSWER", ANSWER));
    let (hub, mut c) = claude_setup(&claude, &env).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    if viewed {
        c.request("_acpmux/view", json!({"sessionId": id, "visible": true})).await.unwrap();
    }
    for n in 0..turns {
        let text = format!("step {n}");
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
        )
        .await
        .unwrap();
    }
    Away { hub, c, id, clock, log }
}

impl Away {
    async fn show(&mut self, visible: bool) {
        self.c
            .request("_acpmux/view", json!({"sessionId": self.id, "visible": visible}))
            .await
            .unwrap();
    }

    /// How many recap requests reached Claude Code.
    fn asked(&self) -> usize {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .filter(|l| *l == "side_question")
            .count()
    }

    /// Moves the clock and lets a recap request that falls due run.
    async fn advance(&self, by: Duration, expect_asked: usize) {
        self.clock.advance(by);
        for _ in 0..250 {
            if self.asked() >= expect_asked {
                break;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
        // Its answer is read back after Claude Code wrote it.
        tokio::time::sleep(Duration::from_millis(200)).await;
    }

    fn recaps(&self) -> Vec<Value> {
        self.hub
            .events(&self.id, 0, 10_000)
            .unwrap()
            .iter()
            .filter(|e| e.dir == "mux" && e.kind == "recap")
            .map(|e| e.msg.clone())
            .collect()
    }

    fn prompts(&self) -> usize {
        self.hub
            .events(&self.id, 0, 10_000)
            .unwrap()
            .iter()
            .filter(|e| e.kind == "user_message")
            .count()
    }
}

#[tokio::test]
async fn coming_back_after_five_minutes_shows_the_recap_made_while_away() {
    let mut a = chat(3, &[]).await;
    a.show(false).await;
    a.advance(Duration::from_secs(3 * 60), 1).await;
    assert_eq!(a.asked(), 1, "asked once, 3 minutes after the person left");
    assert!(a.recaps().is_empty(), "nothing shows while the person is away");
    a.advance(Duration::from_secs(2 * 60), 1).await;
    a.show(true).await;
    let recaps = a.recaps();
    assert_eq!(recaps.len(), 1, "{recaps:?}");
    assert_eq!(recaps[0]["text"], ANSWER);
    assert!(recaps[0]["awayMs"].as_u64().unwrap() >= 5 * 60 * 1000, "{recaps:?}");
    assert_eq!(a.prompts(), 3, "the recap is never a prompt");
    // Leaving and coming back again with no new turn shows no second recap.
    a.show(false).await;
    a.advance(Duration::from_secs(6 * 60), 1).await;
    a.show(true).await;
    assert_eq!(a.recaps().len(), 1);
    assert_eq!(a.asked(), 1, "no turn since the last recap: not asked again");
}

#[tokio::test]
async fn coming_back_within_five_minutes_shows_none() {
    let mut a = chat(3, &[]).await;
    a.show(false).await;
    a.advance(Duration::from_secs(4 * 60), 1).await;
    a.show(true).await;
    assert!(a.recaps().is_empty());
}

#[tokio::test]
async fn a_short_chat_gets_no_recap() {
    let mut a = chat(2, &[]).await;
    a.show(false).await;
    a.advance(Duration::from_secs(6 * 60), 1).await;
    a.show(true).await;
    assert_eq!(a.asked(), 0, "under 3 turns: never asked");
    assert!(a.recaps().is_empty());
}

#[tokio::test]
async fn the_setting_off_asks_for_none() {
    let mut a = chat(3, &[]).await;
    // What the app's `_acpmux/chat_settings` `sessionRecap: false` sets (not sent here: it saves
    // the daemon's settings file, which other tests in this process read at start).
    a.hub.set_session_recap(false);
    a.show(false).await;
    a.advance(Duration::from_secs(6 * 60), 1).await;
    a.show(true).await;
    assert_eq!(a.asked(), 0);
    assert!(a.recaps().is_empty());
}

impl Away {
    /// Sets this chat's own `session-recap` choice, as the composer's Options does.
    async fn choose(&mut self, value: &str) -> Value {
        self.c
            .request(
                method::SESSION_SET_CONFIG_OPTION,
                json!({"sessionId": self.id, "configId": "session-recap", "value": value}),
            )
            .await
            .unwrap()
    }
}

#[tokio::test]
async fn the_chat_off_overrides_the_setting_on() {
    let mut a = chat(3, &[]).await;
    let res = a.choose("off").await;
    let opt = res["configOptions"]
        .as_array()
        .unwrap()
        .iter()
        .find(|o| o["id"] == "session-recap")
        .cloned()
        .unwrap();
    assert_eq!(opt["currentValue"], "off", "{res}");
    assert!(
        opt["options"][1]["description"].as_str().unwrap().contains("$0.016"),
        "each choice names its cost: {opt}"
    );
    a.show(false).await;
    a.advance(Duration::from_secs(6 * 60), 1).await;
    a.show(true).await;
    assert_eq!(a.asked(), 0);
    assert!(a.recaps().is_empty());
}

#[tokio::test]
async fn the_chat_on_overrides_the_setting_off() {
    let mut a = chat(3, &[]).await;
    a.hub.set_session_recap(false);
    a.choose("on").await;
    a.show(false).await;
    a.advance(Duration::from_secs(3 * 60), 1).await;
    a.advance(Duration::from_secs(2 * 60), 1).await;
    a.show(true).await;
    assert_eq!(a.asked(), 1);
    assert_eq!(a.recaps().len(), 1);
}

#[tokio::test]
async fn a_bad_choice_is_refused() {
    let mut a = chat(0, &[]).await;
    let err =
        a.c.request(
            method::SESSION_SET_CONFIG_OPTION,
            json!({"sessionId": a.id, "configId": "session-recap", "value": "sometimes"}),
        )
        .await
        .unwrap_err();
    assert!(err.contains("default, on or off"), "{err}");
    a.choose("default").await;
}

#[tokio::test]
async fn an_idle_chat_is_asked_before_its_process_hibernates() {
    let mut a = chat(3, &[]).await;
    // The daemon's default: an idle process stops after 2 minutes, before the 3-minute ask.
    a.hub.set_idle_child(Some(Duration::from_secs(2 * 60)));
    a.show(false).await;
    // A period that ends while the chat is still in use starts a full one again
    // (`session_hibernate.rs`): each period, until the reaper reaches it.
    for _ in 0..5 {
        if a.asked() > 0 {
            break;
        }
        a.advance(Duration::from_secs(2 * 60 + 1), 1).await;
    }
    assert_eq!(a.asked(), 1, "asked before the process went");
    // Then it hibernates, and is never asked again for the same turns.
    a.advance(Duration::from_secs(2 * 60 + 1), 1).await;
    a.advance(Duration::from_secs(2 * 60 + 1), 1).await;
    assert_eq!(a.asked(), 1);
    a.show(true).await;
    let recaps = a.recaps();
    assert_eq!(recaps.len(), 1, "{recaps:?}");
    assert_eq!(recaps[0]["text"], ANSWER);
}

#[tokio::test]
async fn a_chat_only_an_agent_drove_gets_no_recap() {
    // Its `session/new` and prompts subscribed the agent's connection; no person attached or
    // viewed it. The agent letting go is no person leaving.
    let mut a = chat_viewed(3, &[], false).await;
    a.c.request("_acpmux/detach", json!({"sessionId": a.id})).await.unwrap();
    a.advance(Duration::from_secs(6 * 60), 1).await;
    assert_eq!(a.asked(), 0, "never asked");
    a.c.request("_acpmux/attach", json!({"sessionId": a.id})).await.unwrap();
    assert!(a.recaps().is_empty());
}

/// The small model's stand-in: answers `answer` and keeps each prompt it was given.
fn writer(hub: &Hub, answer: &str) -> Arc<std::sync::Mutex<Vec<String>>> {
    let asked = Arc::new(std::sync::Mutex::new(Vec::new()));
    let (kept, answer) = (asked.clone(), answer.to_owned());
    hub.set_recap_writer(Some(Arc::new(move |prompt: String| {
        kept.lock().unwrap().push(prompt);
        Some(answer.clone())
    })));
    asked
}

/// Waits until the small model's stand-in was asked `n` times (it runs after a log read).
async fn written(asked: &std::sync::Mutex<Vec<String>>, n: usize) {
    for _ in 0..250 {
        if asked.lock().unwrap().len() >= n {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    tokio::time::sleep(Duration::from_millis(100)).await;
}

const SMALL: &str = "The goal is a tolerant parser. Next, rerun the tests.";

#[tokio::test]
async fn a_claude_chat_whose_process_is_gone_gets_the_small_models_recap() {
    let mut a = chat(3, &[]).await;
    let asked = writer(&a.hub, SMALL);
    let session = a.hub.resolve(&a.id).unwrap();
    a.hub.detach_child(&session).await;
    a.show(false).await;
    a.advance(Duration::from_secs(3 * 60), 0).await;
    written(&asked, 1).await;
    assert_eq!(a.asked(), 0, "no process to ask, none started");
    assert_eq!(session.meta().status, acpmux::store::SessionStatus::Idle, "none started for it");
    {
        let prompts = asked.lock().unwrap();
        assert_eq!(prompts.len(), 1);
        assert!(prompts[0].contains("Person: step 2"), "{}", prompts[0]);
        assert!(prompts[0].len() <= acpmux::complete::MAX_PROMPT_BYTES);
    }
    a.advance(Duration::from_secs(2 * 60), 0).await;
    a.show(true).await;
    let recaps = a.recaps();
    assert_eq!(recaps.len(), 1, "{recaps:?}");
    assert_eq!(recaps[0]["text"], SMALL);
    // Leaving again with no new turn asks nothing more.
    a.show(false).await;
    a.advance(Duration::from_secs(6 * 60), 0).await;
    assert_eq!(asked.lock().unwrap().len(), 1);
}

#[tokio::test]
async fn a_chat_on_another_harness_gets_the_small_models_recap() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    let asked = writer(&hub, SMALL);
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let view = |visible: bool| json!({"sessionId": id, "visible": visible});
    c.request("_acpmux/view", view(true)).await.unwrap();
    for n in 0..3 {
        c.request(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("step {n}")}]}),
        )
        .await
        .unwrap();
    }
    c.request("_acpmux/view", view(false)).await.unwrap();
    clock.advance(Duration::from_secs(3 * 60));
    written(&asked, 1).await;
    {
        let prompts = asked.lock().unwrap();
        assert_eq!(prompts.len(), 1, "asked once, 3 minutes after the person left");
        assert!(prompts[0].contains("Agent: echo: step 2"), "{}", prompts[0]);
        assert!(prompts[0].contains("Person: step 0"), "{}", prompts[0]);
    }
    clock.advance(Duration::from_secs(2 * 60));
    c.request("_acpmux/view", view(true)).await.unwrap();
    let recaps: Vec<Value> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|e| e.dir == "mux" && e.kind == "recap")
        .map(|e| e.msg.clone())
        .collect();
    assert_eq!(recaps.len(), 1, "{recaps:?}");
    assert_eq!(recaps[0]["text"], SMALL);
}

/// Another connection to `hub`, introduced with `hello` (`initialize` params).
async fn connect_as(hub: &Arc<Hub>, hello: Value) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client.request(method::INITIALIZE, hello).await.unwrap();
    client
}

#[tokio::test]
async fn an_automated_attach_never_makes_a_chat_eligible_for_a_recap() {
    // #34075: a chat only an agent drove, then followed by automated clients.
    let a = chat_viewed(0, &[], false).await;
    // A supervisor (`mux/host`'s `AcpmuxClient.attach`): no `visible`.
    let mut host = connect_as(
        &a.hub,
        json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "mux-host", "version": "0.1.0"}}),
    )
    .await;
    host.request("_acpmux/attach", json!({"sessionId": a.id, "afterSeq": 0, "limit": 1_000_000}))
        .await
        .unwrap();
    assert!(!a.hub.recap_person_seen(&a.id), "a supervisor's attach is no person");
    // An agent's acpmux CLI, even one that says `visible` or views the chat.
    let mut agent = connect_as(
        &a.hub,
        json!({"protocolVersion": 1, "clientInfo": {"name": "acpmux-cli"},
            "_meta": {"acpmux": {"callerProtocol": 1, "callerKind": "agent"}}}),
    )
    .await;
    agent
        .request("_acpmux/attach", json!({"sessionId": a.id, "visible": true, "limit": 0}))
        .await
        .unwrap();
    agent.request("_acpmux/view", json!({"sessionId": a.id, "visible": true})).await.unwrap();
    assert!(!a.hub.recap_person_seen(&a.id), "an agent's attach or view is no person");
    // A person's pane says what it shows.
    let mut pane =
        connect_as(&a.hub, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}})).await;
    pane.request("_acpmux/attach", json!({"sessionId": a.id, "visible": true, "limit": 0}))
        .await
        .unwrap();
    assert!(a.hub.recap_person_seen(&a.id), "a pane that shows the chat is a person");
}
