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
            ["systemctl", "--user", "show", _, _holder, unit] => {
                let block = match self.slices.borrow().get(*unit) {
                    Some(true) => "ActiveState=active\nFreezerState=frozen\n",
                    Some(false) => "ActiveState=active\nFreezerState=running\n",
                    None => "ActiveState=inactive\nFreezerState=running\n",
                };
                ok(format!("{block}\n{block}"))
            }
            ["systemctl", "--user", "freeze", unit] => {
                if let Some(f) = self.slices.borrow_mut().get_mut(*unit) {
                    *f = true;
                }
                ok(String::new())
            }
            ["systemctl", "--user", "thaw", unit] => {
                if let Some(f) = self.slices.borrow_mut().get_mut(*unit) {
                    *f = false;
                }
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

/// The real shell and filesystem; systemd's calls answer as an empty user manager.
struct RealFs;

impl HostRunner for RealFs {
    fn run(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String> {
        match argv.first().map(String::as_str) {
            Some("systemd-run" | "systemctl") => Ok(Output::default()),
            _ => ProcessRunner.run(argv, stdin),
        }
    }
}

#[test]
fn a_dead_init_reads_stopped_though_its_slice_stays_active() {
    // systemd keeps a slice active after its holder exits; `ls` must not say Running.
    struct DeadInit;
    impl HostRunner for DeadInit {
        fn run(&self, argv: &[String], _stdin: &[u8]) -> Result<Output, String> {
            let stdout = match argv.first().map(String::as_str) {
                Some("systemctl") => {
                    "ActiveState=failed\nFreezerState=running\n\nActiveState=active\nFreezerState=running\n"
                }
                _ => "",
            };
            Ok(Output { code: 0, stdout: stdout.into(), stderr: Vec::new() })
        }
    }
    let pods = PodSlots::new(DeadInit, "/srv/pods");
    let slot = Slot::parse("a").unwrap();
    assert_eq!(pods.state(&slot).unwrap(), Some(SlotState::Stopped));
}

#[test]
fn a_root_no_create_made_is_refused_with_the_reason() {
    // Seen live: a root left from before read `Stopped`, and the pod never booted.
    let host = FakeHost::default();
    host.dirs.borrow_mut().insert("/srv/pods/a".into());
    let pods = PodSlots::new(&host, "/srv/pods");
    let err = pods.create(&slot("a"), SlotSize::default()).unwrap_err();
    assert!(err.contains("/srv/pods/a already exists but no create made it"), "{err}");
    assert!(!host.calls.borrow().iter().any(|c| c[0] == "systemd-run"));
    // Once create made it, a second create is a no-op that reads its state.
    host.dirs.borrow_mut().clear();
    assert_eq!(pods.create(&slot("a"), SlotSize::default()).unwrap(), SlotState::Running);
    assert_eq!(pods.create(&slot("a"), SlotSize::default()).unwrap(), SlotState::Running);
}

#[test]
fn a_host_bind_is_read_only_at_its_own_path_in_every_pod() {
    // A native harness under a home (`~/.local/share/claude`) is outside the system dirs.
    let host = FakeHost::default();
    let pods =
        PodSlots::new(&host, "/srv/pods").with_binds(vec!["/home/u/.local/share/claude".into()]);
    let boot = pods.boot_argv(&slot("a")).join(" ");
    assert!(
        boot.contains("--ro-bind-try /home/u/.local/share/claude /home/u/.local/share/claude"),
        "{boot}"
    );
    assert!(!boot.contains("--bind /home/u"), "{boot}");
}

#[test]
fn create_makes_the_root_and_pods_dir_owner_only_whatever_the_umask() {
    use std::os::unix::fs::PermissionsExt as _;
    // Without the chmod, mkdir gives the host's umask (002 on our VMs: drwxrwxr-x),
    // and the pod's acpmux refuses a writable ancestor of its state dir.
    let dir = std::env::temp_dir().join(format!("cmux-pool-pod-mode-{}", std::process::id()));
    let pods = PodSlots::new(RealFs, dir.to_str().unwrap());
    let size = SlotSize { vcpus: 1, memory_mib: 256 };
    assert_eq!(pods.create(&slot("a"), size).unwrap(), SlotState::Running);
    let mode = |p: &std::path::Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
    let (root, pods_dir) = (mode(&dir.join("a")), mode(&dir));
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!((root, pods_dir), (0o700, 0o700), "{root:o} {pods_dir:o}");
}

#[test]
fn create_boots_the_init_in_bwrap_with_home_at_the_root() {
    let host = FakeHost::default();
    let pods = PodSlots::new(&host, "/srv/pods/")
        .with_init(
            "acpmux",
            vec!["daemon".into()],
            vec![("ACPMUX_HUB".into(), "https://hub".into())],
        )
        .with_pass_env(vec!["ANTHROPIC_AUTH_TOKEN".into()]);
    let boot = pods.boot_argv(&slot("a")).join(" ");
    // A passed variable goes by name only: its value never reaches the argv.
    assert!(boot.starts_with("systemd-run --user --quiet --collect --expand-environment=no --unit=cmux_pod_a_hold.service --slice=cmux_pod_a.slice --setenv=HOME=/srv/pods/a --setenv=ACPMUX_HUB=https://hub --setenv=ANTHROPIC_AUTH_TOKEN -- bwrap "), "{boot}");
    assert!(boot.ends_with("--tmpfs /srv/pods --bind /srv/pods/a /srv/pods/a --setenv CMUX_POD_ROOT /srv/pods/a --chdir /srv/pods/a -- acpmux daemon"), "{boot}");
    let size = SlotSize { vcpus: 3, memory_mib: 2048 };
    assert_eq!(pods.create(&slot("a"), size).unwrap(), SlotState::Running);
    assert!(host.calls.borrow().iter().any(|c| c.join(" ")
            == "systemctl --user set-property --runtime cmux_pod_a.slice CPUQuota=300% MemoryMax=2048M"));
    assert_eq!(host.files.borrow()["/srv/pods/.meta/a.json"], br#"{"vcpus":3,"memoryMib":2048}"#);
}

#[test]
fn a_create_env_goes_to_the_runner_by_name_and_never_into_the_argv() {
    /// Records the env each call was given; the rest as [`FakeHost`].
    #[derive(Default)]
    struct EnvHost {
        host: FakeHost,
        env: RefCell<Vec<(String, Vec<(String, String)>)>>,
    }
    impl HostRunner for &EnvHost {
        fn run(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String> {
            (&self.host).run(argv, stdin)
        }
        fn run_env(
            &self,
            argv: &[String],
            stdin: &[u8],
            env: &[(&str, &str)],
        ) -> Result<Output, String> {
            let pairs = env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
            self.env.borrow_mut().push((argv[0].clone(), pairs));
            (&self.host).run(argv, stdin)
        }
    }
    let host = EnvHost::default();
    let pods = PodSlots::new(&host, "/srv/pods");
    let size = SlotSize { vcpus: 1, memory_mib: 256 };
    let env = [("CMUX_JOIN_TOKEN", "cmj_secret"), ("CMUX_JOIN_HUB", "https://hub")];
    assert_eq!(pods.create_with_env(&slot("a"), size, &env).unwrap(), SlotState::Running);
    let calls = host.host.calls.borrow();
    let boot = calls.iter().find(|c| c[0] == "systemd-run").unwrap().join(" ");
    assert!(boot.contains("--setenv=CMUX_JOIN_TOKEN --setenv=CMUX_JOIN_HUB -- bwrap"), "{boot}");
    assert!(calls.iter().all(|c| !c.join(" ").contains("cmj_secret")));
    let sent = host.env.borrow();
    assert_eq!(sent.len(), 1, "only the boot gets the env");
    assert_eq!(sent[0].0, "systemd-run");
    assert_eq!(sent[0].1[0], ("CMUX_JOIN_TOKEN".to_owned(), "cmj_secret".to_owned()));
    drop((calls, sent));
    // An existing slot is left as it is: no second boot, so the env is not handed again.
    assert_eq!(pods.create_with_env(&slot("a"), size, &env).unwrap(), SlotState::Running);
    assert_eq!(host.env.borrow().len(), 1);
}

#[test]
fn a_runner_that_cannot_set_env_refuses_rather_than_boot_without_it() {
    let host = FakeHost::default();
    let pods = PodSlots::new(&host, "/srv/pods");
    let size = SlotSize { vcpus: 1, memory_mib: 256 };
    let err = pods.create_with_env(&slot("a"), size, &[("X", "y")]).unwrap_err();
    assert!(err.contains("cannot hand a pod environment"), "{err}");
    // With no env the same runner boots as before.
    assert_eq!(pods.create(&slot("b"), size).unwrap(), SlotState::Running);
}

#[test]
fn the_process_runner_sets_the_env_on_its_child_only() {
    let out = ProcessRunner
        .run_env(
            &argv(&["sh", "-c", "printf %s \"$CMUX_TEST_POD_ENV\""]),
            &[],
            &[("CMUX_TEST_POD_ENV", "v1")],
        )
        .unwrap();
    assert_eq!(out.stdout, b"v1");
    assert!(std::env::var_os("CMUX_TEST_POD_ENV").is_none());
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
