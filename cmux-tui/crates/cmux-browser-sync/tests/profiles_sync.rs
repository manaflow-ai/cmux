//! Two devices sync their profile lists through an in-memory server that runs the same rule as cmux-platform's
//! `/v1/sync/browser/records` (last writer wins per id, every accepted write gets the next revision).

use std::sync::Mutex;

use cmux_browser_sync::records::{
    Change, Kind, LocalProfile, LocalView, PullResult, Record, SyncState, Transport, local_view,
    sync_once, wins,
};

#[derive(Default)]
struct FakeServer {
    rows: Mutex<(u64, Vec<(u64, Record)>)>,
}

impl Transport for FakeServer {
    async fn exchange(&self, since: u64, push: &[Record]) -> anyhow::Result<PullResult> {
        let mut guard = self.rows.lock().unwrap();
        let (rev, rows) = &mut *guard;
        for record in push {
            let at = rows.iter().position(|(_, row)| row.key() == record.key());
            match at {
                Some(i) if !wins(record, &rows[i].1) => {}
                Some(i) => {
                    *rev += 1;
                    rows[i] = (*rev, record.clone());
                }
                None => {
                    *rev += 1;
                    rows.push((*rev, record.clone()));
                }
            }
        }
        let records = rows.iter().filter(|(r, _)| *r > since).map(|(_, row)| row.clone()).collect();
        Ok(PullResult { cursor: *rev, records })
    }
}

struct Device {
    id: &'static str,
    profiles: Vec<LocalProfile>,
    state: SyncState,
}

impl Device {
    fn new(id: &'static str, profiles: Vec<LocalProfile>) -> Self {
        Self { id, profiles, state: SyncState::default() }
    }
    fn view(&self) -> LocalView {
        local_view(&self.profiles, &[])
    }
    fn apply(&mut self, changes: &[Change]) {
        for change in changes {
            match change {
                Change::Put { kind: Kind::Profile, id, value } => {
                    let record = Record {
                        kind: Kind::Profile,
                        id: id.clone(),
                        updated_at_ms: 0,
                        device: String::new(),
                        deleted: false,
                        value: Some(value.clone()),
                    };
                    let profile = LocalProfile::from_record(&record).unwrap();
                    match self.profiles.iter_mut().find(|p| p.id == *id) {
                        Some(existing) => *existing = profile,
                        None => self.profiles.push(profile),
                    }
                }
                Change::Delete { kind: Kind::Profile, id } => self.profiles.retain(|p| p.id != *id),
                _ => {}
            }
        }
    }
    async fn sync(&mut self, server: &FakeServer, now: u64) -> usize {
        let round = sync_once(server, &self.view(), &mut self.state, self.id, now).await.unwrap();
        self.apply(&round.changes);
        round.pushed
    }
    fn names(&self) -> Vec<(String, String)> {
        let mut names: Vec<_> =
            self.profiles.iter().map(|p| (p.id.clone(), p.name.clone())).collect();
        names.sort();
        names
    }
}

fn profile(id: &str, name: &str) -> LocalProfile {
    LocalProfile { id: id.into(), name: name.into(), color: Some("#ff0000".into()), icon: None }
}

#[tokio::test]
async fn two_devices_converge_with_last_writer_wins_and_tombstones() {
    let server = FakeServer::default();
    let mut a =
        Device::new("mac-a", vec![profile("default", "Default"), profile("p-work", "Work")]);
    let mut b = Device::new("mac-b", vec![profile("default", "Default")]);

    a.sync(&server, 10).await;
    b.sync(&server, 11).await;
    assert_eq!(b.names(), a.names(), "b gains Work");

    // Both rename Work; the later write wins on both.
    a.profiles.iter_mut().find(|p| p.id == "p-work").unwrap().name = "Job".into();
    b.profiles.iter_mut().find(|p| p.id == "p-work").unwrap().name = "Office".into();
    a.sync(&server, 20).await;
    b.sync(&server, 25).await;
    a.sync(&server, 26).await;
    assert_eq!(a.names(), b.names());
    assert!(a.names().contains(&("p-work".into(), "Office".into())));

    // A deletes Work; b, which still holds it, does not bring it back.
    a.profiles.retain(|p| p.id != "p-work");
    a.sync(&server, 30).await;
    b.sync(&server, 31).await;
    a.sync(&server, 32).await;
    assert_eq!(a.names(), vec![("default".into(), "Default".into())]);
    assert_eq!(b.names(), a.names());

    // Nothing changed: a quiet round pushes nothing.
    assert_eq!(a.sync(&server, 40).await, 0);
    assert_eq!(b.sync(&server, 41).await, 0);
}

#[tokio::test]
async fn an_older_write_loses_and_is_overwritten_locally() {
    let server = FakeServer::default();
    let mut a = Device::new("mac-a", vec![profile("p", "New")]);
    let mut b = Device::new("mac-b", vec![profile("p", "Old")]);
    a.sync(&server, 100).await;
    // b's clock is behind: its write loses, and b takes a's value.
    b.sync(&server, 50).await;
    assert_eq!(b.names(), vec![("p".into(), "New".into())]);
}

#[tokio::test]
async fn equal_stamps_break_ties_by_device_on_every_replica() {
    let server = FakeServer::default();
    let mut a = Device::new("mac-a", vec![profile("p", "From A")]);
    let mut b = Device::new("mac-b", vec![profile("p", "From B")]);
    a.sync(&server, 7).await;
    b.sync(&server, 7).await;
    a.sync(&server, 8).await;
    assert_eq!(a.names(), vec![("p".into(), "From B".into())]);
    assert_eq!(b.names(), a.names());
}

#[test]
fn state_round_trips_through_json() {
    let mut state = SyncState { cursor: 3, ..Default::default() };
    let record = Record {
        kind: Kind::Binding,
        id: "space:s1".into(),
        updated_at_ms: 1,
        device: "d".into(),
        deleted: false,
        value: Some(serde_json::json!({"profile": "p"})),
    };
    state.known.insert(record.key(), record);
    let text = serde_json::to_string(&state).unwrap();
    assert_eq!(serde_json::from_str::<SyncState>(&text).unwrap(), state);
}

#[test]
fn validate_refuses_bad_records() {
    use cmux_browser_sync::records::validate;
    let mut record = Record {
        kind: Kind::Profile,
        id: "p".into(),
        updated_at_ms: 1,
        device: "d".into(),
        deleted: false,
        value: Some(serde_json::json!({"name": ""})),
    };
    assert!(validate(&record).is_err());
    record.value = Some(serde_json::json!({"name": "Work", "color": 3}));
    assert!(validate(&record).is_err());
    record.value = Some(serde_json::json!({"name": "Work", "color": null}));
    assert!(validate(&record).is_ok());
    record.kind = Kind::Binding;
    assert!(validate(&record).is_err());
    record.id = "space:s1".into();
    record.value = Some(serde_json::json!({"profile": "p"}));
    assert!(validate(&record).is_ok());
    record.deleted = true;
    assert!(validate(&record).is_err());
    record.value = None;
    assert!(validate(&record).is_ok());
}
