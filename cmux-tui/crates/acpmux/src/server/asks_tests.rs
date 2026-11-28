//! The asks methods on a memory hub: search, get and link through the dispatcher's handler, and
//! what each refuses (RFD 0010 piece 5).

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::ask_ledger::Line;

fn memory_hub() -> Arc<Hub> {
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn capture(hub: &Hub, id: &str, text: &str) {
    let row = json!({"id": id, "sessionId": "s", "text": text});
    let line = Line::Event {
        ask: id.into(),
        sid: "s".into(),
        ts: 1,
        by: "leo@test".into(),
        kind: Kind::Captured { row },
    };
    assert!(hub.ask_ledger.record(line, None));
}

#[test]
fn an_agent_searches_reads_and_links_the_persons_asks() {
    let hub = memory_hub();
    capture(&hub, "ask-a", "Make the history tab faster");
    capture(&hub, "ask-b", "Ship the ask ledger");
    let found = handle(&hub, method::MUX_ASKS_SEARCH, &json!({"q": "HISTORY tab"}), "me").unwrap();
    assert_eq!(found["matched"], 1);
    assert_eq!(found["asks"][0]["id"], "ask-a");

    let linked = handle(
        &hub,
        method::MUX_ASKS_LINK,
        &json!({"id": "ask-b", "kind": "prOpened", "repo": "manaflow-ai/cmux", "number": 7}),
        "host/lane",
    )
    .unwrap();
    assert_eq!(linked["ask"]["status"], "inProgress");
    assert_eq!(linked["ask"]["events"][0]["by"], "host/lane");
    let picked =
        handle(&hub, method::MUX_ASKS_LINK, &json!({"id": "ask-a", "kind": "picked"}), "host/lane")
            .unwrap();
    assert_eq!(picked["ask"]["owner"], "host/lane");

    let open =
        handle(&hub, method::MUX_ASKS_SEARCH, &json!({"status": "inProgress"}), "me").unwrap();
    assert_eq!(open["matched"], 2);
    let got = handle(&hub, method::MUX_ASKS_GET, &json!({"id": "ask-b"}), "me").unwrap();
    assert_eq!(got["text"], "Ship the ask ledger");
    assert_eq!(got["events"][0]["number"], 7);
}

#[test]
fn a_link_never_captures_and_unknown_asks_or_statuses_are_refused() {
    let hub = memory_hub();
    capture(&hub, "ask-a", "t");
    for params in [
        json!({"id": "ask-a", "kind": "captured", "row": {"text": "forged"}}),
        json!({"id": "ask-a", "kind": "prOpened"}),
        json!({"id": "ask-zzz", "kind": "picked"}),
        json!({"kind": "picked"}),
    ] {
        assert!(handle(&hub, method::MUX_ASKS_LINK, &params, "me").is_err(), "{params}");
    }
    assert!(handle(&hub, method::MUX_ASKS_GET, &json!({"id": "ask-zzz"}), "me").is_err());
    assert!(handle(&hub, method::MUX_ASKS_SEARCH, &json!({"status": "done"}), "me").is_err());
    assert_eq!(hub.ask_ledger.page()["entries"][0]["events"], json!([]));
}
