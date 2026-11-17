//! Synced app storage (`storage:synced`) through the supervisor: the
//! outbox sender, the stream's rows and `app.storage.changed`.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use super::super::storage::{PendingOp, SYNCED_SCOPE};
use super::super::supervisor::HostKey;
use super::super::synced::{AppKvCloud, STORAGE_CHANGED, SendError};
use super::*;
use crate::cloud_conversations::{AppKvRow, AppKvWrite, CloudEvent, Target};

const TODO: &str = "cmux/todo";
const DEMO: &str = "cmux/demo";
const SUB: u64 = 777;

/// The cloud as synced storage sees it: an account (or none) and the ops sent.
#[derive(Default)]
struct FakeCloud {
    account: Mutex<Option<String>>,
    sent: Mutex<Vec<PendingOp>>,
    revision: AtomicU64,
    subscribes: AtomicU64,
    unsubscribes: AtomicU64,
    resyncs: AtomicU64,
    listed: Mutex<Vec<AppKvRow>>,
    lists: AtomicU64,
    /// Sends fail as offline (the outbox stays queued).
    offline: AtomicBool,
    /// `appkv.list` does not answer.
    list_down: AtomicBool,
    /// `appkv.list` names its own cursor as the next page's.
    list_stuck: AtomicBool,
}

impl AppKvCloud for FakeCloud {
    fn account(&self) -> Option<String> {
        self.account.lock().unwrap().clone()
    }

    fn send(&self, op: &PendingOp) -> Result<Option<u64>, SendError> {
        if self.account().is_none() || self.offline.load(Ordering::SeqCst) {
            return Err(SendError::Retry("signed out".into()));
        }
        self.sent.lock().unwrap().push(op.clone());
        Ok(Some(self.revision.fetch_add(1, Ordering::SeqCst) + 1))
    }

    fn subscribe(&self) {
        self.subscribes.fetch_add(1, Ordering::SeqCst);
    }

    fn unsubscribe(&self) {
        self.unsubscribes.fetch_add(1, Ordering::SeqCst);
    }

    fn resync(&self) {
        self.resyncs.fetch_add(1, Ordering::SeqCst);
    }

    /// `listed`, one row a page, read at head revision 9.
    fn list(&self, after: u64) -> Result<(Vec<AppKvRow>, Option<u64>, u64), SendError> {
        if self.list_down.load(Ordering::SeqCst) {
            return Err(SendError::Retry("offline".into()));
        }
        self.lists.fetch_add(1, Ordering::SeqCst);
        let listed = self.listed.lock().unwrap().clone();
        let page: Vec<AppKvRow> =
            listed.into_iter().filter(|r| r.revision > after).take(1).collect();
        let next = if self.list_stuck.load(Ordering::SeqCst) {
            Some(after)
        } else {
            page.last().map(|r| r.revision)
        };
        Ok((page, next, 9))
    }
}

fn until(what: &str, done: impl Fn() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn row(app: &str, key: &str, value: Value, revision: u64) -> AppKvWrite {
    AppKvWrite::Upsert(AppKvRow {
        row_key: format!("{app}/{key}"),
        app: app.into(),
        key: key.into(),
        value,
        revision,
        updated_ms: 0,
    })
}

/// `cmux/todo` asks for `storage:synced`, `cmux/demo` for `storage:local`;
/// both run and are subscribed to `app.storage.changed`.
fn synced_fixture() -> (Fixture, Arc<FakeCloud>) {
    let root = temp_dir();
    write_app(&root.0.join("bundled"), "todo", TODO, json!({ "storage:synced": "Sync your list" }));
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install(TODO);
    f.install(DEMO);
    let cloud = Arc::new(FakeCloud::default());
    f.supervisor.set_appkv_cloud(cloud.clone());
    f.mount("t", TODO, "cmux.palette.scope/1", json!({}));
    f.mount("d", DEMO, "cmux.palette.scope/1", json!({}));
    {
        let mut inner = f.supervisor.inner.lock().unwrap();
        for app in [TODO, DEMO] {
            let key = HostKey { app: app.into(), preview: false };
            inner.hosts.get_mut(&key).unwrap().subs.insert(SUB, STORAGE_CHANGED.into());
        }
    }
    f.supervisor.logs(CLIENT, TODO, true);
    (f, cloud)
}

fn live(account: &str) -> CloudEvent {
    CloudEvent::SubscriptionState {
        target: Target::AppKv,
        state: "live",
        reason: None,
        account: Some(account.into()),
    }
}

#[test]
fn offline_synced_writes_serve_reads_and_flush_after_sign_in() {
    let (f, cloud) = synced_fixture();
    assert!(cloud.subscribes.load(Ordering::SeqCst) > 0, "a synced app subscribes the stream");
    let set =
        f.call("t", "app.storage.set", json!({ "key": "item:1", "value": { "t": "milk" } }), false);
    assert_eq!(set["ok"], true, "{set}");
    assert_eq!(
        f.call("t", "app.storage.get", json!({ "key": "item:1" }), false)["body"]["value"],
        json!({ "t": "milk" })
    );
    std::thread::sleep(Duration::from_millis(100));
    assert!(cloud.sent.lock().unwrap().is_empty(), "signed out: nothing leaves");
    *cloud.account.lock().unwrap() = Some("user_1".into());
    f.supervisor.on_appkv_event(&live("user_1"));
    until("the outbox to flush", || cloud.sent.lock().unwrap().len() == 1);
    let sent = cloud.sent.lock().unwrap()[0].clone();
    assert_eq!((sent.app.as_str(), sent.key.as_str()), (TODO, "item:1"));
    assert_eq!(sent.value, Some(json!({ "t": "milk" })));
}

#[test]
fn another_devices_rows_reach_only_the_synced_app_with_its_keys() {
    let (f, cloud) = synced_fixture();
    *cloud.account.lock().unwrap() = Some("user_1".into());
    // A local-only app's writes never queue for the cloud.
    assert_eq!(
        f.call("d", "app.storage.set", json!({ "key": "item:2", "value": "local" }), false)["ok"],
        true
    );
    f.supervisor.on_appkv_event(&CloudEvent::AppKvChanged {
        seq: 1,
        writes: vec![
            row(TODO, "item:2", json!({ "t": "eggs" }), 4),
            row(DEMO, "item:2", json!("remote"), 5),
        ],
        account: Some("user_1".into()),
    });
    let body = json!({ "keys": ["item:2"] });
    f.wait("app.storage.changed", |e| {
        e["event"] == "apps-log" && e["message"] == format!("event-body {SUB} {body}")
    });
    assert_eq!(
        f.call("t", "app.storage.get", json!({ "key": "item:2" }), false)["body"]["value"],
        json!({ "t": "eggs" })
    );
    // The local-only app keeps its own value and hears nothing.
    assert_eq!(
        f.call("d", "app.storage.get", json!({ "key": "item:2" }), false)["body"]["value"],
        json!("local")
    );
    let logs = f.supervisor.logs(CLIENT, DEMO, false);
    assert!(
        !logs["lines"].as_array().unwrap().iter().any(|line| line["message"]
            .as_str()
            .is_some_and(|m| m.starts_with(&format!("event-body {SUB}")))),
        "{logs}"
    );
    std::thread::sleep(Duration::from_millis(100));
    assert!(cloud.sent.lock().unwrap().is_empty(), "nothing local was queued");
}

#[test]
fn uninstall_clears_the_synced_replica_its_queued_writes_and_the_stream() {
    // A first-party app is only ever hidden; a local one can be removed
    // (`LOCAL`, below).
    let root = temp_dir();
    write_app(&root.0.join("state/apps/local"), "todo", LOCAL, json!({ "storage:synced": "s" }));
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install(LOCAL);
    f.set("grant-synced", LOCAL, Origin::User, |o| o.grant = Some(("storage:synced".into(), true)))
        .unwrap();
    let cloud = Arc::new(FakeCloud::default());
    f.supervisor.set_appkv_cloud(cloud.clone());
    f.mount("l", LOCAL, "cmux.palette.scope/1", json!({}));
    let set = f.call("l", "app.storage.set", json!({ "key": "k", "value": 1 }), false);
    assert_eq!(set["ok"], true, "{set}");
    assert!(f.supervisor.storage().as_ref().unwrap().has_replica(LOCAL));
    f.set("uninstall-todo", LOCAL, Origin::User, |o| o.installed = Some(false)).unwrap();
    *cloud.account.lock().unwrap() = Some("user_1".into());
    f.supervisor.on_appkv_event(&live("user_1"));
    std::thread::sleep(Duration::from_millis(200));
    assert!(cloud.sent.lock().unwrap().is_empty(), "an uninstalled app's write never goes");
    let storage = f.supervisor.storage();
    assert!(!storage.as_ref().unwrap().has_replica(LOCAL));
    assert!(storage.as_ref().unwrap().pending(10, |_| true).is_empty());
    assert_eq!(cloud.unsubscribes.load(Ordering::SeqCst), 1, "no app syncs: the stream goes");
}

fn upserted(write: AppKvWrite) -> AppKvRow {
    match write {
        AppKvWrite::Upsert(row) => row,
        AppKvWrite::Delete { .. } => unreachable!(),
    }
}

fn event(account: &str, writes: Vec<AppKvWrite>) -> CloudEvent {
    CloudEvent::AppKvChanged { seq: 1, writes, account: Some(account.into()) }
}

fn partial_reset(account: &str, rows: Vec<AppKvRow>) -> CloudEvent {
    CloudEvent::AppKvReset {
        seq: 2,
        rows: Some(rows),
        revision: 9,
        complete: false,
        account: Some(account.into()),
    }
}

fn get(f: &Fixture, host: &str, key: &str) -> Value {
    f.call(host, "app.storage.get", json!({ "key": key }), false)["body"]["value"].clone()
}

/// A snapshot with only the owner's newest rows (its head counts more) pages
/// `appkv.list` before a row absent from it is removed.
#[test]
fn a_partial_snapshot_pages_the_list_before_removing_rows() {
    let (f, cloud) = synced_fixture();
    *cloud.account.lock().unwrap() = Some("user_1".into());
    // The list does not answer until the part is checked: the sender would
    // page it as soon as the reset pokes it.
    cloud.list_down.store(true, Ordering::SeqCst);
    f.supervisor.on_appkv_event(&event(
        "user_1",
        vec![row(TODO, "old", json!(1), 1), row(TODO, "gone", json!(2), 2)],
    ));
    let newest = upserted(row(TODO, "new", json!(3), 8));
    *cloud.listed.lock().unwrap() = vec![upserted(row(TODO, "old", json!(1), 1)), newest.clone()];
    f.supervisor.on_appkv_event(&partial_reset("user_1", vec![newest]));
    // The part alone removes nothing.
    assert_eq!(get(&f, "t", "gone"), json!(2));
    cloud.list_down.store(false, Ordering::SeqCst);
    f.supervisor.appkv_wrote();
    until("the list to page", || {
        f.call("t", "app.storage.keys", json!({}), false)["body"]["value"] == json!(["new", "old"])
    });
}

/// A list whose pages stop before the last one (a cursor that does not
/// advance) is not the whole account: it removes nothing.
#[test]
fn a_list_that_never_reaches_its_last_page_removes_nothing() {
    let (f, cloud) = synced_fixture();
    *cloud.account.lock().unwrap() = Some("user_1".into());
    cloud.list_down.store(true, Ordering::SeqCst);
    f.supervisor.on_appkv_event(&event(
        "user_1",
        vec![row(TODO, "old", json!(1), 1), row(TODO, "gone", json!(2), 2)],
    ));
    *cloud.listed.lock().unwrap() = vec![upserted(row(TODO, "old", json!(1), 1))];
    cloud.list_stuck.store(true, Ordering::SeqCst);
    f.supervisor.on_appkv_event(&partial_reset("user_1", vec![]));
    cloud.list_down.store(false, Ordering::SeqCst);
    f.supervisor.appkv_wrote();
    until("the list to be read", || cloud.lists.load(Ordering::SeqCst) > 0);
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(get(&f, "t", "gone"), json!(2), "a list not read whole removed a row");
    assert_eq!(get(&f, "t", "old"), json!(1));
}

/// After an account switch, a late event of the previous account's socket
/// is ignored: it must not reset the replica and drop the new account's
/// queued writes.
#[test]
fn a_late_event_of_the_previous_account_keeps_the_new_accounts_writes() {
    let (f, cloud) = synced_fixture();
    *cloud.account.lock().unwrap() = Some("user_2".into());
    cloud.offline.store(true, Ordering::SeqCst);
    f.supervisor.on_appkv_event(&event("user_2", vec![row(TODO, "theirs", json!(1), 1)]));
    let set = f.call("t", "app.storage.set", json!({ "key": "mine", "value": 2 }), false);
    assert_eq!(set["ok"], true, "{set}");
    f.supervisor.on_appkv_event(&event("user_1", vec![row(TODO, "old", json!(3), 5)]));
    f.supervisor.on_appkv_event(&partial_reset("user_1", vec![]));
    assert_eq!(get(&f, "t", "mine"), json!(2), "the new account's write was dropped");
    assert_eq!(get(&f, "t", "theirs"), json!(1));
    assert_eq!(get(&f, "t", "old"), Value::Null, "the previous account's row applied");
    let storage = f.supervisor.storage();
    let storage = storage.as_ref().unwrap();
    assert_eq!(storage.account().as_deref(), Some("user_2"));
    assert_eq!(storage.pending(10, |_| true).len(), 1);
}

/// A sideloaded app granted `storage:synced`, its cloud link signed out.
const LOCAL: &str = "local/todo";

fn granted_local_fixture() -> (Fixture, Arc<FakeCloud>) {
    let root = temp_dir();
    write_app(&root.0.join("state/apps/local"), "todo", LOCAL, json!({ "storage:synced": "s" }));
    let f = fixture_with(&[], Duration::from_secs(60), root);
    f.install(LOCAL);
    grant_synced(&f, true);
    let cloud = Arc::new(FakeCloud::default());
    f.supervisor.set_appkv_cloud(cloud.clone());
    f.mount("l", LOCAL, "cmux.palette.scope/1", json!({}));
    (f, cloud)
}

fn grant_synced(f: &Fixture, on: bool) {
    f.set("grant-synced", LOCAL, Origin::User, |o| o.grant = Some((SYNCED_SCOPE.into(), on)))
        .unwrap();
}

/// A write queued while the app had `storage:synced` never uploads once the
/// scope is revoked; it is held, and goes only if the person grants it again.
#[test]
fn a_revoked_apps_queued_writes_never_upload() {
    let (f, cloud) = granted_local_fixture();
    let set = f.call("l", "app.storage.set", json!({ "key": "k", "value": 1 }), false);
    assert_eq!(set["ok"], true, "{set}");
    grant_synced(&f, false);
    *cloud.account.lock().unwrap() = Some("user_1".into());
    f.supervisor.on_appkv_event(&live("user_1"));
    f.supervisor.appkv_wrote();
    std::thread::sleep(Duration::from_millis(300));
    assert!(cloud.sent.lock().unwrap().is_empty(), "a revoked app's write went to the cloud");
    assert_eq!(f.supervisor.storage().as_ref().unwrap().pending(10, |_| true).len(), 1);
    grant_synced(&f, true);
    until("the regranted write to go", || cloud.sent.lock().unwrap().len() == 1);
}

/// A replica that missed the stream while its app was revoked reads a
/// snapshot when the scope is granted again.
#[test]
fn regranting_synced_storage_resyncs_the_replica() {
    let (f, cloud) = granted_local_fixture();
    let set = f.call("l", "app.storage.set", json!({ "key": "k", "value": 1 }), false);
    assert_eq!(set["ok"], true, "{set}");
    assert!(f.supervisor.storage().as_ref().unwrap().has_replica(LOCAL));
    grant_synced(&f, false);
    let before = cloud.resyncs.load(Ordering::SeqCst);
    grant_synced(&f, true);
    assert!(cloud.resyncs.load(Ordering::SeqCst) > before, "the regrant read no snapshot");
}
