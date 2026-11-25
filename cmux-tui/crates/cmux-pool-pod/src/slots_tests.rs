use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

use super::*;

/// A host that keeps systemd's slice states and the pod files the way the real one does.
#[derive(Default)]
struct FakeHost {
    /// slice unit -> frozen?
    slices: RefCell<BTreeMap<String, bool>>,
    dirs: RefCell<BTreeSet<String>>,
    files: RefCell<BTreeMap<String, Vec<u8>>>,
    calls: RefCell<Vec<Vec<String>>>,
}

impl HostRunner for &FakeHost {
    fn run(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String> {
        self.calls.borrow_mut().push(argv.to_vec());
        let ok = |stdout: String| Ok(Output { code: 0, stdout: stdout.into(), stderr: Vec::new() });
        let fail = || Ok(Output { code: 1, ..Output::default() });
        let a: Vec<&str> = argv.iter().map(String::as_str).collect();
        match a.as_slice() {
            ["systemd-run", rest @ ..] => {
                let slice = rest.iter().find_map(|x| x.strip_prefix("--slice=")).unwrap();
                self.slices.borrow_mut().insert(slice.to_owned(), false);
                ok(String::new())
            }
            ["systemctl", "--user", "show", _, unit] => ok(match self.slices.borrow().get(*unit) {
                Some(true) => "ActiveState=active\nFreezerState=frozen\n".into(),
                Some(false) => "ActiveState=active\nFreezerState=running\n".into(),
                None => "ActiveState=inactive\nFreezerState=running\n".into(),
            }),
            ["systemctl", "--user", "freeze", unit] => {
                self.slices.borrow_mut().get_mut(*unit).map(|f| *f = true);
                ok(String::new())
            }
            ["systemctl", "--user", "thaw", unit] => {
                self.slices.borrow_mut().get_mut(*unit).map(|f| *f = false);
                ok(String::new())
            }
            ["systemctl", "--user", "stop", unit] => {
                self.slices.borrow_mut().remove(*unit);
                ok(String::new())
            }
            ["systemctl", "--user", "set-property", ..] => ok(String::new()),
            ["test", "-d", dir] => {
                if self.dirs.borrow().contains(*dir) {
                    ok(String::new())
                } else {
                    fail()
                }
            }
            ["cat", "--", path] => match self.files.borrow().get(*path) {
                Some(b) => Ok(Output { code: 0, stdout: b.clone(), stderr: Vec::new() }),
                None => fail(),
            },
            ["sh", "-c", _, "sh", root, meta] => {
                self.dirs.borrow_mut().insert((*root).to_owned());
                self.files.borrow_mut().insert((*meta).to_owned(), stdin.to_vec());
                ok(String::new())
            }
            ["rm", "-rf", "--", root, meta] => {
                self.dirs.borrow_mut().remove(*root);
                self.files.borrow_mut().remove(*meta);
                ok(String::new())
            }
            ["ls", "-1", "--", dir] => ok(self
                .dirs
                .borrow()
                .iter()
                .filter_map(|d| d.strip_prefix(&format!("{dir}/")))
                .map(|name| format!("{name}\n"))
                .collect()),
            other => panic!("unexpected {other:?}"),
        }
    }
}

fn slot(name: &str) -> Slot {
    Slot::parse(name).unwrap()
}

#[test]
fn slot_names_follow_the_host_agent_rule_and_round_trip_units() {
    for bad in ["", "-a", "A", "a_b", "a/b", &"a".repeat(57)] {
        assert!(Slot::parse(bad).is_err(), "{bad}");
    }
    let s = slot("lane-a-1");
    assert_eq!(s.slice(), "cmux_pod_lane_a_1.slice");
    assert_eq!(s.holder(), "cmux_pod_lane_a_1_hold.service");
    assert_eq!(Slot::from_unit(&s.slice()), Some(s));
    assert_eq!(Slot::from_unit("cmux_pod_x_hold.service"), None);
    assert_eq!(Slot::from_unit("user.slice"), None);
}

#[test]
fn create_boots_the_init_in_bwrap_with_home_at_the_root() {
    let host = FakeHost::default();
    let pods = PodSlots::new(&host, "/srv/pods/").with_init(
        "acpmux",
        vec!["daemon".into()],
        vec![("ACPMUX_HUB".into(), "https://hub".into())],
    );
    let boot = pods.boot_argv(&slot("a")).join(" ");
    assert!(boot.starts_with("systemd-run --user --quiet --collect --expand-environment=no --unit=cmux_pod_a_hold.service --slice=cmux_pod_a.slice --setenv=HOME=/srv/pods/a --setenv=ACPMUX_HUB=https://hub -- bwrap "), "{boot}");
    assert!(boot.ends_with("--tmpfs /srv/pods --bind /srv/pods/a /srv/pods/a --setenv CMUX_POD_ROOT /srv/pods/a --chdir /srv/pods/a -- acpmux daemon"), "{boot}");
    let size = SlotSize { vcpus: 3, memory_mib: 2048 };
    assert_eq!(pods.create(&slot("a"), size).unwrap(), SlotState::Running);
    assert!(host.calls.borrow().iter().any(|c| c.join(" ")
        == "systemctl --user set-property --runtime cmux_pod_a.slice CPUQuota=300% MemoryMax=2048M"));
    assert_eq!(host.files.borrow()["/srv/pods/.meta/a.json"], br#"{"vcpus":3,"memoryMib":2048}"#);
}

#[test]
fn every_verb_is_idempotent() {
    let host = FakeHost::default();
    let pods = PodSlots::new(&host, "/srv/pods");
    let a = slot("a");
    let size = SlotSize::default();
    assert_eq!(pods.create(&a, size).unwrap(), SlotState::Running);
    let boots = || host.calls.borrow().iter().filter(|c| c[0] == "systemd-run").count();
    assert_eq!(pods.create(&a, size).unwrap(), SlotState::Running);
    assert_eq!(boots(), 1);
    assert_eq!(pods.pause(&a, PauseMode::Memory).unwrap(), SlotState::Paused);
    assert_eq!(pods.pause(&a, PauseMode::Memory).unwrap(), SlotState::Paused);
    assert_eq!(pods.create(&a, size).unwrap(), SlotState::Paused);
    assert_eq!(pods.resume(&a).unwrap(), SlotState::Running);
    assert_eq!(pods.resume(&a).unwrap(), SlotState::Running);
    pods.destroy(&a).unwrap();
    pods.destroy(&a).unwrap();
    assert_eq!(pods.state(&a).unwrap(), None);
    assert!(pods.pause(&a, PauseMode::Memory).is_err());
    assert!(pods.resume(&a).is_err());
}

#[test]
fn disk_pause_stops_and_keeps_the_root_and_resume_boots_at_its_size() {
    let host = FakeHost::default();
    let pods = PodSlots::new(&host, "/srv/pods");
    let a = slot("a");
    pods.create(&a, SlotSize { vcpus: 1, memory_mib: 512 }).unwrap();
    pods.pause(&a, PauseMode::Memory).unwrap();
    // From frozen too: halt thaws before it stops.
    assert_eq!(pods.pause(&a, PauseMode::Disk).unwrap(), SlotState::Stopped);
    assert_eq!(pods.pause(&a, PauseMode::Disk).unwrap(), SlotState::Stopped);
    assert_eq!(pods.list().unwrap(), vec![(a.clone(), SlotState::Stopped)]);
    host.calls.borrow_mut().clear();
    assert_eq!(pods.resume(&a).unwrap(), SlotState::Running);
    assert!(host.calls.borrow().iter().any(|c| c.join(" ")
        == "systemctl --user set-property --runtime cmux_pod_a.slice CPUQuota=100% MemoryMax=512M"));
}

#[test]
fn list_finds_slots_from_the_host_not_a_record() {
    let host = FakeHost::default();
    PodSlots::new(&host, "/srv/pods").create(&slot("b"), SlotSize::default()).unwrap();
    let first = PodSlots::new(&host, "/srv/pods");
    first.create(&slot("a-1"), SlotSize::default()).unwrap();
    first.pause(&slot("a-1"), PauseMode::Memory).unwrap();
    // A new driver (a restarted host agent) sees both.
    let again = PodSlots::new(&host, "/srv/pods");
    assert_eq!(
        again.list().unwrap(),
        vec![(slot("a-1"), SlotState::Paused), (slot("b"), SlotState::Running)]
    );
}

#[test]
fn another_pods_dirs_slots_are_not_ours() {
    let host = FakeHost::default();
    let one = PodSlots::new(&host, "/srv/one");
    let two = PodSlots::new(&host, "/srv/two");
    one.create(&slot("a"), SlotSize::default()).unwrap();
    assert_eq!(two.list().unwrap(), vec![]);
    assert_eq!(two.state(&slot("a")).unwrap(), None);
    assert_eq!(one.list().unwrap(), vec![(slot("a"), SlotState::Running)]);
}
