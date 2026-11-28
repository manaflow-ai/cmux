use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

use cmux_pool_pod::slots::Output;

use super::*;

/// systemd's slice states (frozen or not) and the pod roots, the way a host keeps them.
#[derive(Default)]
struct Host {
    slices: RefCell<BTreeMap<String, bool>>,
    dirs: RefCell<BTreeSet<String>>,
    files: RefCell<BTreeMap<String, Vec<u8>>>,
    /// Each `run_env` call: its argv and the env it was handed.
    env: RefCell<Vec<(Vec<String>, Vec<(String, String)>)>>,
}

impl HostRunner for &Host {
    fn run_env(
        &self,
        argv: &[String],
        stdin: &[u8],
        env: &[(&str, &str)],
    ) -> Result<Output, String> {
        let pairs: Vec<(String, String)> =
            env.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
        self.env.borrow_mut().push((argv.to_vec(), pairs));
        self.run(argv, stdin)
    }

    fn run(&self, argv: &[String], stdin: &[u8]) -> Result<Output, String> {
        let ok = |out: String| Ok(Output { code: 0, stdout: out.into(), stderr: Vec::new() });
        let a: Vec<&str> = argv.iter().map(String::as_str).collect();
        let set = |unit: &str, frozen: bool| {
            if let Some(f) = self.slices.borrow_mut().get_mut(unit) {
                *f = frozen;
            }
        };
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
                    None => "ActiveState=inactive\n",
                };
                ok(format!("{block}\n{block}"))
            }
            ["systemctl", "--user", "freeze", unit] => {
                set(unit, true);
                ok(String::new())
            }
            ["systemctl", "--user", "thaw", unit] => {
                set(unit, false);
                ok(String::new())
            }
            ["systemctl", "--user", "stop", unit] => {
                self.slices.borrow_mut().remove(*unit);
                ok(String::new())
            }
            ["systemctl", "--user", "set-property", ..] => ok(String::new()),
            ["test", "-d", dir] => Ok(Output {
                code: i32::from(!self.dirs.borrow().contains(*dir)),
                ..Output::default()
            }),
            ["cat", "--", path] => match self.files.borrow().get(*path) {
                Some(b) => Ok(Output { code: 0, stdout: b.clone(), stderr: Vec::new() }),
                None => Ok(Output { code: 1, ..Output::default() }),
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
                .map(|n| format!("{n}\n"))
                .collect()),
            other => panic!("unexpected {other:?}"),
        }
    }
}

#[test]
fn host_agent_verbs_drive_pods_and_list_reads_them_back() {
    let host = Host::default();
    let d = PodsDriver::new(PodSlots::new(&host, "/srv/pods"));
    let a = SlotName::parse("lane-a").unwrap();
    let spec = SlotSpec { vcpus: 1, memory_mib: 512, disk_gib: 40, join: None };
    assert_eq!(d.create(&a, &spec).unwrap(), SlotState::Running);
    // Idempotent, as the host agent expects of every verb.
    assert_eq!(d.create(&a, &spec).unwrap(), SlotState::Running);
    assert_eq!(d.pause(&a, PauseMode::Memory).unwrap(), SlotState::Paused);
    assert_eq!(d.resume(&a).unwrap(), SlotState::Running);
    // No RAM image: a disk pause keeps the root and reports Stopped, never Saved.
    assert_eq!(d.pause(&a, PauseMode::Disk).unwrap(), SlotState::Stopped);
    let listed = d.list().unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!((listed[0].name.as_str(), listed[0].state), ("lane-a", SlotState::Stopped));
    assert_eq!(d.resume(&a).unwrap(), SlotState::Running);
    d.destroy(&a).unwrap();
    d.destroy(&a).unwrap();
    assert!(d.list().unwrap().is_empty());
}

#[test]
fn a_hub_minted_join_token_reaches_the_pods_init_by_name_only() {
    let host = Host::default();
    let d = PodsDriver::new(PodSlots::new(&host, "/srv/pods"));
    let a = SlotName::parse("lane-j").unwrap();
    let join = crate::hypervisor::ChildJoin::new(
        "https://hub.example",
        zeroize::Zeroizing::new("cmj_child_secret".to_owned()),
    );
    let spec = SlotSpec { join: Some(join), ..SlotSpec::default() };
    assert_eq!(d.create(&a, &spec).unwrap(), SlotState::Running);
    let sent = host.env.borrow();
    assert_eq!(sent.len(), 1);
    let (argv, env) = &sent[0];
    let line = argv.join(" ");
    assert!(line.starts_with("systemd-run "), "{line}");
    assert!(line.contains("--setenv=CMUX_JOIN_TOKEN --setenv=CMUX_JOIN_HUB --"), "{line}");
    assert!(!line.contains("cmj_child_secret"), "{line}");
    assert_eq!(
        env,
        &vec![
            ("CMUX_JOIN_TOKEN".to_owned(), "cmj_child_secret".to_owned()),
            ("CMUX_JOIN_HUB".to_owned(), "https://hub.example".to_owned()),
        ]
    );
    // The spec's Debug (a log line, a panic) never shows it.
    assert!(!format!("{spec:?}").contains("cmj_child_secret"));
}
