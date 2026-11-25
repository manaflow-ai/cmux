//! Auto mode on a laptop's daemon (`src/auto_session/`): the holder loop run in process against
//! the Cloud store in memory (`FakeAutoCloud`, the real store's rules), a stand-in agent and a
//! clock the test moves. The chat's folder is a real git checkout with a remote.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

// Who may call the Auto methods.
#[path = "auto_session/access.rs"]
mod access;
// A second connection to a rig's daemon.
#[path = "auto_session/client.rs"]
mod client;
// An import that is still under way when the store has moved on.
#[path = "auto_session/stale_import.rs"]
mod stale_import;
// The kept changes: Apply, Discard, and two requests for one chat.
#[path = "auto_session/leftover.rs"]
mod leftover;
// The chat's log goes with its secrets masked.
#[path = "auto_session/redact.rs"]
mod redact;
// Auto on and Keep in Cloud answered from the store's answer.
#[path = "auto_session/switch.rs"]
mod switch;
// The Cloud's transcript read on the Mac while the Cloud runs the chat.
#[path = "auto_session/transcript.rs"]
mod transcript;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use acpmux::auto_session::record::AutoRecord;
use acpmux::auto_session::runtime::ManualClock;
use acpmux::auto_session::{
    HolderHandle, HolderOptions, ImportError, ImportReason, Imported, SessionImporter,
    spawn_holder_with,
};
use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use cmux_auto_session::AutoCloud;
use cmux_auto_session::consts::{LEASE_MS, RENEW_MS, SELF_STOP_MS};
use cmux_auto_session::fake::FakeAutoCloud;
use cmux_auto_session::wire::{
    Cwd, Fence, Holder, InboxPost, LeaseRequest, MachineSetting, Role, SessionView, SnapshotPost,
};
use futures::future::BoxFuture;
use serde_json::{Value, json};
use tokio::sync::mpsc;

/// Builds a rig's importer from the daemon, the laptop's transport and a folder for new chats.
type MakeImporter = Box<dyn FnOnce(Arc<Hub>, FakeAutoCloud, PathBuf) -> Arc<dyn SessionImporter>>;

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// When the test's clocks start (epoch ms).
const T0: u64 = 1_700_000_000_000;

const DEVICE: &str = "laptop-1";
const MACHINE: &str = "m1";
const TEAM: &str = "team_0123456789abcdef0123";

/// An importer that brings nothing in and says it did: what the loop asks of it is recorded.
#[derive(Default)]
struct StubImporter {
    asked: Mutex<Vec<(String, u64, ImportReason)>>,
}

impl SessionImporter for StubImporter {
    fn import<'a>(
        &'a self,
        session: &'a SessionView,
        reason: ImportReason,
    ) -> BoxFuture<'a, Result<Imported, ImportError>> {
        self.asked.lock().unwrap().push((session.id.clone(), session.epoch, reason));
        let imported = Imported {
            session_id: session.id.clone(),
            epoch: session.epoch,
            last_seq: session.last_seq,
            snapshot: session.snapshot,
        };
        Box::pin(async move { Ok(imported) })
    }
}

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=Test", "-c", "user.email=test@example.com"])
        .args(["-c", "init.defaultBranch=main", "-c", "commit.gpgsign=false"])
        .args(args)
        .output()
        .expect("git runs");
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

/// A checkout with one commit, pushed to a bare repository beside it.
fn checkout(root: &Path) -> PathBuf {
    let (origin, work) = (root.join("origin.git"), root.join("work"));
    std::fs::create_dir_all(&origin).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    git(&origin, &["init", "--bare", "--quiet"]);
    git(&work, &["init", "--quiet"]);
    std::fs::write(work.join("a.txt"), "one\n").unwrap();
    git(&work, &["add", "a.txt"]);
    git(&work, &["commit", "--quiet", "-m", "first"]);
    git(&work, &["remote", "add", "origin", origin.to_str().unwrap()]);
    git(&work, &["push", "--quiet", "-u", "origin", "HEAD:refs/heads/main"]);
    work
}

/// Waits until `ready` holds.
async fn until(what: &str, mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(60);
    while !ready() {
        assert!(Instant::now() < deadline, "timed out waiting for: {what}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn size(path: &Path) -> u64 {
    std::fs::metadata(path).map_or(0, |meta| meta.len())
}

/// Whether the file at `path` grows within a short while.
async fn grows(path: &Path) -> bool {
    let before = size(path);
    tokio::time::sleep(Duration::from_millis(400)).await;
    size(path) > before
}

fn kill(pid: u32) {
    // SAFETY: the pid is the test's own stand-in shell, read from the file it wrote.
    unsafe { libc::kill(pid as i32, libc::SIGKILL) };
}

/// One laptop daemon with Auto mode: the hub, the store, the clock and one connection.
struct Rig {
    hub: Arc<Hub>,
    /// The store as the loop reaches it: `set_offline` takes this laptop off the network.
    cloud: FakeAutoCloud,
    /// The same store over a network of the test's own.
    store: FakeAutoCloud,
    clock: Arc<ManualClock>,
    holder: HolderHandle,
    importer: Arc<StubImporter>,
    me: Holder,
    root: tempfile::TempDir,
    work: PathBuf,
    tx: mpsc::Sender<String>,
    rx: mpsc::Receiver<String>,
    next: i64,
}

impl Rig {
    async fn new() -> Rig {
        Rig::as_device(DEVICE).await
    }

    /// The laptop daemon of the device named `device`, as it says its name to the store.
    async fn as_device(device: &str) -> Rig {
        Rig::build(device, None).await
    }

    /// A rig whose holder loop imports with the importer `make` builds from the daemon, the
    /// laptop's transport and a folder for chats that are new here.
    async fn with_importer(
        make: impl FnOnce(Arc<Hub>, FakeAutoCloud, PathBuf) -> Arc<dyn SessionImporter> + 'static,
    ) -> Rig {
        Rig::build(DEVICE, Some(Box::new(make))).await
    }

    async fn build(device: &str, make: Option<MakeImporter>) -> Rig {
        let root = tempfile::tempdir().unwrap();
        let work = checkout(root.path());
        let wire_log = root.path().join("wire.log");
        let mut cfg: Config = serde_json::from_value(json!({
            "harnesses": {"fake": {
                "argv": ["python3", FAKE],
                "env": {"FAKE_WIRE_LOG": wire_log},
            }},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        }))
        .unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);

        let cloud = FakeAutoCloud::new();
        cloud.set_now(T0);
        let clock = ManualClock::new(T0);
        let importer = Arc::new(StubImporter::default());
        let me = Holder::device(device);
        let options = HolderOptions { clock: clock.clone(), network: None, new_chats: None };
        let chosen: Arc<dyn SessionImporter> = match make {
            Some(make) => make(hub.clone(), cloud.clone(), root.path().join("imports")),
            None => importer.clone(),
        };
        let holder =
            spawn_holder_with(hub.clone(), Arc::new(cloud.clone()), me.clone(), chosen, options);

        let (tx, in_rx) = mpsc::channel(64);
        let (out_tx, rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
        let store = cloud.as_owner();
        Rig { hub, cloud, store, clock, holder, importer, me, root, work, tx, rx, next: 0 }
    }

    /// Sends a request and does not wait for its reply.
    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        self.tx.send(Message::request(self.next, method, params).to_line()).await.unwrap();
        self.next
    }

    /// The reply to one request: its result, or its error.
    async fn reply(&mut self, method: &str, params: Value) -> Result<Value, Value> {
        let id = self.send(method, params).await;
        loop {
            let line = tokio::time::timeout(Duration::from_secs(60), self.rx.recv())
                .await
                .unwrap_or_else(|_| panic!("no reply to {method}"))
                .expect("the connection stays open");
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) && v.get("method").is_none() {
                return match v.get("error") {
                    Some(error) => Err(error.clone()),
                    None => Ok(v["result"].clone()),
                };
            }
        }
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        self.reply(method, params.clone())
            .await
            .unwrap_or_else(|error| panic!("{method} {params}: {error}"))
    }

    /// A chat in the checkout with Auto on, registered and copied once.
    async fn auto_chat(&mut self) -> String {
        let created = self.call("session/new", json!({"cwd": self.work, "mcpServers": []})).await;
        let id = created["sessionId"].as_str().unwrap().to_owned();
        let set =
            self.call("_acpmux/auto_session/set", json!({"sessionId": id, "auto": true})).await;
        assert_eq!(set["autoSession"]["auto"], true, "{set}");
        let (store, me) = (self.store.clone(), self.me.clone());
        until("the chat is registered and copied", || {
            store.peek(&id).is_some_and(|view| view.holder == me && view.snapshot >= 1)
        })
        .await;
        id
    }

    async fn prompt(&mut self, id: &str, text: &str) -> Value {
        let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        self.call("session/prompt", params).await
    }

    /// A prompt to a chat this laptop just took back. It is sent again while the chat asks
    /// the store whether it is still this laptop's, as a client does on a retryable refusal.
    async fn prompt_once_running(&mut self, id: &str, text: &str) -> Value {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
            match self.reply("session/prompt", params).await {
                Ok(done) => return done,
                Err(error) if error["data"]["retryable"] == true && Instant::now() < deadline => {
                    tokio::time::sleep(Duration::from_millis(50)).await;
                }
                Err(error) => {
                    panic!(
                        "session/prompt: {error}; the store was called: {:?}",
                        self.cloud.calls()
                    )
                }
            }
        }
    }

    /// Starts a turn that does not end, and does not wait for it.
    async fn start_turn(&mut self, id: &str, text: &str) {
        let params = json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]});
        self.send("session/prompt", params).await;
    }

    /// Starts a turn whose tool runs a shell that writes to a file, and waits for the store to
    /// know the chat has work. Answers the file and the shell's pid.
    async fn start_shell(&mut self, id: &str) -> (PathBuf, u32) {
        let ticks = self.root.path().join("ticks.log");
        self.start_turn(id, &format!("auto-shell: {}", ticks.display())).await;
        let pid_file = PathBuf::from(format!("{}.pid", ticks.display()));
        until("the tool's shell runs", || pid_file.exists() && size(&ticks) > 0).await;
        let pid: u32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
        let store = self.store.clone();
        until("the store knows the chat has work", || {
            store.peek(id).is_some_and(|view| view.needs_run)
        })
        .await;
        (ticks, pid)
    }

    /// Time passes on this laptop and in the store.
    fn pass(&self, ms: u64) {
        self.cloud.advance(ms);
        self.clock.advance(ms);
    }

    fn record(&self, id: &str) -> Option<AutoRecord> {
        self.hub.resolve(id).ok()?.meta().auto_session
    }

    /// The chat's row field, as a client reads it.
    fn row(&self, id: &str) -> Value {
        let session = self.hub.resolve(id).unwrap();
        self.hub.session_summary(&session)["autoSession"].clone()
    }

    fn view(&self, id: &str) -> SessionView {
        self.store.peek(id).expect("the store has the chat")
    }

    /// How many prompts reached the chat's agent.
    fn prompts_at_agent(&self) -> usize {
        let log = std::fs::read_to_string(self.root.path().join("wire.log")).unwrap_or_default();
        log.lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .filter(|line| line["method"] == "session/prompt")
            .count()
    }

    /// The store's lease runs out while this laptop cannot reach it, then the laptop is back
    /// and its next renewal goes out.
    fn lapse_and_return(&self) {
        self.cloud.set_offline(true);
        self.cloud.advance(LEASE_MS + 1_000);
        self.cloud.set_offline(false);
        self.clock.advance(RENEW_MS);
    }
}

#[tokio::test]
async fn an_auto_chat_renews_and_keeps_a_whole_copy_in_the_cloud() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = rig.auto_chat().await;
    assert_eq!(
        rig.row(&id),
        json!({"auto": true, "state": "local", "here": true, "keepInCloud": false})
    );
    assert_eq!(rig.view(&id).epoch, 1);
    assert_eq!(rig.holder.holder(), &rig.me);

    // A turn's end sends the events, then a snapshot that covers them.
    rig.prompt(&id, "hello").await;
    let deadline = Instant::now() + Duration::from_secs(60);
    let (page, snapshot) = loop {
        let page = rig.store.events(&id, 0, None).await.unwrap();
        let ended = page.events.iter().find(|event| event.record["kind"] == "turn_result");
        let snapshot = rig.store.snapshot(&id).await.unwrap();
        if ended.is_some_and(|ended| snapshot.manifest.last_seq >= ended.seq) {
            break (page, snapshot);
        }
        assert!(Instant::now() < deadline, "the turn's end never reached the Cloud: {page:?}");
        tokio::time::sleep(Duration::from_millis(20)).await;
    };
    let seqs: Vec<u64> = page.events.iter().map(|event| event.seq).collect();
    assert_eq!(seqs, (1..=page.last_seq).collect::<Vec<_>>(), "every record, in order");

    // The snapshot names the checkout and every chunk it names is in the store.
    assert!(snapshot.manifest.last_seq <= page.last_seq);
    assert_eq!(snapshot.manifest.harness, "fake");
    let Cwd::Git { remote, bundle, patch, .. } = &snapshot.manifest.cwd else {
        panic!("a checkout goes in the git form: {:?}", snapshot.manifest.cwd);
    };
    assert!(remote.ends_with("origin.git"), "{remote}");
    for chunk in bundle.iter().chain(patch) {
        rig.store.chunk(&id, chunk).await.unwrap();
    }

    // A renewal goes out every period.
    let renewals = |rig: &Rig| rig.cloud.calls().iter().filter(|call| **call == "lease").count();
    let before = renewals(&rig);
    rig.pass(RENEW_MS);
    until("the next renewal", || renewals(&rig) > before).await;
    assert_eq!(rig.view(&id).lease_expires_at, T0 + RENEW_MS + LEASE_MS);

    // Auto off closes the chat in the store and the row says so.
    let off = rig.call("_acpmux/auto_session/set", json!({"sessionId": id, "auto": false})).await;
    assert_eq!(off["autoSession"]["auto"], false, "{off}");
    assert!(!rig.view(&id).auto);
    assert_eq!(rig.record(&id), None);
}

#[tokio::test]
async fn a_lease_that_lapses_mid_tool_gives_the_chat_to_a_machine_and_kills_the_tree_here() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let setting = MachineSetting { team: TEAM.into(), machine: MACHINE.into() };
    rig.store.set_machine(&setting).await.unwrap();
    let id = rig.auto_chat().await;
    let (ticks, pid) = rig.start_shell(&id).await;

    // The laptop goes away with a change the Cloud's copy does not have.
    rig.cloud.set_offline(true);
    std::fs::write(rig.work.join("a.txt"), "changed after the copy\n").unwrap();
    rig.cloud.advance(LEASE_MS + 1_000);
    let taken = rig.view(&id);
    assert_eq!(taken.holder, Holder::vm(MACHINE), "the lapsed lease gave the chat to the machine");
    assert_eq!(taken.epoch, 2);
    assert_eq!(rig.cloud.machine_starts(), vec![MACHINE.to_owned()]);
    assert!(daemon_env::alive(pid), "nothing told the laptop yet");

    // It returns: its next renewal hears the chat is not its own any more.
    rig.cloud.set_offline(false);
    rig.clock.advance(RENEW_MS);
    until("the laptop stands by with its changes kept", || {
        rig.record(&id).is_some_and(|record| !record.here && record.leftover.is_some())
    })
    .await;
    until("the tool's shell is gone", || !daemon_env::alive(pid)).await;
    assert!(!grows(&ticks).await, "nothing writes after the kill");

    let row = rig.row(&id);
    assert_eq!(row["here"], false, "{row}");
    assert_eq!(row["leftover"]["files"], 1, "{row}");
    let shown =
        rig.call("_acpmux/auto_session/leftover", json!({"sessionId": id, "action": "show"})).await;
    assert_eq!(shown["files"], json!(["a.txt"]), "{shown}");
    assert!(shown["patch"].as_str().unwrap().contains("changed after the copy"), "{shown}");
    // The laptop asks to get the chat back.
    let (store, me) = (rig.store.clone(), rig.me.clone());
    until("the laptop is listed as standby", || store.peek(&id).unwrap().standby.contains(&me))
        .await;

    // A prompt here goes to the chat in the Cloud, not to an agent on this machine.
    let prompts = rig.prompts_at_agent();
    let sent = rig.prompt(&id, "go on").await;
    assert_eq!(sent["_meta"]["acpmux"]["autoSession"]["delivery"], "resuming", "{sent}");
    assert_eq!(rig.view(&id).inbox, 1);
    assert_eq!(rig.prompts_at_agent(), prompts);

    // Discarding the kept changes clears the notice; the folder keeps what it has.
    let settled = rig
        .call("_acpmux/auto_session/leftover", json!({"sessionId": id, "action": "discard"}))
        .await;
    assert!(settled["autoSession"].get("leftover").is_none(), "{settled}");
    let kept = std::fs::read_to_string(rig.work.join("a.txt")).unwrap();
    assert_eq!(kept, "changed after the copy\n");
}

#[tokio::test]
async fn no_network_stops_the_tree_and_an_answered_renewal_continues_it() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = rig.auto_chat().await;
    let (ticks, pid) = rig.start_shell(&id).await;
    assert!(grows(&ticks).await, "the tool's shell writes while the chat runs");

    // No renewal is answered for the self-stop time: the whole tree stops, the detached shell
    // included, before the store's lease runs out.
    rig.cloud.set_offline(true);
    rig.clock.advance(SELF_STOP_MS + 1_000);
    until("the chat says it is offline", || rig.row(&id)["blocked"] == "offline").await;
    assert!(daemon_env::alive(pid), "stopped, not killed");
    assert!(!grows(&ticks).await, "a stopped shell writes nothing");
    let again = json!({"sessionId": id, "prompt": [{"type": "text", "text": "x"}]});
    let refused = rig.reply("session/prompt", again).await.unwrap_err();
    assert_eq!(refused["data"]["reason"], "auto.offline", "{refused}");

    // The network is back and the store still has this laptop as the holder: the tree goes on.
    rig.cloud.set_offline(false);
    rig.clock.advance(RENEW_MS);
    until("the chat runs again", || rig.row(&id).get("blocked").is_none()).await;
    until("the shell writes again", || size(&ticks) > 0 && daemon_env::alive(pid)).await;
    assert!(grows(&ticks).await, "the continued shell writes");
    assert_eq!(rig.view(&id).holder, rig.me);
    assert_eq!(rig.view(&id).epoch, 1);
    kill(pid);
}

#[tokio::test]
async fn a_parked_chat_is_taken_again_by_its_laptop() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = rig.auto_chat().await;

    // An idle chat whose lease runs out is parked: no machine starts for it.
    rig.cloud.set_offline(true);
    rig.cloud.advance(LEASE_MS + 1_000);
    let parked = rig.view(&id);
    assert_eq!(parked.holder, Holder::Parked);
    assert!(rig.cloud.machine_starts().is_empty());

    // The laptop returns: its next renewal takes its own chat again, at a new epoch.
    rig.cloud.set_offline(false);
    rig.clock.advance(RENEW_MS);
    let (store, me) = (rig.store.clone(), rig.me.clone());
    until("the laptop holds the chat again", || {
        store.peek(&id).is_some_and(|view| view.holder == me && view.epoch > parked.epoch)
    })
    .await;
    let epoch = rig.view(&id).epoch;
    until("the chat's record has the new epoch", || {
        rig.record(&id).is_some_and(|record| record.here && record.epoch == epoch)
    })
    .await;
    assert_eq!(rig.row(&id)["here"], true);

    // It runs and copies under the new epoch.
    let before = rig.view(&id).snapshot;
    rig.prompt_once_running(&id, "hello").await;
    until("a copy under the new epoch", || store.peek(&id).unwrap().snapshot > before).await;
}

#[tokio::test]
async fn inbox_messages_become_prompts_exactly_once() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let id = rig.auto_chat().await;
    let post = |id: &str, text: &str| InboxPost { id: id.to_owned(), text: text.to_owned() };

    // Another device sends to the chat: the holder's next renewal says a message waits.
    rig.store.post_inbox(&id, &post("m1", "hello from the phone")).await.unwrap();
    rig.pass(RENEW_MS);
    until("the message reached the agent", || rig.prompts_at_agent() == 1).await;
    let store = rig.store.clone();
    until("the message is acked", || {
        store.peek(&id).is_some_and(|view| view.inbox == 1 && view.inbox_acked == 1)
    })
    .await;

    // The same message again and a new one: only the new one is a prompt.
    rig.store.post_inbox(&id, &post("m1", "hello from the phone")).await.unwrap();
    rig.store.post_inbox(&id, &post("m2", "and another")).await.unwrap();
    rig.pass(RENEW_MS);
    until("the second message reached the agent", || rig.prompts_at_agent() == 2).await;
    until("both are acked", || store.peek(&id).is_some_and(|view| view.inbox_acked == view.inbox))
        .await;

    // More renewals and another drain give the chat nothing twice.
    rig.pass(RENEW_MS);
    rig.pass(RENEW_MS);
    tokio::time::sleep(Duration::from_millis(400)).await;
    assert_eq!(rig.prompts_at_agent(), 2);
    let taken: Vec<String> = rig
        .hub
        .events(&id, 0, 10_000)
        .unwrap()
        .iter()
        .filter(|record| record.kind == "auto_inbox")
        .map(|record| record.msg["promptId"].as_str().unwrap_or_default().to_owned())
        .collect();
    assert_eq!(taken, ["m1", "m2"], "each message is in the chat's own log once");
}

#[tokio::test]
async fn a_handback_imports_the_cloud_copy_and_holds_the_chat() {
    let _hermetic = &HERMETIC;
    let mut rig = Rig::new().await;
    let setting = MachineSetting { team: TEAM.into(), machine: MACHINE.into() };
    rig.store.set_machine(&setting).await.unwrap();
    let id = rig.auto_chat().await;
    let (_ticks, pid) = rig.start_shell(&id).await;

    // The machine takes the chat while the laptop is away; the laptop returns and stands by.
    rig.lapse_and_return();
    let (store, me) = (rig.store.clone(), rig.me.clone());
    until("the laptop is listed as standby", || {
        store.peek(&id).is_some_and(|view| view.standby.contains(&me))
    })
    .await;
    until("the tool's shell is gone", || !daemon_env::alive(pid)).await;
    assert_eq!(rig.row(&id)["here"], false);
    assert!(rig.importer.asked.lock().unwrap().is_empty());

    // The machine picks the chat up, finishes, stores its last copy and says it has nothing
    // left to run: the store gives the chat home.
    let machine = rig.store.as_machine(MACHINE);
    let assigned = machine.assignments(0).await.unwrap();
    assert_eq!(assigned.len(), 1);
    let epoch = assigned[0].session.epoch;
    let vm = Holder::vm(MACHINE);
    machine.ack_assignment(&id, &Fence::new(vm.clone(), epoch)).await.unwrap();
    let mut manifest = machine.snapshot(&id).await.unwrap().manifest;
    manifest.last_seq = rig.view(&id).last_seq;
    let last = SnapshotPost { holder: vm.clone(), epoch, manifest };
    machine.post_snapshot(&id, &last).await.unwrap();
    let done = LeaseRequest { holder: vm, epoch, needs_run: false, standby: None };
    assert_eq!(machine.lease(&id, &done).await.unwrap().role, Role::Lost);
    let home = rig.view(&id);
    assert_eq!(home.holder, rig.me);

    // The laptop's next standby renewal hears it: it imports first, then holds.
    rig.pass(RENEW_MS);
    until("the chat is held here again", || {
        rig.record(&id).is_some_and(|record| record.here && record.epoch == home.epoch)
    })
    .await;
    assert_eq!(
        *rig.importer.asked.lock().unwrap(),
        vec![(id.clone(), home.epoch, ImportReason::Handback)]
    );
    until("the row says the chat runs here", || {
        let row = rig.row(&id);
        row["here"] == true && row["state"] == "local"
    })
    .await;
    // It runs here again: a prompt reaches this machine's agent.
    let before = rig.prompts_at_agent();
    rig.prompt(&id, "hello").await;
    assert_eq!(rig.prompts_at_agent(), before + 1);
}
