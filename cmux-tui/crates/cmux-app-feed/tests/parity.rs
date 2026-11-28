//! The Swift Feed tests' cases, run against the Rust rules through the `app_feed_*` ops the app
//! will call (AcpmuxFeedBridgeQuestionTests, AgentDialogControlTests, FeedNeedsYouPhoneTests,
//! UpdateFeedCardTests, the approve proof's sign and verify).

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_app_feed::{AppFeed, OpError};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use serde_json::{Value, json};

fn call(op: &str, request: Value) -> Value {
    AppFeed::new().call(op, request).unwrap_or_else(|error| panic!("{op}: {error}"))
}

fn options() -> Value {
    json!([{"optionId": "allow", "kind": "allow_once", "name": "Allow"},
           {"optionId": "reject", "kind": "reject_once", "name": "Reject"}])
}

fn question_request() -> Value {
    let item = json!({"id": "q0", "header": "Database", "prompt": "Which database should I use?",
                      "options": [{"id": "o0", "label": "Postgres"}, {"id": "o1", "label": "SQLite"}],
                      "multiSelect": false, "allowsOther": true});
    json!({"sessionId": "sess-1", "options": options(), "toolCall": {
        "toolCallId": "call-1", "title": "AskUserQuestion", "kind": "other",
        "rawInput": {"questions": [{"question": "Which database should I use?", "header": "Database",
                                    "options": [{"label": "Postgres"}, {"label": "SQLite"}]}]},
        "_meta": {"claude": {"tool": "AskUserQuestion"},
                  "acpmux": {"question": {"harness": "claude", "agent": "Claude Code", "items": [item]}}},
    }})
}

fn bash_request() -> Value {
    json!({"sessionId": "sess-1", "options": options(), "toolCall": {
        "toolCallId": "call-2", "title": "Run tests", "kind": "execute",
        "rawInput": {"command": "swift test --filter Login"},
    }})
}

fn post_params(request: Value) -> Value {
    let body = call(
        "app_feed_bridge_post_body",
        json!({"session": "sess-1", "permission": "perm-1", "request": request, "host": "inst_mac"}),
    );
    assert_eq!(body["op"], "feed.post");
    body["params"].clone()
}

// AcpmuxFeedBridgeQuestionTests

#[test]
fn a_question_posts_a_high_priority_notice_not_an_approve() {
    let params = post_params(question_request());
    assert_ne!(params["kind"], "approve");
    assert_eq!(params["type"], "notice");
    assert!(params.get("prompt").is_none());
    let title = params["title"].as_str().unwrap();
    assert!(!title.starts_with("Allow"));
    assert!(title.contains("Claude Code"));
    assert!(title.contains("Which database should I use?"));
    assert_eq!(params["context"]["acp_session"], "sess-1");
    assert_eq!(params["priority"], "high");
    assert_eq!(params["expires_in_ms"], 86_400_000);
}

#[test]
fn a_question_with_no_text_still_reads_as_a_question() {
    let mut request = question_request();
    request["toolCall"]["title"] = "".into();
    request["toolCall"]["rawInput"] = json!({});
    request["toolCall"]["_meta"] = json!({"acpmux": {"question": {"agent": "Codex", "items": []}}});
    assert_eq!(post_params(request)["title"], "Codex asks a question");
}

#[test]
fn an_ask_user_question_without_the_normalized_question_is_still_a_question() {
    let mut request = question_request();
    request["toolCall"]["_meta"] = json!({"claude": {"tool": "AskUserQuestion"}});
    let params = post_params(request);
    assert_ne!(params["kind"], "approve");
    assert!(!params["title"].as_str().unwrap_or_default().starts_with("Allow"));
}

#[test]
fn a_tool_permission_still_posts_an_approve_item() {
    let params = post_params(bash_request());
    assert_eq!(params["type"], "request");
    assert_eq!(params["kind"], "approve");
    assert_eq!(params["title"], "Allow Run tests?");
    assert_eq!(params["prompt"]["action"]["command"], "swift test --filter Login");
}

#[test]
fn localized_strings_fill_the_title() {
    let body = call(
        "app_feed_bridge_post_body",
        json!({
            "session": "s", "permission": "p", "request": bash_request(), "host": "h",
            "strings": {"title": "Autoriser {name} ?"},
        }),
    );
    assert_eq!(body["params"]["title"], "Autoriser Run tests ?");
    assert_eq!(body["params"]["poster"]["label"], "Agent");
}

#[test]
fn a_secret_in_the_command_is_redacted_and_marks_the_prompt_shortened() {
    let mut request = bash_request();
    request["toolCall"]["rawInput"]["command"] = "curl -H Bearer abcdef123".into();
    let params = post_params(request);
    assert_eq!(params["prompt"]["action"]["command"], "curl -H Bearer [redacted]");
    assert_eq!(params["prompt"]["action"]["truncated"], true);
}

// AgentDialogControlTests

fn tool_prompt() -> Value {
    json!({"permission": "perm-tool", "session": "s-tool", "session_name": "builder", "request": {
        "toolCall": {"title": "Run rm -rf build", "kind": "execute", "rawInput": {"command": "rm -rf build"}},
        "options": [{"optionId": "yes", "kind": "allow_once", "name": "Allow"},
                    {"optionId": "no", "kind": "reject_once", "name": "Deny"}],
    }})
}

fn ask_question() -> Value {
    json!({"harness": "claude", "decline_option": "skip", "items": [{
        "id": "q0", "header": "DB", "prompt": "Which database?", "multi_select": false, "allows_other": true,
        "options": [{"id": "Postgres", "label": "Postgres"}, {"id": "SQLite", "label": "SQLite"}],
    }]})
}

fn ask_prompt() -> Value {
    json!({"permission": "perm-ask", "session": "s-ask", "request": {
        "toolCall": {"title": "AskUserQuestion", "_meta": {"claude": {"tool": "AskUserQuestion"}}},
        "options": [{"optionId": "ok", "kind": "allow_once", "name": "Answer"},
                    {"optionId": "skip", "kind": "reject_once", "name": "Skip"}],
    }})
}

#[test]
fn the_list_shows_a_permission_and_a_question() {
    let tool = call("app_feed_desk_item", json!({"prompt": tool_prompt()}));
    assert_eq!(tool["id"], "perm-tool");
    assert_eq!(tool["kind"], "permissionRequest");
    assert_eq!(tool["status"], "pending");
    assert_eq!(tool["session_id"], "s-tool");
    assert_eq!(tool["title"], "Run rm -rf build");
    assert_eq!(tool["command"], "rm -rf build");
    assert_eq!(tool["tool"], "execute");
    let ask = call(
        "app_feed_desk_item",
        json!({"prompt": ask_prompt(), "question": ask_question(), "tab_id": "tab_ask"}),
    );
    assert_eq!(ask["kind"], "question");
    assert_eq!(ask["tab_id"], "tab_ask");
    assert_eq!(ask["questions"][0]["prompt"], "Which database?");
    let labels: Vec<&str> = ask["questions"][0]["options"]
        .as_array()
        .unwrap()
        .iter()
        .map(|o| o["label"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["Postgres", "SQLite"]);
    assert!(ask["questions"][0].get("decline_option").is_none());
    let denied = call("app_feed_desk_item", json!({"prompt": tool_prompt(), "status": "denied"}));
    assert_eq!(denied["status"], "denied");
}

#[test]
fn a_permission_is_denied_with_its_reject_option() {
    let reply = call("app_feed_desk_deny", json!({"mode": "deny", "prompt": tool_prompt()}));
    assert_eq!(
        reply["reply"],
        json!({"sessionId": "s-tool", "permissionId": "perm-tool", "optionId": "no"})
    );
    let declined = call(
        "app_feed_desk_deny",
        json!({"mode": "deny", "prompt": ask_prompt(), "question": ask_question()}),
    );
    assert_eq!(declined["reply"]["optionId"], "skip");
}

#[test]
fn a_permission_is_never_allowed_from_the_socket() {
    for mode in ["allow", "always", "bypassPermissions", "acceptEdits"] {
        let reply = call("app_feed_desk_deny", json!({"mode": mode, "prompt": tool_prompt()}));
        assert_eq!(reply["error"]["code"], "person_required", "{mode}");
        assert_eq!(reply["error"]["request_id"], "perm-tool");
        assert!(reply.get("reply").is_none());
    }
}

#[test]
fn a_question_answer_matches_an_option_ignoring_case() {
    let reply =
        call("app_feed_desk_answer", json!({"selections": ["sqlite"], "question": ask_question()}));
    assert_eq!(reply["selections"]["q0"], json!({"option_ids": ["SQLite"]}));
}

#[test]
fn a_question_answer_by_item_key_and_other_text() {
    let reply = call(
        "app_feed_desk_answer",
        json!({"selections": ["DB=MySQL"], "question": ask_question()}),
    );
    assert_eq!(reply["selections"]["q0"], json!({"option_ids": [], "other": "MySQL"}));
    let reply = call(
        "app_feed_desk_answer",
        json!({"selections": ["which database? = Postgres"], "question": ask_question()}),
    );
    assert_eq!(reply["selections"]["q0"]["option_ids"], json!(["Postgres"]));
}

#[test]
fn a_choice_outside_the_options_is_refused_without_other() {
    let mut question = ask_question();
    question["items"][0]["allows_other"] = false.into();
    let reply =
        call("app_feed_desk_answer", json!({"selections": ["MySQL"], "question": question}));
    assert_eq!(reply["error"]["code"], "invalid_params");
    assert_eq!(
        reply["error"]["message"],
        "MySQL is not an option of DB; choose from: Postgres, SQLite"
    );
}

#[test]
fn several_items_need_item_keys() {
    let mut question = ask_question();
    let mut second = question["items"][0].clone();
    second["id"] = "q1".into();
    second["header"] = "Cache".into();
    second["prompt"] = "Which cache?".into();
    question["items"].as_array_mut().unwrap().push(second);
    let reply = call(
        "app_feed_desk_answer",
        json!({"selections": ["SQLite"], "question": question.clone()}),
    );
    assert_eq!(reply["error"]["code"], "invalid_params");
    let reply = call(
        "app_feed_desk_answer",
        json!({"selections": ["cache=Postgres", "DB=SQLite"], "question": question}),
    );
    assert_eq!(reply["selections"]["q1"]["option_ids"], json!(["Postgres"]));
    assert_eq!(reply["selections"]["q0"]["option_ids"], json!(["SQLite"]));
}

// FeedNeedsYouPhoneTests

fn needs_you_item(
    id: &str,
    kind: &str,
    kind_type: &str,
    context: Value,
    state: &str,
    github: Value,
) -> Value {
    json!({"id": id, "home": "local:github", "type": kind_type, "kind": kind, "title": "GitHub", "body": "acme/app#30817",
           "context": context, "poster": {"kind": "integration", "label": "GitHub"}, "state": state,
           "created_at": 1_700_000_000_000_i64, "github": github})
}

fn pr_context() -> Value {
    json!({"url": "https://github.com/acme/app/pull/30817"})
}

#[test]
fn a_held_pull_request_goes_to_the_phone_with_its_title_and_link() {
    let held = needs_you_item(
        "fi_held",
        "review",
        "request",
        pr_context(),
        "open",
        json!({"title": "Spaces switcher", "repo": "acme/app", "number": 30817, "url": "https://github.com/acme/app/pull/30817"}),
    );
    let reply = call("app_feed_needs_you_requests", json!({"items": [held]}));
    assert_eq!(
        reply["requests"],
        json!([{"id": "fi_held", "title": "Spaces switcher", "body": "acme/app#30817", "kind": "review",
        "source": "GitHub", "url": "https://github.com/acme/app/pull/30817", "createdAt": 1_700_000_000.0}])
    );
}

#[test]
fn approvals_from_acpmux_notices_and_closed_requests_stay_off() {
    let items = [
        needs_you_item(
            "fi_agent",
            "review",
            "request",
            json!({"acp_session": "s1"}),
            "open",
            Value::Null,
        ),
        needs_you_item("fi_notice", "notice", "notice", pr_context(), "open", Value::Null),
        needs_you_item("fi_done", "review", "request", pr_context(), "answered", Value::Null),
        needs_you_item("fi_open", "review", "request", pr_context(), "open", Value::Null),
    ];
    let reply = call("app_feed_needs_you_requests", json!({"items": items}));
    let ids: Vec<&str> =
        reply["requests"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["fi_open"]);
}

fn view(loaded: bool, state: &str, reason: Option<&str>, signed_in: bool, entries: Value) -> Value {
    let mut connection = json!({"state": state});
    if let Some(reason) = reason {
        connection["reason"] = reason.into();
    }
    let mut view = json!({"loaded": loaded, "connection": connection, "groups": [{"id": "needs_you", "entries": entries}]});
    if signed_in {
        view["account"] = json!({"id": "stack:p:a", "user": "a"});
    }
    view
}

fn current(view: Value) -> Value {
    call("app_feed_needs_you", json!({"view": view}))["requests"].clone()
}

#[test]
fn nothing_goes_until_the_feed_loaded() {
    assert_eq!(current(view(false, "connecting", None, true, json!([]))), Value::Null);
    assert_eq!(current(view(true, "offline", None, true, json!([]))), Value::Null);
    assert_eq!(current(view(true, "connected", None, true, json!([]))), json!([]));
    assert_eq!(current(view(true, "disconnected", Some("offline"), true, json!([]))), json!([]));
    assert_eq!(current(view(false, "disconnected", Some("offline"), true, json!([]))), Value::Null);
    assert_eq!(
        current(view(false, "disconnected", Some("signed_out"), false, json!([]))),
        Value::Null
    );
}

#[test]
fn an_unloaded_empty_view_after_a_failed_first_connection_sends_nothing() {
    for reason in ["offline", "unavailable", "expired", "forbidden", "unauthenticated"] {
        let failed = view(false, "disconnected", Some(reason), true, json!([]));
        let reply = call("app_feed_needs_you", json!({"view": failed}));
        assert_eq!(reply["settled"], false, "{reason}");
        assert_eq!(reply["requests"], Value::Null, "{reason}");
    }
    let open = needs_you_item("fi_open", "review", "request", pr_context(), "open", Value::Null);
    let loaded = view(true, "connected", None, true, json!([{"id": "fi_open", "item": open}]));
    let requests = current(loaded);
    assert_eq!(requests, call("app_feed_needs_you_requests", json!({"items": [open]}))["requests"]);
    assert_eq!(requests[0]["id"], "fi_open");
}

#[test]
fn a_signed_out_view_has_no_owner() {
    let reply = call(
        "app_feed_needs_you",
        json!({"view": view(true, "disconnected", Some("signed_out"), true, json!([]))}),
    );
    assert_eq!(reply["owner"], Value::Null);
    let reply =
        call("app_feed_needs_you", json!({"view": view(true, "connected", None, true, json!([]))}));
    assert_eq!(reply["owner"], "stack:p:a");
}

// UpdateFeedCardTests (the posting step)

fn highlights(from: &str, changes: usize) -> Value {
    let items: Vec<Value> =
        (0..changes.min(3)).map(|index| json!({"title": format!("change {index}")})).collect();
    let rest: Vec<Value> =
        (3..changes.max(3)).map(|index| json!({"title": format!("change {index}")})).collect();
    json!({"version": "1.0.0-nightly.200", "from_version": from, "items": items, "rest": rest, "more_count": rest.len()})
}

#[test]
fn the_app_card_comes_from_the_highlights_once_they_list_changes() {
    let card = call(
        "app_feed_update_card",
        json!({"highlights": highlights("1.0.0-nightly.100", 7), "at": 1.0}),
    )["card"]
        .clone();
    assert_eq!(card["subject"], "app");
    assert_eq!(card["from"], "1.0.0-nightly.100");
    assert_eq!(card["to"], "1.0.0-nightly.200");
    assert_eq!(card["changes"].as_array().unwrap().len(), 7);
    assert_eq!(card["unlisted"], 0);
    let loading =
        call("app_feed_update_card", json!({"highlights": highlights("1.0.0-nightly.100", 0)}));
    assert_eq!(loading["card"], Value::Null);
    let same =
        call("app_feed_update_card", json!({"highlights": highlights("1.0.0-nightly.200", 7)}));
    assert_eq!(same["card"], Value::Null);
    let mut old = highlights("1.0.0-nightly.100", 7);
    old["rest"] = Value::Null;
    let old_card = call("app_feed_update_card", json!({"highlights": old}))["card"].clone();
    assert_eq!(old_card["unlisted"], 4);
    assert_eq!(old_card["changes"].as_array().unwrap().len(), 3);
    let first =
        call("app_feed_update_card", json!({"highlights": highlights("", 3)}))["card"].clone();
    assert_eq!(first["from"], Value::Null);
}

#[test]
fn each_version_posts_once_and_waits_for_its_notes() {
    let updated = highlights("1.0.0-nightly.100", 3);
    let step =
        call("app_feed_update_step", json!({"highlights": updated, "posted": "1.0.0-nightly.100"}));
    assert_eq!(step["step"], "post");
    assert_eq!(step["card"]["to"], "1.0.0-nightly.200");
    assert_eq!(
        call("app_feed_update_step", json!({"highlights": updated, "posted": "1.0.0-nightly.200"}))
            ["step"],
        "done"
    );
    assert_eq!(
        call("app_feed_update_step", json!({"highlights": highlights("1.0.0-nightly.100", 0)}))["step"],
        "wait"
    );
    assert_eq!(call("app_feed_update_step", json!({}))["step"], "wait");
}

#[test]
fn whats_new_off_posts_no_feed_card() {
    let updated = highlights("1.0.0-nightly.100", 3);
    let off = call(
        "app_feed_update_step",
        json!({"highlights": updated, "posted": "1.0.0-nightly.100", "enabled": false}),
    );
    assert_eq!(off, json!({"step": "skip", "version": "1.0.0-nightly.200"}));
    let done = call(
        "app_feed_update_step",
        json!({"highlights": updated, "posted": "1.0.0-nightly.200", "enabled": false}),
    );
    assert_eq!(done["step"], "done");
    let unknown = call(
        "app_feed_update_step",
        json!({"highlights": updated, "posted": "1.0.0-nightly.100", "enabled": null}),
    );
    assert_eq!(unknown["step"], "wait");
}

// The approve proof: a phone's software P-256 key signs, the Mac verifies.

const NOW: f64 = 1_800_000_000_000.0;

fn token(claims: &Value) -> String {
    format!("e30.{}.c2ln", URL_SAFE_NO_PAD.encode(claims.to_string()))
}

fn presence_keys(signing: &SigningKey, overrides: Value) -> Value {
    let point = signing.verifying_key().to_encoded_point(false);
    let mut entry = json!({"install": "inst_phone", "platform": "ios", "attested": true, "install_active": true,
        "revoked_at": null, "usable_from": NOW - 1000.0,
        "jwk": {"kty": "EC", "crv": "P-256", "x": URL_SAFE_NO_PAD.encode(point.x().unwrap()),
                "y": URL_SAFE_NO_PAD.encode(point.y().unwrap())}});
    for (key, value) in overrides.as_object().unwrap() {
        entry[key] = value.clone();
    }
    json!({"keys": [entry]})
}

fn context() -> Value {
    let token =
        token(&json!({"iss": "https://cmux-api/prod", "sub": "user_1", "inst": "inst_mac"}));
    let reply = call("app_feed_token", json!({"token": token}));
    assert_eq!(reply["install"], "inst_mac");
    reply["context"].clone()
}

fn signed(signing: &SigningKey, item: &str, shown: &str, ts: i64) -> String {
    let message = [
        "cmux-feed-approve-v1",
        "prod",
        "user_1",
        "inst_phone",
        "inst_mac",
        item,
        shown,
        "allow",
        "once",
        &ts.to_string(),
    ]
    .join("\n");
    let signature: Signature = signing.sign(message.as_bytes());
    URL_SAFE_NO_PAD.encode(signature.to_bytes())
}

fn posted_entry() -> (Value, Value) {
    let request = bash_request();
    let body = call(
        "app_feed_bridge_post_body",
        json!({"session": "sess-1", "permission": "perm-1", "request": request, "host": "inst_mac"}),
    );
    let entry = call(
        "app_feed_bridge_posted",
        json!({"session": "sess-1", "permission": "perm-1", "request": request, "body": body}),
    );
    let action = body["params"]["prompt"]["action"].clone();
    assert_eq!(entry["shown"], call("app_feed_shown_sha256", json!({"action": action}))["sha256"]);
    (request, entry)
}

fn answer(signing: &SigningKey, keys: Value, ts: i64, presence: bool) -> Value {
    let (request, entry) = posted_entry();
    let shown = entry["shown"].as_str().unwrap().to_owned();
    let item = json!({"kind": "approve", "answer": {"value": {"decision": "allow", "scope": "once",
        "proof": {"install": "inst_phone", "ts": ts, "sig": signed(signing, "fi_1", &shown, ts)}}}});
    let decision = call("app_feed_approve_decision", json!({"item": item}))["decision"].clone();
    let mut facts = json!({"item": "fi_1", "entry": entry, "decision": decision, "by": "inst_phone",
        "own_install": "inst_mac", "pending": request, "now_ms": NOW});
    if presence {
        facts["presence"] = json!({"context": context(), "keys": keys});
    }
    call("app_feed_bridge_answer", facts)
}

#[test]
fn a_signed_allow_reaches_the_agent() {
    let signing = SigningKey::from_slice(&[7; 32]).unwrap();
    let now = NOW as i64;
    assert_eq!(
        answer(&signing, presence_keys(&signing, json!({})), now, false)["step"],
        "needs_presence"
    );
    let step = answer(&signing, presence_keys(&signing, json!({})), now, true);
    assert_eq!(step["step"], "respond", "{step}");
    assert_eq!(step["params"]["optionId"], "allow");
    assert_eq!(
        step["params"]["_meta"]["acpmux"]["answeredBy"],
        json!({"device": "inst_phone", "feedItem": "fi_1"})
    );
}

#[test]
fn a_proof_that_does_not_hold_is_refused() {
    let signing = SigningKey::from_slice(&[7; 32]).unwrap();
    let other = SigningKey::from_slice(&[9; 32]).unwrap();
    let now = NOW as i64;
    let reason = |keys: Value, ts: i64| answer(&signing, keys, ts, true)["reason"].clone();
    assert_eq!(reason(presence_keys(&other, json!({})), now), json!({"proof": "bad_signature"}));
    assert_eq!(
        reason(presence_keys(&signing, json!({"platform": "macos"})), now),
        json!({"proof": "not_phone"})
    );
    assert_eq!(
        reason(presence_keys(&signing, json!({"attested": false})), now),
        json!({"proof": "not_attested"})
    );
    assert_eq!(
        reason(presence_keys(&signing, json!({"revoked_at": 1})), now),
        json!({"proof": "revoked"})
    );
    assert_eq!(
        reason(presence_keys(&signing, json!({"install_active": false})), now),
        json!({"proof": "revoked"})
    );
    assert_eq!(
        reason(presence_keys(&signing, json!({"usable_from": NOW + 1.0})), now),
        json!({"proof": "cooling_down"})
    );
    assert_eq!(
        reason(presence_keys(&signing, json!({})), now - 300_001),
        json!({"proof": "stale"})
    );
    assert_eq!(reason(presence_keys(&signing, json!({})), now + 60_001), json!({"proof": "stale"}));
    assert_eq!(reason(json!({"keys": []}), now), json!({"proof": "no_key"}));
}

#[test]
fn an_answer_to_a_changed_or_ended_prompt_is_refused() {
    let (request, entry) = posted_entry();
    let deny = json!({"outcome": "deny"});
    let facts = |pending: Value, by: &str| {
        json!({"item": "fi_1", "entry": entry, "decision": deny, "by": by,
        "own_install": "inst_mac", "pending": pending, "now_ms": NOW})
    };
    let respond = call("app_feed_bridge_answer", facts(request.clone(), "inst_phone"));
    assert_eq!(respond["params"]["optionId"], "reject");
    assert_eq!(
        call("app_feed_bridge_answer", facts(Value::Null, "inst_phone"))["reason"],
        "not_pending"
    );
    let mut changed = request.clone();
    changed["toolCall"]["rawInput"]["command"] = "rm -rf /".into();
    assert_eq!(call("app_feed_bridge_answer", facts(changed, "inst_phone"))["reason"], "changed");
    assert_eq!(
        call("app_feed_bridge_answer", facts(request.clone(), "inst_mac"))["reason"],
        "own_install"
    );
    assert_eq!(
        call("app_feed_bridge_answer", facts(request, "session:x"))["reason"],
        "session_answer"
    );
}

#[test]
fn an_allow_wider_than_once_is_refused() {
    let reply = call(
        "app_feed_bridge_option",
        json!({"decision": {"outcome": "allow", "scope": "always"}, "offered": options()}),
    );
    assert_eq!(reply["reason"], "scope");
    let reply = call(
        "app_feed_bridge_option",
        json!({"decision": {"outcome": "allow"}, "offered": options()}),
    );
    assert_eq!(reply["option"], "allow");
}

// The ops surface.

#[test]
fn unknown_ops_and_bad_requests_are_errors() {
    assert!(AppFeed::serves("app_feed_scrub"));
    assert!(!AppFeed::serves("tab_discard_plan"));
    assert_eq!(
        AppFeed::new().call("app_feed_nope", Value::Null),
        Err(OpError::UnknownOp("app_feed_nope".into()))
    );
    assert!(matches!(
        AppFeed::new().call("app_feed_scrub", json!({"text": 1})),
        Err(OpError::Invalid(_))
    ));
    assert!(matches!(
        AppFeed::new().call("app_feed_bridge_answer", Value::Null),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn control_request_plans_the_post_and_clamps_the_wait() {
    let plan = call(
        "app_feed_control_request",
        json!({"params": {"post": {"title": "t"}, "idempotency_key": "k", "wait_seconds": 999}}),
    );
    assert_eq!(plan["wait"], 120);
    assert_eq!(
        plan["body"],
        json!({"op": "feed.post", "params": {"title": "t"}, "idempotency_key": "k", "origin": "cli"})
    );
    let missing = call("app_feed_control_request", json!({"params": {"post": {}}}));
    assert_eq!(missing["error"]["code"], "invalid_params");
    let cancel = call("app_feed_control_cancel", json!({"params": {"item": "fi_1"}}));
    assert_eq!(cancel["body"]["idempotency_key"], "cancel:fi_1:poster");
    let result = call(
        "app_feed_control_result",
        json!({"read": {"value": {"item": {"state": "open"}}}, "wait": 5}),
    );
    assert_eq!(result["timed_out"], true);
    let signed_out = call("app_feed_owner_error", json!({"failure": "signed_out"}));
    assert_eq!(signed_out["error"]["code"], "feed.signed_out");
}

#[test]
fn github_actions_plan_their_effect() {
    let item = json!({"title": "T", "github_actions": ["open", "checkout", "comment"],
        "github": {"url": "https://github.com/a/b/pull/1", "number": 1, "branch": "feat", "repo": "a/b"}});
    let open = call("app_feed_github_plan", json!({"action": "open", "item": item}));
    assert_eq!(open, json!({"effect": "open_url", "url": "https://github.com/a/b/pull/1"}));
    let checkout =
        call("app_feed_github_plan", json!({"action": "checkout", "item": item, "root": "/r"}));
    assert_eq!(checkout["effect"], "type");
    assert!(checkout["command"].as_str().unwrap().contains("fetch origin pull/1/head:'feat'"));
    let blank =
        call("app_feed_github_plan", json!({"action": "comment", "item": item, "text": "  "}));
    assert_eq!(blank["effect"], "none");
    let not_offered = call("app_feed_github_plan", json!({"action": "approve", "item": item}));
    assert_eq!(not_offered["effect"], "none");
    let tab = call("app_feed_open_target", json!({"item": {"context": {"terminal": "t1"}}}));
    assert_eq!(
        tab,
        json!({"open": "tab", "reported": null, "terminal": "t1", "agent_session": null})
    );
}
