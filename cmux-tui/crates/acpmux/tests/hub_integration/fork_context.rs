//! A fork's agent sees what the fork shows (#50021, #50094, #50089). For every kind of fork,
//! the turns its rows show (the chat's history through the fork's `forked` record) are the turns
//! its agent's context holds: none shown but unseen, none seen but hidden. [`assert_same_turns`]
//! is the check; each fork kind reads "seen" from its agent its own way: a Claude copy by
//! fake_claude's `history-probe`, an agent fed the chat's transcript from that transcript as its
//! first prompt carried it ([`seen_in_restored_transcript`]).

use super::*;

/// The prompts a fork's rows show of the chat it was forked from: its `user_message` records
/// before its `forked` record.
pub(super) fn shown_prompts(hub: &Arc<Hub>, fork: &str) -> Vec<String> {
    let mut shown = Vec::new();
    for e in hub.events(fork, 0, 100_000).unwrap() {
        if e.kind == "forked" {
            return shown;
        }
        if e.kind == "user_message"
            && let Some(t) = e.msg.get("text").and_then(Value::as_str)
        {
            shown.push(t.to_owned());
        }
    }
    panic!("fork {fork} has no forked record");
}

fn flat(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The invariant: the prompts the fork shows and those its agent holds are the same turns, in
/// order. A prompt the agent holds only by its opening words (a transcript over its budget says
/// which it shortened) matches the shown prompt it begins.
#[track_caller]
pub(super) fn assert_same_turns(shown: &[String], seen: &[String]) {
    let same = |shown: &str, seen: &str| {
        let (shown, seen) = (flat(shown), flat(seen));
        let seen = seen.strip_suffix('…').unwrap_or(&seen);
        shown == seen || (!seen.is_empty() && shown.starts_with(seen))
    };
    let unseen: Vec<&String> = shown.iter().filter(|p| !seen.iter().any(|s| same(p, s))).collect();
    let hidden: Vec<&String> = seen.iter().filter(|s| !shown.iter().any(|p| same(p, s))).collect();
    let short = |v: &[&String]| {
        v.iter().map(|s| flat(s).chars().take(60).collect::<String>()).collect::<Vec<_>>()
    };
    assert!(unseen.is_empty(), "shown but unseen by the fork's agent: {:?}", short(&unseen));
    assert!(hidden.is_empty(), "seen by the fork's agent but not shown: {:?}", short(&hidden));
    assert_eq!(
        shown.len(),
        seen.len(),
        "shown {} turns, the agent holds {}",
        shown.len(),
        seen.len()
    );
}

/// The prompts of the `<restored_transcript>` an agent's first prompt carried (fake_agent echoes
/// its prompt), and the transcript itself.
pub(super) fn seen_in_restored_transcript(echo: &str) -> (Vec<String>, String) {
    let start =
        echo.find("<restored_transcript").expect("the fork's first prompt carries the transcript");
    let end = echo[start..].find("</restored_transcript>").map_or(echo.len(), |e| start + e);
    let transcript = &echo[start..end];
    let body = &transcript[transcript.find(">\n").map_or(0, |i| i + 2)..];
    let seen = body
        .split("\n\n")
        .filter_map(|block| block.strip_prefix("user: "))
        .map(str::to_owned)
        .collect();
    (seen, transcript.to_owned())
}

fn two_harness_setup(no_fork: bool) -> (Arc<Hub>, Config) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let profile = |family: Option<&str>, env: BTreeMap<String, String>| HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env,
        description: None,
        fallback: None,
        family: family.map(str::to_owned),
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let env = if no_fork {
        BTreeMap::from([("FAKE_NO_FORK".to_owned(), "1".to_owned())])
    } else {
        BTreeMap::new()
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([
            ("fake".to_owned(), profile(None, env)),
            ("other".to_owned(), profile(Some("other"), BTreeMap::new())),
        ]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    (Hub::new(cfg.clone(), store), cfg)
}

async fn client(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut c = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    c.request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "pane"}}))
        .await
        .unwrap();
    c
}

fn say(id: &str, text: &str) -> Value {
    json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]})
}

/// What the session's agent answered after record `after`.
fn replies_after(hub: &Arc<Hub>, id: &str, after: u64) -> String {
    hub.events(id, after, 100_000)
        .unwrap()
        .iter()
        .filter(|e| e.kind == "agent_message_chunk")
        .filter_map(|e| e.msg.pointer("/params/update/content/text").and_then(Value::as_str))
        .collect()
}

async fn new_chat(c: &mut TestClient, name: &str) -> String {
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": name}}}),
        )
        .await
        .unwrap();
    s["sessionId"].as_str().unwrap().to_owned()
}

/// The fork's first prompt, and the turns its agent got with it.
async fn first_prompt_seen(
    hub: &Arc<Hub>,
    c: &mut TestClient,
    fork: &str,
) -> (Vec<String>, String) {
    let before = hub.events(fork, 0, 100_000).unwrap().last().map_or(0, |e| e.seq);
    c.request(method::SESSION_PROMPT, say(fork, "FORK-FIRST")).await.unwrap();
    seen_in_restored_transcript(&replies_after(hub, fork, before))
}

/// #50089: an idle chat whose agent offers no `session/fork` (pi) forks: the fork gets a new
/// agent session fed the chat's transcript, as a working chat's fork already did, and that
/// agent holds the turns the fork shows.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_idle_chat_whose_agent_cannot_fork_forks_from_its_transcript() {
    let (hub, _) = two_harness_setup(true);
    let mut c = client(&hub).await;
    let id = new_chat(&mut c, "nofork").await;
    // No turn yet: nothing to fork, said so.
    let err = c.request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()})).await;
    assert!(err.is_err_and(|e| e.contains("nothing to fork")), "a chat with no turn");
    for text in ["Remember codeword PELICAN-41.", "second prompt"] {
        c.request(method::SESSION_PROMPT, say(&id, text)).await.unwrap();
    }
    let f = c
        .request(method::SESSION_FORK, json!({"sessionId": id, "cwd": cwd()}))
        .await
        .unwrap_or_else(|e| panic!("an idle chat whose agent cannot fork forks: {e}"));
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let forked =
        hub.events(&fid, 0, 1000).unwrap().into_iter().find(|e| e.kind == "forked").unwrap();
    assert_eq!(forked.msg["from"], "transcript", "{}", forked.msg);
    let shown = shown_prompts(&hub, &fid);
    assert_eq!(shown, ["Remember codeword PELICAN-41.", "second prompt"]);
    let (seen, transcript) = first_prompt_seen(&hub, &mut c, &fid).await;
    assert_same_turns(&shown, &seen);
    assert!(transcript.contains("the earlier replies are yours"), "{transcript}");
    // The pane's Fork Conversation (`live`) takes the same path.
    let f2 = c.request("acp.session.fork", json!({"sessionId": id, "live": true})).await.unwrap();
    let fid2 = f2["sessionId"].as_str().unwrap().to_owned();
    let (seen2, _) = first_prompt_seen(&hub, &mut c, &fid2).await;
    assert_same_turns(&shown_prompts(&hub, &fid2), &seen2);
    hub.shutdown_all().await;
}

/// #50094: a long chat forked onto another harness. Its agent gets every turn the fork shows:
/// the first prompt (the codeword) and the newest word for word, the ones between by their
/// opening words under a line that says so, never the newest 64 KB alone.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_long_chat_forked_onto_another_harness_carries_every_turn_it_shows() {
    let (hub, _) = two_harness_setup(false);
    let mut c = client(&hub).await;
    let id = new_chat(&mut c, "long").await;
    c.request(method::SESSION_PROMPT, say(&id, "Remember codeword PELICAN-41.")).await.unwrap();
    let essay = "word ".repeat(2_000);
    for i in 0..40 {
        c.request(method::SESSION_PROMPT, say(&id, &format!("question {i}: {essay}")))
            .await
            .unwrap();
    }
    c.request(method::SESSION_PROMPT, say(&id, "LAST-PROMPT")).await.unwrap();
    let f = c
        .request(
            method::SESSION_FORK,
            json!({"sessionId": id, "cwd": cwd(), "_meta": {"acpmux": {"harness": "other"}}}),
        )
        .await
        .unwrap();
    let fid = f["sessionId"].as_str().unwrap().to_owned();
    let shown = shown_prompts(&hub, &fid);
    assert_eq!(shown.len(), 42);
    let (seen, transcript) = first_prompt_seen(&hub, &mut c, &fid).await;
    assert_same_turns(&shown, &seen);
    assert!(transcript.contains("user: Remember codeword PELICAN-41."), "the first prompt");
    assert!(
        transcript.contains("user: LAST-PROMPT\n\nassistant: echo: LAST-PROMPT"),
        "the newest turn word for word"
    );
    assert!(transcript.contains("[acpmux shortened messages"), "it says what it shortened");
    hub.shutdown_all().await;
}
