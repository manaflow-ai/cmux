//! The journey's world: one store, a Cloud machine's daemon, a laptop's daemon that can be
//! started late, the clocks all three run on, and the laptop's checkout with its remote.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;

use acpmux::auto_session::import::Importer;
use acpmux::auto_session::machine::attach_with;
use acpmux::auto_session::record::AutoRecord;
use acpmux::auto_session::runtime::ManualClock;
use acpmux::auto_session::{HolderHandle, HolderOptions, SessionImporter, spawn_holder_with};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use cmux_auto_session::AutoCloud;
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{Holder, MachineSetting, Manifest, SessionView};
use serde_json::{Value, json};

use super::logs::until;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// When the clocks start (epoch ms).
pub const T0: u64 = 1_700_000_000_000;

pub const DEVICE: &str = "laptop-1";
pub const VM: &str = "vm_1";
const TEAM: &str = "team_0123456789abcdef0123";

pub fn device() -> Holder {
    Holder::device(DEVICE)
}

pub fn vm() -> Holder {
    Holder::vm(VM)
}

/// Runs git in `dir`; its output, trimmed. Panics when git fails.
pub fn git(dir: &Path, args: &[&str]) -> String {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
        .args(["-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .expect("git runs");
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "git {args:?} in {}: {err}", dir.display());
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

pub fn write(dir: &Path, name: &str, text: &str) {
    std::fs::write(dir.join(name), text).unwrap();
}

pub fn read(dir: &Path, name: &str) -> String {
    std::fs::read_to_string(dir.join(name)).unwrap_or_default()
}

/// A bare remote whose `main` has `a.txt` ("one"), and a checkout of it that follows `main`.
fn checkout(root: &Path) -> (PathBuf, PathBuf) {
    let (origin, work) = (root.join("origin.git"), root.join("work"));
    std::fs::create_dir_all(&origin).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    git(&origin, &["init", "--bare", "--quiet"]);
    git(&work, &["init", "--quiet"]);
    write(&work, "a.txt", "one\n");
    git(&work, &["add", "a.txt"]);
    git(&work, &["commit", "--quiet", "-m", "first"]);
    git(&work, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&work, &["push", "--quiet", "-u", "origin", "HEAD:refs/heads/main"]);
    (origin, work)
}

/// What the stand-in agent of both daemons is, besides the defaults.
#[derive(Clone, Copy, Default)]
pub struct Agent {
    /// Its environment (`fake_agent.py`'s switches).
    pub env: &'static [(&'static str, &'static str)],
    /// The agent family its profile names, which says whose session store its chats keep.
    pub family: Option<&'static str>,
}

/// A daemon's hub on the stand-in agent, its store in memory. `env` is the agent's own, on
/// top of `agent`'s.
fn hub(agent: Agent, mut env: Value) -> Arc<Hub> {
    for (name, value) in agent.env {
        env[*name] = json!(value);
    }
    let mut fake = json!({"argv": ["python3", FAKE], "env": env});
    if let Some(family) = agent.family {
        fake["family"] = json!(family);
    }
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fake": fake},
        "defaultHarness": "fake",
        "permissionPolicy": "approve-all",
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// One daemon with its holder loop.
pub struct Daemon {
    pub hub: Arc<Hub>,
    pub holder: HolderHandle,
    /// Where a chat that is new to this daemon gets its folder.
    pub root: PathBuf,
}

impl Daemon {
    /// The chat's Auto record on this daemon.
    pub fn record(&self, id: &str) -> Option<AutoRecord> {
        self.hub.resolve(id).ok()?.meta().auto_session
    }

    /// The chat's row field, as a client reads it.
    pub fn row(&self, id: &str) -> Value {
        match self.hub.resolve(id) {
            Ok(session) => self.hub.session_summary(&session)["autoSession"].clone(),
            Err(_) => Value::Null,
        }
    }

    /// The chat's folder on this daemon.
    pub fn folder(&self, id: &str) -> PathBuf {
        self.hub.resolve(id).expect("the chat is here").meta().cwd
    }
}

pub struct World {
    /// The store as the phone reaches it, which is also how the test reads it.
    pub phone: FakeAutoCloud,
    /// The store as the laptop reaches it: `set_offline` takes the laptop off the network.
    pub laptop_net: FakeAutoCloud,
    pub laptop_clock: Arc<ManualClock>,
    pub machine_clock: Arc<ManualClock>,
    pub machine: Daemon,
    /// The stand-in agent both daemons run.
    agent: Agent,
    pub dir: tempfile::TempDir,
    /// The bare remote.
    pub origin: PathBuf,
    /// The laptop's checkout of it.
    pub work: PathBuf,
}

impl World {
    /// A store with the Auto machine set, and that machine's daemon running. No laptop yet.
    pub async fn new() -> World {
        World::with_agent(Agent::default()).await
    }

    /// [`World::new`] with both daemons on the stand-in agent `agent`.
    pub async fn with_agent(agent: Agent) -> World {
        let dir = tempfile::tempdir().unwrap();
        let (origin, work) = checkout(dir.path());
        let phone = FakeAutoCloud::new();
        phone.set_now(T0);
        let setting = MachineSetting { team: TEAM.into(), machine: VM.into() };
        phone.set_machine(&setting).await.expect("the Auto machine");

        let machine_clock = ManualClock::new(T0);
        // Both daemons run on this one host and name the chat alike, and a daemon finds a
        // chat's detached processes by the chat's id in their environment. On two real
        // machines neither sees the other's processes; here the machine's agents carry
        // another id, so the laptop's kill of its own tree does not reach them.
        let machine_hub = hub(agent, json!({"ACPMUX_SESSION_ID": "on-the-cloud-machine"}));
        let root = dir.path().join("machine");
        let options =
            HolderOptions { clock: machine_clock.clone(), network: None, new_chats: None };
        let cloud = Arc::new(phone.as_machine(VM));
        let (reader, holder) = attach_with(machine_hub.clone(), cloud, vm(), root.clone(), options);
        // The reader ends with the test's runtime.
        tokio::spawn(reader.run());
        let machine = Daemon { hub: machine_hub, holder, root };

        let laptop_net = phone.as_owner();
        let laptop_clock = ManualClock::new(T0);
        World { phone, laptop_net, laptop_clock, machine_clock, machine, agent, dir, origin, work }
    }

    /// Starts the laptop's daemon: its holder loop as `device:<id>` over the owner's
    /// transport, with the real importer over the same transport.
    pub fn start_laptop(&self) -> Daemon {
        let hub = hub(self.agent, json!({}));
        let root = self.dir.path().join("laptop-chats");
        let cloud = Arc::new(self.laptop_net.clone());
        let importer: Arc<dyn SessionImporter> =
            Importer::new(hub.clone(), cloud.clone(), root.clone());
        let options =
            HolderOptions { clock: self.laptop_clock.clone(), network: None, new_chats: None };
        let holder = spawn_holder_with(hub.clone(), cloud, device(), importer, options);
        Daemon { hub, holder, root }
    }

    /// Time passes everywhere: in the store and on both daemons.
    pub fn pass(&self, ms: u64) {
        self.phone.advance(ms);
        self.machine_clock.advance(ms);
        self.laptop_clock.advance(ms);
    }

    /// Time passes while the laptop sleeps: its clock is not read until it wakes.
    pub fn pass_while_laptop_sleeps(&self, ms: u64) {
        self.phone.advance(ms);
        self.machine_clock.advance(ms);
    }

    /// The laptop's clock after a sleep: the time everywhere else.
    pub fn laptop_clock_catches_up(&self) {
        self.laptop_clock.set(self.phone.now());
    }

    pub fn view(&self, id: &str) -> SessionView {
        self.phone.peek(id).expect("the store has the chat")
    }

    /// The newest snapshot's manifest; None while the chat has no snapshot.
    pub async fn manifest(&self, id: &str) -> Option<Manifest> {
        self.phone.snapshot(id).await.ok().map(|answer| answer.manifest)
    }

    /// Waits until the store's view of the chat is as `ready` says.
    pub async fn until_view(&self, id: &str, what: &str, ready: impl Fn(&SessionView) -> bool) {
        until(what, || self.phone.peek(id).is_some_and(|view| ready(&view))).await;
    }

    /// Waits until the machine holds the chat with nothing left to do: its assignment and the
    /// inbox acked, nothing to run, and a snapshot that covers its last event.
    pub async fn machine_at_rest(&self, id: &str) {
        let deadline = std::time::Instant::now() + super::logs::DEADLINE;
        loop {
            let view = self.view(id);
            let assigned = self.phone.as_machine(VM).assignments(0).await.unwrap_or_default();
            let covered = self.manifest(id).await.is_some_and(|m| m.last_seq == view.last_seq);
            let quiet = view.holder == vm()
                && !view.needs_run
                && view.inbox_acked == view.inbox
                && !assigned.iter().any(|assignment| assignment.session.id == id);
            if quiet && covered {
                return;
            }
            assert!(
                std::time::Instant::now() < deadline,
                "the machine never came to rest with the chat: {view:?}"
            );
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    }
}
