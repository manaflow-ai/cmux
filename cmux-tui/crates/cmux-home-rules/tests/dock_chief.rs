//! Parity with HomeChiefTabKey, HomeChiefActionPlanTests, ChiefMoveTargetsTests, ChiefMovePlanTests,
//! ChiefMoveTargetHomeTests and HomeChiefDirectMessagesTests, through the `dock.*` op table.

use cmux_home_rules::call;
use serde_json::{Value, json};

fn op(name: &str, request: &Value) -> Value {
    call(&format!("dock.{name}"), request).unwrap_or_else(|err| panic!("dock.{name}: {err}"))
}

fn key_step(pending: Option<&str>, event: Value) -> Value {
    op("chief_tab_key_step", &json!({"state": {"pending": pending}, "event": event}))
}

#[test]
fn an_open_chief_tab_sends_nothing_and_settles() {
    let step = key_step(Some("k1"), json!({"type": "begin", "chiefTabOpen": true, "fresh": "k2"}));
    assert_eq!(
        step,
        json!({"state": {"pending": null}, "send": null, "fail": false, "created": false})
    );
}

#[test]
fn a_failed_create_retries_under_the_same_key() {
    let step = key_step(None, json!({"type": "begin", "chiefTabOpen": false, "fresh": "k1"}));
    assert_eq!(step["send"], json!("k1"));
    let failed = key_step(
        Some("k1"),
        json!({"type": "failed", "key": "k1", "code": "timeout", "fresh": "k2"}),
    );
    assert_eq!(
        failed,
        json!({"state": {"pending": "k1"}, "send": null, "fail": true, "created": false})
    );
    let again =
        key_step(Some("k1"), json!({"type": "begin", "chiefTabOpen": false, "fresh": "k3"}));
    assert_eq!(again["send"], json!("k1"), "the next connect replays the pending key");
}

#[test]
fn a_closed_key_retries_once_under_a_new_key() {
    let closed = json!({"type": "failed", "key": "k1", "code": "frontend_browser_key_closed", "fresh": "k2"});
    let step = key_step(Some("k1"), closed);
    assert_eq!(step["send"], json!("k2"));
    assert_eq!(step["state"]["pending"], json!("k2"));
    let retried = json!({"type": "failed", "key": "k2", "code": "frontend_browser_key_closed", "fresh": "k3", "retried": true});
    assert_eq!(key_step(Some("k2"), retried)["fail"], json!(true));
    let sent = key_step(Some("k2"), json!({"type": "sent", "key": "k2"}));
    assert_eq!(
        sent,
        json!({"state": {"pending": null}, "send": null, "fail": false, "created": true})
    );
}

#[test]
fn settling_an_old_key_keeps_a_newer_one() {
    let step = key_step(Some("k2"), json!({"type": "settleKey", "key": "k1"}));
    assert_eq!(step["state"]["pending"], json!("k2"));
    assert_eq!(key_step(Some("k2"), json!({"type": "settle"}))["state"]["pending"], Value::Null);
}

#[test]
fn a_moved_chief_tab_still_counts_as_open() {
    let tab = json!({"kind": "conversation", "conversation": "c1"});
    let workspaces =
        json!([{"screens": []}, {"screens": [{"panes": [{"handle": 3, "tabs": [tab]}]}]}]);
    assert_eq!(
        op("chief_tab_open", &json!({"chief": "c1", "workspaces": workspaces})),
        json!(true)
    );
    assert_eq!(
        op("chief_tab_open", &json!({"chief": "c2", "workspaces": workspaces})),
        json!(false)
    );
}

fn action_plan(front: Value, working: &[&str]) -> Value {
    let chiefs = json!([
        {"conversation": "conv_other", "isWorking": working.contains(&"conv_other"), "isDefault": false},
        {"conversation": "conv_default", "isWorking": working.contains(&"conv_default"), "isDefault": true},
    ]);
    op("chief_action_plan", &json!({"front": front, "chiefs": chiefs}))
}

#[test]
fn chief_action_plan_matches_swift() {
    let working = json!({"type": "chief", "isWorking": true});
    let idle = json!({"type": "chief", "isWorking": false});
    let none = json!({"type": "none"});
    assert_eq!(action_plan(working, &["conv_other"])["stop"], json!({"type": "front"}));
    assert_eq!(action_plan(idle.clone(), &["conv_other"])["stop"], json!({"type": "nothingRuns"}));
    assert_eq!(
        action_plan(none.clone(), &["conv_other"])["stop"],
        json!({"type": "chief", "conversation": "conv_other"})
    );
    assert_eq!(
        action_plan(none.clone(), &["conv_other", "conv_default"])["stop"],
        json!({"type": "chief", "conversation": "conv_default"})
    );
    assert_eq!(action_plan(none.clone(), &[])["stop"], json!({"type": "nothingRuns"}));
    let empty = op("chief_action_plan", &json!({"front": none, "chiefs": []}));
    assert_eq!(empty, json!({"stop": {"type": "nothingRuns"}, "settings": {"type": "noChief"}}));
    assert_eq!(action_plan(idle, &[])["settings"], json!({"type": "front"}));
    assert_eq!(
        action_plan(none.clone(), &[])["settings"],
        json!({"type": "open", "conversation": "conv_default"})
    );
    let only_other = op(
        "chief_action_plan",
        &json!({"front": none, "chiefs": [{"conversation": "conv_other", "isWorking": false, "isDefault": false}]}),
    );
    assert_eq!(only_other["settings"], json!({"type": "open", "conversation": "conv_other"}));
}

fn hosts() -> Value {
    let host = |id: &str, name: &str, kind: Value, online: bool, group: bool| json!({"machineID": id, "name": name, "kind": kind, "isOnline": online, "isRemoteGroup": group});
    json!([
        host(
            "ssh-mini",
            "cmux-mini",
            json!({"type": "ssh", "destination": "lawrence@cmux-mini"}),
            true,
            true
        ),
        host(
            "ssh-gcp",
            "gcp-linux-1",
            json!({"type": "ssh", "destination": "gcp-linux-1"}),
            false,
            true
        ),
        host("ssh-plain", "plain", json!({"type": "ssh", "destination": "plain"}), true, false),
        host("srv", "brain-box", json!({"type": "server", "destination": "brain-box"}), true, true),
        host(
            "srv-off",
            "brain-off",
            json!({"type": "server", "destination": "me@brain-off"}),
            false,
            true
        ),
        host("srv-noroute", "???", json!({"type": "server", "destination": null}), true, true),
        host("vm-1", "a cloud vm", json!({"type": "cloud", "staging": false}), true, true),
    ])
}

fn targets(local_home: &str, hosts: Value, cloud: Value) -> Vec<Value> {
    let listed =
        op("move_targets", &json!({"localHome": local_home, "hosts": hosts, "cloud": cloud}));
    serde_json::from_value(listed).expect("a list")
}

fn target(list: &[Value], id: &str) -> Value {
    list.iter().find(|target| target["machineID"] == id).cloned().unwrap_or(Value::Null)
}

#[test]
fn move_targets_match_swift() {
    let list = targets("/Users/me/.cmux/chief/default", hosts(), json!({"type": "signedIn"}));
    assert_eq!(list[0]["machineID"], json!("local"));
    assert_eq!(list[0]["to"], json!("local:/Users/me/.cmux/chief/default"));
    assert_eq!(list[0]["disabledReason"], Value::Null);
    assert_eq!(target(&list, "ssh-mini")["to"], json!("ssh:lawrence@cmux-mini"));
    assert_eq!(target(&list, "ssh-mini")["disabledReason"], Value::Null);
    assert_eq!(target(&list, "cloud")["to"], json!("cloud"));
    assert_eq!(target(&list, "vm-1"), Value::Null, "a Cloud VM is not where a Cloud Chief lives");
    assert_eq!(target(&list, "ssh-gcp")["disabledReason"], json!("offline"));
    assert_eq!(target(&list, "srv-off")["disabledReason"], json!("offline"));
    assert_eq!(target(&list, "srv-off")["to"], json!("ssh:me@brain-off"));
    assert_eq!(target(&list, "srv")["to"], json!("ssh:brain-box"));
    assert_eq!(target(&list, "srv")["disabledReason"], Value::Null);
    assert_eq!(target(&list, "srv-noroute")["to"], Value::Null);
    assert_eq!(target(&list, "srv-noroute")["disabledReason"], json!("noSSHRoute"));
    assert_eq!(target(&list, "ssh-plain"), Value::Null);
    let ids: Vec<&Value> = list.iter().map(|target| &target["machineID"]).collect();
    assert_eq!(ids, ["local", "ssh-mini", "ssh-gcp", "srv", "srv-off", "srv-noroute", "cloud"]);
}

#[test]
fn cloud_follows_the_apps_auth() {
    let staging = targets(
        "/h",
        json!([]),
        json!({"type": "signedIn", "api": "https://cloud-api-staging.cmux.dev"}),
    );
    assert_eq!(target(&staging, "cloud")["to"], json!("cloud:https://cloud-api-staging.cmux.dev"));
    let signed_out = targets("/h", json!([]), json!({"type": "signedOut"}));
    assert_eq!(target(&signed_out, "cloud")["disabledReason"], json!("signInNeeded"));
    let dev = targets(
        "/h",
        json!([]),
        json!({"type": "signedIn", "api": "https://cmux-api-development.debussy.workers.dev/"}),
    );
    let cloud = target(&dev, "cloud");
    assert_eq!(cloud["to"], json!("cloud:https://cmux-api-development.debussy.workers.dev"));
    assert_eq!(cloud["kind"], json!({"type": "cloud", "staging": true}));
}

fn plan(to: &str, kind: Value, source: &str, target_home: &str, token: Option<&str>) -> Value {
    op(
        "move_plan",
        &json!({"to": to, "kind": kind, "sourceHome": source, "targetHome": target_home, "tokenFile": token}),
    )
}

#[test]
fn move_plans_match_swift() {
    let src = "/Users/me/.cmux/chief/dev";
    for (to, kind, dest) in [
        ("ssh:cmux-mini", json!({"type": "ssh", "destination": "cmux-mini"}), "cmux-mini"),
        ("ssh:brain-box", json!({"type": "server", "destination": "brain-box"}), "brain-box"),
    ] {
        let plan = plan(to, kind, src, "~/.cmux/chief/default", None);
        assert_eq!(
            plan["dryRun"],
            json!(["chief", "move", "--to", to, "--dry-run", "--chief-home", src])
        );
        assert_eq!(plan["move"], json!(["chief", "move", "--to", to, "--chief-home", src]));
        assert_eq!(
            plan["reach"],
            json!({"type": "remote", "args": ["ssh", "-o", "BatchMode=yes", dest, "optchat-chief", "move", "reach", "--home", "~/.cmux/chief/default"]})
        );
    }
    let local = plan("local:/h/new", json!({"type": "local", "home": "/h/new"}), src, "~/x", None);
    assert_eq!(
        local["reach"],
        json!({"type": "cli", "args": ["chief", "move", "reach", "--chief-home", "/h/new"]})
    );
    let cloud = plan(
        "cloud:staging",
        json!({"type": "cloud", "staging": true}),
        src,
        "~/x",
        Some("/tmp/x/token"),
    );
    assert_eq!(
        cloud["dryRun"],
        json!([
            "chief",
            "move",
            "--to",
            "cloud:staging",
            "--dry-run",
            "--chief-home",
            src,
            "--session-token-file",
            "/tmp/x/token"
        ])
    );
    assert_eq!(
        cloud["move"],
        json!([
            "chief",
            "move",
            "--to",
            "cloud:staging",
            "--chief-home",
            src,
            "--session-token-file",
            "/tmp/x/token"
        ])
    );
    assert_eq!(cloud["reach"], json!({"type": "none"}), "a cloud Chief has no home to probe");
}

#[test]
fn rollback_and_target_home_match_swift() {
    assert_eq!(
        op("move_rollback", &json!({"sourceHome": "/h/tagged"})),
        json!(["chief", "move", "rollback", "--chief-home", "/h/tagged"])
    );
    assert_eq!(
        op("move_rollback", &json!({"sourceHome": "/h/tagged", "tokenFile": "/tmp/t/token"})),
        json!([
            "chief",
            "move",
            "rollback",
            "--chief-home",
            "/h/tagged",
            "--session-token-file",
            "/tmp/t/token"
        ])
    );
    let home =
        |home: &str, user: &str| op("move_target_home", &json!({"home": home, "userHome": user}));
    assert_eq!(home("/Users/me/.cmux/chief/default", "/Users/me"), json!("~/.cmux/chief/default"));
    assert_eq!(home("/Users/me/.cmux/chief/default", "/Users/me/"), json!("~/.cmux/chief/default"));
    assert_eq!(home("/opt/chief", "/Users/me"), json!("/opt/chief"));
}

fn listed() -> Value {
    json!({"chiefs": [
        {"id": "agent_mux", "display_name": "Chief"},
        {"id": "agent_scout01", "display_name": "Scout"},
        {"id": "agent_01M5KF414NPA3JJD601WWAE9SP", "display_name": "Codex Chief"},
    ]})
}

#[test]
fn a_chief_with_no_conversation_gets_its_direct_message() {
    let missing =
        op("chief_dm_missing", &json!({"all": listed(), "listed": ["agent_mux", "agent_scout01"]}));
    assert_eq!(missing, json!([{"id": "agent_01M5KF414NPA3JJD601WWAE9SP", "name": "Codex Chief"}]));
    let me = json!({"id": "user_local", "kind": "human", "display_name": "Me"});
    let request = op(
        "chief_dm_request",
        &json!({"me": me, "chief": "agent_01M5KF414NPA3JJD601WWAE9SP", "name": "Codex Chief"}),
    );
    assert_eq!(
        request,
        json!({
            "idempotency_key": "home-chief-dm-agent_01M5KF414NPA3JJD601WWAE9SP",
            "title": "Codex Chief",
            "participants": [me, {"id": "agent_01M5KF414NPA3JJD601WWAE9SP", "kind": "agent", "display_name": "Codex Chief", "agent_class": "mux"}],
        })
    );
    assert_eq!(
        op("chief_dm_key", &json!({"chief": "agent_scout01"})),
        json!("home-chief-dm-agent_scout01")
    );
}

#[test]
fn the_default_chief_is_never_opened_here() {
    let missing = op("chief_dm_missing", &json!({"all": listed()}));
    let ids: Vec<&Value> =
        missing.as_array().expect("list").iter().map(|record| &record["id"]).collect();
    assert_eq!(ids, ["agent_scout01", "agent_01M5KF414NPA3JJD601WWAE9SP"]);
}

#[test]
fn records_read_the_wrapped_reply_and_name_a_nameless_chief_by_id() {
    let wrapped = json!({"value": {"chiefs": [{"id": "a"}, {"id": ""}, {"display_name": "x"}, {"id": "b", "display_name": ""}]}});
    assert_eq!(
        op("chief_dm_records", &json!({"listed": wrapped})),
        json!([{"id": "a", "name": "a"}, {"id": "b", "name": "b"}])
    );
    assert_eq!(op("chief_dm_records", &json!({"listed": "nope"})), json!([]));
}
