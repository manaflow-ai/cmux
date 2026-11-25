//! Pods as a host agent's slots (cmuxterm-hq RFD 0100, the "plain pod" row of section 9).
//!
//! `acpmux machine hypervisor serve` drives one driver per hypervisor through the verbs
//! `create | pause | resume | destroy | list`, by slot name, every verb idempotent, and the
//! host's actual objects are the truth it reconciles against. [`PodSlots`] is that driver
//! for a plain host with no libvirt or Kubernetes: our lane VMs, or a customer's box.
//!
//! - A slot is a systemd user slice, `cmux_pod_<slot>.slice` (`-` becomes `_`: `-` nests
//!   slices), with `CPUQuota` and `MemoryMax` from its size, and a root folder
//!   `<pods_dir>/<slot>`.
//! - Its init runs as the slice's holder unit, inside `bwrap` (see [`bwrap_argv`]): `create`
//!   boots it. For a guest that is the pod's own `acpmux`, with `HOME` the pod root, so the
//!   pod joins the hub as its own machine.
//! - `pause` with [`PauseMode::Memory`] freezes the slice's cgroup (RAM kept); with
//!   [`PauseMode::Disk`] it stops the init and keeps the root ([`SlotState::Stopped`]: plain
//!   pods have no RAM image). `resume` thaws, or boots the init again.
//! - The slot's size is kept in `<pods_dir>/.meta/<slot>.json`, which the pods cannot see
//!   (a tmpfs covers the pods dir inside each pod), so a pod cannot grow itself.
//! - `list` reads the pods dir and systemd, never a record of its own, so a slot made by an
//!   earlier run, or left by a crash, is still found. Unit names are per user manager: one
//!   pods dir per host user.

use cmux_process::{Command, Stdio};

use serde::{Deserialize, Serialize};

use crate::systemd::{argv, bwrap_argv};

/// Unit names: the holder is `<PREFIX><token>_hold.service` in `<PREFIX><token>.slice`.
pub const UNIT_PREFIX: &str = "cmux_pod_";

/// A slot's name as the hub books it: 1 to 56 of `[a-z0-9-]`, not starting with `-`.
/// The same rule as the host agent's, so every slot it books is one here.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Slot(String);

impl Slot {
    pub fn parse(name: &str) -> Result<Self, String> {
        let ok = !name.is_empty()
            && name.len() <= 56
            && !name.starts_with('-')
            && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-');
        if ok {
            Ok(Self(name.to_owned()))
        } else {
            Err(format!("slot name {name:?}: use 1 to 56 of a-z, 0-9 and -, not starting with -"))
        }
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }

    fn token(&self) -> String {
        self.0.replace('-', "_")
    }

    /// `cmux_pod_<token>.slice`.
    pub fn slice(&self) -> String {
        format!("{UNIT_PREFIX}{}.slice", self.token())
    }

    /// `cmux_pod_<token>_hold.service`.
    pub fn holder(&self) -> String {
        format!("{UNIT_PREFIX}{}_hold.service", self.token())
    }

    /// The slot a unit name belongs to, when it is one of ours.
    pub fn from_unit(unit: &str) -> Option<Self> {
        let token = unit.strip_prefix(UNIT_PREFIX)?.strip_suffix(".slice")?;
        Self::parse(&token.replace('_', "-")).ok()
    }
}

/// The size of a slot's pod.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SlotSize {
    pub vcpus: u32,
    pub memory_mib: u64,
}

impl Default for SlotSize {
    fn default() -> Self {
        Self { vcpus: 2, memory_mib: 4096 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SlotState {
    Running,
    /// Frozen, RAM kept.
    Paused,
    /// No processes; the root and size are kept.
    Stopped,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PauseMode {
    #[default]
    Memory,
    Disk,
}

/// What one host command printed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Output {
    pub code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Output {
    fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
}

/// Runs one argv on this host and waits for it (the host agent's loop is synchronous).
pub trait HostRunner {
    fn run(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String>;
}

/// [`HostRunner`] by `cmux_process`: each child is owned, and ends with its handle.
pub struct ProcessRunner;

impl HostRunner for ProcessRunner {
    fn run(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String> {
        use std::io::Write as _;
        let (program, args) = argv.split_first().ok_or("empty argv")?;
        let mut child = Command::new(program)
            .args(args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("{program}: {e}"))?;
        if let Some(mut input) = child.stdin.take() {
            input.write_all(stdin).map_err(|e| format!("{program} stdin: {e}"))?;
        }
        let out = child.wait_with_output().map_err(|e| format!("{program}: {e}"))?;
        Ok(Output { code: out.status.code().unwrap_or(-1), stdout: out.stdout, stderr: out.stderr })
    }
}

/// The plain-pod slot driver for one host.
pub struct PodSlots<X> {
    runner: X,
    pods_dir: String,
    /// The program each pod's holder runs, and its arguments.
    init: (String, Vec<String>),
    /// Environment for the init (the pod's `HOME` is always set to its root).
    env: Vec<(String, String)>,
}

impl<X: HostRunner> PodSlots<X> {
    pub fn new(runner: X, pods_dir: impl Into<String>) -> Self {
        Self {
            runner,
            pods_dir: pods_dir.into().trim_end_matches('/').to_owned(),
            init: ("sleep".to_owned(), vec!["infinity".to_owned()]),
            env: Vec::new(),
        }
    }

    /// What each pod boots: for a guest, its own `acpmux` daemon.
    pub fn with_init(
        mut self,
        program: impl Into<String>,
        args: Vec<String>,
        env: Vec<(String, String)>,
    ) -> Self {
        self.init = (program.into(), args);
        self.env = env;
        self
    }

    pub fn root(&self, slot: &Slot) -> String {
        format!("{}/{}", self.pods_dir, slot.as_str())
    }

    fn meta(&self, slot: &Slot) -> String {
        format!("{}/.meta/{}.json", self.pods_dir, slot.as_str())
    }

    /// The argv that boots a slot's init in its slice.
    pub fn boot_argv(&self, slot: &Slot) -> Vec<String> {
        let root = self.root(slot);
        let mut out = argv(&[
            "systemd-run",
            "--user",
            "--quiet",
            "--collect",
            "--expand-environment=no",
            &format!("--unit={}", slot.holder()),
            &format!("--slice={}", slot.slice()),
            &format!("--setenv=HOME={root}"),
        ]);
        for (key, value) in &self.env {
            out.push(format!("--setenv={key}={value}"));
        }
        out.push("--".to_owned());
        out.extend(bwrap_argv(&self.pods_dir, &root, &root, &self.init.0, &self.init.1));
        out
    }

    pub fn size_argv(slot: &Slot, size: SlotSize) -> Vec<String> {
        argv(&[
            "systemctl",
            "--user",
            "set-property",
            "--runtime",
            &slot.slice(),
            &format!("CPUQuota={}%", u64::from(size.vcpus) * 100),
            &format!("MemoryMax={}M", size.memory_mib),
        ])
    }

    fn ok(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String> {
        let out = self.runner.run(argv, stdin)?;
        if out.code != 0 {
            return Err(format!(
                "{} exited {}: {}",
                argv.first().map(String::as_str).unwrap_or(""),
                out.code,
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
        Ok(out)
    }

    fn systemctl(&self, verb: &str, unit: &str) -> Result<Output, String> {
        self.ok(&argv(&["systemctl", "--user", verb, unit]), &[])
    }

    /// The slot's state, or `None` when this pods dir has no root for it.
    pub fn state(&self, slot: &Slot) -> Result<Option<SlotState>, String> {
        let out = self.ok(
            &argv(&[
                "systemctl",
                "--user",
                "show",
                "--property=ActiveState,FreezerState",
                &slot.slice(),
            ]),
            &[],
        )?;
        let text = out.text();
        let prop = |name: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(name).and_then(|v| v.strip_prefix('=')))
                .unwrap_or("")
                .to_owned()
        };
        let exists = self.runner.run(&argv(&["test", "-d", &self.root(slot)]), &[])?.code == 0;
        if !exists {
            return Ok(None);
        }
        if prop("ActiveState") == "active" {
            return Ok(Some(if prop("FreezerState").starts_with("frozen") {
                SlotState::Paused
            } else {
                SlotState::Running
            }));
        }
        Ok(Some(SlotState::Stopped))
    }

    fn size_of(&self, slot: &Slot) -> SlotSize {
        self.runner
            .run(&argv(&["cat", "--", &self.meta(slot)]), &[])
            .ok()
            .filter(|o| o.code == 0)
            .and_then(|o| serde_json::from_slice(&o.stdout).ok())
            .unwrap_or_default()
    }

    fn boot(&self, slot: &Slot, size: SlotSize) -> Result<SlotState, String> {
        self.ok(&self.boot_argv(slot), &[])?;
        self.ok(&Self::size_argv(slot, size), &[])?;
        Ok(SlotState::Running)
    }

    /// Make and boot the slot's pod; an existing slot is left as it is.
    pub fn create(&self, slot: &Slot, size: SlotSize) -> Result<SlotState, String> {
        if let Some(state) = self.state(slot)? {
            return Ok(state);
        }
        let meta = serde_json::to_vec(&size).map_err(|e| e.to_string())?;
        self.ok(
            &argv(&[
                "sh",
                "-c",
                "mkdir -p -- \"$1\" \"$(dirname -- \"$2\")\" && cat > \"$2\"",
                "sh",
                &self.root(slot),
                &self.meta(slot),
            ]),
            &meta,
        )?;
        self.boot(slot, size)
    }

    pub fn pause(&self, slot: &Slot, mode: PauseMode) -> Result<SlotState, String> {
        let state = self.state(slot)?.ok_or_else(|| format!("no slot {}", slot.as_str()))?;
        match (mode, state) {
            (_, SlotState::Stopped) => Ok(SlotState::Stopped),
            (PauseMode::Memory, SlotState::Paused) => Ok(SlotState::Paused),
            (PauseMode::Memory, SlotState::Running) => {
                self.systemctl("freeze", &slot.slice())?;
                Ok(SlotState::Paused)
            }
            (PauseMode::Disk, _) => {
                self.halt(slot)?;
                Ok(SlotState::Stopped)
            }
        }
    }

    pub fn resume(&self, slot: &Slot) -> Result<SlotState, String> {
        match self.state(slot)?.ok_or_else(|| format!("no slot {}", slot.as_str()))? {
            SlotState::Running => Ok(SlotState::Running),
            SlotState::Paused => {
                self.systemctl("thaw", &slot.slice())?;
                Ok(SlotState::Running)
            }
            SlotState::Stopped => self.boot(slot, self.size_of(slot)),
        }
    }

    /// Thaw first: a frozen cgroup's processes cannot take the stop signal.
    fn halt(&self, slot: &Slot) -> Result<(), String> {
        let _ = self.runner.run(&argv(&["systemctl", "--user", "thaw", &slot.slice()]), &[])?;
        let _ = self.runner.run(&argv(&["systemctl", "--user", "stop", &slot.slice()]), &[])?;
        Ok(())
    }

    /// Stop the pod and remove its root and size. A slot that is gone is fine.
    pub fn destroy(&self, slot: &Slot) -> Result<(), String> {
        self.halt(slot)?;
        self.ok(&argv(&["rm", "-rf", "--", &self.root(slot), &self.meta(slot)]), &[]).map(drop)
    }

    /// Every slot of this pods dir. A slot is its root folder: `create` makes the root
    /// before it boots and `destroy` stops before it removes, so no slice of ours lives
    /// without one. Slice names are host-wide, so another pods dir's slices (a second
    /// driver on the same user manager) are never read as ours.
    pub fn list(&self) -> Result<Vec<(Slot, SlotState)>, String> {
        let dirs = self.runner.run(&argv(&["ls", "-1", "--", &self.pods_dir]), &[])?;
        if dirs.code != 0 {
            return Ok(Vec::new());
        }
        let mut names: Vec<Slot> =
            dirs.text().lines().filter_map(|l| Slot::parse(l.trim()).ok()).collect();
        names.sort();
        let mut out = Vec::new();
        for slot in names {
            if let Some(state) = self.state(&slot)? {
                out.push((slot, state));
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
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
            let ok =
                |stdout: String| Ok(Output { code: 0, stdout: stdout.into(), stderr: Vec::new() });
            let fail = || Ok(Output { code: 1, ..Output::default() });
            let a: Vec<&str> = argv.iter().map(String::as_str).collect();
            match a.as_slice() {
                ["systemd-run", rest @ ..] => {
                    let slice = rest.iter().find_map(|x| x.strip_prefix("--slice=")).unwrap();
                    self.slices.borrow_mut().insert(slice.to_owned(), false);
                    ok(String::new())
                }
                ["systemctl", "--user", "show", _, unit] => {
                    ok(match self.slices.borrow().get(*unit) {
                        Some(true) => "ActiveState=active\nFreezerState=frozen\n".into(),
                        Some(false) => "ActiveState=active\nFreezerState=running\n".into(),
                        None => "ActiveState=inactive\nFreezerState=running\n".into(),
                    })
                }
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
        assert_eq!(
            host.files.borrow()["/srv/pods/.meta/a.json"],
            br#"{"vcpus":3,"memoryMib":2048}"#
        );
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
}
