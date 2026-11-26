use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use async_trait::async_trait;
use cmux_tui_machine_protocol::{
    CreateMachineSpec, ExecOutput, ExecRequest, MachineOperation, MachineProvider,
    MachineProviderError, MachineRunState,
};

use super::*;

#[derive(Default, Clone)]
struct FakeClock(Arc<AtomicU64>);

impl FakeClock {
    fn set(&self, ms: u64) {
        self.0.store(ms, Ordering::SeqCst);
    }
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.0.load(Ordering::SeqCst)
    }
}

type Calls = Arc<Mutex<Vec<(String, Vec<String>)>>>;

/// Records every runner call; answers `cat` from a file map.
#[derive(Default, Clone)]
struct FakeRunner {
    calls: Calls,
    files: Arc<Mutex<BTreeMap<String, Vec<u8>>>>,
    fail_start: Arc<Mutex<bool>>,
}

#[async_trait]
impl CommandRunner for FakeRunner {
    async fn run(&self, host: &str, argv: &[String], stdin: &[u8]) -> Result<ExecOutput, String> {
        self.calls.lock().unwrap().push((host.to_owned(), argv.to_vec()));
        let ok = |stdout: Vec<u8>| Ok(ExecOutput { exit_code: 0, stdout, stderr: Vec::new() });
        match argv[0].as_str() {
            "systemd-run"
                if argv.iter().any(|a| a == "infinity") && *self.fail_start.lock().unwrap() =>
            {
                Ok(ExecOutput {
                    exit_code: 1,
                    stdout: Vec::new(),
                    stderr: b"no user manager".to_vec(),
                })
            }
            "cat" => match self.files.lock().unwrap().get(&argv[2]) {
                Some(bytes) => ok(bytes.clone()),
                None => Ok(ExecOutput {
                    exit_code: 1,
                    stdout: Vec::new(),
                    stderr: b"no such file".to_vec(),
                }),
            },
            "sh" => {
                self.files.lock().unwrap().insert(argv[4].clone(), stdin.to_vec());
                ok(Vec::new())
            }
            _ => ok(Vec::new()),
        }
    }
}

type Provider = PoolPodProvider<SystemdPodRuntime<FakeRunner>, FakeClock>;

fn pool(hosts: &[(&str, u32)]) -> (Provider, FakeRunner, FakeClock) {
    let runner = FakeRunner::default();
    let clock = FakeClock::default();
    let hosts = hosts.iter().map(|(n, m)| PoolHost { name: (*n).into(), max_pods: *m }).collect();
    let runtime = SystemdPodRuntime::new(runner.clone(), "/home/cmux/pods/");
    (PoolPodProvider::with_clock("team-pool", hosts, runtime, clock.clone()), runner, clock)
}

fn spec(name: &str, labels: &[(&str, &str)]) -> CreateMachineSpec {
    CreateMachineSpec {
        name: name.into(),
        image: None,
        labels: labels.iter().map(|(k, v)| ((*k).into(), (*v).into())).collect(),
    }
}

#[tokio::test]
async fn create_spreads_pods_over_hosts_and_fills_the_pool() {
    let (p, _, _) = pool(&[("pool-host-a", 2), ("pool-host-b", 1)]);
    let a = p.create(spec("lane-a", &[])).await.unwrap();
    let b = p.create(spec("lane-b", &[])).await.unwrap();
    let c = p.create(spec("lane-c", &[])).await.unwrap();
    assert_eq!(p.host_of(&a).unwrap(), "pool-host-a");
    assert_eq!(p.host_of(&b).unwrap(), "pool-host-b");
    assert_eq!(p.host_of(&c).unwrap(), "pool-host-a");
    let err = p.create(spec("lane-d", &[])).await.unwrap_err();
    assert_eq!(err, MachineProviderError::Backend("pool team-pool is full".into()));
    p.delete(&b).await.unwrap();
    let d = p.create(spec("lane-d", &[])).await.unwrap();
    assert_eq!(p.host_of(&d).unwrap(), "pool-host-b");
}

#[tokio::test]
async fn host_label_pins_and_unknown_host_is_refused() {
    let (p, _, _) = pool(&[("h1", 1), ("h2", 1)]);
    let a = p.create(spec("x", &[(LABEL_HOST, "h2")])).await.unwrap();
    assert_eq!(p.host_of(&a).unwrap(), "h2");
    assert!(matches!(
        p.create(spec("y", &[(LABEL_HOST, "h2")])).await,
        Err(MachineProviderError::Backend(_))
    ));
    assert!(matches!(
        p.create(spec("y", &[(LABEL_HOST, "nope")])).await,
        Err(MachineProviderError::InvalidInput(_))
    ));
}

#[tokio::test]
async fn failed_start_releases_the_slot() {
    let (p, runner, _) = pool(&[("h1", 1)]);
    *runner.fail_start.lock().unwrap() = true;
    let err = p.create(spec("x", &[])).await.unwrap_err();
    assert!(
        matches!(err, MachineProviderError::Backend(ref m) if m.contains("no user manager")),
        "{err:?}"
    );
    assert_eq!(p.free_slots().unwrap(), vec![("h1".to_owned(), 1)]);
}

#[tokio::test]
async fn pause_freezes_the_slice_and_exec_waits_for_resume() {
    let (p, runner, _) = pool(&[("h1", 1)]);
    let m = p.create(spec("Lane A", &[])).await.unwrap();
    p.pause(&m).await.unwrap();
    p.pause(&m).await.unwrap(); // idempotent: one freeze
    let req = ExecRequest { program: "true".into(), ..Default::default() };
    assert_eq!(
        p.exec(&m, req.clone()).await.unwrap_err(),
        MachineProviderError::InvalidState {
            operation: MachineOperation::Exec,
            state: MachineRunState::Paused
        }
    );
    // Files are on the host's disk: they work while paused.
    p.write_file(&m, "notes/a.txt", b"hi").await.unwrap();
    assert_eq!(p.read_file(&m, "/notes/a.txt").await.unwrap(), b"hi");
    p.resume(&m).await.unwrap();
    p.exec(&m, req).await.unwrap();
    let calls = runner.calls.lock().unwrap();
    let freezes =
        calls.iter().filter(|(_, a)| a.get(2).map(String::as_str) == Some("freeze")).count();
    assert_eq!(freezes, 1);
    assert!(
        calls.iter().any(|(_, a)| a == &["systemctl", "--user", "thaw", "cmux_pod_lane_a_1.slice"])
    );
}

#[tokio::test]
async fn bad_paths_never_reach_the_host() {
    let (p, runner, _) = pool(&[("h1", 1)]);
    let m = p.create(spec("x", &[])).await.unwrap();
    let before = runner.calls.lock().unwrap().len();
    for bad in ["", "/", "../etc/passwd", "a/../../b", "a//b", "./a"] {
        assert!(
            matches!(p.read_file(&m, bad).await, Err(MachineProviderError::InvalidInput(_))),
            "{bad}"
        );
    }
    assert_eq!(runner.calls.lock().unwrap().len(), before);
}

#[tokio::test]
async fn meter_bills_running_time_only() {
    let (p, _, clock) = pool(&[("h1", 2)]);
    clock.set(1_000);
    let m = p.create(spec("x", &[(LABEL_LANE, "fleet/lane-x")])).await.unwrap();
    clock.set(4_000);
    p.pause(&m).await.unwrap();
    clock.set(10_000);
    p.resume(&m).await.unwrap();
    clock.set(12_000);
    let drained = p.drain_meter().unwrap();
    assert_eq!(drained.iter().map(MeterInterval::duration_ms).sum::<u64>(), 5_000);
    assert_eq!(drained.iter().map(MeterInterval::vcpu_ms).sum::<u64>(), 10_000);
    assert_eq!(drained.iter().map(MeterInterval::memory_mib_ms).sum::<u64>(), 5_000 * 4096);
    assert!(drained.iter().all(|i| i.lane.as_deref() == Some("fleet/lane-x") && i.host == "h1"));
    clock.set(15_000);
    p.delete(&m).await.unwrap();
    let rest = p.drain_meter().unwrap();
    assert_eq!(rest.len(), 1);
    assert_eq!((rest[0].started_ms, rest[0].ended_ms), (12_000, 15_000));
    assert!(p.drain_meter().unwrap().is_empty());
}

#[tokio::test]
async fn capabilities_match_behaviour() {
    let (p, _, _) = pool(&[("h1", 1)]);
    let caps = p.capabilities();
    let m = p.create(spec("x", &[])).await.unwrap();
    assert!(!caps.snapshot && !caps.fork && !caps.exposed_ports && caps.fs_while_paused);
    assert_eq!(
        p.snapshot(&m).await.unwrap_err(),
        MachineProviderError::Unsupported(MachineOperation::Snapshot)
    );
    assert_eq!(
        p.exposed_ports(&m).await.unwrap_err(),
        MachineProviderError::Unsupported(MachineOperation::ExposedPorts)
    );
    assert!(matches!(
        p.create(CreateMachineSpec { image: Some("ubuntu".into()), ..spec("y", &[]) }).await,
        Err(MachineProviderError::InvalidInput(_))
    ));
}

#[test]
fn exec_runs_in_the_pod_slice_inside_bwrap() {
    let rt = SystemdPodRuntime::new(FakeRunner::default(), "/home/cmux/pods");
    let pod = PodSpec {
        id: "lane-a-1".into(),
        host: "h1".into(),
        size: PodSize::default(),
        labels: BTreeMap::new(),
    };
    let req = ExecRequest {
        program: "acpmux".into(),
        args: vec!["daemon".into()],
        env: [("HOME".to_owned(), "/home/cmux/pods/lane-a-1".to_owned())].into(),
        cwd: None,
        stdin: Vec::new(),
    };
    let argv = rt.exec_argv(&pod, &req);
    let joined = argv.join(" ");
    assert!(joined.starts_with("systemd-run --user --quiet --collect --wait --pipe --expand-environment=no --slice=cmux_pod_lane_a_1.slice --setenv=HOME=/home/cmux/pods/lane-a-1 -- bwrap "));
    assert!(joined.contains("--tmpfs /home/cmux/pods --bind /home/cmux/pods/lane-a-1 /home/cmux/pods/lane-a-1 --setenv CMUX_POD_ROOT /home/cmux/pods/lane-a-1 --chdir /home/cmux/pods/lane-a-1 -- acpmux daemon"));
    assert_eq!(
        rt.start_argv(&pod)[2],
        [
            "systemctl",
            "--user",
            "set-property",
            "--runtime",
            "cmux_pod_lane_a_1.slice",
            "CPUQuota=200%",
            "MemoryMax=4096M"
        ]
    );
    assert_eq!(
        rt.stop_argv(&pod).last().unwrap(),
        &["rm", "-rf", "--", "/home/cmux/pods/lane-a-1"]
    );
}

#[test]
fn sanitize_makes_unit_safe_names() {
    assert_eq!(sanitize("pool-host-a/Fleet Pool!"), "pool-host-a-fleet-pool");
    assert_eq!(sanitize("!!!"), "pod");
}

/// A pod's own `acpmux` refuses a state dir with an ancestor owned by another user, and in
/// unprivileged `bwrap`'s user namespace a host root-owned dir reads as the overflow uid. So the
/// pod binds the system dirs, never `/`, and every ancestor of its root is the pod user's.
#[test]
fn a_pods_root_and_every_ancestor_are_the_pod_users_own() {
    let argv = bwrap_argv("/p/pods", "/p/pods/a", "/p/pods/a", &[], "/opt/x/acpmux", &[]);
    let pairs: Vec<_> = argv.windows(3).map(|w| (w[0].as_str(), w[1].as_str())).collect();
    assert!(!pairs.iter().any(|(flag, src)| flag.contains("bind") && *src == "/"), "{argv:?}");
    for dir in ["/usr", "/etc", "/opt/x/acpmux"] {
        assert!(pairs.contains(&("--ro-bind-try", dir)), "{dir}: {argv:?}");
    }

    // Live where the host has bwrap and unprivileged user namespaces.
    let base = std::env::temp_dir().join(format!("cmux-pod-ancestors-{}", std::process::id()));
    let pods = base.join("pods");
    let root = pods.join("a");
    std::fs::create_dir_all(&root).unwrap();
    let (pods, root) = (pods.to_str().unwrap(), root.to_str().unwrap());
    let script = format!(
        "p={root}; while :; do stat -c '%u %n' \"$p\"; [ \"$p\" = / ] && break; p=$(dirname \"$p\"); done"
    );
    let argv = bwrap_argv(pods, root, root, &[], "/bin/sh", &["-c".into(), script]);
    let out = std::process::Command::new(&argv[0]).args(&argv[1..]).output();
    let Ok(out) = out.inspect_err(|_| drop(std::fs::remove_dir_all(&base))) else {
        eprintln!("no bwrap here; the argv check above stands");
        return;
    };
    if !out.status.success() {
        std::fs::remove_dir_all(&base).unwrap();
        eprintln!("bwrap cannot run here: {}", String::from_utf8_lossy(&out.stderr));
        return;
    }
    use std::os::unix::fs::MetadataExt;
    let uid = std::fs::metadata(&base).unwrap().uid();
    std::fs::remove_dir_all(&base).unwrap();
    let lines = String::from_utf8(out.stdout).unwrap();
    assert!(lines.lines().any(|l| l.ends_with(" /")), "{lines}");
    for line in lines.lines() {
        assert!(line.starts_with(&format!("{uid} ")), "not the pod user's: {line}\n{lines}");
    }
}
