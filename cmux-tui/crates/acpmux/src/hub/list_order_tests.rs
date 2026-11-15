use super::*;
use serde_json::json;

fn meta(id: &str, updated: u64) -> crate::store::SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
        "cwd": "/tmp", "status": "closed", "createdAt": 1, "updatedAt": updated
    }))
    .unwrap()
}

/// Every session sorted now, as a list of every chat sorts them: what the kept order must be.
fn sorted_now(hub: &Hub) -> Vec<String> {
    let mut rows: Vec<(u64, String)> = hub
        .session_handles()
        .iter()
        .map(|s| (s.read_meta(|m| m.updated_at), s.id.clone()))
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    rows.into_iter().map(|(_, id)| id).collect()
}

/// The ids of every page of `limit` rows, following each page's cursor.
fn paged(hub: &Hub, limit: u64) -> Vec<String> {
    let (mut ids, mut cursor) = (Vec::new(), Value::Null);
    loop {
        let params = json!({"limit": limit, "cursor": cursor});
        let (rows, next) = hub.session_page_rows(&params, false).unwrap();
        ids.extend(
            rows.iter().map(|r| super::super::session_pages::PageRow::session_id(r).to_owned()),
        );
        cursor = next.unwrap_or(Value::Null);
        if cursor.is_null() {
            return ids;
        }
    }
}

fn check(hub: &Hub, change: &str) {
    let want = sorted_now(hub);
    assert_eq!(hub.kept_order_for_test(), want, "the kept order after {change}");
    for limit in [1, 2, 5] {
        assert_eq!(paged(hub, limit), want, "pages of {limit} after {change}");
    }
}

#[tokio::test]
async fn the_kept_order_is_every_chat_sorted_after_every_kind_of_change() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    let mut sessions = Vec::new();
    for n in 0..6 {
        let meta = meta(&format!("s{n}"), 10 + n);
        hub.store.save(&meta).unwrap();
        sessions.push(hub.insert_test_session(meta));
    }
    let s = |n: usize| sessions.get(n).cloned().unwrap();
    let (s0, s1, s2, s3) = (&s(0), &s(1), &s(2), &s(3));
    check(&hub, "the first read");

    hub.append(s0, "mux", "status", json!({"status": "closed"}));
    check(&hub, "a record, which dates its chat");
    hub.set_composer_draft(s1, "a draft").unwrap();
    check(&hub, "a draft, which dates its chat with no record");
    hub.edit_test_meta(s2, |m| m.updated_at = 1);
    check(&hub, "a direct metadata write");
    // Two rows alike in `updatedAt`: ties by id.
    hub.edit_test_meta(s3, |m| m.updated_at = 1);
    check(&hub, "a tie");
    let late = meta("late", 5);
    hub.store.save(&late).unwrap();
    hub.insert_test_session(late);
    check(&hub, "a session that came");
    // Put in place and taken out with no list position: the count the order does not match
    // sorts every chat again.
    let quiet = hub.make_session(meta("quiet", 99));
    hub.sessions.lock().unwrap().insert("quiet".into(), quiet);
    check(&hub, "a session put in place with no position");
    hub.sessions.lock().unwrap().remove("s4");
    check(&hub, "a session taken out with no position");
    hub.edit_test_meta(s0, |m| m.updated_at = 1_000);
    hub.events.changed(None);
    check(&hub, "a barrier");
}

#[tokio::test]
async fn a_first_page_reads_its_window_not_every_chat() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    for n in 0..500 {
        let meta = meta(&format!("c{n:03}"), 10 + n);
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    // The first read sorts every chat once; a change after it places its own row again.
    let _ = hub.session_page_rows(&json!({"limit": 20}), false).unwrap();
    hub.edit_test_meta(&hub.session_by_id("c007").unwrap(), |m| m.updated_at = 9_999);
    let (own, all) = hub.own_rows_from(None, 20 + super::super::page_first::WINDOW_ROOM);
    assert!(!all, "a window of the order, not all of it");
    assert_eq!(own.len(), 20 + super::super::page_first::WINDOW_ROOM);
    assert_eq!(own.first().map(|(s, _)| s.id.as_str()), Some("c007"));
    let (rows, next) = hub.session_page_rows(&json!({"limit": 20}), false).unwrap();
    assert_eq!(rows.len(), 20);
    assert!(next.is_some_and(|next| next.is_string()));
}

/// Many sessions of one `updatedAt` (#42131 review, F1): a page's cursor row may lie past the
/// window a page first reads, and the pages still give every session once, in order.
#[tokio::test]
async fn pages_through_many_rows_of_one_updated_at_give_each_once() {
    let hub = Hub::new(Config::default(), Box::new(crate::store::MemoryStore::default()));
    for n in 0..200 {
        let meta = meta(&format!("t{n:03}"), 7);
        hub.store.save(&meta).unwrap();
        hub.insert_test_session(meta);
    }
    let ids = paged(&hub, 50);
    let want: Vec<String> = (0..200).map(|n| format!("t{n:03}")).collect();
    assert_eq!(ids, want, "every session once, ties by id");
}
