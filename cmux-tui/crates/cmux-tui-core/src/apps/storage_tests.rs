use std::collections::BTreeMap;

use super::*;

#[test]
fn set_get_keys_delete_and_clear_are_per_app() {
    let s = Storage::open(None).unwrap();
    s.call("cmux/a", "app.storage.set", &json!({ "key": "k", "value": { "n": 1 } }), false)
        .unwrap();
    s.call("cmux/b", "app.storage.set", &json!({ "key": "k", "value": 2 }), false).unwrap();
    assert_eq!(
        s.call("cmux/a", "app.storage.get", &json!({ "key": "k" }), false).unwrap(),
        json!({ "n": 1 })
    );
    assert_eq!(s.call("cmux/a", "app.storage.keys", &json!({}), false).unwrap(), json!(["k"]));
    s.clear("cmux/a").unwrap();
    assert_eq!(
        s.call("cmux/a", "app.storage.get", &json!({ "key": "k" }), false).unwrap(),
        Value::Null
    );
    assert_eq!(
        s.call("cmux/b", "app.storage.get", &json!({ "key": "k" }), false).unwrap(),
        json!(2)
    );
    s.call("cmux/b", "app.storage.delete", &json!({ "key": "k" }), false).unwrap();
    assert_eq!(s.call("cmux/b", "app.storage.keys", &json!({}), false).unwrap(), json!([]));
}

#[test]
fn limits_are_enforced() {
    let s = Storage::open(None).unwrap();
    let big = "x".repeat(MAX_VALUE_BYTES);
    for synced in [false, true] {
        assert_eq!(
            s.call("a", "app.storage.set", &json!({ "key": "k", "value": big }), synced)
                .unwrap_err()
                .code,
            "app.limit"
        );
        assert_eq!(
            s.call("a", "app.storage.get", &json!({ "key": "" }), synced).unwrap_err().code,
            "validation.invalid"
        );
    }
    assert!(s.pending(10).is_empty(), "a refused write queues nothing");
}

/// The cloud's side as the wire contract states it: it orders writes, keeps
/// the last per (app, key), gives each a revision, and streams one row write
/// per op (a delete removes the row).
#[derive(Default)]
struct Cloud {
    rows: BTreeMap<(String, String), (Value, u64)>,
    revision: u64,
    log: Vec<AppKvWrite>,
    keys_seen: BTreeSet<String>,
}

fn row_key(app: &str, key: &str) -> String {
    format!("{app}\u{1f}{key}")
}

impl Cloud {
    /// `POST /v1/ops`: a key it decided before answers again, unchanged.
    fn send(&mut self, op: &PendingOp) -> u64 {
        if !self.keys_seen.insert(op.idempotency_key.clone()) {
            return self.revision;
        }
        self.revision += 1;
        let at = (op.app.clone(), op.key.clone());
        match &op.value {
            Some(value) => {
                self.rows.insert(at, (value.clone(), self.revision));
                self.log.push(AppKvWrite::Upsert(self.row(&op.app, &op.key)));
            }
            None => {
                self.rows.remove(&at);
                self.log.push(AppKvWrite::Delete { row_key: row_key(&op.app, &op.key) });
            }
        }
        self.revision
    }

    fn row(&self, app: &str, key: &str) -> AppKvRow {
        let (value, revision) = self.rows[&(app.to_string(), key.to_string())].clone();
        AppKvRow {
            row_key: row_key(app, key),
            app: app.into(),
            key: key.into(),
            value,
            revision,
            updated_ms: 0,
        }
    }

    fn snapshot(&self) -> Vec<AppKvRow> {
        self.rows.keys().map(|(app, key)| self.row(app, key)).collect()
    }
}

/// One device: its replica and how far it read the stream.
struct Device {
    storage: Storage,
    cursor: usize,
    heard: Changed,
}

const APP: &str = "cmux/todo";

fn synced(app: &str) -> bool {
    app == APP
}

impl Device {
    fn new() -> Self {
        Self { storage: Storage::open(None).unwrap(), cursor: 0, heard: Changed::new() }
    }

    fn set(&self, key: &str, value: Value) {
        self.storage
            .call(APP, "app.storage.set", &json!({ "key": key, "value": value }), true)
            .unwrap();
    }

    fn delete(&self, key: &str) {
        self.storage.call(APP, "app.storage.delete", &json!({ "key": key }), true).unwrap();
    }

    fn get(&self, key: &str) -> Value {
        self.storage.call(APP, "app.storage.get", &json!({ "key": key }), true).unwrap()
    }

    fn keys(&self) -> Value {
        self.storage.call(APP, "app.storage.keys", &json!({}), true).unwrap()
    }

    /// Sends the outbox; the HTTP answers come before the stream's events.
    fn flush(&mut self, cloud: &mut Cloud) {
        for op in self.storage.pending(100) {
            let revision = cloud.send(&op);
            let changed = self.storage.acked(&op, Some(revision));
            self.note(changed);
        }
    }

    fn read_stream(&mut self, cloud: &Cloud) {
        let changed = self.storage.apply_writes(&cloud.log[self.cursor..], synced).unwrap();
        self.cursor = cloud.log.len();
        self.note(changed);
    }

    fn note(&mut self, changed: Changed) {
        for (app, keys) in changed {
            self.heard.entry(app).or_default().extend(keys);
        }
    }

    fn dump(&self) -> BTreeMap<String, Value> {
        self.keys()
            .as_array()
            .unwrap()
            .iter()
            .map(|key| {
                let key = key.as_str().unwrap();
                (key.to_string(), self.get(key))
            })
            .collect()
    }
}

#[test]
fn two_replicas_over_a_fake_stream_converge() {
    let mut cloud = Cloud::default();
    let (mut mac, mut laptop) = (Device::new(), Device::new());
    mac.set("item:1", json!({ "t": "milk" }));
    laptop.set("item:2", json!({ "t": "eggs" }));
    // Both write the same key; the laptop's reaches the cloud last and wins.
    mac.set("shared", json!("mac"));
    laptop.set("shared", json!("laptop"));
    mac.flush(&mut cloud);
    laptop.flush(&mut cloud);
    mac.read_stream(&cloud);
    laptop.read_stream(&cloud);
    laptop.delete("item:1");
    laptop.flush(&mut cloud);
    mac.read_stream(&cloud);
    laptop.read_stream(&cloud);
    let expected: BTreeMap<String, Value> =
        cloud.rows.iter().map(|((_, key), (value, _))| (key.clone(), value.clone())).collect();
    assert_eq!(mac.dump(), expected);
    assert_eq!(laptop.dump(), expected);
    assert_eq!(expected.get("shared"), Some(&json!("laptop")));
    assert!(!expected.contains_key("item:1"));
    // The mac heard each key another device changed.
    let heard = mac.heard.get(APP).cloned().unwrap_or_default();
    assert!(heard.contains("item:2") && heard.contains("shared") && heard.contains("item:1"));
    assert!(mac.storage.pending(10).is_empty() && laptop.storage.pending(10).is_empty());
}

#[test]
fn offline_writes_serve_reads_and_flush_once_online() {
    let mut cloud = Cloud::default();
    let mut device = Device::new();
    device.set("a", json!(1));
    device.set("a", json!(2));
    device.set("b", json!(3));
    device.delete("b");
    // Offline: reads come from the replica, and only the newest write per key queues.
    assert_eq!(device.get("a"), json!(2));
    assert_eq!(device.keys(), json!(["a"]));
    let pending = device.storage.pending(10);
    assert_eq!(pending.len(), 2, "{pending:?}");
    assert_eq!(pending[0].value, Some(json!(2)));
    assert_eq!(pending[1].value, None);
    // Back online, the same keys go: a lost answer resends the same key and
    // the cloud decides it once.
    let lost = pending[0].clone();
    cloud.send(&lost);
    device.flush(&mut cloud);
    assert_eq!(cloud.revision, 2, "the resent key was decided once");
    assert!(device.storage.pending(10).is_empty());
    device.read_stream(&cloud);
    assert_eq!(device.dump(), BTreeMap::from([("a".to_string(), json!(2))]));
}

#[test]
fn a_stale_stream_row_does_not_undo_a_local_write() {
    let mut cloud = Cloud::default();
    let (mut mac, mut laptop) = (Device::new(), Device::new());
    laptop.set("k", json!("old"));
    laptop.flush(&mut cloud);
    // The mac writes before it heard the laptop's row: pending, it wins locally.
    mac.set("k", json!("new"));
    mac.read_stream(&cloud);
    assert_eq!(mac.get("k"), json!("new"), "a pending local write is not undone");
    assert!(mac.heard.is_empty());
    // Acked at a later revision; the old row and our own echo change nothing.
    mac.flush(&mut cloud);
    mac.read_stream(&cloud);
    assert_eq!(mac.get("k"), json!("new"));
    let stale = AppKvWrite::Upsert(AppKvRow {
        row_key: row_key(APP, "k"),
        app: APP.into(),
        key: "k".into(),
        value: json!("old"),
        revision: 1,
        updated_ms: 0,
    });
    assert!(mac.storage.apply_writes(&[stale], synced).unwrap().is_empty());
    assert_eq!(mac.get("k"), json!("new"));
    // A snapshot taken before our write landed does not undo it either.
    let mut before = cloud.snapshot();
    before[0].value = json!("old");
    before[0].revision = 1;
    assert!(mac.storage.apply_snapshot(&before, synced).unwrap().is_empty());
    assert_eq!(mac.get("k"), json!("new"));
}

#[test]
fn a_row_the_cloud_ordered_after_a_pending_write_applies_after_its_ack() {
    let mut cloud = Cloud::default();
    let (mut mac, mut laptop) = (Device::new(), Device::new());
    mac.set("k", json!("mac"));
    let mine = mac.storage.pending(1).remove(0);
    let revision = cloud.send(&mine);
    // The laptop's write lands after ours; the mac hears both before its ack.
    laptop.set("k", json!("laptop"));
    laptop.flush(&mut cloud);
    mac.read_stream(&cloud);
    assert_eq!(mac.get("k"), json!("mac"), "pending until the ack");
    let changed = mac.storage.acked(&mine, Some(revision));
    assert_eq!(changed.get(APP).map(|k| k.contains("k")), Some(true));
    assert_eq!(mac.get("k"), json!("laptop"));
    // A delete the cloud ordered after a pending write applies the same way.
    mac.set("d", json!(1));
    let mine = mac.storage.pending(1).remove(0);
    let revision = cloud.send(&mine);
    mac.read_stream(&cloud);
    laptop.read_stream(&cloud);
    laptop.delete("d");
    laptop.flush(&mut cloud);
    mac.set("d", json!(2));
    let newer = mac.storage.pending(1).remove(0);
    mac.read_stream(&cloud);
    assert_eq!(mac.get("d"), json!(2));
    assert!(mac.storage.acked(&mine, Some(revision)).is_empty(), "an older ack keeps it dirty");
    let revision = cloud.send(&newer);
    mac.storage.acked(&newer, Some(revision));
    mac.read_stream(&cloud);
    assert_eq!(mac.get("d"), json!(2), "our write came after the delete");
}

#[test]
fn a_snapshot_replaces_clean_rows_and_keeps_pending_ones() {
    let mut cloud = Cloud::default();
    let (mut mac, mut laptop) = (Device::new(), Device::new());
    laptop.set("a", json!(1));
    laptop.set("b", json!(2));
    laptop.flush(&mut cloud);
    mac.read_stream(&cloud);
    // Rows the mac never heard deleted (it missed the events) go with the snapshot.
    cloud.rows.remove(&(APP.to_string(), "a".to_string()));
    mac.set("mine", json!(true));
    let changed = mac.storage.apply_snapshot(&cloud.snapshot(), synced).unwrap();
    assert_eq!(changed[APP], BTreeSet::from(["a".to_string()]));
    assert_eq!(mac.keys(), json!(["b", "mine"]));
    // An app that does not sync here keeps nothing.
    let mut rows = cloud.snapshot();
    rows.push(AppKvRow { app: "cmux/other".into(), ..rows[0].clone() });
    assert!(mac.storage.apply_snapshot(&rows, synced).unwrap().is_empty());
    assert!(!mac.storage.has_replica("cmux/other"));
    assert_eq!(mac.keys(), json!(["b", "mine"]));
}

#[test]
fn a_refused_write_goes_back_to_the_clouds_value() {
    let mut cloud = Cloud::default();
    let (mut mac, mut laptop) = (Device::new(), Device::new());
    laptop.set("k", json!("cloud"));
    laptop.flush(&mut cloud);
    mac.set("k", json!("refused"));
    mac.read_stream(&cloud);
    let op = mac.storage.pending(1).remove(0);
    let changed = mac.storage.refused(&op);
    assert!(changed[APP].contains("k"));
    assert_eq!(mac.get("k"), json!("cloud"));
    assert!(mac.storage.pending(1).is_empty());
}

#[test]
fn local_only_apps_are_unaffected_by_sync() {
    let mut cloud = Cloud::default();
    let mut device = Device::new();
    // The same app id stored locally and synced: separate tables.
    device
        .storage
        .call(APP, "app.storage.set", &json!({ "key": "k", "value": "local" }), false)
        .unwrap();
    assert!(device.storage.pending(10).is_empty(), "a local write never queues");
    assert!(!device.storage.has_replica(APP));
    let mut laptop = Device::new();
    laptop.set("k", json!("synced"));
    laptop.flush(&mut cloud);
    // A stream row for an app that does not sync here changes nothing.
    let changed = device.storage.apply_writes(&cloud.log, |_| false).unwrap();
    assert!(changed.is_empty());
    assert_eq!(
        device.storage.call(APP, "app.storage.get", &json!({ "key": "k" }), false).unwrap(),
        json!("local")
    );
    // Uninstall clears both the local table and the replica.
    device.read_stream(&cloud);
    assert_eq!(device.get("k"), json!("synced"));
    device.storage.clear(APP).unwrap();
    assert_eq!(device.keys(), json!([]));
    assert!(device.storage.pending(10).is_empty());
}

#[test]
fn another_account_drops_the_previous_accounts_replica() {
    let device = Device::new();
    assert_eq!(device.storage.account(), None);
    device.set("k", json!(1));
    device.storage.set_account("user_a").unwrap();
    let changed = device.storage.reset_synced();
    assert!(changed[APP].contains("k"));
    assert_eq!(device.keys(), json!([]));
    assert!(device.storage.pending(10).is_empty(), "user_a's writes never go to user_b");
}
