//! `send_hop.rs`: which targets hop, the refusal's route, the probe's answer and the relay stamp.

use super::send_hop::{HOP_RELAY, hop_host, note_route, probe_refusal, stamp_relay};
use serde_json::{Value, json};

#[test]
fn only_a_host_neither_here_nor_peered_hops() {
    let peered = |h: &str| h == "cosmic-gray";
    assert_eq!(hop_host("air-blue/lead", "lane-vm", peered), Some("air-blue"));
    assert_eq!(hop_host("cosmic-gray/lead", "lane-vm", peered), None);
    assert_eq!(hop_host("LANE-VM/lead", "lane-vm", peered), None);
    assert_eq!(hop_host("lead", "lane-vm", peered), None);
    assert_eq!(hop_host("air-blue/", "lane-vm", peered), None);
}

#[test]
fn a_refusal_names_the_route_it_tried() {
    let mut text = "no session lead on air-blue; run `acpmux ls` for its sessions".to_owned();
    let mut data = json!({"reason": "no_session"});
    let tried = vec![
        json!({"peer": "cosmic-gray", "why": "peers the host, sendHop off"}),
        json!({"peer": "cmux16", "why": "probe timed out"}),
    ];
    note_route(&mut text, &mut data, &tried);
    assert!(
        text.ends_with(
            "; tried a hop via: cosmic-gray (peers the host, sendHop off), cmux16 (probe timed out)"
        ),
        "{text}"
    );
    assert_eq!(data["reason"], "no_session");
    assert_eq!(data["hop"]["tried"][1]["peer"], "cmux16");

    let (mut bare, mut data) = ("no session x on y".to_owned(), json!({}));
    note_route(&mut bare, &mut data, &[]);
    assert_eq!(bare, "no session x on y");
    assert!(data.get("hop").is_none());
}

#[test]
fn a_peer_carries_only_when_it_peers_the_host_and_takes_hops() {
    assert_eq!(probe_refusal(&json!({"peered": true, "relays": true, "connected": true})), None);
    // A link that is down still queues it there (the outbox retries).
    assert_eq!(probe_refusal(&json!({"peered": true, "relays": true, "connected": false})), None);
    assert_eq!(
        probe_refusal(&json!({"peered": true, "relays": false})),
        Some("peers the host, sendHop off")
    );
    assert_eq!(
        probe_refusal(&json!({"peered": false, "relays": true})),
        Some("does not peer the host")
    );
    // An older peer that knows no send_hop answers nothing of the kind.
    assert_eq!(probe_refusal(&json!({})), Some("does not peer the host"));
}

#[test]
fn a_hop_replaces_the_claimed_sender_with_the_relay_record() {
    let mut request = json!({
        "sessionId": "air-blue/lead",
        "prompt": [{"type": "text", "text": "hi"}],
        "_meta": {"acpmux": {"fromSessionId": "forged", "fromAgent": "leo", "promptId": "p1"}},
    });
    stamp_relay(&mut request, &json!({"machine": "lane-vm", "session": "fork-6"})).unwrap();
    let mux = &request["_meta"]["acpmux"];
    assert!(mux.get("fromSessionId").is_none());
    assert_eq!(
        mux["fromRelay"],
        json!({"by": HOP_RELAY, "machine": "lane-vm", "session": "fork-6"})
    );
    assert_eq!(mux["fromAgent"], "lane-vm/fork-6");
    assert_eq!(mux["promptId"], "p1");

    let mut bare = json!({"sessionId": "air-blue/lead"});
    stamp_relay(&mut bare, &json!({"machine": "lane-vm"})).unwrap();
    assert_eq!(bare["_meta"]["acpmux"]["fromAgent"], "lane-vm");

    let mut nameless: Value = json!({"sessionId": "air-blue/lead"});
    assert!(stamp_relay(&mut nameless, &json!({})).is_err());
}
