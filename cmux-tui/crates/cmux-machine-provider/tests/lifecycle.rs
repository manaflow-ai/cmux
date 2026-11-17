//! The contract's promises, against the fake provider and against the GCP
//! adapter over a scripted transport.

use cmux_machine_provider::gcp::request_id;
use cmux_machine_provider::{
    AccessToken, CreateSpec, FakeProvider, GcpProvider, IdempotencyKey, Ledger, MachineProvider,
    MachineState, Op, Outcome, ProviderError, Request, Transport, TransportError, labs,
};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::rc::Rc;

fn ledger_path(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-machine-provider-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir.join("ledger.jsonl")
}

fn spec() -> CreateSpec {
    CreateSpec {
        image: "projects/cmux-images/global/images/cmux-linux-2026-11-17".into(),
        machine_type: "e2-standard-4".into(),
        zone: "us-central1-a".into(),
        disk_gb: 50,
        idle_grace_minutes: 30,
        labels: BTreeMap::from([("team".into(), "cmux".into())]),
    }
}

fn key(k: &str) -> IdempotencyKey {
    IdempotencyKey::new(k).unwrap()
}

#[test]
fn the_whole_lifecycle_commits_once_and_replays() {
    let fake = FakeProvider::new();
    let path = ledger_path("lifecycle");
    let mut ledger = Ledger::open(&path).unwrap();
    let created = ledger.run(&fake, &key("c1"), &Request::create(spec())).unwrap();
    let machine = created.receipt().machine.clone();
    assert!(matches!(created, Outcome::Committed(_)));
    assert_eq!(fake.state(&machine), Some(MachineState::Running));
    for (k, op, want) in [
        ("s1", Op::Stop, MachineState::Stopped),
        ("s2", Op::Start, MachineState::Running),
        ("s3", Op::Snapshot, MachineState::Running),
        ("s4", Op::Delete, MachineState::Deleted),
    ] {
        let receipt = ledger.run(&fake, &key(k), &Request::on(op, &machine)).unwrap();
        assert_eq!(receipt.receipt().state, want, "{op:?}");
    }
    assert_eq!(fake.snapshots().len(), 1);
    assert_eq!(fake.state(&machine), None);
    let calls = fake.applied.get();
    // Reopen: every key replays from the file, no provider call.
    drop(ledger);
    let mut reopened = Ledger::open(&path).unwrap();
    let again = reopened.run(&fake, &key("c1"), &Request::create(spec())).unwrap();
    assert!(matches!(again, Outcome::Replayed(_)));
    assert_eq!(again.receipt(), created.receipt());
    assert_eq!(fake.applied.get(), calls);
    // Generations count the machine's committed ops.
    let deleted = reopened.run(&fake, &key("s4"), &Request::on(Op::Delete, &machine)).unwrap();
    assert_eq!(deleted.receipt().generation, 5);
}

#[test]
fn a_key_means_one_request() {
    let fake = FakeProvider::new();
    let mut ledger = Ledger::open(&ledger_path("conflict")).unwrap();
    ledger.run(&fake, &key("k"), &Request::create(spec())).unwrap();
    let mut other = spec();
    other.disk_gb = 100;
    let err = ledger.run(&fake, &key("k"), &Request::create(other)).unwrap_err();
    assert!(matches!(err, ProviderError::Conflict(_)), "{err}");
}

#[test]
fn a_lost_create_answer_settles_by_looking_not_by_creating_again() {
    let fake = FakeProvider::new();
    let path = ledger_path("lost-create");
    let mut ledger = Ledger::open(&path).unwrap();
    fake.lose_next_answer.set(true);
    let err = ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap_err();
    assert!(matches!(err, ProviderError::Indeterminate(_)));
    assert_eq!(ledger.pending().len(), 1, "the lost op is an orphan until settled");
    // A restart, then the same click.
    drop(ledger);
    let mut ledger = Ledger::open(&path).unwrap();
    assert_eq!(ledger.pending().len(), 1);
    let settled = ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap();
    assert!(matches!(settled, Outcome::Reconciled(_)));
    assert!(settled.receipt().reconciled);
    assert_eq!(fake.applied.get(), 1, "one machine, not two");
    assert!(ledger.pending().is_empty());
}

#[test]
fn a_lost_stop_that_did_not_happen_is_reissued() {
    let fake = FakeProvider::new();
    let mut ledger = Ledger::open(&ledger_path("lost-stop")).unwrap();
    let machine =
        ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap().receipt().machine.clone();
    // Simulate a pending stop that never reached the provider: write the
    // pending line by losing an answer on an op the fake then undoes.
    fake.lose_next_answer.set(true);
    let _ = ledger.run(&fake, &key("stop"), &Request::on(Op::Stop, &machine));
    ledger.run(&fake, &key("start-again"), &Request::on(Op::Start, &machine)).unwrap();
    // The stop key is still pending; the machine runs, so looking says "not
    // stopped" and the ledger reissues.
    let out = ledger.run(&fake, &key("stop"), &Request::on(Op::Stop, &machine)).unwrap();
    assert!(matches!(out, Outcome::Committed(_)));
    assert_eq!(fake.state(&machine), Some(MachineState::Stopped));
}

#[test]
fn a_definite_refusal_frees_the_key() {
    let fake = FakeProvider::new();
    let mut ledger = Ledger::open(&ledger_path("refused")).unwrap();
    fake.refuse_next.set(true);
    let err = ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap_err();
    assert!(matches!(err, ProviderError::Refused(_)));
    assert!(ledger.pending().is_empty());
    let ok = ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap();
    assert!(matches!(ok, Outcome::Committed(_)));
}

#[test]
fn a_torn_last_line_leaves_the_op_pending() {
    let fake = FakeProvider::new();
    let path = ledger_path("torn");
    let mut ledger = Ledger::open(&path).unwrap();
    fake.lose_next_answer.set(true);
    let _ = ledger.run(&fake, &key("c"), &Request::create(spec()));
    drop(ledger);
    let mut bytes = std::fs::read(&path).unwrap();
    bytes.extend_from_slice(br#"{"phase":"done","fingerpr"#);
    std::fs::write(&path, bytes).unwrap();
    let ledger = Ledger::open(&path).unwrap();
    assert_eq!(ledger.pending().len(), 1);
}

#[test]
fn unpinned_images_and_reserved_labels_are_refused_before_any_call() {
    let fake = FakeProvider::new();
    let mut ledger = Ledger::open(&ledger_path("refuse-spec")).unwrap();
    let mut family = spec();
    family.image = "projects/cmux-images/global/images/family/cmux-linux".into();
    let mut reserved = spec();
    reserved.labels.insert("cmux-key".into(), "x".into());
    for bad in [family, reserved] {
        assert!(matches!(
            ledger.run(&fake, &key("bad"), &Request::create(bad)),
            Err(ProviderError::Refused(_))
        ));
    }
    assert_eq!(fake.applied.get(), 0);
}

#[test]
fn labs_is_off_unless_the_settings_file_turns_it_on() {
    assert!(!labs::enabled_in_text(""));
    assert!(!labs::enabled_in_text("{}"));
    assert!(!labs::enabled_in_text(r#"{"labs": {"gcpMachineProvider": "true"}}"#));
    assert!(!labs::enabled_in_text(r#"{"labs": {"gcpMachineProvider": true"#));
    assert!(labs::enabled_in_text("{\"labs\": {\"gcpMachineProvider\": true}, // on\n}"));
    assert!(labs::enabled_in_text(r#"{"labs.gcpMachineProvider": true}"#));
    assert!(!labs::enabled_in(&PathBuf::from("/nonexistent/cmux-next.json")));
}

type Answer = Result<(u16, Value), TransportError>;
/// Method, URL and body of one call.
type Call = (String, String, Option<Value>);

/// A scripted Compute Engine: answers in order, records each call.
#[derive(Clone, Default)]
struct Script {
    answers: Rc<RefCell<VecDeque<Answer>>>,
    calls: Rc<RefCell<Vec<Call>>>,
}

impl Script {
    fn answer(&self, status: u16, body: Value) -> &Self {
        self.answers.borrow_mut().push_back(Ok((status, body)));
        self
    }
    fn lose(&self) -> &Self {
        self.answers.borrow_mut().push_back(Err(TransportError::NoAnswer("timeout".into())));
        self
    }
}

impl Transport for Script {
    fn send(
        &self,
        method: &str,
        url: &str,
        token: &AccessToken,
        body: Option<&Value>,
    ) -> Result<(u16, Value), TransportError> {
        assert_eq!(format!("{token:?}"), "AccessToken(<redacted>)");
        self.calls.borrow_mut().push((method.into(), url.into(), body.cloned()));
        self.answers.borrow_mut().pop_front().expect("a scripted answer")
    }
}

fn on() -> labs::Enabled {
    labs::require_in_text(r#"{"labs": {"gcpMachineProvider": true}}"#).unwrap()
}

fn gcp(script: &Script) -> GcpProvider {
    GcpProvider::new(
        on(),
        "my-project",
        "us-central1-a",
        AccessToken::new(b"ya29.secret-token\n").unwrap(),
        Box::new(script.clone()),
    )
    .unwrap()
}

#[test]
fn gcp_create_carries_a_stable_request_id_and_no_public_address() {
    let script = Script::default();
    let provider = gcp(&script);
    script.answer(200, json!({"name": "operation-1"}));
    let mut ledger = Ledger::open(&ledger_path("gcp-create")).unwrap();
    let out = ledger.run(&provider, &key("c"), &Request::create(spec())).unwrap();
    assert_eq!(out.receipt().state, MachineState::Provisioning);
    assert_eq!(out.receipt().provider, "gcp");
    let calls = script.calls.borrow();
    let (method, url, body) = &calls[0];
    assert_eq!(method, "POST");
    let rid = request_id(&key("c"), Op::Create);
    assert_eq!(
        url,
        &format!(
            "https://compute.googleapis.com/compute/v1/projects/my-project/zones/us-central1-a/instances?requestId={rid}"
        )
    );
    let body = body.as_ref().unwrap();
    assert_eq!(body["name"], json!(out.receipt().machine));
    assert!(body["networkInterfaces"][0].get("accessConfigs").is_none());
    assert_eq!(body["serviceAccounts"], json!([]));
    assert_eq!(body["labels"]["team"], json!("cmux"));
    assert_eq!(body["labels"]["cmux-machine"], json!("true"));
    let text = body.to_string();
    assert!(!text.contains("secret-token"), "no credential in the request body");
    // The receipt and ledger name no credential either.
    let ledger_text = std::fs::read_to_string(ledger.path()).unwrap();
    assert!(!ledger_text.contains("secret-token"));
    // A UUID, version 4.
    assert_eq!(rid.len(), 36);
    assert_eq!(&rid[14..15], "4");
}

#[test]
fn gcp_create_after_a_timeout_finds_its_own_machine() {
    let script = Script::default();
    let provider = gcp(&script);
    let mut ledger = Ledger::open(&ledger_path("gcp-lost")).unwrap();
    script.lose();
    assert!(matches!(
        ledger.run(&provider, &key("c"), &Request::create(spec())),
        Err(ProviderError::Indeterminate(_))
    ));
    let machine = provider.machine_for(&key("c"));
    // Next run looks first (GET) and sees the machine: no second insert.
    script.answer(200, json!({"name": machine, "status": "RUNNING"}));
    let out = ledger.run(&provider, &key("c"), &Request::create(spec())).unwrap();
    assert!(matches!(out, Outcome::Reconciled(_)));
    assert_eq!(out.receipt().state, MachineState::Running);
    let calls = script.calls.borrow();
    assert_eq!(calls.len(), 2);
    assert_eq!(calls[1].0, "GET");
}

#[test]
fn gcp_create_conflict_is_ours_only_with_our_label() {
    let script = Script::default();
    let provider = gcp(&script);
    let machine = provider.machine_for(&key("c"));
    script.answer(409, json!({"error": {"message": "already exists"}}));
    script.answer(
        200,
        json!({"name": machine, "status": "RUNNING", "labels": {"cmux-key": "someone-else"}}),
    );
    let mut ledger = Ledger::open(&ledger_path("gcp-409")).unwrap();
    assert!(matches!(
        ledger.run(&provider, &key("c"), &Request::create(spec())),
        Err(ProviderError::Conflict(_))
    ));
}

#[test]
fn gcp_maps_status_codes() {
    let script = Script::default();
    let provider = gcp(&script);
    let mut ledger = Ledger::open(&ledger_path("gcp-codes")).unwrap();
    script
        .answer(403, json!({"error": {"message": "Required 'compute.instances.stop' permission"}}));
    let err = ledger.run(&provider, &key("a"), &Request::on(Op::Stop, "cmux-0123")).unwrap_err();
    assert!(matches!(err, ProviderError::Refused(ref m) if m.contains("compute.instances.stop")));
    script.answer(503, json!({}));
    let err = ledger.run(&provider, &key("b"), &Request::on(Op::Stop, "cmux-0123")).unwrap_err();
    assert!(matches!(err, ProviderError::Indeterminate(_)));
    script.answer(404, json!({}));
    let out = ledger.run(&provider, &key("d"), &Request::on(Op::Delete, "cmux-0123")).unwrap();
    assert_eq!(out.receipt().state, MachineState::Deleted, "deleting a gone machine is done");
}

#[test]
fn gcp_refuses_names_that_would_change_the_url() {
    let script = Script::default();
    let provider = gcp(&script);
    let mut ledger = Ledger::open(&ledger_path("gcp-names")).unwrap();
    for (i, bad) in ["../other", "Cmux", "cmux-1?x=y", ""].into_iter().enumerate() {
        assert!(matches!(
            ledger.run(&provider, &key(&format!("x{i}")), &Request::on(Op::Stop, bad)),
            Err(ProviderError::Refused(_))
        ));
    }
    assert!(script.calls.borrow().is_empty());
    let token = AccessToken::new(b"t").unwrap();
    assert!(GcpProvider::new(on(), "p/../q", "z", token, Box::new(script)).is_err());
    assert!(AccessToken::new(b"two words").is_err());
    assert!(AccessToken::new(b"line\nInjected: 1").is_err());
}

#[test]
fn gcp_snapshot_names_are_stable_per_key() {
    let script = Script::default();
    let provider = gcp(&script);
    let mut ledger = Ledger::open(&ledger_path("gcp-snap")).unwrap();
    let label = |k: &str| key(k).digest("label")[..32].to_owned();
    // 409 on a snapshot carrying our key's label: ours.
    script.answer(409, json!({"error": {"message": "already exists"}}));
    script.answer(200, json!({"labels": {"cmux-key": label("snap")}}));
    script.answer(200, json!({"status": "RUNNING"}));
    let out = ledger.run(&provider, &key("snap"), &Request::on(Op::Snapshot, "cmux-0123")).unwrap();
    let name = out.receipt().artifact.clone().unwrap();
    assert!(name.starts_with("cmux-snap-") && name.len() <= 63);
    {
        let calls = script.calls.borrow();
        assert!(calls[0].1.contains("/disks/cmux-0123/createSnapshot?requestId="));
        assert_eq!(calls[0].2.as_ref().unwrap()["name"], json!(name));
        assert!(calls[1].1.ends_with(&format!("/projects/my-project/global/snapshots/{name}")));
    }
    // 409 on someone else's snapshot of that name: a conflict.
    script.answer(409, json!({"error": {"message": "already exists"}}));
    script.answer(200, json!({"labels": {"cmux-key": "someone-else"}}));
    assert!(matches!(
        ledger.run(&provider, &key("snap2"), &Request::on(Op::Snapshot, "cmux-0123")),
        Err(ProviderError::Conflict(_))
    ));
}

#[test]
fn a_key_belongs_to_one_zone() {
    // A delete times out in one zone and is retried against another: the
    // ledger refuses, instead of finding nothing there and calling it done.
    let script = Script::default();
    let a = gcp(&script);
    let b = GcpProvider::new(
        on(),
        "my-project",
        "us-central1-b",
        AccessToken::new(b"t").unwrap(),
        Box::new(script.clone()),
    )
    .unwrap();
    let mut ledger = Ledger::open(&ledger_path("zones")).unwrap();
    script.lose();
    let delete = Request::on(Op::Delete, "cmux-0123");
    assert!(matches!(ledger.run(&a, &key("d"), &delete), Err(ProviderError::Indeterminate(_))));
    assert!(matches!(ledger.run(&b, &key("d"), &delete), Err(ProviderError::Conflict(_))));
    assert_eq!(script.calls.borrow().len(), 1, "nothing was asked of the other zone");
    // A create's spec names the provider's own zone.
    let mut elsewhere = spec();
    elsewhere.zone = "us-central1-b".into();
    assert!(matches!(
        ledger.run(&a, &key("c"), &Request::create(elsewhere)),
        Err(ProviderError::Refused(_))
    ));
}

#[test]
fn a_failed_operation_is_a_failure_even_without_waiting() {
    let script = Script::default();
    let provider = gcp(&script);
    let mut ledger = Ledger::open(&ledger_path("op-error")).unwrap();
    script.answer(
        200,
        json!({"name": "operation-1", "error": {"errors": [{"message": "QUOTA_EXCEEDED"}]}}),
    );
    let err = ledger.run(&provider, &key("c"), &Request::create(spec())).unwrap_err();
    assert!(matches!(err, ProviderError::Api { ref message, .. } if message == "QUOTA_EXCEEDED"));
}

#[test]
fn a_second_open_of_a_held_ledger_is_refused() {
    let path = ledger_path("locked");
    let held = Ledger::open(&path).unwrap();
    assert!(Ledger::open(&path).is_err());
    drop(held);
    assert!(Ledger::open(&path).is_ok());
}

#[test]
fn a_line_after_a_torn_tail_survives_the_next_open() {
    let fake = FakeProvider::new();
    let path = ledger_path("torn-then-append");
    drop(Ledger::open(&path).unwrap());
    // A crash mid-append, in the middle of a multi-byte character.
    std::fs::write(&path, &"{\"phase\":\"failed\",\"error\":\"caf\u{e9}".as_bytes()[..30]).unwrap();
    let mut ledger = Ledger::open(&path).unwrap();
    let made = ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap();
    drop(ledger);
    let mut ledger = Ledger::open(&path).unwrap();
    let again = ledger.run(&fake, &key("c"), &Request::create(spec())).unwrap();
    assert!(matches!(again, Outcome::Replayed(_)));
    assert_eq!(again.receipt(), made.receipt());
}

#[test]
fn labs_off_makes_no_provider() {
    assert!(labs::require_in_text("{}").is_err());
    assert!(labs::require_in_text(r#"{"labs": {"gcpMachineProvider": false}}"#).is_err());
}

#[test]
fn label_keys_start_with_a_lowercase_letter() {
    let fake = FakeProvider::new();
    let mut ledger = Ledger::open(&ledger_path("label-keys")).unwrap();
    for (i, bad) in ["1team", "_team", "-team"].into_iter().enumerate() {
        let mut s = spec();
        s.labels.insert(bad.into(), "x".into());
        assert!(matches!(
            ledger.run(&fake, &key(&format!("l{i}")), &Request::create(s)),
            Err(ProviderError::Refused(_))
        ));
    }
}
