//! Teleport in the local store (docs/automations-teleport-teams.md, section 2):
//! the new fields load from older stores, a fenced automation never fires, a
//! handoff resumes with the same id, a moved automation is a tombstone that
//! never fires and lists for 30 days, an import is idempotent by its handoff
//! id and its next fire follows `last_slot` and the catch-up policy.

use std::path::PathBuf;

use cmux_automations::{
    AutomationSpec, Body, CatchUp, Destination, Executor, ImportHandoff, ImportSpec, Job,
    LOCAL_HOME, RunState, Store, StoreError, Trigger, export_spec, parse_destination, start_manual,
    tick,
};
use serde_json::{Value, json};

const FRI_0900: i64 = 1_793_350_800;
const HOUR: i64 = 3_600;
const DAY: i64 = 86_400;

fn temp_root(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir()
        .join(format!("cmux-automations-teleport-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    dir
}

fn spec(name: &str, catch_up: CatchUp) -> AutomationSpec {
    AutomationSpec {
        name: name.into(),
        trigger: Trigger::Cron { expr: "0 9 * * *".into(), tz: "UTC".into() },
        body: Body::Prompt { prompt: "Summarize".into(), folder: None, model: None },
        catch_up,
        timeout_seconds: 60,
        enabled: true,
    }
}

#[derive(Default)]
struct Recorder {
    started: Vec<Job>,
}

impl Executor for Recorder {
    fn start(&mut self, job: &Job) -> Result<u32, String> {
        self.started.push(job.clone());
        Ok(4_000_000 + self.started.len() as u32)
    }
    fn is_alive(&self, _pid: u32) -> bool {
        false
    }
}

fn is_handoff_id(id: &str) -> bool {
    id.len() == 35
        && id.strip_prefix("tp_").is_some_and(|hex| {
            hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        })
}

#[test]
fn teleport_fields_default_when_an_older_store_loads() {
    let root = temp_root("old");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Old", CatchUp::default()), FRI_0900 - HOUR).unwrap();
    // An automation.json written before teleport: none of the new fields.
    let path = root.join(&a.id).join("automation.json");
    let mut v: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    for field in ["home", "epoch", "last_slot", "handoff"] {
        v.as_object_mut().unwrap().remove(field);
    }
    std::fs::write(&path, serde_json::to_vec(&v).unwrap()).unwrap();
    let loaded = store.get(&a.id).unwrap();
    assert_eq!(loaded.home, LOCAL_HOME);
    assert_eq!(loaded.epoch, 1);
    assert_eq!(loaded.last_slot, None);
    assert_eq!(loaded.handoff, None);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn teleport_create_sets_home_and_epoch_one_and_the_json_names_every_field() {
    let root = temp_root("create");
    let store = Store::open(&root).unwrap().with_home("mac:machine_test");
    let a = store.create(spec("New", CatchUp::default()), FRI_0900 - HOUR).unwrap();
    assert_eq!(a.home, "mac:machine_test");
    assert_eq!(a.epoch, 1);
    let v = serde_json::to_value(&a).unwrap();
    assert_eq!(v["home"], "mac:machine_test");
    assert_eq!(v["epoch"], 1);
    assert_eq!(v["last_slot"], Value::Null);
    assert_eq!(v["handoff"], Value::Null);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn teleport_a_fire_records_last_slot_in_milliseconds() {
    let root = temp_root("slot");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Slot", CatchUp::default()), FRI_0900 - HOUR).unwrap();
    let mut exec = Recorder::default();
    tick(&store, FRI_0900 + 30, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
    assert_eq!(store.get(&a.id).unwrap().last_slot, Some(FRI_0900 * 1000));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn teleport_a_fenced_automation_never_fires_and_the_fence_resumes_with_one_id() {
    let root = temp_root("fence");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Fenced", CatchUp::default()), FRI_0900 - HOUR).unwrap();
    let first = store.fence(&a.id, "cloud", (FRI_0900 - 60) * 1000).unwrap();
    assert!(is_handoff_id(&first.id), "{}", first.id);
    assert_eq!(first.to, "cloud");
    assert_eq!(first.epoch, 2);
    assert_eq!(first.at, (FRI_0900 - 60) * 1000);
    // Re-run: the same handoff, not a second one.
    let again = store.fence(&a.id, "cloud", FRI_0900 * 1000).unwrap();
    assert_eq!(again, first);
    // Another destination while one is pending is refused.
    assert!(matches!(store.fence(&a.id, "ssh:mini", FRI_0900 * 1000), Err(StoreError::Invalid(_))));

    let mut exec = Recorder::default();
    let report = tick(&store, FRI_0900 + 30, &mut exec).unwrap();
    assert!(report.started.is_empty());
    assert!(exec.started.is_empty());
    assert!(store.runs(&a.id).unwrap().is_empty(), "a fenced automation records no run");
    assert!(start_manual(&store, &a.id, "k", FRI_0900 + 40, &mut exec).is_err());
    assert_eq!(store.get(&a.id).unwrap().last_slot, None, "last_slot is frozen");

    // Abort: the fence goes and it fires again.
    let cleared = store.clear_fence(&a.id).unwrap();
    assert_eq!(cleared.handoff, None);
    assert_eq!(cleared.epoch, 1);
    tick(&store, FRI_0900 + DAY + 30, &mut exec).unwrap();
    assert_eq!(exec.started.len(), 1);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn teleport_release_leaves_a_tombstone_that_never_fires_and_lists_for_30_days() {
    let root = temp_root("release");
    let store = Store::open(&root).unwrap();
    let a = store.create(spec("Moving", CatchUp::default()), FRI_0900 - HOUR).unwrap();
    let h = store.fence(&a.id, "cloud", FRI_0900 * 1000).unwrap();
    // The wrong handoff id never releases.
    assert!(
        store.release(&a.id, "tp_00000000000000000000000000000000", "cloud", "auto_x", 0).is_err()
    );
    let moved_at = (FRI_0900 + 10) * 1000;
    let t = store.release(&a.id, &h.id, "cloud", "auto_cloudcloudcloudcloud", moved_at).unwrap();
    assert_eq!(t.id, a.id);
    assert_eq!(t.name, "Moving");
    assert_eq!(t.moved_to, "cloud");
    assert_eq!(t.moved_id, "auto_cloudcloudcloudcloud");
    assert_eq!(t.epoch, 2);
    assert_eq!(t.moved_at, moved_at);
    // Release again (a resumed teleport) answers the same tombstone.
    assert_eq!(
        store.release(&a.id, &h.id, "cloud", "auto_cloudcloudcloudcloud", moved_at + 5).unwrap(),
        t
    );
    assert_eq!(
        serde_json::to_value(&t).unwrap(),
        json!({"id": a.id, "name": "Moving", "moved_to": "cloud",
               "moved_id": "auto_cloudcloudcloudcloud", "epoch": 2, "moved_at": moved_at})
    );

    assert!(store.list().unwrap().is_empty(), "a tombstone is not an automation");
    assert!(store.find("Moving").is_err());
    assert_eq!(store.find_moved("moving").unwrap(), Some(t.clone()));
    assert_eq!(store.find_moved(&a.id).unwrap(), Some(t.clone()));
    let mut exec = Recorder::default();
    tick(&store, FRI_0900 + DAY + 30, &mut exec).unwrap();
    assert!(exec.started.is_empty(), "a tombstone never fires");

    assert_eq!(store.moved(moved_at + 29 * DAY * 1000).unwrap(), vec![t]);
    assert!(store.moved(moved_at + 31 * DAY * 1000).unwrap().is_empty(), "dropped after 30 days");
    let _ = std::fs::remove_dir_all(&root);
}

fn handoff(id: &str, epoch: u64, last_slot: Option<i64>) -> ImportHandoff {
    ImportHandoff {
        id: id.into(),
        from: "cloud".into(),
        source_id: "auto_sourcesourcesourceso".into(),
        epoch,
        last_slot,
    }
}

#[test]
fn teleport_import_is_idempotent_by_handoff_id_and_keeps_epoch_and_last_slot() {
    let root = temp_root("import");
    let store = Store::open(&root).unwrap().with_home("mac:machine_dest");
    let h = handoff("tp_0123456789abcdef0123456789abcdef", 3, Some((FRI_0900 - DAY) * 1000));
    let first = store.import(spec("Arrived", CatchUp::default()), &h, FRI_0900 - HOUR).unwrap();
    assert!(!first.replayed);
    assert_eq!(first.automation.home, "mac:machine_dest");
    assert_eq!(first.automation.epoch, 3);
    assert_eq!(first.automation.last_slot, Some((FRI_0900 - DAY) * 1000));
    assert_eq!(first.automation.handoff, None);
    let second = store.import(spec("Arrived", CatchUp::default()), &h, FRI_0900).unwrap();
    assert!(second.replayed);
    assert_eq!(second.automation.id, first.automation.id);
    assert_eq!(store.list().unwrap().len(), 1, "a retried import makes no second copy");
    let _ = std::fs::remove_dir_all(&root);
}

/// The source fired Thursday 09:00, the handoff took until Friday 09:30, so
/// Friday 09:00 fell inside it: the destination runs it once (latest, all) or
/// records it skipped (none), never twice.
#[test]
fn teleport_a_slot_inside_the_handoff_fires_once_by_the_catch_up_policy() {
    for (tag, policy, runs, skipped) in [
        ("latest", CatchUp::default(), 1, 0),
        ("all", CatchUp::All { max: 10 }, 1, 0),
        ("none", CatchUp::None, 0, 1),
    ] {
        let root = temp_root(&format!("catchup-{tag}"));
        let store = Store::open(&root).unwrap();
        let h = handoff("tp_11111111111111111111111111111111", 2, Some((FRI_0900 - DAY) * 1000));
        let a = store.import(spec("Daily", policy), &h, FRI_0900 + 1_800).unwrap().automation;
        let mut exec = Recorder::default();
        tick(&store, FRI_0900 + 1_800, &mut exec).unwrap();
        tick(&store, FRI_0900 + 1_860, &mut exec).unwrap();
        let rows = store.runs(&a.id).unwrap();
        let ran = rows.iter().filter(|r| r.state != RunState::Skipped).count();
        let skip = rows.iter().filter(|r| r.state == RunState::Skipped).count();
        assert_eq!((ran, skip), (runs, skipped), "{tag}: {rows:?}");
        assert!(rows.iter().all(|r| r.scheduled_at == Some(FRI_0900)), "{tag}: {rows:?}");
        let _ = std::fs::remove_dir_all(&root);
    }
}

#[test]
fn teleport_destination_grammar_is_the_chief_teleports_plus_cloud() {
    assert_eq!(parse_destination("cloud"), Ok(Destination::Cloud));
    assert_eq!(parse_destination("home"), Ok(Destination::Home));
    assert_eq!(
        parse_destination("ssh:mini"),
        Ok(Destination::Ssh { host: "mini".into(), dir: None })
    );
    assert_eq!(
        parse_destination("ssh:me@mini.local:/Users/me/work"),
        Ok(Destination::Ssh { host: "me@mini.local".into(), dir: Some("/Users/me/work".into()) })
    );
    assert_eq!(parse_destination("local:/tmp/x"), Ok(Destination::Local { dir: "/tmp/x".into() }));
    assert_eq!(
        parse_destination("ssh:me@mini.local:/w").unwrap().to_string(),
        "ssh:me@mini.local:/w"
    );
    let long = format!("ssh:{}", "a".repeat(260));
    for bad in
        ["", "mars", "ssh:", "ssh:-oProxyCommand=x", "ssh:mini:", "local:rel", "ssh:mi\nni", &long]
    {
        assert!(parse_destination(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn teleport_import_specs_map_triggers_bodies_and_catch_up() {
    let parse = |v: Value| serde_json::from_value::<ImportSpec>(v).unwrap();
    let base = |triggers: Value, body: Value| {
        json!({"name": "Brief", "triggers": triggers, "body": body, "catch_up": "all",
               "handoff": {"id": "tp_22222222222222222222222222222222", "from": "cloud",
                           "source_id": "auto_x", "epoch": 2, "last_slot": null}})
    };
    let chief =
        json!({"type": "chief", "chief": "agent_A", "conversation": "c", "prompt": "Summarize"});
    let s = parse(base(
        json!([{"type": "cron", "expr": "0 9 * * *", "tz": "America/Los_Angeles"}, {"type": "manual"}]),
        chief.clone(),
    ))
    .to_spec("America/Los_Angeles", None)
    .unwrap();
    assert_eq!(s.trigger, Trigger::Cron { expr: "0 9 * * *".into(), tz: "local".into() });
    assert_eq!(s.body, Body::Prompt { prompt: "Summarize".into(), folder: None, model: None });
    assert_eq!(s.catch_up, CatchUp::All { max: 10 });
    assert!(s.enabled);
    // Cloud lists triggers as {spec: …}.
    let wrapped = parse(base(
        json!([{"spec": {"type": "cron", "expr": "0 9 * * *", "tz": "UTC"}}]),
        json!({"type": "command", "command": "make", "folder": "/w"}),
    ))
    .to_spec("America/Los_Angeles", Some("/elsewhere"))
    .unwrap();
    assert_eq!(wrapped.trigger, Trigger::Cron { expr: "0 9 * * *".into(), tz: "UTC".into() });
    assert_eq!(
        wrapped.body,
        Body::Command { command: "make".into(), folder: Some("/elsewhere".into()) }
    );
    // A zone this machine does not run in, and a webhook, are refused.
    let paris = json!([{"type": "cron", "expr": "0 9 * * *", "tz": "Europe/Paris"}]);
    assert!(parse(base(paris, chief.clone())).to_spec("America/Los_Angeles", None).is_err());
    assert!(parse(base(json!([{"type": "webhook"}]), chief.clone())).to_spec("UTC", None).is_err());
    let manual = parse(base(json!([{"type": "manual"}]), chief)).to_spec("UTC", None).unwrap();
    assert_eq!(manual.trigger, Trigger::Manual);
}

#[test]
fn teleport_export_names_the_zone_and_carries_the_handoff() {
    let root = temp_root("export");
    let store = Store::open(&root).unwrap().with_home("mac:machine_src");
    let mut s = spec("Out", CatchUp::None);
    s.trigger = Trigger::Cron { expr: "0 9 * * 1-5".into(), tz: "local".into() };
    let a = store.create(s, FRI_0900 - HOUR).unwrap();
    let h = store.fence(&a.id, "ssh:mini", FRI_0900 * 1000).unwrap();
    let a = store.get(&a.id).unwrap();
    let out = serde_json::to_value(export_spec(&a, &h, "America/Los_Angeles")).unwrap();
    assert_eq!(out["name"], "Out");
    assert_eq!(
        out["triggers"],
        json!([{"type": "cron", "expr": "0 9 * * 1-5", "tz": "America/Los_Angeles"}])
    );
    assert_eq!(out["body"], json!({"type": "prompt", "prompt": "Summarize"}));
    assert_eq!(out["catch_up"], "none");
    assert_eq!(
        out["handoff"],
        json!({"id": h.id, "from": "mac:machine_src", "source_id": a.id, "epoch": 2, "last_slot": null})
    );
    // The receiving machine reads it back to the same schedule.
    let back = serde_json::from_value::<ImportSpec>(out)
        .unwrap()
        .to_spec("America/Los_Angeles", None)
        .unwrap();
    assert_eq!(back.trigger, Trigger::Cron { expr: "0 9 * * 1-5".into(), tz: "local".into() });
    let _ = std::fs::remove_dir_all(&root);
}
