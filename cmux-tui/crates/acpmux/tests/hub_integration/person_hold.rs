//! The person's prompts to a held chat (`hub/person_hold.rs`): those that come within the hold go
//! in as one turn, in order; one the triage calls urgent goes in at once, and so does one whose
//! triage fails. Leo, 2026-11-20: "another model could go case by case if something actually
//! warrants rushing vs just waiting lke 30s or so".

use super::*;

/// A prompt `fromAgent` names as `agent`'s message (`acpmux send --from`).
fn from_agent(id: &str, prompt_id: &str, agent: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}], "_meta": {"acpmux": {"promptId": prompt_id, "fromAgent": agent}}})
}

/// The echoes of every turn up to the one that echoes `last`.
async fn echoes_until(c: &mut TestClient, last: &str) -> Vec<String> {
    let seen = c
        .collect_until(|m, p| {
            m == method::SESSION_UPDATE
                && p["update"]["content"]["text"]
                    .as_str()
                    .is_some_and(|t| t.starts_with("echo: ") && t.contains(last))
        })
        .await;
    seen.iter()
        .filter(|(m, _)| m == method::SESSION_UPDATE)
        .filter_map(|(_, p)| p["update"]["content"]["text"].as_str())
        .filter(|t| t.starts_with("echo: "))
        .map(str::to_owned)
        .collect()
}

/// A hub whose chat `coord` holds the person's prompts for `ms`, its triage answered by `triage`.
async fn held(
    ms: u64,
    triage: impl Fn(String) -> Result<bool, String> + Send + Sync + 'static,
) -> (Arc<Hub>, TestClient, String) {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.person_hold =
        Some(acpmux::config::PersonHoldConfig { sessions: vec!["coord".into()], ms: Some(ms) });
    hub.set_prompt_triager(Some(Arc::new(triage)));
    let id = new_session(&mut c, "coord").await;
    (hub, c, id)
}

fn turns(hub: &Arc<Hub>, id: &str) -> usize {
    find(&hub.events(id, 0, 1000).unwrap(), "user_message").len()
}

/// Two of the person's prompts 5 s apart, both judged able to wait, are one turn, in order.
#[tokio::test]
async fn two_prompts_5s_apart_go_in_as_one_turn() {
    let (hub, mut c, id) = held(8_000, |_| Ok(false)).await;
    c.send(method::SESSION_PROMPT, prompt(&id, "first idea", Some("p-a"))).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-a").await;
    assert_eq!(accepted["queued"], true, "it waits: {accepted}");
    tokio::time::sleep(Duration::from_secs(5)).await;
    c.send(method::SESSION_PROMPT, prompt(&id, "second idea", Some("p-b"))).await;
    let echoes = echoes_until(&mut c, "second idea").await;
    assert_eq!(echoes, ["echo: first idea\n\nsecond idea"], "one turn, in order");
    assert_eq!(turns(&hub, &id), 1);
}

/// A prompt the triage calls urgent goes in at once, not after the 30 s hold.
#[tokio::test]
async fn a_rush_prompt_goes_in_at_once() {
    let (hub, mut c, id) = held(30_000, |text| Ok(text.contains("broken"))).await;
    let started = std::time::Instant::now();
    c.send(method::SESSION_PROMPT, prompt(&id, "the build is broken", Some("p-r"))).await;
    let echoes = echoes_until(&mut c, "the build is broken").await;
    assert_eq!(echoes, ["echo: the build is broken"]);
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    assert_eq!(turns(&hub, &id), 1);
}

/// A triage that fails delivers at once: today's behavior, never a lost prompt.
#[tokio::test]
async fn a_triage_error_delivers_at_once() {
    let (hub, mut c, id) = held(30_000, |_| Err("no model".into())).await;
    let started = std::time::Instant::now();
    c.send(method::SESSION_PROMPT, prompt(&id, "hello there", Some("p-e"))).await;
    let echoes = echoes_until(&mut c, "hello there").await;
    assert_eq!(echoes, ["echo: hello there"]);
    assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());
    assert_eq!(turns(&hub, &id), 1);
}

/// Nothing is reordered: the person's prompts go in in the order sent, each in exactly one
/// turn, and an agent message that comes inside the hold keeps the queue's own rule, behind the
/// person's prompts (`digest.rs`: the person's prompt goes ahead of waiting agent messages).
#[tokio::test]
async fn nothing_reorders() {
    let (hub, mut c, id) = held(3_000, |_| Ok(false)).await;
    let mut agents = connect(&hub).await;
    c.send(method::SESSION_PROMPT, prompt(&id, "one", Some("p-1"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-1").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "two", Some("p-2"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-2").await;
    agents.send(method::SESSION_PROMPT, from_agent(&id, "p-x", "lane-x", "from x")).await;
    agents.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-x").await;
    c.send(method::SESSION_PROMPT, prompt(&id, "three", Some("p-3"))).await;
    let echoes = echoes_until(&mut c, "from x").await;
    assert_eq!(echoes, ["echo: one\n\ntwo\n\nthree", "echo: from x"]);
    assert_eq!(turns(&hub, &id), 2);
}

/// A chat the config does not name never holds the person's prompt.
#[tokio::test]
async fn other_chats_never_hold() {
    let (hub, mut c, _) = held(30_000, |_| Ok(false)).await;
    let id = new_session(&mut c, "worker").await;
    let started = std::time::Instant::now();
    c.send(method::SESSION_PROMPT, prompt(&id, "go", Some("p-w"))).await;
    let accepted = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-w").await;
    assert_eq!(accepted["queued"], false, "{accepted}");
    assert_eq!(echoes_until(&mut c, "go").await, ["echo: go"]);
    assert!(started.elapsed() < Duration::from_secs(10));
    assert_eq!(turns(&hub, &id), 1);
}
