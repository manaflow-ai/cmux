//! The host agent against a fake `virsh`: a tiny libvirt in memory that answers the
//! commands the driver sends and records them.

use super::lease::{Lease, LeaseBook, Reason, Verdict};
use super::libvirt::{LibvirtConfig, LibvirtDriver, RunOutput, Runner, parse_domstate};
use super::serve::HostAgent;
use super::source::{Command, CommandSource, Envelope, SpoolSource};
use super::*;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

/// Domains by name, with libvirt's state text, and every call made.
#[derive(Default)]
struct World {
    domains: BTreeMap<String, &'static str>,
    calls: Vec<String>,
}

#[derive(Clone, Default)]
struct FakeVirsh(Rc<RefCell<World>>);

impl FakeVirsh {
    fn calls(&self) -> Vec<String> {
        self.0.borrow().calls.clone()
    }
    fn clear(&self) {
        self.0.borrow_mut().calls.clear();
    }
    fn set(&self, domain: &str, state: &'static str) {
        self.0.borrow_mut().domains.insert(domain.into(), state);
    }
    fn state(&self, domain: &str) -> Option<&'static str> {
        self.0.borrow().domains.get(domain).copied()
    }
}

fn ok(stdout: &str) -> RunOutput {
    RunOutput { ok: true, stdout: stdout.into(), stderr: String::new() }
}

fn missing(domain: &str) -> RunOutput {
    RunOutput {
        ok: false,
        stdout: String::new(),
        stderr: format!("error: failed to get domain '{domain}'"),
    }
}

impl Runner for FakeVirsh {
    fn run(&self, program: &str, args: &[String]) -> anyhow::Result<RunOutput> {
        let mut w = self.0.borrow_mut();
        w.calls.push(format!("{program} {}", args.join(" ")));
        if program == "qemu-img" {
            // Make the overlay file so a second create sees it.
            std::fs::write(
                &args[args.len() - if args.last().unwrap().ends_with('G') { 2 } else { 1 }],
                b"",
            )?;
            return Ok(ok(""));
        }
        let args: Vec<&str> = args.iter().map(String::as_str).collect();
        let args = if args.first() == Some(&"-c") { &args[2..] } else { &args[..] };
        let dom = args.get(1).copied().unwrap_or("");
        let present = w.domains.contains_key(dom);
        Ok(match args[0] {
            "list" => ok(&w.domains.keys().map(|k| format!("{k}\n")).collect::<String>()),
            "domstate" => match w.domains.get(dom) {
                Some(s) => ok(&format!("{s}\n\n")),
                None => missing(dom),
            },
            "define" => {
                let xml = std::fs::read_to_string(dom)?;
                let name =
                    xml.split("<name>").nth(1).and_then(|s| s.split("</name>").next()).unwrap();
                w.domains.insert(name.to_owned(), "shut off (unknown)");
                ok("")
            }
            "start" if present => {
                w.domains.insert(dom.into(), "running (booted)");
                ok("")
            }
            "suspend" if present => {
                w.domains.insert(dom.into(), "paused (user)");
                ok("")
            }
            "resume" if present => {
                w.domains.insert(dom.into(), "running (unpaused)");
                ok("")
            }
            "managedsave" if present => {
                w.domains.insert(dom.into(), "shut off (saved)");
                ok("")
            }
            "destroy" if present => {
                w.domains.insert(dom.into(), "shut off (destroyed)");
                ok("")
            }
            "undefine" if present => {
                w.domains.remove(dom);
                ok("")
            }
            _ => missing(dom),
        })
    }
}

fn slot(s: &str) -> SlotName {
    SlotName::parse(s).unwrap()
}

fn driver(dir: &std::path::Path) -> (LibvirtDriver<FakeVirsh>, FakeVirsh) {
    let fake = FakeVirsh::default();
    let mut config = LibvirtConfig::new(dir.join("images"));
    config.base_image = Some(dir.join("base.qcow2"));
    (LibvirtDriver::new(config, fake.clone()), fake)
}

#[test]
fn slot_names_are_safe_domain_names() {
    assert!(SlotName::parse("a1-b2").is_ok());
    for bad in ["", "-a", "A", "a/b", "a b", "a.b", &"x".repeat(57)] {
        assert!(SlotName::parse(bad).is_err(), "{bad:?}");
    }
    assert_eq!(slot("a1").domain(), "cmux-a1");
    assert_eq!(SlotName::from_domain("cmux-a1"), Some(slot("a1")));
    assert_eq!(SlotName::from_domain("ubuntu"), None);
    assert!(serde_json::from_str::<SlotName>("\"../x\"").is_err());
}

#[test]
fn domstate_reasons_map_to_slot_states() {
    assert_eq!(parse_domstate("running (booted)\n"), Some(SlotState::Running));
    assert_eq!(parse_domstate("paused (user)"), Some(SlotState::Paused));
    assert_eq!(parse_domstate("shut off (saved)"), Some(SlotState::Saved));
    assert_eq!(parse_domstate("shut off (destroyed)"), Some(SlotState::Stopped));
    assert_eq!(parse_domstate("shut off"), Some(SlotState::Stopped));
    assert_eq!(parse_domstate("nonsense"), None);
}

#[test]
fn create_makes_an_overlay_defines_and_starts_once() {
    let dir = tempfile::tempdir().unwrap();
    let (d, fake) = driver(dir.path());
    let spec = SlotSpec { vcpus: 4, memory_mib: 8192, disk_gib: 40 };
    assert_eq!(d.create(&slot("a1"), &spec).unwrap(), SlotState::Running);
    let calls = fake.calls();
    let overlay = dir.path().join("images/cmux-a1.qcow2");
    assert_eq!(
        calls[1],
        format!(
            "qemu-img create -f qcow2 -F qcow2 -b {} {} 40G",
            dir.path().join("base.qcow2").display(),
            overlay.display()
        )
    );
    assert!(calls[2].starts_with("virsh define "));
    assert_eq!(calls[3], "virsh start cmux-a1");
    let xml = std::fs::read_to_string(dir.path().join("images/cmux-a1.xml")).unwrap();
    assert!(xml.contains("<name>cmux-a1</name>"));
    assert!(xml.contains("<vcpu>4</vcpu>"));
    assert!(xml.contains("<memory unit='MiB'>8192</memory>"));
    assert!(xml.contains(&format!("<source file='{}'/>", overlay.display())));
    assert!(xml.contains("<source network='default'/>"));

    // Again: only a state read, nothing made.
    fake.clear();
    assert_eq!(d.create(&slot("a1"), &spec).unwrap(), SlotState::Running);
    assert_eq!(fake.calls(), vec!["virsh domstate cmux-a1 --reason"]);
}

#[test]
fn create_without_a_base_image_refuses_and_names_the_flag() {
    let dir = tempfile::tempdir().unwrap();
    let (mut d, fake) = driver(dir.path());
    d.config.base_image = None;
    let err = d.create(&slot("a1"), &SlotSpec::default()).unwrap_err().to_string();
    assert!(err.contains("--base-image"), "{err}");
    assert!(fake.state("cmux-a1").is_none());
}

#[test]
fn connect_uri_goes_first_on_every_virsh_call() {
    let dir = tempfile::tempdir().unwrap();
    let (mut d, fake) = driver(dir.path());
    d.config.connect = Some("qemu:///system".into());
    d.list().unwrap();
    assert_eq!(fake.calls(), vec!["virsh -c qemu:///system list --all --name"]);
}

#[test]
fn pause_resume_and_destroy_are_idempotent() {
    let dir = tempfile::tempdir().unwrap();
    let (d, fake) = driver(dir.path());
    let a = slot("a1");
    d.create(&a, &SlotSpec::default()).unwrap();

    assert_eq!(d.pause(&a, PauseMode::Memory).unwrap(), SlotState::Paused);
    fake.clear();
    assert_eq!(d.pause(&a, PauseMode::Memory).unwrap(), SlotState::Paused);
    assert_eq!(fake.calls().len(), 1, "a second pause only reads the state");

    // From RAM-paused to disk, then resume restores the managed save with `start`.
    assert_eq!(d.pause(&a, PauseMode::Disk).unwrap(), SlotState::Saved);
    assert_eq!(d.pause(&a, PauseMode::Memory).unwrap(), SlotState::Saved);
    fake.clear();
    assert_eq!(d.resume(&a).unwrap(), SlotState::Running);
    assert_eq!(fake.calls()[1], "virsh start cmux-a1");
    assert_eq!(d.resume(&a).unwrap(), SlotState::Running);

    d.pause(&a, PauseMode::Memory).unwrap();
    fake.clear();
    d.resume(&a).unwrap();
    assert_eq!(fake.calls()[1], "virsh resume cmux-a1");

    std::fs::write(d.overlay_path(&a), b"disk").unwrap();
    fake.clear();
    d.destroy(&a).unwrap();
    assert_eq!(
        fake.calls()[1..],
        [
            "virsh destroy cmux-a1",
            "virsh undefine cmux-a1 --managed-save --snapshots-metadata --remove-all-storage"
        ]
    );
    assert!(fake.state("cmux-a1").is_none());
    assert!(!d.overlay_path(&a).exists());
    d.destroy(&a).unwrap();
    assert!(d.pause(&a, PauseMode::Disk).is_err());
    assert!(d.resume(&a).is_err());
}

#[test]
fn list_shows_only_cmux_domains() {
    let dir = tempfile::tempdir().unwrap();
    let (d, fake) = driver(dir.path());
    fake.set("ubuntu-dev", "running (booted)");
    fake.set("cmux-b2", "shut off (saved)");
    fake.set("cmux-a1", "paused (user)");
    fake.set("cmux-Bad", "running (booted)");
    assert_eq!(
        d.list().unwrap(),
        vec![
            Slot { name: slot("a1"), state: SlotState::Paused },
            Slot { name: slot("b2"), state: SlotState::Saved },
        ]
    );
}

fn lease(f: impl FnOnce(&mut Lease)) -> Lease {
    let mut l = Lease::default();
    f(&mut l);
    l
}

#[test]
fn leases_judge_delete_after_then_max_run_idle_and_renewal() {
    let mut book = LeaseBook::default();
    let s = slot("a1");
    book.create(
        &s,
        lease(|l| {
            l.delete_after_secs = Some(100);
            l.max_run_secs = Some(60);
            l.idle_secs = Some(30);
            l.renew_within_secs = Some(20);
        }),
        0,
    );
    let run = [(s.clone(), SlotState::Running)];
    let judge = |b: &LeaseBook, now| {
        b.judge(&run, now).into_iter().map(|a| (a.verdict, a.reason)).collect::<Vec<_>>()
    };
    assert_eq!(judge(&book, 19_999), vec![]);
    assert_eq!(judge(&book, 20_000), vec![(Verdict::PauseToDisk, Reason::NotRenewed)]);
    book.renew(&s, None, 25_000);
    assert_eq!(judge(&book, 30_000), vec![(Verdict::PauseToDisk, Reason::Idle)]);
    book.touch(&s, 30_000);
    book.renew(&s, None, 50_000);
    assert_eq!(judge(&book, 55_000), vec![]);
    assert_eq!(judge(&book, 60_000), vec![(Verdict::PauseToDisk, Reason::MaxRun)]);
    assert_eq!(judge(&book, 100_000), vec![(Verdict::Destroy, Reason::DeleteAfter)]);

    // Already saved: nothing more to pause, but delete-after still deletes.
    let saved = [(s.clone(), SlotState::Saved)];
    assert!(book.judge(&saved, 99_000).is_empty());
    assert_eq!(book.judge(&saved, 100_000)[0].verdict, Verdict::Destroy);
}

#[test]
fn orphans_are_paused_to_disk_never_destroyed() {
    let book = LeaseBook::default();
    let o = slot("orphan");
    let acts = book.judge(&[(o.clone(), SlotState::Running)], 0);
    assert_eq!(acts.len(), 1);
    assert_eq!((acts[0].verdict, acts[0].reason), (Verdict::PauseToDisk, Reason::Orphan));
    assert!(book.judge(&[(o, SlotState::Saved)], u64::MAX).is_empty());
}

#[test]
fn spool_round_trips_commands_and_records_outcomes() {
    let dir = tempfile::tempdir().unwrap();
    let mut spool = SpoolSource::new(dir.path().to_path_buf());
    let cmd: Command = serde_json::from_str(
        r#"{"verb":"create","slot":"a1","spec":{"vcpus":2},"lease":{"deleteAfterSecs":86400}}"#,
    )
    .unwrap();
    let env = spool.submit(cmd.clone(), None, 7).unwrap();
    assert_eq!(env.id, "0000000000007-a1");
    assert!(spool.submit(cmd, Some("../x".into()), 8).is_err());
    std::fs::write(dir.path().join("inbox/bad.json"), b"{").unwrap();

    let taken = spool.take().unwrap();
    assert_eq!(taken, vec![env.clone()]);
    assert!(dir.path().join("done/bad.json.error").exists());
    let outcome = source::Outcome { ok: true, state: Some(SlotState::Running), error: None };
    spool.ack(&env, &outcome).unwrap();
    assert!(spool.take().unwrap().is_empty());
    let done: serde_json::Value = serde_json::from_slice(
        &std::fs::read(dir.path().join(format!("done/{}.json", env.id))).unwrap(),
    )
    .unwrap();
    assert_eq!(done["outcome"]["state"], "running");
    assert_eq!(done["command"]["verb"], "create");
}

/// A source the test fills directly.
#[derive(Default)]
struct Queue(Vec<Envelope>, Vec<(String, source::Outcome)>);

impl CommandSource for Queue {
    fn take(&mut self) -> anyhow::Result<Vec<Envelope>> {
        Ok(std::mem::take(&mut self.0))
    }
    fn ack(&mut self, env: &Envelope, outcome: &source::Outcome) -> anyhow::Result<()> {
        self.1.push((env.id.clone(), outcome.clone()));
        Ok(())
    }
}

fn env(id: &str, json: &str) -> Envelope {
    Envelope { id: id.into(), command: serde_json::from_str(json).unwrap() }
}

#[test]
fn serve_applies_commands_enforces_leases_and_keeps_state_across_restarts() {
    let dir = tempfile::tempdir().unwrap();
    let (d, fake) = driver(dir.path());
    fake.set("cmux-stray", "running (booted)");
    let state = dir.path().join("state");
    let mut agent = HostAgent::open(d, Queue::default(), state.clone()).unwrap();
    agent.source.0 = vec![
        env("1", r#"{"verb":"create","slot":"a1","lease":{"deleteAfterSecs":100,"idleSecs":10}}"#),
        env("2", r#"{"verb":"resume","slot":"nope"}"#),
    ];
    let tick = agent.tick(1_000).unwrap();
    assert!(tick.applied[0].outcome.ok);
    assert!(!tick.applied[1].outcome.ok);
    assert_eq!(agent.source.1.len(), 2);
    assert_eq!(tick.orphans, vec![slot("stray")]);
    assert_eq!(tick.enforced.len(), 1);
    assert_eq!(fake.state("cmux-stray"), Some("shut off (saved)"));
    assert_eq!(fake.state("cmux-a1"), Some("running (booted)"));
    assert!(state.join("status.json").exists());

    // A restarted agent reads the lease back; idle passes, the VM is saved, not deleted.
    let (d, _) = driver(dir.path());
    let fake2 = d.runner.clone();
    *fake2.0.borrow_mut() = std::mem::take(&mut *fake.0.borrow_mut());
    let mut agent = HostAgent::open(d, Queue::default(), state).unwrap();
    let tick = agent.tick(11_000).unwrap();
    assert_eq!(tick.enforced[0].action.reason, Reason::Idle);
    assert_eq!(fake2.state("cmux-a1"), Some("shut off (saved)"));

    // delete-after passes: destroyed, and the lease goes with it.
    let tick = agent.tick(101_000).unwrap();
    assert_eq!(tick.enforced[0].action.verdict, Verdict::Destroy);
    assert!(fake2.state("cmux-a1").is_none());
    assert!(agent.book.slots.is_empty());
}

#[test]
fn session_end_pauses_or_deletes_by_the_lease() {
    let dir = tempfile::tempdir().unwrap();
    let (d, fake) = driver(dir.path());
    let mut agent = HostAgent::open(d, Queue::default(), dir.path().join("s")).unwrap();
    agent.source.0 = vec![
        env("1", r#"{"verb":"create","slot":"keep"}"#),
        env("2", r#"{"verb":"create","slot":"gone","lease":{"deleteOnEnd":true}}"#),
        env("3", r#"{"verb":"end","slot":"keep"}"#),
        env("4", r#"{"verb":"end","slot":"gone"}"#),
    ];
    let tick = agent.tick(0).unwrap();
    assert!(tick.applied.iter().all(|a| a.outcome.ok), "{:?}", tick.applied);
    assert_eq!(fake.state("cmux-keep"), Some("shut off (saved)"));
    assert!(fake.state("cmux-gone").is_none());
}

#[test]
fn a_vm_removed_behind_the_agents_back_is_reported_gone() {
    let dir = tempfile::tempdir().unwrap();
    let (d, fake) = driver(dir.path());
    let mut agent = HostAgent::open(d, Queue::default(), dir.path().join("s")).unwrap();
    agent.source.0 = vec![env("1", r#"{"verb":"create","slot":"a1"}"#)];
    agent.tick(0).unwrap();
    fake.0.borrow_mut().domains.clear();
    let tick = agent.tick(1).unwrap();
    assert_eq!(tick.gone, vec![slot("a1")]);
    assert!(agent.book.slots.is_empty());
}
