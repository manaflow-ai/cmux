use super::*;

/// A free-text item (no options, own text allowed: an elicitation's
/// string field) takes the whole value as typed, commas and spacing
/// included; it is never split into parts and rejoined.
#[test]
fn a_free_text_answer_is_kept_whole() {
    let question = json!({"harness": "claude", "items": [
            {"id": "q1", "prompt": "Name?", "options": [], "allowsOther": true}]});
    for typed in ["a,  b", "x, x", "a,,b", "1,000"] {
        let answers = parse_answers(&question, &[format!("q1={typed}")]).expect(typed);
        assert_eq!(answers, json!({"Name?": typed}), "{typed:?}");
    }
}

/// An item with options still reads comma-separated labels, and unknown
/// parts become its Other text.
#[test]
fn an_item_with_options_still_splits_on_commas() {
    let question = json!({"harness": "claude", "items": [
            {"id": "q1", "prompt": "Pick?", "multiSelect": true, "allowsOther": true,
             "options": [{"label": "Red"}, {"label": "Blue"}]}]});
    let answers = parse_answers(&question, &["q1=blue, red, teal".into()]).unwrap();
    assert_eq!(answers, json!({"Pick?": "Red, Blue, teal"}));
}

/// The CLI is never the person (`hub/person.rs`): the daemon refuses its
/// allow and its answer. The way to answer a pending ask it prints (the
/// send reply, `acpmux pending`) names the app for those, and only the
/// commands the CLI may run (ergo-walk, 2026-10-25).
#[test]
fn the_pending_hint_offers_only_what_the_cli_may_run() {
    let permission = json!({"toolCall": {"title": "Read README.md"}, "options": [
            {"optionId": "accept", "kind": "allow_once"},
            {"optionId": "cancel", "kind": "reject_once"}]});
    let hint = pending_hint(&permission, "my-linux/api-work");
    assert!(!hint.contains("session allow"), "{hint}");
    assert!(hint.contains("allow it in the cmux app (the chat's permission card)"), "{hint}");
    assert!(hint.contains("acpmux session deny my-linux/api-work"), "{hint}");
    assert!(hint.contains("acpmux session cancel my-linux/api-work"), "{hint}");

    let question = json!({"toolCall": {"_meta": {"acpmux": {"question": {"items": [
            {"id": "q1", "prompt": "Pick?", "options": [{"label": "Red"}]}]}}}},
            "options": [{"optionId": "allow", "kind": "allow_once"}]});
    let hint = pending_hint(&question, "s");
    assert!(!hint.contains("session answer"), "{hint}");
    assert!(hint.contains("answer it in the cmux app (the chat's question card)"), "{hint}");
    assert!(hint.contains("acpmux session deny s"), "{hint}");
    assert!(hint.contains("acpmux session cancel s"), "{hint}");
}

/// `new` and `send` say before the work starts that an allow needs the
/// app, only for a policy that asks.
#[test]
fn the_app_allow_note_is_only_for_a_policy_that_asks() {
    for policy in ["ask", "approve-reads", "approve-edits"] {
        let note = app_allow_note(&json!({"policy": policy}), "api-work").expect(policy);
        assert!(note.contains("only the cmux app can allow"), "{note}");
        assert!(note.contains("`acpmux session deny api-work`"), "{note}");
        assert!(!note.contains("session allow"), "{note}");
    }
    // A session on the daemon default has no policy of its own: the
    // default it runs under counts (`enforcement.policy`).
    let default = json!({"policy": null, "enforcement": {"policy": "ask"}});
    assert!(app_allow_note(&default, "api-work").is_some());
    let own = json!({"policy": "approve-all", "enforcement": {"policy": "approve-all"}});
    assert_eq!(app_allow_note(&own, "api-work"), None);
    for info in [json!({"policy": "approve-all"}), json!({"policy": "deny-all"}), json!({})] {
        assert_eq!(app_allow_note(&info, "api-work"), None, "{info}");
    }
}

/// W5-S, bench round 4 friction 6 (2026-11-08): `policy ask` (the daemon default) with mode
/// `bypassPermissions` from the harness's settings asked nothing, and the note said the
/// session "asks before some tools run". A daemon default that is not the chat's own does not
/// change a mode that runs tools unasked (chats start in full access, `hub/policy_gate.rs`):
/// the note says that, and how to hold the policy.
#[test]
fn w5s_the_note_says_when_the_mode_runs_tools_unasked() {
    let modes = |id: &str| json!({"currentModeId": id, "availableModes": []});
    let default_ask = json!({"harness": "claude", "policy": null,
                                 "enforcement": {"policy": "ask"},
                                 "modes": modes("bypassPermissions")});
    let note = app_allow_note(&default_ask, "alpha").expect("a note");
    assert!(!note.contains("asks before some tools run"), "{note}");
    assert!(note.contains("bypassPermissions"), "{note}");
    assert!(note.contains("acpmux session set alpha policy=ask"), "{note}");
    // The chat's own policy holds whatever mode it started in (`policy_mode.rs`).
    let own = json!({"harness": "claude", "policy": "ask", "enforcement": {"policy": "ask"},
                         "modes": modes("bypassPermissions")});
    let note = app_allow_note(&own, "alpha").expect("a note");
    assert!(note.contains("asks before some tools run"), "{note}");
    // A mode that asks keeps the note as it was.
    let asking = json!({"harness": "claude", "policy": null,
                            "enforcement": {"policy": "ask"}, "modes": modes("default")});
    let note = app_allow_note(&asking, "alpha").expect("a note");
    assert!(note.contains("asks before some tools run"), "{note}");
}

/// Review of #39057: only a mode that runs every tool unasked makes the daemon default not
/// hold. Claude's `acceptEdits` still asks before Bash, and the default `ask` answers that;
/// `dontAsk` denies what is not allowed; Codex's `read-only` and `agent` ask outside the
/// workspace; opencode's `build` asks outside the project, for `*.env` and repeated calls.
/// They keep the asking note. Claude's `bypassPermissions` and Codex's `agent-full-access`
/// run everything, so they get the note that says so; a mode of the same name in another
/// reviewed harness (opencode) says nothing about what it asks, and neither does a mode
/// with no full-access marker in an unreviewed one (`build`).
#[test]
fn w5s_only_a_mode_that_runs_everything_unasked_drops_the_asking_note() {
    let default_ask = |harness: &str, mode: &str| {
        json!({"harness": harness, "policy": null, "enforcement": {"policy": "ask"},
                   "modes": {"currentModeId": mode, "availableModes": []}})
    };
    for (harness, mode) in [
        ("claude", "acceptEdits"),
        ("codex", "read-only"),
        ("codex", "agent"),
        ("opencode", "build"),
        ("my-agent", "build"),
        ("gemini", "autoEdit"),
        ("opencode", "agent-full-access"),
    ] {
        let note = app_allow_note(&default_ask(harness, mode), "alpha").expect("a note");
        assert!(note.contains("asks before some tools run"), "{harness} {mode}: {note}");
        assert!(!note.contains("does not hold"), "{harness} {mode}: {note}");
    }
    for (harness, mode) in [("claude", "bypassPermissions"), ("codex", "agent-full-access")] {
        let note = app_allow_note(&default_ask(harness, mode), "alpha").expect("a note");
        assert!(note.contains("does not hold here"), "{harness} {mode}: {note}");
    }
    // A launcher profile of its own family that runs Claude Code has Claude Code's modes.
    let sr2 = json!({"harness": "claude-sr2", "family": "claude-sr2", "policy": null,
                         "agentInfo": {"name": crate::claude_stdio::AGENT_NAME},
                         "enforcement": {"policy": "ask"},
                         "modes": {"currentModeId": "bypassPermissions", "availableModes": []}});
    let note = app_allow_note(&sr2, "alpha").expect("a note");
    assert!(note.contains("does not hold here"), "{note}");
}

/// Review 3 of #39057: a Codex launcher with a family of its own (`codex-sr2`, whose agent is
/// codex-acp) in `agent-full-access` runs everything as Codex does, so the note says the
/// default does not hold; its `agent` still asks.
#[test]
fn w5s_a_codex_launcher_in_full_access_gets_the_bypass_note() {
    let info = |mode: &str| {
        json!({"harness": "codex-sr2", "family": "codex-sr2", "policy": null,
                   "agentInfo": {"name": "@agentclientprotocol/codex-acp", "title": "Codex"},
                   "enforcement": {"policy": "ask"},
                   "modes": {"currentModeId": mode, "availableModes": []}})
    };
    let note = app_allow_note(&info("agent-full-access"), "alpha").expect("a note");
    assert!(note.contains("does not hold here"), "{note}");
    let note = app_allow_note(&info("agent"), "alpha").expect("a note");
    assert!(note.contains("asks before some tools run"), "{note}");
}

/// Review 3 of #39057: a harness outside the reviewed table whose mode skips every approval
/// by acpmux's shared rule (`spec/full-access-modes.json`: Gemini's `yolo`, a custom
/// agent's `bypassPermissions`) gets the bypass note too.
#[test]
fn w5s_a_full_access_mode_of_an_unreviewed_harness_gets_the_bypass_note() {
    for (harness, mode) in [("gemini", "yolo"), ("my-agent", "bypassPermissions")] {
        let info = json!({"harness": harness, "policy": null, "enforcement": {"policy": "ask"},
                              "modes": {"currentModeId": mode, "availableModes": []}});
        let note = app_allow_note(&info, "alpha").expect("a note");
        assert!(note.contains("does not hold here"), "{harness} {mode}: {note}");
    }
}

/// Review of #39057: Claude's `dontAsk` asks nothing; it denies a tool that is not allowed
/// beforehand. Under a daemon default the note says that, not "asks before some tools run"
/// (no question comes) and not "runs tools without asking" (denied tools do not run). The
/// chat's own policy keeps the asking note, and another harness's `dontAsk` says nothing.
#[test]
fn w5s_dont_ask_says_tools_not_allowed_are_denied() {
    let info = |harness: &str, policy: Value| {
        json!({"harness": harness, "policy": policy, "enforcement": {"policy": "ask"},
                   "modes": {"currentModeId": "dontAsk", "availableModes": []}})
    };
    let note = app_allow_note(&info("claude", Value::Null), "alpha").expect("a note");
    assert!(note.contains("denied, not asked"), "{note}");
    assert!(note.contains("acpmux session set alpha policy=ask"), "{note}");
    assert!(!note.contains("asks before some tools run"), "{note}");
    assert!(!note.contains("runs tools without asking"), "{note}");
    let own = app_allow_note(&info("claude", json!("ask")), "alpha").expect("a note");
    assert!(own.contains("asks before some tools run"), "{own}");
    let other = app_allow_note(&info("my-agent", Value::Null), "alpha").expect("a note");
    assert!(other.contains("asks before some tools run"), "{other}");
}
