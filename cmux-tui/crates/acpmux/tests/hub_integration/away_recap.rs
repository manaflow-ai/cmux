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
    /// What Claude Code answers the next recap ask with, once written (`ANSWER` before).
    answer: std::path::PathBuf,
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
    let answer = root.join("answer");
    let answer_s = answer.to_string_lossy().into_owned();
    env.push(("FAKE_CLAUDE_SIDE_ANSWER_FILE", &answer_s));
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
    Away { hub, c, id, clock, log, answer }
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

/// A recap ask that panics lets the chat go: the next turns' recap is still asked for and shown
/// (#41950's review: `Away::asking` was cleared only on the ask's normal return).
#[tokio::test]
async fn a_recap_ask_that_panics_does_not_stop_the_next_one() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let clock = acpmux::clock::ManualClock::new();
    hub.set_clock(clock.clone());
    hub.set_idle_child(None);
    let asked = Arc::new(std::sync::Mutex::new(Vec::new()));
    let kept = asked.clone();
    hub.set_recap_writer(Some(Arc::new(move |prompt: String| {
        let first = {
            let mut kept = kept.lock().unwrap();
            kept.push(prompt);
            kept.len() == 1
        };
        assert!(!first, "the first recap ask panics");
        Some(SMALL.to_owned())
    })));
    let s = c.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let view = |visible: bool| json!({"sessionId": id, "visible": visible});
    let prompt = |n: usize| json!({"sessionId": id, "prompt": [{"type": "text", "text": format!("step {n}")}]});
    c.request("_acpmux/view", view(true)).await.unwrap();
    for n in 0..3 {
        c.request(method::SESSION_PROMPT, prompt(n)).await.unwrap();
    }
    c.request("_acpmux/view", view(false)).await.unwrap();
    clock.advance(Duration::from_secs(3 * 60));
    written(&asked, 1).await;
    c.request("_acpmux/view", view(true)).await.unwrap();
    for n in 3..6 {
        c.request(method::SESSION_PROMPT, prompt(n)).await.unwrap();
    }
    c.request("_acpmux/view", view(false)).await.unwrap();
    clock.advance(Duration::from_secs(3 * 60));
    written(&asked, 2).await;
    assert_eq!(asked.lock().unwrap().len(), 2, "asked again after the panic");
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

impl Away {
    /// One more turn.
    async fn prompt(&mut self, text: &str) {
        self.c
            .request(
                method::SESSION_PROMPT,
                json!({"sessionId": self.id, "prompt": [{"type": "text", "text": text}]}),
            )
            .await
            .unwrap();
    }

    /// The person leaves for 5 minutes and comes back; the recap is asked 3 minutes in.
    async fn away_and_back(&mut self) {
        let asked = self.asked() + 1;
        self.show(true).await;
        self.show(false).await;
        self.advance(Duration::from_secs(3 * 60), asked).await;
        self.advance(Duration::from_secs(2 * 60), asked).await;
        self.show(true).await;
    }

    fn recap_records(&self) -> Vec<(u64, Value)> {
        self.hub
            .events(&self.id, 0, 10_000)
            .unwrap()
            .iter()
            .filter(|e| e.dir == "mux" && e.kind == "recap")
            .map(|e| (e.seq, e.msg.clone()))
            .collect()
    }

    fn kept(&self) -> Option<acpmux::store::AwayRecap> {
        self.hub.resolve(&self.id).unwrap().meta().away_recap
    }
}

/// The same facts each time in other words, as Claude Code words each recap afresh (the eight
/// cards Leo saw on 2026-11-11).
const SAME_FACTS: [&str; 4] = [
    "The Chief CSS design-system batch is finished and merged (cmux#34338, #34349, leo-workspace#2996). The leo1024rd resume can't start because `/tmp/cx-lanes/leo1024rd` doesn't exist on this VM.",
    "The goal was moving the Chief pages' CSS onto the design system; that's done and merged (#34338, #34349, leo-workspace#2996). Next: find out where the leo1024rd lane lives.",
    "Chief CSS batch is landed: cmux#34338 and #34349 are merged. The restart message points to a leo1024rd lane folder this VM doesn't have.",
    "The Chief CSS design-system batch is done and merged (#34338). The /tmp/cx-lanes/leo1024rd folder isn't on this VM, so it needs re-creating.",
];

#[tokio::test]
async fn n_wakes_with_no_change_give_one_recap() {
    let mut a = chat(3, &[]).await;
    std::fs::write(&a.answer, SAME_FACTS[0]).unwrap();
    a.away_and_back().await;
    assert_eq!(a.recap_records().len(), 1);
    for (n, words) in SAME_FACTS.iter().cycle().skip(1).take(6).enumerate() {
        // A wake that sends the chat a turn or two, and every other one a daemon restart.
        if n % 2 == 1 {
            a.hub.recap_forget_run(&a.id);
        }
        a.prompt(&format!("resume {n}")).await;
        a.prompt(&format!("again {n}")).await;
        std::fs::write(&a.answer, words).unwrap();
        a.away_and_back().await;
    }
    assert!(a.asked() >= 4, "recaps were asked for: {}", a.asked());
    let records = a.recap_records();
    assert_eq!(records.len(), 1, "nothing new: no second recap {records:?}");
    let kept = a.kept().unwrap();
    assert_eq!(kept.seq, records[0].0);
    assert_eq!(
        kept.turns,
        a.hub.resolve(&a.id).unwrap().meta().turn_count,
        "the next waits from here"
    );
}

#[tokio::test]
async fn a_changed_recap_replaces_the_old_one() {
    let mut a = chat(3, &[]).await;
    std::fs::write(&a.answer, SAME_FACTS[0]).unwrap();
    a.away_and_back().await;
    a.prompt("go on").await;
    a.prompt("and on").await;
    std::fs::write(&a.answer, "The leo1024rd lane is restored; #41622 is open with CI green.")
        .unwrap();
    a.away_and_back().await;
    let records = a.recap_records();
    assert_eq!(records.len(), 2, "{records:?}");
    let (first, _) = &records[0];
    let (second, msg) = &records[1];
    assert_eq!(msg["replaces"], json!(first), "the new recap names the one it replaces: {msg}");
    assert!(records[0].1.get("replaces").is_none(), "the first replaces none");
    assert_ne!(records[0].1["digest"], msg["digest"]);
    assert_eq!(a.kept().unwrap().seq, *second, "the chat's one recap is the newest");
}

#[tokio::test]
async fn dismissed_stays_dismissed_after_reload() {
    let mut a = chat(3, &[]).await;
    std::fs::write(&a.answer, SAME_FACTS[0]).unwrap();
    a.away_and_back().await;
    let (seq, _) = a.recap_records()[0].clone();
    a.hub.dismiss_recap(&a.id, seq).unwrap();
    assert!(a.kept().unwrap().dismissed);
    // The chat's metadata as a restarted daemon reads it back from disk.
    let meta = a.hub.resolve(&a.id).unwrap().meta();
    let reloaded: acpmux::store::SessionMeta =
        serde_json::from_value(serde_json::to_value(&meta).unwrap()).unwrap();
    assert_eq!(reloaded.away_recap, meta.away_recap, "kept across a reload");
    assert!(reloaded.away_recap.unwrap().dismissed);
    a.hub.recap_forget_run(&a.id);
    a.prompt("resume").await;
    a.prompt("resume again").await;
    std::fs::write(&a.answer, SAME_FACTS[2]).unwrap();
    a.away_and_back().await;
    assert_eq!(a.recap_records().len(), 1, "a dismissed recap does not come back in other words");
    assert!(a.kept().unwrap().dismissed);
}

impl Away {
    /// Another agent's question (`acpmux send --from --class question`) as one more turn, waited
    /// until it ended. The first is the chat's first work; the next go in as its inbox's notice,
    /// due 2 s after they came by the chat's clock (`hub/inbox.rs` `WAKE_DEBOUNCE_MS`).
    async fn agent_turn(&mut self, n: usize) {
        let before = self.hub.resolve(&self.id).unwrap().meta().turn_count;
        self.c
            .send(
                method::SESSION_PROMPT,
                json!({"sessionId": self.id, "prompt": [{"type": "text", "text": format!("task {n}")}],
                       "_meta": {"acpmux": {"promptId": format!("a-{n}"), "fromAgent": "lane-a", "class": "question"}}}),
            )
            .await;
        self.clock.advance(Duration::from_secs(3));
        for _ in 0..400 {
            let session = self.hub.resolve(&self.id).unwrap();
            if session.meta().turn_count > before && session.turn().is_none() {
                return;
            }
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        panic!("the agent's turn {n} never ended");
    }
}

#[tokio::test]
async fn a_shown_chat_only_other_agents_prompted_gets_no_recap() {
    // A person has shown it, but each turn is another agent's message, as a Chief's subagent's
    // are: the person reads that agent's report, not a recap of this chat. These were 87% of all
    // recaps on the team gateway (sr2 audit 2026-11-20).
    let mut a = chat_viewed(0, &[], false).await;
    for n in 0..3 {
        a.agent_turn(n).await;
    }
    a.show(true).await;
    a.show(false).await;
    a.advance(Duration::from_secs(6 * 60), 1).await;
    a.show(true).await;
    assert_eq!(a.asked(), 0, "never asked");
    assert!(a.recaps().is_empty());
    // The person's own prompt makes the next one worth asking for.
    a.prompt("my own question").await;
    a.away_and_back().await;
    assert_eq!(a.asked(), 1);
    assert_eq!(a.recaps().len(), 1);
}
