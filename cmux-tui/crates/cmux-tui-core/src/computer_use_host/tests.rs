//! The supervisor with an in-process worker (the real control channel and
//! agent socket, the fake desktop).

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::sync::atomic::AtomicUsize;
use std::sync::mpsc;

use cmux_computer_use::desktop::fake::FakeDesktop;
use cmux_computer_use::worker::{self, Platform};

use super::*;

fn fake() -> Result<Platform, String> {
    Ok(Platform {
        desktop: Arc::new(FakeDesktop::standard()),
        cursor: Arc::new(cmux_computer_use::cursor::NoCursor),
        takeover: Arc::new(cmux_computer_use::engine::NoTakeover),
    })
}

#[derive(Default)]
struct InProcess {
    launches: AtomicUsize,
    refuse: Option<String>,
}

impl Launcher for InProcess {
    fn launch(&self, _log: &Path) -> Result<WorkerProcess, String> {
        if let Some(reason) = &self.refuse {
            return Err(reason.clone());
        }
        self.launches.fetch_add(1, Ordering::SeqCst);
        let (in_r, in_w) = std::io::pipe().map_err(|e| e.to_string())?;
        let (out_r, out_w) = std::io::pipe().map_err(|e| e.to_string())?;
        let worker = std::thread::spawn(move || {
            worker::run(BufReader::new(in_r), out_w, fake, Duration::from_secs(10))
        });
        Ok(WorkerProcess {
            input: Box::new(in_w),
            output: Box::new(out_r),
            reap: Box::new(move || {
                let _ = worker.join();
            }),
        })
    }
}

struct Fixture {
    host: ComputerUseHost,
    launcher: Arc<InProcess>,
    dir: PathBuf,
}

impl Drop for Fixture {
    fn drop(&mut self) {
        Inner::stop(&self.host.inner);
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn fixture(tag: &str, mode: Mode, launcher: InProcess) -> Fixture {
    let dir = PathBuf::from(format!("/tmp/cuh{tag}{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let paths = Paths {
        endpoint: dir.join("r").join("cu.sock").display().to_string(),
        state: dir.join("state"),
        log: dir.join("worker.log"),
    };
    let host = ComputerUseHost::default();
    let launcher = Arc::new(launcher);
    let config = PolicyConfig { mode, ..PolicyConfig::default() };
    host.configure(paths, launcher.clone(), "box".into(), config, config::Source::Settings);
    Fixture { host, launcher, dir }
}

fn agent(endpoint: &Value) -> (UnixStream, BufReader<UnixStream>) {
    let stream = UnixStream::connect(endpoint["socket"].as_str().unwrap()).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    writeln!(writer, "{}", json!({"secret": endpoint["secret"]})).unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "{line}");
    (writer, reader)
}

fn recv(reader: &mut BufReader<UnixStream>) -> Value {
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// Waits (bounded) until the phase satisfies `done`.
fn wait_phase(host: &ComputerUseHost, done: impl Fn(&Phase) -> bool) {
    let guard = lock(&host.inner.phase);
    let (guard, timeout) = host
        .inner
        .changed
        .wait_timeout_while(guard, Duration::from_secs(10), |phase| !done(phase))
        .unwrap();
    assert!(!timeout.timed_out(), "phase stayed {:?}", *guard);
}

#[test]
fn endpoint_starts_the_worker_once_and_agents_reach_it() {
    let f = fixture("start", Mode::FullAccess, InProcess::default());
    let endpoint = f.host.endpoint(ENDPOINT_WAIT);
    assert_eq!(endpoint["state"], "ready", "{endpoint}");
    assert_eq!(endpoint["secret"].as_str().unwrap().len(), 64);
    let again = f.host.endpoint(ENDPOINT_WAIT);
    assert_eq!(again, endpoint);
    assert_eq!(f.launcher.launches.load(Ordering::SeqCst), 1);
    let (mut w, mut r) = agent(&endpoint);
    writeln!(
        w,
        "{}",
        json!({"id": 1, "method": "tools/call", "name": "click", "session": "s",
        "arguments": {"window_id": "1", "element_id": "e1"}, "call_id": "c"})
    )
    .unwrap();
    assert_eq!(recv(&mut r)["result"]["is_error"], false);
    assert_eq!(f.host.status()["state"], "ready");
}

#[test]
fn a_crashed_worker_restarts_with_a_new_secret_and_keeps_grants() {
    let f = fixture("crash", Mode::FullAccess, InProcess::default());
    let first = f.host.endpoint(ENDPOINT_WAIT);
    f.host.edit_approvals("never", "com.example.Never").unwrap();
    // The worker goes away under the agent (its control channel ends).
    lock(&f.host.inner.link).clone().unwrap().close();
    let old = first["secret"].as_str().unwrap().to_string();
    wait_phase(&f.host, |p| matches!(p, Phase::Ready { secret, .. } if *secret != old));
    assert_eq!(f.launcher.launches.load(Ordering::SeqCst), 2);
    let list = f.host.list_approvals().unwrap();
    assert_eq!(list["saved"]["never"], json!(["com.example.Never"]), "{list}");
    let second = f.host.endpoint(ENDPOINT_WAIT);
    assert_eq!(second["socket"], first["socket"]);
    agent(&second);
}

#[test]
fn off_stops_the_worker_and_answers_off() {
    let f = fixture("off", Mode::FullAccess, InProcess::default());
    assert_eq!(f.host.endpoint(ENDPOINT_WAIT)["state"], "ready");
    f.host.set_config(
        PolicyConfig { mode: Mode::Off, ..PolicyConfig::default() },
        config::Source::Settings,
    );
    assert_eq!(f.host.endpoint(ENDPOINT_WAIT)["state"], "off");
    assert!(lock(&f.host.inner.link).is_none());
    // On again: a new worker.
    f.host.set_config(PolicyConfig::default(), config::Source::Settings);
    assert_eq!(f.host.endpoint(ENDPOINT_WAIT)["state"], "ready");
    assert_eq!(f.launcher.launches.load(Ordering::SeqCst), 2);
}

#[test]
fn no_desktop_is_unavailable_with_the_reason() {
    let launcher =
        InProcess { refuse: Some("no graphical session here".into()), ..InProcess::default() };
    let f = fixture("nodisp", Mode::FullAccess, launcher);
    let endpoint = f.host.endpoint(ENDPOINT_WAIT);
    assert_eq!(endpoint, json!({"state": "unavailable", "reason": "no graphical session here"}));
}

#[test]
fn questions_go_to_the_app_and_its_answer_back_to_the_worker() {
    let f = fixture("ask", Mode::AskEveryTime, InProcess::default());
    let (tx, rx) = mpsc::channel::<u64>();
    let tx = Mutex::new(tx);
    f.host.set_router(Arc::new(move |ask: &PendingAsk| {
        tx.lock().unwrap().send(ask.id).unwrap();
        true
    }));
    let endpoint = f.host.endpoint(ENDPOINT_WAIT);
    let (mut w, mut r) = agent(&endpoint);
    writeln!(
        w,
        "{}",
        json!({"id": 1, "method": "tools/call", "name": "click", "session": "s",
        "label": "Codex", "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    let id = rx.recv_timeout(Duration::from_secs(10)).unwrap();
    let pending = f.host.pending();
    assert_eq!(pending[0]["question"]["app"]["id"], "com.apple.Safari", "{pending:?}");
    assert_eq!(pending[0]["question"]["agent"], "Codex");
    f.host.answer(id, "allow_once").unwrap();
    assert_eq!(recv(&mut r)["result"]["is_error"], false);
    assert!(f.host.answer(id, "allow_once").is_err());
    // No app to ask: refused at once.
    f.host.set_router(Arc::new(|_: &PendingAsk| false));
    writeln!(
        w,
        "{}",
        json!({"id": 2, "method": "tools/call", "name": "click", "session": "s2",
        "arguments": {"window_id": "1", "element_id": "e1"}})
    )
    .unwrap();
    let refused = recv(&mut r);
    assert_eq!(refused["result"]["is_error"], true, "{refused}");
    assert!(f.host.pending().is_empty());
}

#[test]
fn a_new_policy_reaches_the_running_worker() {
    let f = fixture("cfg", Mode::FullAccess, InProcess::default());
    let endpoint = f.host.endpoint(ENDPOINT_WAIT);
    f.host.set_config(
        PolicyConfig { mode: Mode::LookOnly, ..PolicyConfig::default() },
        config::Source::App,
    );
    // A control round trip: the worker applied the config line before it.
    f.host.list_approvals().unwrap();
    let (mut w, mut r) = agent(&endpoint);
    writeln!(w, "{}", json!({"id": 1, "method": "status"})).unwrap();
    assert_eq!(recv(&mut r)["result"]["body"]["mode"], "lookOnly");
    assert_eq!(f.host.status()["config_source"], "app");
}
