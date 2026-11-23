//! Fakes for every effect in `cmux_apps::io`.
#![allow(dead_code)]

use std::cell::{Cell, RefCell};
use std::collections::{BTreeMap, BTreeSet};
use std::io;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_apps::infer::{Inferred, infer};
use cmux_apps::io::{
    Answered, AppsTransport, Clock, Fs, Git, Listeners, Probe, Procs, Start, Started, Unanswered,
};
use cmux_apps::platform::PlatformClient;
use cmux_apps::publish::Host;
use serde_json::{Value, json};

#[derive(Default)]
pub struct FakeFs {
    pub files: RefCell<BTreeMap<PathBuf, Vec<u8>>>,
    pub links: RefCell<BTreeMap<PathBuf, PathBuf>>,
}

impl FakeFs {
    pub fn file(&self, path: &str, bytes: &[u8]) {
        self.files.borrow_mut().insert(PathBuf::from(path), bytes.to_vec());
    }

    pub fn link(&self, path: &str, target: &str) {
        self.links.borrow_mut().insert(PathBuf::from(path), PathBuf::from(target));
    }

    pub fn text(&self, path: &Path) -> Option<String> {
        self.files.borrow().get(path).map(|b| String::from_utf8_lossy(b).into_owned())
    }
}

fn missing() -> io::Error {
    io::Error::new(io::ErrorKind::NotFound, "missing")
}

impl Fs for FakeFs {
    fn read(&self, path: &Path) -> io::Result<Vec<u8>> {
        self.files.borrow().get(path).cloned().ok_or_else(missing)
    }

    fn read_link(&self, path: &Path) -> io::Result<PathBuf> {
        self.links.borrow().get(path).cloned().ok_or_else(missing)
    }

    fn list(&self, dir: &Path) -> io::Result<Vec<String>> {
        let mut names = BTreeSet::new();
        let files = self.files.borrow();
        let links = self.links.borrow();
        for path in files.keys().chain(links.keys()) {
            if let Ok(rest) = path.strip_prefix(dir)
                && let Some(first) = rest.components().next()
            {
                names.insert(first.as_os_str().to_string_lossy().into_owned());
            }
        }
        if names.is_empty() { Err(missing()) } else { Ok(names.into_iter().collect()) }
    }

    fn write(&self, path: &Path, bytes: &[u8]) -> io::Result<()> {
        self.files.borrow_mut().insert(path.to_path_buf(), bytes.to_vec());
        Ok(())
    }
}

pub const HEAD: &str = "1111111111111111111111111111111111111111";
pub const SNAPSHOT: &str = "2222222222222222222222222222222222222222";

pub struct FakeGit {
    pub repo: PathBuf,
    pub dirty: Cell<bool>,
    pub snapshots: RefCell<Vec<String>>,
    pub archives: RefCell<Vec<(String, PathBuf)>>,
}

impl FakeGit {
    pub fn new(repo: &str) -> FakeGit {
        FakeGit {
            repo: PathBuf::from(repo),
            dirty: Cell::new(false),
            snapshots: RefCell::default(),
            archives: RefCell::default(),
        }
    }
}

impl Git for FakeGit {
    fn toplevel(&self, dir: &Path) -> Result<PathBuf, String> {
        if dir.starts_with(&self.repo) {
            Ok(self.repo.clone())
        } else {
            Err("not a git repository".into())
        }
    }

    fn resolve(&self, _repo: &Path, rev: &str) -> Result<String, String> {
        if rev == "HEAD" { Ok(HEAD.into()) } else { Ok(format!("{rev:0>40}")) }
    }

    fn dirty(&self, _repo: &Path) -> Result<bool, String> {
        Ok(self.dirty.get())
    }

    fn snapshot(&self, _repo: &Path, refname: &str, _message: &str) -> Result<String, String> {
        self.snapshots.borrow_mut().push(refname.to_owned());
        Ok(SNAPSHOT.into())
    }

    fn archive(&self, _repo: &Path, commit: &str, dest: &Path) -> Result<(), String> {
        self.archives.borrow_mut().push((commit.to_owned(), dest.to_path_buf()));
        Ok(())
    }
}

/// One `apps.spawn` the agent got.
#[derive(Debug, Clone)]
pub struct Spawned {
    pub slug: String,
    pub version: u32,
    pub version_dir: PathBuf,
    pub subdir: String,
    pub command: String,
    pub setup: Option<String>,
    pub port: u16,
    pub env: Vec<(String, String)>,
    pub restart: bool,
}

/// This machine's agent's `apps.spawn`, `apps.status` and `apps.stop`, by pid.
pub struct FakeProcs {
    pub next_pid: Cell<u32>,
    pub port: Cell<u16>,
    pub spawned: RefCell<Vec<Spawned>>,
    /// The pid each version was last started as.
    pub pids: RefCell<BTreeMap<(String, u32), u32>>,
    pub stopped: RefCell<Vec<u32>>,
    pub dead: RefCell<BTreeSet<u32>>,
    pub taken_ports: RefCell<BTreeSet<u16>>,
    /// The agent's refusal of every start (it can't make or switch to the app user).
    pub refusal: RefCell<Option<String>>,
}

impl Default for FakeProcs {
    fn default() -> Self {
        FakeProcs {
            next_pid: Cell::new(500),
            port: Cell::new(41000),
            spawned: RefCell::default(),
            pids: RefCell::default(),
            stopped: RefCell::default(),
            dead: RefCell::default(),
            taken_ports: RefCell::default(),
            refusal: RefCell::default(),
        }
    }
}

impl Procs for FakeProcs {
    fn start(&self, start: &Start<'_>) -> Result<Started, String> {
        if let Some(refusal) = self.refusal.borrow().clone() {
            return Err(refusal);
        }
        self.spawned.borrow_mut().push(Spawned {
            slug: start.slug.to_owned(),
            version: start.version,
            version_dir: start.version_dir.to_path_buf(),
            subdir: start.subdir.to_owned(),
            command: start.command.to_owned(),
            setup: start.setup.map(str::to_owned),
            port: start.port,
            env: start.env.to_vec(),
            restart: start.restart,
        });
        let pid = self.next_pid.get();
        self.next_pid.set(pid + 1);
        self.pids.borrow_mut().insert((start.slug.to_owned(), start.version), pid);
        let run_dir =
            PathBuf::from(format!("/var/lib/cmux-apps/1000/{}/v{}", start.slug, start.version));
        Ok(Started {
            pid,
            start_time: u64::from(pid) * 10,
            log: run_dir.join("app.log"),
            run_dir,
            user: "cmux-app".into(),
        })
    }

    fn alive(&self, slug: &str, version: u32) -> bool {
        let pid = self.pids.borrow().get(&(slug.to_owned(), version)).copied();
        pid.is_some_and(|pid| {
            !self.dead.borrow().contains(&pid) && !self.stopped.borrow().contains(&pid)
        })
    }

    fn stop(&self, slug: &str, version: u32) {
        if let Some(pid) = self.pids.borrow().get(&(slug.to_owned(), version)) {
            self.stopped.borrow_mut().push(*pid);
        }
    }

    fn free_port(&self) -> Result<u16, String> {
        let port = self.port.get();
        self.port.set(port + 1);
        Ok(port)
    }

    fn port_free(&self, port: u16) -> bool {
        !self.taken_ports.borrow().contains(&port)
    }
}

#[derive(Default)]
pub struct FakeClock {
    pub now: Cell<u64>,
}

impl Clock for FakeClock {
    fn now_ms(&self) -> u64 {
        self.now.get()
    }

    fn sleep(&self, duration: Duration) {
        self.now.set(self.now.get() + duration.as_millis() as u64);
    }
}

/// Answers `status` on every port, after `refusals` connection failures.
pub struct FakeProbe {
    pub status: Cell<u16>,
    pub refusals: Cell<u32>,
    pub calls: Cell<u32>,
}

impl FakeProbe {
    pub fn answering(status: u16) -> FakeProbe {
        FakeProbe { status: Cell::new(status), refusals: Cell::new(0), calls: Cell::new(0) }
    }
}

impl Probe for FakeProbe {
    fn get(&self, _port: u16, _path: &str) -> Result<u16, String> {
        self.calls.set(self.calls.get() + 1);
        if self.refusals.get() > 0 {
            self.refusals.set(self.refusals.get() - 1);
            return Err("connection refused".into());
        }
        Ok(self.status.get())
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Sent {
    pub method: String,
    pub path: String,
    pub body: Option<Value>,
    pub key: Option<String>,
}

/// This machine's agent's `apps.call`: records each call and answers the platform contract's
/// success shapes.
#[derive(Default)]
pub struct FakeAgent {
    pub sent: RefCell<Vec<Sent>>,
    /// An answer to use for every `/versions` call instead of the 201.
    pub versions_answer: RefCell<Option<(u16, Value)>>,
    /// This many `/versions` calls get no answer (a lost response) before one does.
    pub lose_answers: Cell<u32>,
    /// The platform's version numbers handed out so far.
    pub promoted: Cell<u32>,
    /// The agent's refusal of every call (an unbound machine).
    pub refusal: RefCell<Option<Unanswered>>,
    /// The platform's versions of the app, for `GET /v1/cloud/apps/{slug}`.
    pub app_versions: RefCell<Vec<Value>>,
}

impl AppsTransport for FakeAgent {
    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        idempotency_key: Option<&str>,
    ) -> Result<Answered, Unanswered> {
        if let Some(refusal) = self.refusal.borrow().clone() {
            return Err(refusal);
        }
        self.sent.borrow_mut().push(Sent {
            method: method.into(),
            path: path.into(),
            body: body.cloned(),
            key: idempotency_key.map(str::to_owned),
        });
        let answered =
            |status: u16, body: Value| Ok(Answered { status, body, machine: "vm_self".into() });
        if self.lose_answers.get() > 0 && path.ends_with("/versions") {
            self.lose_answers.set(self.lose_answers.get() - 1);
            return Err(Unanswered {
                code: "app.unreachable".into(),
                message: "connection reset".into(),
            });
        }
        let app = json!({"id": "app_1", "slug": "web", "team": "team_abc", "url": "https://a-web--team_abc.preview.example"});
        if path.ends_with("/versions") {
            if let Some((status, body)) = self.versions_answer.borrow().clone() {
                return answered(status, body);
            }
            let n = self.promoted.get() + 1;
            self.promoted.set(n);
            return answered(
                201,
                json!({"app": app, "version": {"n": n, "state": "live"}, "url": "https://a-web--team_abc.preview.example"}),
            );
        }
        if path.ends_with("/rollback") {
            return answered(
                200,
                json!({"app": app, "url": "https://a-web--team_abc.preview.example"}),
            );
        }
        if method == "GET" && path != "/v1/cloud/apps" {
            let versions = self.app_versions.borrow().clone();
            return answered(200, json!({"app": app, "versions": versions}));
        }
        if method == "GET" {
            return answered(200, json!({"items": []}));
        }
        answered(201, json!({"app": app}))
    }
}

/// The agent's `apps.listener`, read from the fake `/proc` the way the agent reads the real one.
pub struct FakeListeners<'a>(pub &'a FakeFs);

impl Listeners for FakeListeners<'_> {
    fn holder(&self, port: u16) -> Result<Inferred, String> {
        infer(self.0, Path::new("/proc"), port).map_err(|e| e.to_string())
    }
}

/// One machine: a repo at /work/web, the apps store at /state/apps, /proc under /proc.
pub struct World {
    pub fs: FakeFs,
    pub git: FakeGit,
    pub procs: FakeProcs,
    pub clock: FakeClock,
    pub probe: FakeProbe,
    pub parent_env: Vec<(String, String)>,
    pub agent: FakeAgent,
}

impl World {
    pub fn new() -> World {
        World {
            fs: FakeFs::default(),
            git: FakeGit::new("/work/web"),
            procs: FakeProcs::default(),
            clock: FakeClock::default(),
            probe: FakeProbe::answering(200),
            parent_env: vec![("PATH".into(), "/usr/bin:/bin".into())],
            agent: FakeAgent::default(),
        }
    }

    pub fn with<R>(&self, f: impl FnOnce(&Host<'_>) -> R) -> R {
        let platform = PlatformClient::new(&self.agent);
        let host = Host {
            fs: &self.fs,
            git: &self.git,
            procs: &self.procs,
            clock: &self.clock,
            probe: &self.probe,
            platform: &platform,
            listeners: &FakeListeners(&self.fs),
            apps_root: PathBuf::from("/state/apps"),
            parent_env: self.parent_env.clone(),
        };
        f(&host)
    }

    pub fn promotes(&self) -> Vec<Sent> {
        self.agent.sent.borrow().iter().filter(|s| s.path.ends_with("/versions")).cloned().collect()
    }

    /// The calls that change something (every one but the readiness `GET`).
    pub fn changes(&self) -> Vec<Sent> {
        self.agent.sent.borrow().iter().filter(|s| s.method != "GET").cloned().collect()
    }
}

/// `/proc/net/tcp` text with one listener: 127.0.0.1:`port`, socket inode `inode`.
pub fn tcp_table(port: u16, inode: u64) -> String {
    format!(
        "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   \
         0: 0100007F:{port:04X} 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 {inode} 1 0000000000000000 100 0 0 10 0\n   \
         1: 0100007F:1F40 0100007F:9C40 01 00000000:00000000 00:00000000 00000000  1000        0 999 1 0000000000000000 20 4 30 10 -1\n"
    )
}

/// A server process `pid` (parent `ppid`) holding socket `inode`, in `cwd`, running `argv`.
pub fn proc_entry(fs: &FakeFs, pid: u32, ppid: u32, inode: u64, cwd: &str, argv: &[&str]) {
    fs.link(&format!("/proc/{pid}/fd/0"), "/dev/null");
    fs.link(&format!("/proc/{pid}/fd/7"), &format!("socket:[{inode}]"));
    fs.link(&format!("/proc/{pid}/cwd"), cwd);
    let mut cmdline = argv.join("\0").into_bytes();
    cmdline.push(0);
    fs.file(&format!("/proc/{pid}/cmdline"), &cmdline);
    fs.file(
        &format!("/proc/{pid}/stat"),
        format!("{pid} (node server) S {ppid} {pid} {pid} 0").as_bytes(),
    );
}
