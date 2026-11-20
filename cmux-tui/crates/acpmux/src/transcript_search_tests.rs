use serde_json::json;

use super::*;

#[test]
fn params_read_the_wire_and_bound_the_limit_and_context() {
    let p = Params::from_value(&json!({
        "query": "four agent pages", "sessionId": "coord", "role": "assistant",
        "sinceMs": 5, "limit": 5000, "context": 99_999, "host": "all",
    }))
    .unwrap();
    assert_eq!(p.query, "four agent pages");
    assert_eq!(p.session.as_deref(), Some("coord"));
    assert_eq!(p.limit, MAX_LIMIT);
    assert_eq!(p.context, MAX_CONTEXT);
    assert_eq!(p.host.as_deref(), Some("all"));
    assert_eq!(Params::from_value(&p.to_value()).unwrap(), p);

    let bare = Params::from_value(&json!({"query": "x", "role": null, "host": ""})).unwrap();
    assert_eq!((bare.limit, bare.context, bare.host), (DEFAULT_LIMIT, DEFAULT_CONTEXT, None));
    assert!(Params::from_value(&json!({"query": "  "})).is_err());
    assert!(Params::from_value(&json!({"query": "x", "role": "system"})).is_err());
}

#[test]
fn merge_puts_every_hosts_hits_newest_first_up_to_the_limit() {
    let here = json!({"hits": [{"host": "a", "at": 30}, {"host": "a", "at": 10}],
        "files": 2, "caughtUpBytes": 100, "catchUpMs": 4, "queryMs": 2, "unreached": []});
    let peer = json!({"hits": [{"host": "b", "at": 20}, {"host": "b", "at": null}],
        "files": 3, "caughtUpBytes": 0, "catchUpMs": 9, "queryMs": 1, "unreached": []});
    let merged = merge(vec![here, peer], vec![json!({"host": "c", "error": "down"})], 3, 12);
    let order: Vec<_> =
        merged["hits"].as_array().unwrap().iter().map(|h| h["at"].clone()).collect();
    assert_eq!(order, [json!(30), json!(20), json!(10)]);
    assert_eq!(merged["files"], 5);
    assert_eq!(merged["caughtUpBytes"], 100);
    assert_eq!(merged["catchUpMs"], 9);
    assert_eq!(merged["tookMs"], 12);
    assert_eq!(merged["unreached"][0]["host"], "c");
}
