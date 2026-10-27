//! Only verified native UI can persist its non-secret update intent identities.
use super::*;

fn entry(key: &str) -> Value {
    json!({"key":key,"root_key":"original-root","machine":format!("machine_{}","1".repeat(32)),
        "session":format!("session_{}","2".repeat(32)),"cli":"claude","profiles":["work-profile"]})
}

fn envelope(mux: &Mux, command: &str) -> Value {
    json!({"id":1,"cmd":command,"expected_machine_id":mux.machine_public_id,
        "expected_session_id":mux.session_public_id})
}

#[test]
fn cmux_next_agent_cli_intent_wire_records_and_reads_without_contacting_an_updater() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("intent-wire");
    let caller = Caller::new(&mux, true);
    let mut write = envelope(&mux, "agent-cli-intents-record");
    write["intents"] = json!([entry("original-one"), entry("original-two")]);
    assert_eq!(caller.call(&mux, write.clone())["ok"], true);
    assert_eq!(caller.call(&mux, write)["data"]["changed"], false);
    let replacement = Caller::new(&mux, true);
    let listed = replacement.call(&mux, envelope(&mux, "agent-cli-intents-list"));
    assert_eq!(listed["ok"], true, "{listed}");
    assert_eq!(listed["data"]["intents"].as_array().unwrap().len(), 2);
    assert_eq!(listed["data"]["intents"][0]["root_key"], "original-root");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn cmux_next_agent_cli_intent_wire_denies_unproved_calls_owner_changes_and_actor_claims() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("intent-wire-denied");
    let denied = Caller::new(&mux, false);
    assert_code(
        &denied.call(&mux, json!({"id":1,"cmd":"agent-cli-intents-list"})),
        "agent_cli_intents.not_trusted",
    );
    let caller = Caller::new(&mux, true);
    for field in ["actor", "origin", "argv", "socket"] {
        let mut bad = envelope(&mux, "agent-cli-intents-list");
        bad[field] = json!("claim");
        assert_code(&caller.call(&mux, bad), "agent_cli_intents.bad_request");
    }
    let mut foreign = envelope(&mux, "agent-cli-intents-list");
    foreign["expected_session_id"] = json!(format!("session_{}", "b".repeat(32)));
    assert_code(&caller.call(&mux, foreign), "agent_cli_intents.owner_mismatch");
    let mut bad = envelope(&mux, "agent-cli-intents-record");
    let mut claimed = entry("original");
    claimed["argv"] = json!(["claim"]);
    bad["intents"] = json!([claimed]);
    assert_code(&caller.call(&mux, bad), "agent_cli_intents.bad_request");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
}

#[test]
fn cmux_next_agent_cli_intent_wire_settles_rows_so_they_stop_blocking() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("intent-wire-settle");
    let caller = Caller::new(&mux, true);
    let mut write = envelope(&mux, "agent-cli-intents-record");
    write["intents"] = json!([entry("refused-before-journal"), entry("still-running")]);
    assert_eq!(caller.call(&mux, write)["ok"], true);
    let mut settle = envelope(&mux, "agent-cli-intents-settle");
    settle["keys"] = json!(["refused-before-journal"]);
    let settled = caller.call(&mux, settle.clone());
    assert_eq!(settled["ok"], true, "{settled}");
    assert_eq!(settled["data"]["changed"], true);
    assert_eq!(settled["data"]["intents"].as_array().unwrap().len(), 1);
    assert_eq!(caller.call(&mux, settle)["data"]["changed"], false);
    let listed = caller.call(&mux, envelope(&mux, "agent-cli-intents-list"));
    assert_eq!(listed["data"]["intents"][0]["key"], "still-running");
    let mut bad = envelope(&mux, "agent-cli-intents-settle");
    bad["keys"] = json!([]);
    assert_code(&caller.call(&mux, bad), "agent_cli_intents.refused");
    let denied = Caller::new(&mux, false);
    let mut foreign = envelope(&mux, "agent-cli-intents-settle");
    foreign["keys"] = json!(["still-running"]);
    assert_code(&denied.call(&mux, foreign), "agent_cli_intents.not_trusted");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
}

/// The route answers every line as the sniffer did: one decode past the
/// head for a line it accepts or refuses, a `null` id answered as `null`,
/// a repeated member's last value, and a line with no `Value` left to the
/// `Command` parse.
#[test]
fn cmux_next_agent_cli_intent_wire_decodes_once_and_answers_as_the_sniffer_did() {
    let owner = Owner::new(json!(["harnessUpdatePrepare"]), prepared());
    let mux = owner.mux("intent-wire-typed");
    let caller = Caller::new(&mux, true);
    let list = envelope(&mux, "agent-cli-intents-list");
    let (listed, parses) = caller.call_counted(&mux, &list.to_string());
    assert_eq!(listed["ok"], true, "{listed}");
    assert_eq!(parses, 2, "the head and the route's decode");

    let mut unknown = list.clone();
    unknown["actor"] = json!("claim");
    let (refused, parses) = caller.call_counted(&mux, &unknown.to_string());
    assert_code(&refused, "agent_cli_intents.bad_request");
    assert_eq!(refused["id"], 1, "{refused}");
    assert_eq!(parses, 2, "a refusal takes its id from the same decode");

    let mut null_id = list.clone();
    null_id["id"] = Value::Null;
    let answered = caller.call(&mux, null_id);
    assert_eq!(answered.get("id"), Some(&Value::Null), "{answered}");
    let mut anonymous = list.clone();
    anonymous.as_object_mut().unwrap().remove("id");
    let anonymous = caller.call(&mux, anonymous);
    assert_eq!(anonymous["ok"], true, "{anonymous}");
    assert!(anonymous.get("id").is_none(), "{anonymous}");

    let repeated = format!(
        r#"{{"id":2,"cmd":"agent-cli-intents-list","expected_machine_id":"{}","expected_session_id":"session_{}","expected_session_id":"{}"}}"#,
        mux.machine_public_id,
        "b".repeat(32),
        mux.session_public_id,
    );
    let last_wins = caller.call_line(&mux, &repeated);
    assert_eq!(last_wins["ok"], true, "a repeated member keeps its last value: {last_wins}");
    assert_eq!(last_wins["id"], 2);

    // The route is found by the decoded `cmd`, never a substring of the
    // line, so an escaped name answers as its plain spelling.
    let escaped =
        list.to_string().replace("agent-cli-intents-list", r"agent-cli-intents\u002dlist");
    let routed = caller.call_line(&mux, &escaped);
    assert_eq!(routed["ok"], true, "{escaped}: {routed}");

    let generic = caller.call_line(&mux, r#"{"id":3,"cmd":"agent-cli-intents-list","x":1e999}"#);
    assert_eq!(generic["ok"], false, "{generic}");
    assert!(generic.get("error_code").is_none(), "the Command parse answers it: {generic}");

    let denied = Caller::new(&mux, false);
    let mut shapeless = list;
    shapeless["intents"] = json!("not a list");
    assert_code(&denied.call(&mux, shapeless), "agent_cli_intents.not_trusted");
    assert!(owner.connections.recv_timeout(Duration::from_millis(100)).is_err());
}
