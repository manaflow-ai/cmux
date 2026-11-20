//! A metadata change that also logs a line (`tags`, `renamed`, `rules`, `policy`, `mode`): the
//! line reaches the store before any metadata image that holds the change (R-DURABILITY S3b,
//! DESIGN.md 3.3e, E6). With the event journal, records survive a crash as a prefix in append
//! order, so the change is then never in the chat's metadata without its line in the log.

use super::*;
use crate::store::{MemoryStore, Store};

/// The store calls in order: `line:<kind>` or `save:<what the image holds>`.
type Calls = Arc<StdMutex<Vec<String>>>;

struct Recording {
    inner: MemoryStore,
    calls: Calls,
    /// What a `save` reports of its image.
    show: fn(&SessionMeta) -> String,
}

impl Store for Recording {
    fn list(&self) -> Result<Vec<SessionMeta>> {
        self.inner.list()
    }
    fn load(&self, id: &str) -> Result<Option<SessionMeta>> {
        self.inner.load(id)
    }
    fn save(&self, meta: &SessionMeta) -> Result<()> {
        let shown = (self.show)(meta);
        self.calls.lock().unwrap_or_else(|e| e.into_inner()).push(format!("save:{shown}"));
        self.inner.save(meta)
    }
    fn append(&self, id: &str, event: &EventRecord) -> Result<()> {
        self.calls.lock().unwrap_or_else(|e| e.into_inner()).push(format!("line:{}", event.kind));
        self.inner.append(id, event)
    }
    fn events(&self, id: &str, after: u64, limit: usize) -> Result<Vec<EventRecord>> {
        self.inner.events(id, after, limit)
    }
    fn delete(&self, id: &str) -> Result<()> {
        self.inner.delete(id)
    }
}

fn hub_with(show: fn(&SessionMeta) -> String) -> (Arc<Hub>, Arc<Session>, Calls) {
    let config = serde_json::from_value(json!({})).unwrap_or_else(|e| panic!("config: {e}"));
    let calls = Calls::default();
    let store = Recording { inner: MemoryStore::default(), calls: calls.clone(), show };
    let hub = Hub::new(config, Box::new(store));
    let meta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "order-test", "name": "before",
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"));
    let session = hub.insert_test_session(meta);
    (hub, session, calls)
}

/// The calls recorded so far; the record starts again empty.
fn take_calls(calls: &Calls) -> Vec<String> {
    std::mem::take(&mut *calls.lock().unwrap_or_else(|e| e.into_inner()))
}

/// Whether a `save` whose image holds the change (`holds`) comes before the change's `line`.
fn saved_before_its_line(calls: &[String], line: &str, holds: &str) -> bool {
    let saved = calls.iter().position(|call| call == holds);
    let logged = calls.iter().position(|call| call == line);
    match (saved, logged) {
        (Some(saved), Some(logged)) => saved < logged,
        (Some(_), None) => true,
        _ => false,
    }
}

#[tokio::test]
async fn a_tag_change_logs_its_line_before_its_metadata() {
    let (hub, session, calls) =
        hub_with(
            |meta| {
                if meta.tags.contains_key("stage") { "tagged".into() } else { "untagged".into() }
            },
        );
    take_calls(&calls);
    let _ = hub.set_tags_answered(&session, json!({"stage": "review"}).as_object(), &[], None);
    let calls = take_calls(&calls);
    assert!(calls.contains(&"line:tags".to_owned()), "no tags line: {calls:?}");
    assert!(
        !saved_before_its_line(&calls, "line:tags", "save:tagged"),
        "the tag was saved before its line (a crash between them keeps the tag without its line): {calls:?}"
    );
}

#[tokio::test]
async fn a_rules_change_logs_its_line_before_its_metadata() {
    let (hub, session, calls) =
        hub_with(
            |meta| {
                if meta.permission_rules.is_some() { "ruled".into() } else { "unruled".into() }
            },
        );
    take_calls(&calls);
    let _ = hub.set_rules_answered(&session, Some(json!([{"tool": "Bash", "decision": "allow"}])));
    let calls = take_calls(&calls);
    assert!(calls.contains(&"line:rules".to_owned()), "no rules line: {calls:?}");
    assert!(
        !saved_before_its_line(&calls, "line:rules", "save:ruled"),
        "the rules were saved before their line: {calls:?}"
    );
}

#[tokio::test]
async fn a_rename_logs_its_line_before_its_metadata() {
    let (hub, session, calls) = hub_with(|meta| meta.name.clone());
    take_calls(&calls);
    let _ = hub.rename(&session, "after".to_owned()).await;
    let calls = take_calls(&calls);
    assert!(calls.contains(&"line:renamed".to_owned()), "no renamed line: {calls:?}");
    assert!(
        !saved_before_its_line(&calls, "line:renamed", "save:after"),
        "the name was saved before its line: {calls:?}"
    );
}
