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
