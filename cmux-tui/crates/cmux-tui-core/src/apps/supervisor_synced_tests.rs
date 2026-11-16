//! Synced app storage (`storage:synced`) through the supervisor: the
//! outbox sender, the stream's rows and `app.storage.changed`.

use std::sync::atomic::{AtomicU64, Ordering};

use super::super::storage::PendingOp;
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
    listed: Mutex<Vec<AppKvRow>>,
}

impl AppKvCloud for FakeCloud {
    fn account(&self) -> Option<String> {
        self.account.lock().unwrap().clone()
    }

    fn send(&self, op: &PendingOp) -> Result<Option<u64>, SendError> {
        if self.account().is_none() {
            return Err(SendError::Retry("signed out".into()));
        }
        self.sent.lock().unwrap().push(op.clone());
        Ok(Some(self.revision.fetch_add(1, Ordering::SeqCst) + 1))
    }

    fn subscribe(&self) {
        self.subscribes.fetch_add(1, Ordering::SeqCst);
    }

    fn resync(&self) {}

    /// `listed`, one row a page, read at head revision 9.
    fn list(&self, after: u64) -> Result<(Vec<AppKvRow>, Option<u64>, u64), SendError> {
        let listed = self.listed.lock().unwrap().clone();
        let page: Vec<AppKvRow> =
            listed.into_iter().filter(|r| r.revision > after).take(1).collect();
        let next = page.last().map(|r| r.revision);
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
fn uninstall_clears_the_synced_replica_and_its_queued_writes() {
    // A first-party app is only ever hidden; a local one can be removed.
    const LOCAL: &str = "local/todo";
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
    assert!(storage.as_ref().unwrap().pending(10).is_empty());
}

fn upserted(write: AppKvWrite) -> AppKvRow {
    match write {
        AppKvWrite::Upsert(row) => row,
        AppKvWrite::Delete { .. } => unreachable!(),
    }
}

/// A snapshot with only the owner's newest rows (its head counts more) pages
/// `appkv.list` before a row absent from it is removed.
#[test]
fn a_partial_snapshot_pages_the_list_before_removing_rows() {
    let (f, cloud) = synced_fixture();
    *cloud.account.lock().unwrap() = Some("user_1".into());
    let event =
        |writes| CloudEvent::AppKvChanged { seq: 1, writes, account: Some("user_1".into()) };
    f.supervisor.on_appkv_event(&event(vec![
        row(TODO, "old", json!(1), 1),
        row(TODO, "gone", json!(2), 2),
    ]));
    let newest = upserted(row(TODO, "new", json!(3), 8));
    *cloud.listed.lock().unwrap() = vec![upserted(row(TODO, "old", json!(1), 1)), newest.clone()];
    f.supervisor.on_appkv_event(&CloudEvent::AppKvReset {
        seq: 2,
        rows: Some(vec![newest]),
        revision: 9,
        complete: false,
        account: Some("user_1".into()),
    });
    // The part alone removes nothing.
    assert_eq!(
        f.call("t", "app.storage.get", json!({ "key": "gone" }), false)["body"]["value"],
        json!(2)
    );
    f.supervisor.appkv_wrote();
    until("the list to page", || {
        f.call("t", "app.storage.keys", json!({}), false)["body"]["value"] == json!(["new", "old"])
    });
}
