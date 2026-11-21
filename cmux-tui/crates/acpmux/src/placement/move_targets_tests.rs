use super::*;

fn peer(name: &str, room: u64) -> Value {
    json!({"name": name, "url": format!("ssh://{name}"), "connected": true,
        "state": "connected", "health": {"cpus": 32, "load": [1, 1, 1],
            "ram": {"freeBytes": (room * 4 + 8) * 1_000_000_000},
            "disk": {"freeBytes": 500_000_000_000u64}, "liveSessions": 0,
            "pressure": {"ok": true}}})
}

fn registry(names: &[&str]) -> Value {
    let machines: serde_json::Map<String, Value> = names
        .iter()
        .map(|name| {
            (
                (*name).to_owned(),
                json!({"lanes": {"reserved_gb": 8, "per_lane_gb": 4,
            "free_gb_floor": 20, "disk_per_lane_gb": 5}}),
            )
        })
        .collect();
    json!({"machines": machines})
}

fn target<'a>(reply: &'a Value, id: &str) -> &'a Value {
    reply["targets"].as_array().unwrap().iter().find(|t| t["id"] == id).unwrap()
}

#[test]
fn move_targets_auto_first_room_from_placement_and_source_excluded() {
    let rows = [peer("zeta", 5), peer("source", 10), peer("alpha", 2)];
    let reg = registry(&["zeta", "source", "alpha"]);
    let reply = targets(&rows, Some("SOURCE.local"), None, Some(&reg));
    let ids: Vec<&str> =
        reply["targets"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["auto", "alpha", "zeta"]);
    assert_eq!(reply["pick"], "zeta");
    assert_eq!(target(&reply, "auto")["status"], "zeta · room for 5");
    assert_eq!(target(&reply, "zeta")["status"], "room for 5");
    let candidates: Vec<Candidate> = rows.iter().filter_map(Candidate::peer).collect();
    let placement = super::super::place(&candidates, Some(&reg), Work::Agent);
    let measured =
        placement["hosts"].as_array().unwrap().iter().find(|h| h["name"] == "zeta").unwrap();
    assert_eq!(target(&reply, "zeta")["room"], measured["room"]);
}

#[test]
fn move_targets_only_connected_peers_and_unsupported_transports_are_explained() {
    let mut offline = peer("offline", 8);
    offline["connected"] = json!(false);
    let mut reconnecting = peer("reconnecting", 8);
    reconnecting["state"] = json!("reconnecting");
    let mut remote = peer("relay", 8);
    remote["url"] = json!("wss://relay.example/peer");
    let mut degraded = peer("slow", 3);
    degraded["state"] = json!("degraded");
    let reply = targets(&[offline, reconnecting, remote, degraded], None, None, None);
    let ids: Vec<&str> =
        reply["targets"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["auto", "relay", "slow"]);
    assert_eq!(target(&reply, "relay")["kind"], "remote");
    assert_eq!(
        target(&reply, "relay")["reason"],
        "Moving to this machine requires an SSH connection"
    );
    assert_eq!(reply["pick"], "slow");
}

#[test]
fn move_targets_busy_and_interactive_are_named_choices_but_holds_are_not() {
    let mut reg = registry(&["busy", "desk", "held"]);
    reg["machines"]["desk"]["interactive"] = json!(true);
    reg["machines"]["held"]["hold"] = json!("maintenance");
    let reply =
        targets(&[peer("busy", 0), peer("desk", 8), peer("held", 12)], None, None, Some(&reg));
    assert_eq!(reply["pick"], "busy", "Auto leaves interactive and held hosts out");
    assert_eq!(target(&reply, "busy")["status"], "busy");
    assert!(target(&reply, "busy")["reason"].is_null());
    assert!(target(&reply, "desk")["reason"].is_null());
    assert!(target(&reply, "held")["reason"].as_str().unwrap().contains("maintenance"));
}

#[test]
fn move_targets_unknown_health_stays_unknown_and_empty_auto_explains_the_next_step() {
    let unknown = json!({"name": "unknown", "url": "ssh://unknown", "connected": true});
    let reply = targets(&[unknown.clone(), unknown], None, None, None);
    assert_eq!(reply["targets"].as_array().unwrap().len(), 2, "a peer appears only once");
    assert_eq!(target(&reply, "unknown")["status"], "room unknown");
    assert!(target(&reply, "unknown")["room"].is_null());
    assert_eq!(reply["pick"], "unknown");
    let empty = targets(&[], None, None, None);
    assert_eq!(empty["targets"].as_array().unwrap().len(), 1);
    assert!(empty["pick"].is_null());
    assert_eq!(
        target(&empty, "auto")["reason"],
        "Connect an SSH machine to move this chat automatically"
    );
}

#[test]
fn move_targets_auto_uses_session_moves_ranking_instead_of_new_chat_tiers() {
    let mut reg = registry(&["preferred", "roomy"]);
    reg["lane_place"] = json!({"placement_preference": ["preferred", "roomy"]});
    let rows = [peer("preferred", 2), peer("roomy", 6)];
    let reply = targets(&rows, None, None, Some(&reg));
    let candidates: Vec<Candidate> = rows.iter().filter_map(Candidate::peer).collect();
    let placement = super::super::place(&candidates, Some(&reg), Work::Agent);
    assert_eq!(placement["pick"], "preferred", "new-chat placement follows tiers");
    let hosts = placement["hosts"].as_array().unwrap();
    let (order, _) = ranked(hosts, &HashMap::new(), |_| None);
    assert_eq!(reply["pick"], order.first().unwrap().as_str());
    assert_eq!(reply["pick"], "roomy");
}

#[test]
fn move_targets_source_and_duplicates_resolve_registry_aliases() {
    let mut reg = registry(&["source", "target"]);
    reg["machines"]["source"]["aliases"] = json!(["source-ssh"]);
    reg["machines"]["target"]["aliases"] = json!(["target-ssh"]);
    let rows = [peer("source-ssh", 10), peer("target", 5), peer("target-ssh", 5)];
    let reply = targets(&rows, Some("SOURCE.local"), None, Some(&reg));
    assert_eq!(reply["targets"].as_array().unwrap().len(), 2);
    assert_eq!(reply["pick"], "target");
    let reply = targets(&rows, Some("SOURCE-SSH.local"), None, Some(&reg));
    assert_eq!(reply["targets"].as_array().unwrap().len(), 2);
    assert_eq!(reply["pick"], "target");
}

#[test]
fn move_targets_cloud_source_explains_why_added_machines_require_a_local_move_first() {
    let rows = [peer("target", 5)];
    let reg = registry(&["target"]);
    let legacy = targets(&rows, Some("cloud-machine"), None, Some(&reg));
    assert_eq!(legacy["pick"], "target", "omitting sourceKind remains compatible");
    for kind in ["local", "ssh"] {
        assert_eq!(targets(&rows, Some("cloud-machine"), Some(kind), Some(&reg)), legacy);
    }
    let reply = targets(&rows, Some("cloud-machine"), Some("cloud"), Some(&reg));
    assert_eq!(reply["targets"].as_array().unwrap().len(), 2, "Auto and peers remain visible");
    assert!(reply["pick"].is_null());
    assert!(target(&reply, "auto")["machine"].is_null());
    for row in reply["targets"].as_array().unwrap() {
        assert_eq!(row["reason"], "Move this chat to This Mac first");
    }
    assert_eq!(target(&reply, "auto")["status"], "Move this chat to This Mac first");
    assert_eq!(target(&reply, "target")["status"], target(&legacy, "target")["status"]);
    assert_eq!(target(&reply, "target")["room"], target(&legacy, "target")["room"]);
}
