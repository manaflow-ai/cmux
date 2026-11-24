//! The keys relay's rules: an ask carries only a key's scope, the minting machine's CLI words come
//! from that scope alone, and a reply carries the key and nothing else, so a bootstrap token the
//! minting machine holds never crosses the link.

use super::*;

fn ask(extra: Value) -> Value {
    let mut ask = json!({"kind": "cloudflare-r2", "bucket": "cmux-ci-handoff", "access": "ro"});
    for (k, v) in extra.as_object().unwrap() {
        ask[k] = v.clone();
    }
    ask
}

#[test]
fn an_ask_carries_only_a_keys_scope() {
    let parsed = parse(&ask(json!({"ttl": "30d", "machine": "leo-mac"}))).unwrap();
    assert_eq!(parsed.machine.as_deref(), Some("leo-mac"));
    assert!(!parsed.write);
    assert_eq!(parsed.ttl, "30d");
    for bad in [
        json!({"store": "gh-secret:a/b:X"}),
        json!({"argv": ["--store", "x"]}),
        json!({"origin": "remote"}),
        json!({"bucket": "-bad"}),
        json!({"bucket": "BAD"}),
        json!({"access": "admin"}),
        json!({"ttl": "1y"}),
        json!({"ttl": "--store"}),
        json!({"account": "nothex"}),
        json!({"kind": "cloudflare-admin"}),
        json!({"expire_objects_days": 0}),
        json!({"machine": "a\nb"}),
    ] {
        assert!(parse(&ask(bad.clone())).is_err(), "{bad}");
    }
}

#[test]
fn the_next_hop_gets_the_scope_and_no_machine() {
    let parsed = parse(&ask(json!({"machine": "leo-mac", "create_bucket": true}))).unwrap();
    let onward = parsed.onward();
    assert!(onward.get("machine").is_none());
    let again = parse(&onward).unwrap();
    assert_eq!(again, MintAsk { machine: None, ..parsed });
}

#[test]
fn the_minting_cli_replies_to_the_asking_machine_and_stores_nothing_of_its_own() {
    let parsed = parse(&ask(json!({"ttl": "12h", "expire_objects_days": 1}))).unwrap();
    let argv = parsed.argv("gcp-agent-lane-2");
    assert_eq!(
        argv,
        [
            "--json",
            "keys",
            "mint",
            "cloudflare-r2",
            "--bucket",
            "cmux-ci-handoff",
            "--ro",
            "--ttl",
            "12h",
            "--expire-objects-days",
            "1",
            "--reply-to-machine",
            "gcp-agent-lane-2"
        ]
    );
    assert!(!argv.iter().any(|w| w == "--store"));
}

#[test]
fn a_reply_carries_the_key_and_never_anything_else_the_cli_printed() {
    // Whatever else the minting CLI's answer held (a bucket note, or a field a later version adds),
    // only the listed key fields and the two values go back.
    let answer = json!({
        "minted": {"id": "key-id", "bucket": "cmux-ci-handoff", "access": "ro",
                   "expires_at": "2027-01-01T00:00:00Z", "stores": ["machine:lane"],
                   "bootstrap": "BOOTSTRAP-TOKEN-VALUE", "by": "machine=lane"},
        "values": {"ACCESS_KEY_ID": "key-id", "SECRET_ACCESS_KEY": "abc123",
                   "BOOTSTRAP": "BOOTSTRAP-TOKEN-VALUE"},
        "bucket": {"bucket": "cmux-ci-handoff", "token": "BOOTSTRAP-TOKEN-VALUE"},
        "provider_token": "BOOTSTRAP-TOKEN-VALUE",
    });
    let reply = reply(&answer).unwrap();
    let text = reply.to_string();
    assert!(!text.contains("BOOTSTRAP-TOKEN-VALUE"), "{text}");
    assert_eq!(reply["values"]["SECRET_ACCESS_KEY"], "abc123");
    assert_eq!(reply["minted"]["id"], "key-id");
    assert!(reply["minted"].get("stores").is_none());
    // An answer without a whole key is no reply.
    assert!(
        super::reply(&json!({"minted": {"id": "x"}, "values": {"ACCESS_KEY_ID": "x"}})).is_none()
    );
    assert!(super::reply(&json!({"values": {}})).is_none());
}
