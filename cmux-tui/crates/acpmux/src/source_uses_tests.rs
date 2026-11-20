use super::*;
use crate::store::{EventRecord, LocalStore, MemoryStore, SessionMeta};

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({"schema":crate::store::META_SCHEMA, "id":id,"name":id,
        "harness":"claude","family":"claude","cwd":"/tmp","status":"idle",
        "createdAt":1,"updatedAt":1}))
    .unwrap()
}

fn event(seq: u64, sources: Value) -> EventRecord {
    EventRecord {
        seq,
        at: seq * 1000,
        dir: "mux".into(),
        kind: "turn_sources".into(),
        host_seq: None,
        msg: json!({"turnId":format!("turn-{seq}"), "replyId":format!("turn-{seq}.boot.1"), "sources":sources}),
    }
}

fn source(revision: &str) -> Value {
    json!({"uri":"file:///wiki/design.md","kind":"wiki","revision":revision,
        "title":"Design","toolCallId":format!("read-{revision}")})
}

fn query(cursor: Option<&str>, limit: usize) -> Query {
    Query::from_params(
        &json!({"sessionId":"a","uri":"file:///wiki/design.md","cursor":cursor,"limit":limit}),
    )
    .unwrap()
}

#[test]
fn source_uses_restart_and_mid_record_pagination_preserve_exact_edges() {
    let dir = tempfile::tempdir().unwrap();
    let store = LocalStore::new(dir.path().to_owned(), 64 * 1024).unwrap();
    store.save(&meta("a")).unwrap();
    store.save(&meta("b")).unwrap();
    store.append("a", &event(1, json!([source("v1")]))).unwrap();
    store.append("a", &event(2, json!([source("v2"), source("v3")]))).unwrap();
    store.append("b", &event(3, json!([source("private")]))).unwrap();
    // Raw reads, failed tools, answer text and replayed events are never reverse edges.
    let mut raw = event(3, json!([source("not-an-edge")]));
    raw.kind = "tool_call_update".into();
    store.append("a", &raw).unwrap();
    raw.seq = 4;
    raw.kind = "turn_sources.replay".into();
    store.append("a", &raw).unwrap();
    store.flush().unwrap();
    let first = read(&store, "a", &query(None, 1)).unwrap();
    assert_eq!(first["uses"][0]["revision"], "v2");
    assert_eq!(first["uses"][0]["replyId"], "turn-2.boot.1");
    let cursor = first["nextCursor"].as_str().unwrap().to_owned();
    drop(store);
    let reopened = LocalStore::new(dir.path().to_owned(), 64 * 1024).unwrap();
    // Newer records after the first page do not move its cursor or duplicate its results.
    reopened.append("a", &event(5, json!([source("v5")]))).unwrap();
    let second = read(&reopened, "a", &query(Some(&cursor), 1)).unwrap();
    assert_eq!(second["uses"][0]["revision"], "v3");
    let third = read(&reopened, "a", &query(second["nextCursor"].as_str(), 1)).unwrap();
    assert_eq!(third["uses"][0]["revision"], "v1");
    assert!(third["nextCursor"].is_null());
    assert!(
        read(&reopened, "b", &query(Some(&cursor), 1))
            .unwrap_err()
            .to_string()
            .contains("bad_cursor")
    );
    let filtered = Query::from_params(
        &json!({"sessionId":"a","uri":"file:///wiki/design.md","revision":"v3"}),
    )
    .unwrap();
    assert_eq!(read(&reopened, "a", &filtered).unwrap()["uses"].as_array().unwrap().len(), 1);
    let mut changed = query(Some(&cursor), 1);
    changed.revision = Some("v3".into());
    assert!(read(&reopened, "a", &changed).is_err());
}

#[test]
fn source_uses_no_match_scan_and_response_bytes_are_bounded() {
    let store = MemoryStore::default();
    store.save(&meta("a")).unwrap();
    store.append("a", &event(1, json!([source("v1")]))).unwrap();
    for seq in 2..=(SCAN_RECORDS as u64 + 2) {
        let mut noise = event(seq, json!([]));
        noise.kind = "turn_result".into();
        store.append("a", &noise).unwrap();
    }
    let first = read(&store, "a", &query(None, 100)).unwrap();
    assert_eq!(first["scanned"], SCAN_RECORDS);
    assert_eq!(first["uses"], json!([]));
    assert!(first["nextCursor"].is_string());
    let second = read(&store, "a", &query(first["nextCursor"].as_str(), 100)).unwrap();
    assert_eq!(second["uses"][0]["revision"], "v1");
    let uri = format!("https://example.test/{}", "x".repeat(4000));
    for seq in 600..700 {
        let mut value = source("v1");
        value["uri"] = json!(uri);
        store.append("a", &event(seq, json!([value]))).unwrap();
    }
    let q = Query::from_params(&json!({"sessionId":"a","uri":uri,"limit":100})).unwrap();
    let page = read(&store, "a", &q).unwrap();
    assert!(serde_json::to_vec(&page).unwrap().len() <= MAX_PAGE);
    assert!(page["nextCursor"].is_string());
    assert!(page["uses"].as_array().unwrap().len() < 100);
}

#[test]
fn source_uses_rejects_malformed_selectors_and_stale_mid_record_cursor() {
    for params in [
        json!({"uri":"x"}),
        json!({"sessionId":"a","uri":""}),
        json!({"sessionId":"a","uri":"x","limit":101}),
        json!({"sessionId":"a","uri":"x","revision":5}),
        json!({"sessionId":"a","uri":"x","cursor":"not-json"}),
    ] {
        assert!(Query::from_params(&params).is_err());
    }
    let store = MemoryStore::default();
    store.save(&meta("a")).unwrap();
    let mut q = query(None, 1);
    q.cursor = Some(Cursor {
        version: 1,
        session_id: "a".into(),
        selection: q.selection(),
        before_seq: 3,
        source_offset: 1,
    });
    assert!(read(&store, "a", &q).unwrap_err().to_string().contains("stale_cursor"));
}

async fn request(
    tx: &tokio::sync::mpsc::Sender<String>,
    rx: &mut tokio::sync::mpsc::Receiver<String>,
    id: u64,
    params: Value,
) -> Value {
    tx.send(
        crate::rpc::Message::request(id, crate::rpc::method::MUX_SOURCE_USES, params).to_line(),
    )
    .await
    .unwrap();
    loop {
        let line = tokio::time::timeout(std::time::Duration::from_secs(10), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let value: Value = serde_json::from_str(&line).unwrap();
        if value["id"] == id {
            return value;
        }
    }
}

#[tokio::test]
async fn source_uses_rpc_enforces_carrier_session_grants_and_authentication() {
    use crate::server::{ConnAuth, Origin, carrier, serve_connection_authed};
    let store = MemoryStore::default();
    for id in ["a", "b"] {
        store.save(&meta(id)).unwrap();
        store.append(id, &event(1, json!([source(id)]))).unwrap();
    }
    let hub = crate::hub::Hub::new(crate::config::Config::default(), Box::new(store));
    let (tx, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut rx) = tokio::sync::mpsc::channel(32);
    let who = carrier::Attested {
        role: carrier::Role::Team,
        sub: "user-one".into(),
        team: Some("team-one".into()),
        chats: vec!["a".into()],
        name: None,
    };
    let task = tokio::spawn(carrier::serve_attested(hub.clone(), inbound, out, who));
    let allowed =
        request(&tx, &mut rx, 1, json!({"sessionId":"a","uri":"file:///wiki/design.md"})).await;
    assert_eq!(allowed["result"]["uses"][0]["revision"], "a", "{allowed}");
    for (id, params) in [
        (2, json!({"sessionId":"b","uri":"file:///wiki/design.md"})),
        (3, json!({"session":"a","uri":"file:///wiki/design.md"})),
        (4, json!({"sessionId":"a","host":"elsewhere","uri":"file:///wiki/design.md"})),
    ] {
        let denied = request(&tx, &mut rx, id, params).await;
        assert_eq!(denied["error"]["data"]["reason"], "carrier.team_refused", "{denied}");
        assert!(denied.get("result").is_none());
    }
    drop(tx);
    task.abort();
    let (tx, inbound) = tokio::sync::mpsc::channel(8);
    let (out, mut rx) = tokio::sync::mpsc::channel(32);
    let task = tokio::spawn(serve_connection_authed(
        hub.clone(),
        inbound,
        out,
        Origin::Web,
        ConnAuth::None,
    ));
    let denied =
        request(&tx, &mut rx, 5, json!({"sessionId":"a","uri":"file:///wiki/design.md"})).await;
    assert!(denied.get("error").is_some(), "{denied}");
    assert!(denied.get("result").is_none());
    drop(tx);
    task.abort();
    hub.shutdown_all().await;
}
