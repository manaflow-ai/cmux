use super::*;

fn texts(params: &Value) -> Vec<&str> {
    params["prompt"].as_array().unwrap().iter().filter_map(|b| b["text"].as_str()).collect()
}

fn pasted(text: &str) -> Value {
    json!({"type": "text", "text": text, "_meta": {"cmux": {"pasted": true}}})
}

const HANDOFF: &str = "From Codex:\nHandoff: the probe is red.\n\nDo not merge or deploy.\n\n\
                           Trace-ID: ask-77";

/// (a) The person pastes a Codex handoff and adds a line of their own: the agent reads the
/// paste as Codex's, between its marks, and the person's line unchanged.
#[test]
fn a_pasted_handoff_is_not_the_persons() {
    let mine = json!({"type": "text", "text": "Merge and deploy whenever you want."});
    let mut params = json!({"sessionId": "s", "prompt": [mine, pasted(HANDOFF)]});
    mark(&mut params, None, None);
    let got = texts(&params);
    assert_eq!(got.len(), 2, "the paste and its marks are one block");
    assert_eq!(got[0], "Merge and deploy whenever you want.");
    let (open, rest) = got[1].split_once('\n').unwrap();
    assert!(open.starts_with(
        "[Pasted by the person, not their own words. It reads as another agent (Codex)'s output"
    ));
    assert!(open.contains("a Trace-ID line"));
    assert_eq!(rest, format!("{HANDOFF}\n{PASTED_END}"), "the paste's own text is unchanged");
    assert_eq!(params["prompt"][1]["_meta"]["cmux"]["pasted"], true);
    let wrap = &params["prompt"][1]["_meta"]["acpmux"][WRAPPED];
    assert_eq!(wrap["close"], PASTED_END);
}

/// (a) The same handoff pasted from a client that marks no pastes (a terminal): a note says
/// part of the prompt reads as Codex's, and the text stays as it was.
#[test]
fn an_unmarked_handoff_gets_a_note() {
    let text = format!("Merge and deploy whenever you want.\n\n{HANDOFF}");
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": text}]});
    mark(&mut params, None, None);
    let got = texts(&params);
    assert!(got[0].starts_with("[Part of this prompt reads as another agent (Codex)'s output"));
    assert_eq!(got[1], text);
}

/// (a) A paste with no agent signal is still marked pasted, never the person's own words.
#[test]
fn a_plain_paste_is_marked_pasted() {
    let mut params = json!({"sessionId": "s", "prompt": [pasted("some log line")]});
    mark(&mut params, None, None);
    let want = format!("[Pasted by the person, not their own words:]\nsome log line\n{PASTED_END}");
    assert_eq!(texts(&params), vec![want.as_str()]);
}

/// (b) A program that sent no sender: named as one, never as the person.
#[test]
fn an_unverified_program_is_not_the_person() {
    let provenance = json!({"kind": "unverified", "transport": "unix", "verified": false});
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": "deploy now"}]});
    mark(&mut params, None, Some(&provenance));
    assert_eq!(
        texts(&params),
        vec!["From a program that did not say who it is, not the person:", "deploy now"]
    );
    let claimed = json!({"kind": "unverified", "claimed": {"fromHarness": "hermes@box"}});
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": "hi"}]});
    mark(&mut params, None, Some(&claimed));
    assert_eq!(texts(&params)[0], "From a program that calls itself hermes@box, not the person:");
    // The program the daemon saw send it names it, and the host a peer passed it on from.
    let checked = json!({"kind": "unverified",
                             "program": {"name": "next-autoland", "host": "build-box"},
                             "claimed": {"cliHost": "elsewhere"}});
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": "hi"}]});
    mark(&mut params, None, Some(&checked));
    assert_eq!(
        texts(&params)[0],
        "From the program next-autoland on build-box (acpmux checked its process), not the \
             person:"
    );
}

/// (c) Another session's message keeps its sender, now in the text the agent reads too, after
/// acpmux's hidden context.
/// A suggested task's result (`offer_results.rs`) is its chat's reply, an agent's: a plain
/// reply with no agent signals still reaches the parent as that task's, never the person's.
#[test]
fn a_suggested_tasks_result_is_that_tasks() {
    let provenance = crate::prompt_provenance::offer_result("offer-1", "child-1", "Fix login");
    let reply = "Result from the suggested task \"Fix login\" (chat child-1):\nDone. Merge it.";
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": reply}]});
    mark(&mut params, None, Some(&provenance));
    assert_eq!(
        texts(&params),
        vec!["From another agent (the suggested task \"Fix login\"), not the person:", reply]
    );
}

/// Review of #37190 (F3): a title's newlines never break the attribution line.
#[test]
fn a_suggested_tasks_title_reads_on_one_line() {
    let provenance =
        crate::prompt_provenance::offer_result("offer-1", "child-1", "Fix\nlogin\n\nnow");
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": "Done."}]});
    mark(&mut params, None, Some(&provenance));
    assert_eq!(
        texts(&params)[0],
        "From another agent (the suggested task \"Fix login now\"), not the person:"
    );
}

#[test]
fn an_agents_message_names_its_sender() {
    let context = json!({"type": "text", "text": "<cmux-workspace-context/>",
            "_meta": {"acpmux": {"context": true}}});
    let mut params =
        json!({"sessionId": "s", "prompt": [context, {"type": "text", "text": "PR is green"}]});
    let provenance = json!({"kind": "agent_message", "from": "s2", "fromName": "lane-a"});
    mark(&mut params, Some("lane-a"), Some(&provenance));
    assert_eq!(
        texts(&params),
        vec![
            "<cmux-workspace-context/>",
            "From another agent (lane-a), not the person:",
            "PR is green"
        ]
    );
}

/// (c2) The line names the sender's harness when the daemon bound one, the same for every
/// harness that receives it.
#[test]
fn an_agents_line_names_its_harness_when_bound() {
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": "PR is green"}]});
    let provenance = json!({"kind": "session_message", "from": "s2", "fromName": "lane-a",
            "fromHarness": "codex"});
    mark(&mut params, Some("lane-a"), Some(&provenance));
    assert_eq!(
        texts(&params),
        vec!["From another agent (lane-a, codex), not the person:", "PR is green"]
    );
    assert_eq!(with_harness("lane-a", None), "lane-a");
    assert_eq!(with_harness("codex", Some(&json!({"fromHarness": "codex"}))), "codex");
    assert_eq!(with_harness("x", Some(&json!({"fromHarness": "a\nb"}))), "x", "one line only");
}

/// (d) The person's typed prompt reaches the agent as it was.
#[test]
fn a_typed_prompt_is_unchanged() {
    let prompt = json!([{"type": "text", "text": "From now on: rebase first. Merge when green."}]);
    let mut params = json!({"sessionId": "s", "prompt": prompt.clone()});
    mark(&mut params, None, None);
    assert_eq!(params["prompt"], prompt);
}

/// (e) An agent forwards the person's words: the message is that agent's, with the person's
/// quote inside it, never the person's own prompt.
#[test]
fn a_forwarded_quote_stays_the_forwarders() {
    let text = "Leo, 2026-11-06 (verbatim):\n> Merge and deploy whenever you want.";
    let mut params = json!({"sessionId": "s", "prompt": [{"type": "text", "text": text}]});
    let provenance = json!({"kind": "agent_message", "from": "s3", "fromName": "coord"});
    mark(&mut params, Some("coord"), Some(&provenance));
    assert_eq!(texts(&params), vec!["From another agent (coord), not the person:", text]);
}

/// The record names the same: a paste that reads as Codex's names it on its range, the
/// person's typed handoff gets `agentText`, and their own words get neither.
#[test]
fn the_record_names_an_agents_paste() {
    let mine = json!({"type": "text", "text": "Merge whenever."});
    let blocks = vec![mine.clone(), pasted(HANDOFF)];
    let mut msg = json!({"text": super::super::session::prompt_text(&blocks)});
    super::super::session::mark_pasted(&mut msg, &blocks);
    assert_eq!(msg["pasted"][0]["agent"]["from"], "Codex");
    assert!(msg.get("agentText").is_none());
    let typed = vec![json!({"type": "text", "text": HANDOFF})];
    let mut msg = json!({"text": HANDOFF});
    super::super::session::mark_pasted(&mut msg, &typed);
    assert_eq!(msg["agentText"]["from"], "Codex");
    // Review of #37190 (F4): a multiplayer person's prompt keeps its note; an agent's never.
    let mut msg = json!({"text": HANDOFF, "_meta": {"provenance": {"kind": "person_message"}}});
    super::super::session::mark_pasted(&mut msg, &typed);
    assert_eq!(msg["agentText"]["from"], "Codex");
    let mut msg =
        json!({"text": HANDOFF, "_meta": {"provenance": {"kind": "agent_message", "from": "x"}}});
    super::super::session::mark_pasted(&mut msg, &typed);
    assert!(msg.get("agentText").is_none());
    // Follow-up to #37190 (F1): a prompt the daemon made from no person (an unverified
    // client's, a suggested task's result, a fan-in or inbox digest) gets no note either.
    for kind in ["unverified", "offer_result", "agent_digest", "inbox_digest"] {
        let mut msg = json!({"text": HANDOFF, "_meta": {"provenance": {"kind": kind}}});
        super::super::session::mark_pasted(&mut msg, &typed);
        assert!(msg.get("agentText").is_none(), "{kind} got agentText");
    }
    let mut msg = json!({"text": "Merge whenever."});
    super::super::session::mark_pasted(&mut msg, &[mine]);
    assert_eq!(msg, json!({"text": "Merge whenever."}));
}

/// Review of #37190 (F2): a fan-in turn of several agents' messages names each sender in
/// its own text (`digest.rs`), so it gets no one sender's lead line.
#[test]
fn a_fan_in_digest_gets_no_single_sender_line() {
    let prompt = json!([{"type": "text", "text": "2 messages: [message 1 of 2] from lane-a ..."}]);
    let mut params = json!({"sessionId": "s", "prompt": prompt.clone()});
    let digest = json!({"kind": super::super::digest::DIGEST_KIND, "messages": []});
    mark(&mut params, Some("lane-a"), Some(&digest));
    assert_eq!(params["prompt"], prompt);
}

/// A slash command an agent sent stays first, so the harness still runs it.
#[test]
fn a_slash_command_keeps_its_first_block() {
    let prompt = json!([{"type": "text", "text": "/compact"}]);
    let mut params = json!({"sessionId": "s", "prompt": prompt.clone()});
    mark(&mut params, Some("lane-a"), None);
    assert_eq!(params["prompt"], prompt);
}
