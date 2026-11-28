//! Apps under heavy machine load (`load_bench`): every core busy four
//! times over plus disk writes with fsync, as on a Mac building cmux while
//! agents run. It measures what a person waits on when they save an
//! extension or open its view: a host spawn, a mount, an install, a save
//! reaching the open view through the real file watch, and `apps-list`
//! answered meanwhile (it waits only on the supervisor lock, so its latency
//! is how long the lock was held). Load must have no bearing on any of them.
//!
//! The bench is slow, so it runs only when asked: `CMUX_APPS_LOAD_BENCH=1`,
//! or a plain `cargo test` whose filter names `load_bench` (the fleet's
//! `scripts/measure/rust-test-bench.sh`). nextest's own `--exact` run skips it.
//! It prints one `APPS-LOAD-BENCH` JSON line per scenario.

use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::JoinHandle;

use super::*;

fn bench_selected() -> bool {
    if std::env::var_os("CMUX_APPS_LOAD_BENCH").is_some_and(|v| v == "1") {
        return true;
    }
    let args: Vec<String> = std::env::args().collect();
    args.iter().skip(1).any(|a| a.contains("load_bench")) && !args.iter().any(|a| a == "--exact")
}

/// Busy processes (four per core) and two threads writing and fsyncing
/// 8 MiB files. Dropping it stops and reaps what it started.
struct Load {
    busy: Vec<Child>,
    stop: Arc<AtomicBool>,
    disk: Vec<JoinHandle<()>>,
    _dir: TempDir,
}

impl Load {
    fn start() -> Self {
        let cores = std::thread::available_parallelism().map_or(4, |n| n.get());
        let busy = (0..cores * 4)
            .map(|_| {
                Command::new("/bin/sh")
                    .args(["-c", "while :; do :; done"])
                    .stdin(Stdio::null())
                    .stdout(Stdio::null())
                    .stderr(Stdio::null())
                    .spawn()
                    .expect("busy process")
            })
            .collect();
        let stop = Arc::new(AtomicBool::new(false));
        let dir = temp_dir();
        let disk = (0..2)
            .map(|n| {
                let stop = stop.clone();
                let path = dir.0.join(format!("disk-{n}"));
                std::thread::spawn(move || {
                    use std::io::Write as _;
                    let block = vec![0x5a_u8; 8 << 20];
                    while !stop.load(Ordering::Relaxed) {
                        if let Ok(mut file) = std::fs::File::create(&path) {
                            let _ = file.write_all(&block);
                            let _ = file.sync_all();
                        }
                    }
                })
            })
            .collect();
        // Let the scheduler fill up before the first sample.
        std::thread::sleep(Duration::from_millis(500));
        Self { busy, stop, disk, _dir: dir }
    }
}

impl Drop for Load {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        for child in &mut self.busy {
            let _ = child.kill();
            let _ = child.wait();
        }
        for thread in self.disk.drain(..) {
            let _ = thread.join();
        }
    }
}

/// Milliseconds, as sampled.
#[derive(Default)]
pub(super) struct Samples(pub(super) Vec<f64>);

impl Samples {
    pub(super) fn push(&mut self, since: Instant) {
        self.0.push(since.elapsed().as_secs_f64() * 1000.0);
    }

    pub(super) fn summary(&self) -> Value {
        let mut v = self.0.clone();
        v.sort_by(f64::total_cmp);
        let at = |q: f64| {
            if v.is_empty() {
                return 0.0;
            }
            let i = ((v.len() - 1) as f64 * q).round() as usize;
            (v[i] * 10.0).round() / 10.0
        };
        json!({ "n": v.len(), "p50": at(0.5), "p90": at(0.9), "p95": at(0.95), "max": at(1.0) })
    }
}

/// Calls `apps-list` every 2 ms on its own thread until stopped. Its
/// latency is how long it waited for the supervisor lock.
pub(super) struct ListProbe {
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<Samples>>,
}

impl ListProbe {
    pub(super) fn start(supervisor: &Arc<Supervisor>) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let supervisor = supervisor.clone();
        let flag = stop.clone();
        let thread = std::thread::spawn(move || {
            let mut samples = Samples::default();
            while !flag.load(Ordering::Relaxed) {
                let start = Instant::now();
                let _ = supervisor.list();
                samples.push(start);
                std::thread::sleep(Duration::from_millis(2));
            }
            samples
        });
        Self { stop, thread: Some(thread) }
    }

    pub(super) fn finish(mut self) -> Samples {
        self.stop.store(true, Ordering::Relaxed);
        self.thread.take().expect("probe").join().expect("probe thread")
    }
}

fn report(scenario: &str, loaded: bool, fields: Value) {
    let mut line = json!({
        "scenario": scenario,
        "load": if loaded { "heavy" } else { "idle" },
        "cores": std::thread::available_parallelism().map_or(0, |n| n.get()),
        "os": std::env::consts::OS,
    });
    if let (Some(line), Some(fields)) = (line.as_object_mut(), fields.as_object()) {
        line.extend(fields.clone());
    }
    println!("APPS-LOAD-BENCH {line}");
}

const SPAWNS: usize = 12;
const APPS: usize = 8;
const SAVES: usize = 6;

/// A host spawn alone: the call's own time and the time to its first answer.
fn spawn_scenario(loaded: bool) {
    let f = fixture();
    let binary = f.supervisor_host_binary();
    let args = f.supervisor_host_args();
    let (mut call, mut ready) = (Samples::default(), Samples::default());
    for n in 0..SPAWNS {
        let (tx, rx) = channel();
        let start = Instant::now();
        let process = super::super::host::HostProcess::spawn(
            &binary,
            &args,
            &format!("bench-{n}"),
            move |message| {
                if matches!(message, FromHost::Ready { .. }) {
                    let _ = tx.send(());
                }
            },
            |_| {},
        )
        .expect("spawn");
        call.push(start);
        process.send(&ToHost::Init {
            app: cmux_app_host::AppInfo { id: "local/bench".into(), version: "1.0.0".into() },
            settings: json!({}),
            api_version: "1.0.0".into(),
            ops: None,
            known_ops: None,
            locale: None,
            strings: Value::Null,
            main: String::new(),
            main_name: None,
            state: None,
        });
        rx.recv_timeout(Duration::from_secs(60)).expect("ready");
        ready.push(start);
        process.kill();
    }
    report("host_spawn", loaded, json!({ "call_ms": call.summary(), "ready_ms": ready.summary() }));
}

/// Installs then mounts `APPS` local apps, each mount starting a host,
/// with `apps-list` probing the lock throughout.
fn mount_scenario(loaded: bool) {
    let f = fixture();
    let local = f.state.join("apps/local");
    for n in 0..APPS {
        write_app(&local, &format!("bench{n}"), &format!("local/bench{n}"), json!({}));
    }
    f.supervisor.reload_local_apps(&Default::default());
    let probe = ListProbe::start(&f.supervisor);
    let mut install = Samples::default();
    for n in 0..APPS {
        let start = Instant::now();
        f.install(&format!("local/bench{n}"));
        install.push(start);
    }
    let install_list = probe.finish();
    let probe = ListProbe::start(&f.supervisor);
    let (mut call, mut scene) = (Samples::default(), Samples::default());
    for n in 0..APPS {
        let id = format!("m{n}");
        let start = Instant::now();
        f.supervisor
            .mount(CLIENT, &id, &format!("local/bench{n}"), "cmux.section/1", json!({}))
            .unwrap();
        call.push(start);
        f.wait("first scene", |e| e["event"] == "apps-scene" && e["mount_id"] == id);
        scene.push(start);
    }
    let mount_list = probe.finish();
    report(
        "install",
        loaded,
        json!({ "call_ms": install.summary(), "list_ms": install_list.summary() }),
    );
    report(
        "mount",
        loaded,
        json!({ "call_ms": call.summary(), "scene_ms": scene.summary(), "list_ms": mount_list.summary() }),
    );
}

/// A save of an app whose view is open, through the real file watch: the
/// time to `apps-changed` and to the open view's new scene.
fn reload_scenario(loaded: bool) {
    let f = fixture();
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/spy");
    f.mount("m1", "local/spy", "cmux.section/1", json!({}));
    f.supervisor.start_local_watch_for_test();
    // The watch reads once as it starts; let that settle.
    std::thread::sleep(Duration::from_millis(500));
    while f.events.try_recv().is_ok() {}
    let probe = ListProbe::start(&f.supervisor);
    let (mut changed, mut scene) = (Samples::default(), Samples::default());
    for n in 0..SAVES {
        let path = f.state.join("apps/local/spy/cmux-app.json");
        let mut manifest: Value =
            serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let export = format!("render{n}");
        manifest["version"] = json!(format!("1.0.{}", n + 1));
        manifest["implements"]["cmux.section/1"]["export"] = json!(export);
        let start = Instant::now();
        std::fs::write(&path, manifest.to_string()).unwrap();
        let deadline = start + Duration::from_secs(60);
        let (mut saw_changed, mut saw_scene) = (false, false);
        while !(saw_changed && saw_scene) {
            let left = deadline.saturating_duration_since(Instant::now());
            let event = f.events.recv_timeout(left).expect("the save reached the view");
            if !saw_changed && event["event"] == "apps-changed" && event["app"] == "local/spy" {
                saw_changed = true;
                changed.push(start);
            }
            if !saw_scene
                && event["event"] == "apps-scene"
                && event["mount_id"] == "m1"
                && event["ops"][0]["op"] == "create"
                && event["ops"][0]["props"]["text"] == export.as_str()
            {
                saw_scene = true;
                scene.push(start);
            }
        }
    }
    let list = probe.finish();
    report(
        "save_reload",
        loaded,
        json!({ "changed_ms": changed.summary(), "scene_ms": scene.summary(), "list_ms": list.summary() }),
    );
}

/// A host that is slow to start (fork, exec and the loader on a loaded
/// machine) holds up neither the mount call nor any other apps request:
/// they answer at once and the view renders when the host is up (base red:
/// the start ran under the supervisor lock, inside the mount call, so
/// `apps-list` and every later request on the app's connection waited for it).
#[test]
fn a_slow_host_start_holds_up_neither_the_mount_nor_apps_list() {
    let f = fixture();
    write_app(&f.state.join("apps/local"), "slowstart", "local/slowstart", json!({}));
    f.supervisor.reload_local_apps(&Default::default());
    f.install("local/slowstart");
    super::super::host::test_seams::pause_next_spawn("local/slowstart", Duration::from_secs(3));
    let supervisor = f.supervisor.clone();
    let mounting = std::thread::spawn(move || {
        let start = Instant::now();
        supervisor.mount(CLIENT, "m1", "local/slowstart", "cmux.section/1", json!({})).unwrap();
        start.elapsed()
    });
    std::thread::sleep(Duration::from_millis(300));
    let start = Instant::now();
    let _ = f.supervisor.list();
    let list = start.elapsed();
    let mount = mounting.join().unwrap();
    assert!(list < Duration::from_secs(1), "apps-list waited {list:?} behind a host start");
    assert!(mount < Duration::from_secs(1), "apps-mount waited {mount:?} for its host to start");
    f.wait("the view's first scene", |e| e["event"] == "apps-scene" && e["mount_id"] == "m1");
}

/// A slow `apps.json` write (an fsync behind a busy disk) holds up only the
/// install that waits for it: `apps-list` answers meanwhile, and a second
/// install in that time is kept with the first, in memory and on disk (base
/// red: the write ran under the supervisor lock).
#[test]
fn a_slow_apps_json_write_holds_up_only_its_own_install() {
    let f = fixture();
    write_app(&f.state.join("apps/local"), "slowsave", "local/slowsave", json!({}));
    f.supervisor.reload_local_apps(&Default::default());
    super::super::supervisor::pause_next_persist(&f.state, Duration::from_secs(3));
    let install = |app: &str| {
        let supervisor = f.supervisor.clone();
        let op = SetOp {
            key: format!("install-{app}"),
            app: app.into(),
            origin: Origin::User,
            installed: Some(true),
            ..SetOp::default()
        };
        std::thread::spawn(move || supervisor.set(CLIENT, op).map(|_| ()))
    };
    let slow = install("local/slowsave");
    std::thread::sleep(Duration::from_millis(300));
    let second = install("local/spy");
    let start = Instant::now();
    let _ = f.supervisor.list();
    let list = start.elapsed();
    slow.join().unwrap().unwrap();
    second.join().unwrap().unwrap();
    assert!(list < Duration::from_secs(1), "apps-list waited {list:?} behind an apps.json write");
    let listed = f.supervisor.list();
    let saved = std::fs::read_to_string(f.state.join("apps.json")).unwrap();
    for app in ["local/slowsave", "local/spy"] {
        assert_eq!(app_entry(&listed, app)["installed"], true, "{app} is installed");
        assert!(saved.contains(&format!("\"{app}\"")), "{app} is in apps.json");
    }
}

#[test]
fn load_bench() {
    if !bench_selected() {
        return;
    }
    // As the daemon runs: its open-file limit raised (owner_start.rs), and a
    // hundred threads of its own.
    let limit = crate::raise_open_file_limit(crate::OPEN_FILE_LIMIT_CEILING);
    println!("APPS-LOAD-BENCH-SETUP open-file limit {limit:?}");
    let (_park, parked) = channel::<()>();
    let parked = Arc::new(Mutex::new(parked));
    let _threads: Vec<_> = (0..100)
        .map(|_| {
            let parked = parked.clone();
            std::thread::spawn(move || drop(parked.lock().map(|rx| rx.recv())))
        })
        .collect();
    for loaded in [false, true] {
        let _load = loaded.then(Load::start);
        spawn_scenario(loaded);
        mount_scenario(loaded);
        reload_scenario(loaded);
    }
}

impl Fixture {
    fn supervisor_host_binary(&self) -> PathBuf {
        std::env::current_exe().unwrap()
    }

    fn supervisor_host_args(&self) -> Vec<String> {
        [
            "--ignored",
            "--exact",
            "apps::supervisor_tests::scripted_app_host",
            "--test-threads=1",
            "-q",
        ]
        .map(String::from)
        .to_vec()
    }
}
