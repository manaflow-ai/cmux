use super::*;

fn answer(json: serde_json::Value) -> CarrierAnswer {
    serde_json::from_value(json).unwrap()
}

#[test]
fn an_older_platform_names_one_relay_and_nothing_moves() {
    let old = answer(serde_json::json!({"relay": "relay+do://a", "slot": "s", "ticket": "t"}));
    let list = candidates(&old);
    assert_eq!(list, vec!["relay+do://a".to_owned()]);
    assert_eq!(next_home(&list, "relay+do://a"), None);
}

#[test]
fn a_newer_platform_names_the_others_in_order_each_once() {
    let new = answer(serde_json::json!({"relay": "relay+do://a", "slot": "s", "ticket": "t",
        "relays": ["relay+do://b", "relay+do://a", "", "relay+do://c"]}));
    let list = candidates(&new);
    assert_eq!(list, vec!["relay+do://a", "relay+do://b", "relay+do://c"]);
    assert_eq!(next_home(&list, "relay+do://a").as_deref(), Some("relay+do://b"));
    assert_eq!(next_home(&list, "relay+do://c").as_deref(), Some("relay+do://a"));
    // A relay the list no longer names moves the host to the second.
    assert_eq!(next_home(&list, "relay+do://gone").as_deref(), Some("relay+do://b"));
}

/// The answer as a carrier before this field reads it: the new field is ignored.
#[derive(serde::Deserialize)]
struct OldCarrierAnswer {
    relay: String,
    slot: String,
    #[allow(dead_code, reason = "read only to prove the old shape parses")]
    ticket: String,
}

#[test]
fn an_older_carrier_reads_a_newer_answer_and_stays_on_relay() {
    let old: OldCarrierAnswer = serde_json::from_value(serde_json::json!({
        "relay": "relay+do://a", "slot": "s", "ticket": "t", "relays": ["relay+do://b"],
    }))
    .unwrap();
    assert_eq!((old.relay.as_str(), old.slot.as_str()), ("relay+do://a", "s"));
}

#[test]
fn a_dial_tries_the_relay_that_last_carried_the_machine_first() {
    let homes = Homes::default();
    let list = vec!["a".to_owned(), "b".to_owned(), "c".to_owned()];
    assert_eq!(homes.order("m", list.clone()), list);
    homes.carried("m", "c");
    assert_eq!(homes.order("m", list.clone()), vec!["c", "a", "b"]);
    assert_eq!(homes.order("other", list.clone()), list);
    // A home the platform stopped naming is passed over.
    homes.carried("m", "z");
    assert_eq!(homes.order("m", list.clone()), list);
    homes.clear();
    assert_eq!(homes.of("m"), None);
}
