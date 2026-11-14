//! Session recap (`hub/away_recap.rs`): a Claude chat the person comes back to
//! after 5+ minutes away gets a `mux` `recap` record, asked of the running
//! Claude Code as a transcript-free `side_question` while the person is away,
//! never sent to the model as a prompt.

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
