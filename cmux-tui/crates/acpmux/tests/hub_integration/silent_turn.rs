//! A turn whose agent says nothing (`hub/silent_turn.rs`): past `silentTurnMs`
//! with no word from the agent, the chat logs `turn_silent`.

use super::*;

/// An OpenCode free model that stalls left the chat on "Thinking" with no end
/// and no sign why. A turn whose agent sends nothing past `silentTurnMs` logs
/// `turn_silent` once; a turn whose agent answered and then works quietly (a
/// long command) never does.
#[tokio::test]
async fn a_turn_the_agent_never_answers_says_so_and_a_quiet_working_one_does_not() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.silent_turn_ms = Some(400);
    let id = new_session(&mut c, "silent").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "mute", None)).await;
    let silent = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_silent").await;
    assert_eq!(silent["msg"]["silentMs"], 400, "{silent}");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let started = find(&events, "turn_started");
    assert_eq!(silent["msg"]["turnId"], started[0].msg["turnId"], "{silent}");
    assert_eq!(c.response(rid).await.0.unwrap()["stopReason"], "end_turn");

    // An answer at once, then a turn that streams one word and works on: neither is silent.
    c.request(method::SESSION_PROMPT, prompt(&id, "hi", None)).await.unwrap();
    c.send(method::SESSION_PROMPT, prompt(&id, "hang", None)).await;
    c.wait_for(method::SESSION_UPDATE, |p| p["update"]["content"]["text"] == "working").await;
    tokio::time::sleep(Duration::from_millis(1_200)).await;
    let events = hub.events(&id, 0, 10_000).unwrap();
    assert_eq!(find(&events, "turn_silent").len(), 1, "{:?}", find(&events, "turn_silent"));

    // 0 turns it off.
    hub.config.write().await.silent_turn_ms = Some(0);
    let quiet = new_session(&mut c, "silent-off").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&quiet, "mute", None)).await;
    assert_eq!(c.response(rid).await.0.unwrap()["stopReason"], "end_turn");
    assert!(find(&hub.events(&quiet, 0, 10_000).unwrap(), "turn_silent").is_empty());
}

/// Codex reports its turn and its token usage as soon as the prompt goes out, so a stalled Codex
/// model was never silent: only what the model says (a message, a thought, a tool call, a plan, a
/// request) counts as an answer, not the agent's own bookkeeping.
#[tokio::test]
async fn a_turn_whose_agent_only_reports_bookkeeping_is_silent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.silent_turn_ms = Some(400);
    let id = new_session(&mut c, "silent-busy").await;
    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "mute-busy", None)).await;
    let silent = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_silent").await;
    assert_eq!(silent["msg"]["silentMs"], 400, "{silent}");
    // The model's late word ends the silence for every client: `turn_heard`, before the word.
    let heard = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_heard").await;
    assert_eq!(heard["msg"]["turnId"], silent["msg"]["turnId"], "{heard}");
    assert_eq!(c.response(rid).await.0.unwrap()["stopReason"], "end_turn");
    let events = hub.events(&id, 0, 10_000).unwrap();
    let at = |kind: &str| events.iter().position(|e| e.kind == kind).unwrap_or(usize::MAX);
    assert!(
        at("turn_heard") < at("agent_message_chunk"),
        "{:?}",
        events.iter().map(|e| &e.kind).collect::<Vec<_>>()
    );
    assert_eq!(find(&events, "turn_heard").len(), 1);
}

/// A model at work often says nothing a client shows: Codex reasoning without summaries, Claude's
/// redacted thinking, a prompt queued behind a running tool. Any sign of the model working counts:
/// what it says or does, its requests, and the raw harness lines only a responding model produces.
#[tokio::test]
async fn a_turn_whose_model_shows_any_sign_of_work_is_not_silent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.silent_turn_ms = Some(300);
    let id = new_session(&mut c, "silent-signs").await;
    for what in [
        "thought",
        "tool",
        "plan",
        "ask",
        "compaction",
        "subagent",
        "stream",
        "assistant",
        "thinking",
        "tool-progress",
        "moderation",
    ] {
        let text = format!("quiet-{what}");
        c.request(method::SESSION_PROMPT, prompt(&id, &text, None)).await.unwrap();
        let events = hub.events(&id, 0, 10_000).unwrap();
        assert!(
            find(&events, "turn_silent").is_empty(),
            "{what}: {:?}",
            find(&events, "turn_silent")
        );
    }
}

/// "No response from the model yet" said nothing of why (Leo, 2026-11-03: "and why am i getting
/// this"). The silence's `reason` says it: nothing known (`no_answer`), the harness retrying an
/// overloaded API (`capacity`, with its attempt, logged again as the attempt moves), or a refused
/// sign-in on its stderr (`auth`, with the harness's line).
#[tokio::test]
async fn a_silent_turn_says_why_it_is_silent() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.silent_turn_ms = Some(300);
    let id = new_session(&mut c, "silent-why").await;

    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "mute", None)).await;
    let silent = c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_silent").await;
    assert_eq!(silent["msg"]["reason"]["kind"], "no_answer", "{silent}");
    c.response(rid).await.0.unwrap();

    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "mute-retry", None)).await;
    let first = c
        .wait_for(method::MUX_EVENT, |p| {
            p["kind"] == "turn_silent" && p["msg"]["reason"]["attempt"] == 1
        })
        .await;
    assert_eq!(first["msg"]["reason"]["kind"], "capacity", "{first}");
    assert_eq!(first["msg"]["reason"]["of"], 10, "{first}");
    let second = c
        .wait_for(method::MUX_EVENT, |p| {
            p["kind"] == "turn_silent" && p["msg"]["reason"]["attempt"] == 2
        })
        .await;
    assert_eq!(second["msg"]["turnId"], first["msg"]["turnId"], "{second}");
    c.response(rid).await.0.unwrap();

    let rid = c.send(method::SESSION_PROMPT, prompt(&id, "mute-auth", None)).await;
    let auth = c
        .wait_for(method::MUX_EVENT, |p| {
            p["kind"] == "turn_silent" && p["msg"]["reason"]["kind"] != "no_answer"
        })
        .await;
    assert_eq!(auth["msg"]["reason"]["kind"], "auth", "{auth}");
    let detail = auth["msg"]["reason"]["detail"].as_str().unwrap_or_default();
    assert!(detail.contains("401"), "{auth}");
    c.response(rid).await.0.unwrap();
}

/// The silent line's Retry (`_acpmux/retry` `silent`) ends the silent turn as failed and sends it
/// again at once; a running turn that is not silent is `retry.busy`.
#[tokio::test]
async fn retry_on_a_silent_turn_ends_it_and_sends_it_again() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.silent_turn_ms = Some(300);
    hub.config.write().await.auto_resume_delays_ms = Some(vec![]);
    let id = new_session(&mut c, "silent-retry").await;

    // Not silent: busy.
    let mut other = connect(&hub).await;
    let sid = id.clone();
    let running = tokio::spawn(async move {
        other
            .request(
                method::SESSION_PROMPT,
                json!({"sessionId": sid, "prompt": [{"type": "text", "text": "until-cancel"}], "_meta": {"acpmux": {"promptId": "p-run"}}}),
            )
            .await
    });
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_started").await;
    let e = c.request("_acpmux/retry", json!({"sessionId": id, "silent": true})).await.unwrap_err();
    assert!(e.starts_with("retry.busy"), "{e}");
    c.request(method::SESSION_CANCEL, json!({"sessionId": id})).await.unwrap();
    let _ = running.await;

    let rid = c
        .send(
            method::SESSION_PROMPT,
            json!({"sessionId": id, "prompt": [{"type": "text", "text": "mute"}], "_meta": {"acpmux": {"promptId": "p-mute"}}}),
        )
        .await;
    c.wait_for(method::MUX_EVENT, |p| p["kind"] == "turn_silent").await;
    let v = c.request("_acpmux/retry", json!({"sessionId": id, "silent": true})).await.unwrap();
    assert_eq!(v["promptId"], "p-mute~resume-1", "{v}");
    let e = c.response(rid).await.0.unwrap_err();
    assert!(e.contains("said nothing"), "{e}");
}
