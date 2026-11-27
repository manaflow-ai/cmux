//! Who wrote a prompt, as the agent reads it (`hub/prompt_attribution.rs`, ask-fa4c523fa8): the
//! fake agent echoes the marks acpmux puts in the prompt's blocks (`FAKE_ECHO_ATTRIBUTION`).
//! Leo, 2026-11-06: "it should be automatically attributable, so it doesn't just pass off as one
//! of my messages."

use super::prompt_provenance::{Client, hub_env, seen};
use serde_json::{Value, json};

const HANDOFF: &str =
    "From Codex:\nHandoff: the probe is red.\n\nDo not merge or deploy.\n\nTrace-ID: ask-77";

/// The app's handshake on `c` (`hub_integration.rs` `become_person`): the person's prompts are
/// the person's only by that proof (`server/requests.rs` `person_admitted`); a unix client that
/// proves nothing sends unverified ones.
async fn become_person(c: &mut Client, hub: &acpmux::hub::Hub) {
    crate::hold_person_key(hub);
    let init =
        c.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "test"}})).await;
    let challenge = &init["_meta"]["acpmux"]["personChallenge"];
    let proof = acpmux::hub::person::person_proof(
        crate::PERSON_KEY,
        acpmux::hub::person::TRANSPORT_UNIX,
        challenge["nonce"].as_str().unwrap(),
        challenge["connection"].as_str().unwrap(),
    )
    .unwrap();
    let proved = c.call("_acpmux/person_prove", json!({"proof": proof})).await;
    assert_eq!(proved["person"], json!(true), "{proved}");
}

/// Sends `params` as a turn and returns what the agent read of it (its `echo: ` echo).
async fn agent_read(c: &mut Client, params: Value) -> String {
    let id = c.send("session/prompt", params).await;
    let echo = c
        .until(|v| {
            v.pointer("/params/update/content/text")
                .and_then(Value::as_str)
                .is_some_and(|t| t.starts_with("echo: "))
        })
        .await;
    let reply = c.reply_to(id).await;
    assert!(reply.get("error").is_none(), "{reply}");
    echo["params"]["update"]["content"]["text"].as_str().unwrap()["echo: ".len()..].to_owned()
}

fn params(session: &str, prompt_id: &str, blocks: Value, provenance: Option<Value>) -> Value {
    let mut mux = json!({"promptId": prompt_id});
    if let Some(p) = provenance {
        mux["provenance"] = p;
    }
    json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": mux}})
}

/// (a) The person pastes a Codex handoff saying "Do not merge or deploy" and types a line of
/// their own: the agent reads the paste as Codex's, not the person's, and their line as theirs.
/// (d) A typed prompt reaches the agent unchanged. (c) Another session's message keeps its
/// sender. (e) An agent forwarding the person's words is still that agent.
#[tokio::test]
async fn the_agent_reads_who_wrote_each_part_of_a_prompt() {
    let hub = hub_env(json!({"FAKE_ECHO_ATTRIBUTION": "1"}));
    let mut c = Client::open(&hub);
    become_person(&mut c, &hub).await;
    let session = c.new_session(json!({"harness": "fake"})).await;

    let mine = "Merge and deploy whenever you want.";
    let pasted = json!({"type": "text", "text": HANDOFF, "_meta": {"cmux": {"pasted": true}}});
    let blocks = json!([{"type": "text", "text": mine}, pasted]);
    let read = agent_read(&mut c, params(&session, "p-paste", blocks, None)).await;
    assert!(read.starts_with(mine), "{read}");
    let rest = &read[mine.len()..];
    assert!(
        rest.starts_with(
            "[Pasted by the person, not their own words. It reads as another agent (Codex)'s output"
        ),
        "{read}"
    );
    assert!(rest.ends_with(&format!("{HANDOFF}\n[End of pasted text]")), "{read}");
    let record = c.user_message(&session, "p-paste").await;
    assert_eq!(
        record["text"],
        format!("{mine}\n{HANDOFF}"),
        "the record keeps the words: {record}"
    );
    assert_eq!(record["pasted"][0]["agent"]["from"], "Codex", "{record}");

    let typed = "From now on: rebase first.";
    let read = agent_read(
        &mut c,
        params(&session, "p-typed", json!([{"type": "text", "text": typed}]), None),
    )
    .await;
    assert_eq!(read, typed);

    let provenance = json!({"kind": "agent_message", "from": "acp:sender-1", "fromName": "builder",
        "to": format!("acp:{session}"), "msgId": "msg-1", "threadId": "thread-1"});
    let text = "Leo, 2026-11-06 (verbatim):\n> Merge and deploy whenever you want.";
    let blocks = json!([{"type": "text", "text": text}]);
    let read =
        agent_read(&mut c, params(&session, "p-agent", blocks, Some(provenance.clone()))).await;
    assert_eq!(read, format!("From another agent (builder), not the person:{text}"));
    let record = c.user_message(&session, "p-agent").await;
    assert_eq!(record.pointer("/_meta/provenance"), Some(&seen(provenance, "unix")), "{record}");
    assert!(record.get("agentText").is_none(), "{record}");
}

/// A send from a Codex shell outside acpmux goes through this daemon's outbox
/// (`_acpmux/send_queue`, client `acpmux-outbox#…`) naming its harness (`cli/sender.rs`
/// `implicit`, `harness_name`): it is recorded as that agent's message, never the person's "you",
/// and the agent reads it as that agent's. Leo saw such sends as his own (ask-03a81c42d5).
#[tokio::test]
async fn an_outbox_send_from_an_agent_shell_is_that_agents() {
    let hub = hub_env(json!({"FAKE_ECHO_ATTRIBUTION": "1"}));
    let mut c = Client::open(&hub);
    let session = c.new_session(json!({"harness": "fake"})).await;
    let request = json!({"sessionId": session, "prompt": [{"type": "text", "text": "PR is green"}],
        "_meta": {"acpmux": {"promptId": "p-outbox", "fromAgent": "Codex on devbox"}}});
    c.call("_acpmux/send_queue", json!({"request": request})).await;
    let echo = c
        .until(|v| {
            v.pointer("/params/update/content/text")
                .and_then(Value::as_str)
                .is_some_and(|t| t.starts_with("echo: From another agent"))
        })
        .await;
    assert_eq!(
        echo["params"]["update"]["content"]["text"],
        "echo: From another agent (Codex on devbox), not the person:PR is green"
    );
    let record = c.user_message(&session, "p-outbox").await;
    assert!(record["client"].as_str().unwrap_or_default().starts_with("acpmux-outbox"), "{record}");
    assert_eq!(
        record.pointer("/_meta/provenance/fromName"),
        Some(&json!("Codex on devbox")),
        "{record}"
    );
}
