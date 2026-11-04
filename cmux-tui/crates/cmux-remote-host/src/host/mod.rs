//! The cmux Remote host on Windows and Linux (docs/cmux-remote.md, "Windows
//! and Linux"): the daemon's supervisor link (`remote-host-v1`), the Computer
//! Use worker it supervises, and the approval questions it routes to the
//! collectors. The Swift host (`CmuxRemoteHost/RemoteHost.swift`) is the
//! macOS twin; both pass `schemas/remote-host/v1-conformance.json`.

mod worker_link;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use serde_json::{Map, Value, json};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::{Notify, mpsc};

use crate::approval::{ApprovalRequest, Decision, Target};
use crate::approver::{ApproverDecision, Collectors, RemoteApprover};
use crate::wire;
pub use worker_link::WorkerLink;

/// How long the host serves with no daemon before it exits (docs/cmux-remote.md, Lifecycle).
pub const ADOPTION_GRACE: Duration = Duration::from_secs(60);
/// How long a peer has to send its hello.
const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
/// How often one question may be shown again through `computer_use.approvals.prompt`.
pub const PROMPT_COOLDOWN: Duration = Duration::from_secs(10);

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// What the daemon hands the host at start (one JSON line on fd 3 or in a 0600
/// bootstrap file the host deletes; never argv or env).
#[derive(Clone, Debug, Default)]
pub struct Bootstrap {
    pub supervisor_secret: Vec<u8>,
    pub daemon_build: String,
    pub computer_use: bool,
    pub screen_sharing: bool,
    pub headless: bool,
    /// The daemon's socket: a supervisor is admitted only when it is the process serving it (Linux).
    pub daemon_socket: Option<PathBuf>,
    /// The daemon's executable: a supervisor must run it (Windows).
    pub daemon_exe: Option<PathBuf>,
    /// The daemon that started this host, by pid and creation time (Windows: a
    /// supervisor must be that process, or the one now serving `daemon_socket`).
    pub daemon_pid: Option<u32>,
    pub daemon_start: Option<u64>,
    /// This build's acpmux: the worker admits only bridges running this image.
    pub acpmux: Option<PathBuf>,
    /// This machine's acpmux socket: the worker registers the daemon serving it.
    pub acpmux_socket: Option<PathBuf>,
    /// The cmux client (stable, NIGHTLY, a DEV tag): saved approvals are per client.
    pub client: Option<String>,
}

impl Bootstrap {
    pub fn parse(line: &Value) -> Option<Self> {
        let secret = line.get("supervisor_secret").and_then(Value::as_str).and_then(wire::unhex)?;
        if secret.len() < 16 {
            return None;
        }
        let path = |key: &str| line.get(key).and_then(Value::as_str).map(PathBuf::from).filter(|path| path.is_absolute());
        Some(Self {
            supervisor_secret: secret,
            daemon_build: line.get("daemon_build").and_then(Value::as_str).unwrap_or_default().to_owned(),
            computer_use: line.get("computer_use").and_then(Value::as_bool).unwrap_or(false),
            screen_sharing: line.get("screen_sharing").and_then(Value::as_bool).unwrap_or(false),
            headless: line.get("headless").and_then(Value::as_bool).unwrap_or(true),
            daemon_socket: path("daemon_socket"),
            daemon_exe: path("daemon_exe"),
            daemon_pid: line.get("daemon_pid").and_then(Value::as_u64).and_then(|pid| u32::try_from(pid).ok()),
            daemon_start: line.get("daemon_start").and_then(Value::as_u64),
            acpmux: path("acpmux"),
            acpmux_socket: path("acpmux_socket"),
            client: line.get("client").and_then(Value::as_str).map(str::to_owned),
        })
    }
}

/// The files of one host, in its private directory (the daemon names it).
#[derive(Clone, Debug)]
pub struct Layout {
    pub dir: PathBuf,
}

impl Layout {
    fn leaf(&self) -> String {
        self.dir.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_else(|| "rh".into())
    }

    /// The supervisor endpoint: `<dir>/s.sock`, or `\\.\pipe\cmux-remote-<leaf>` on Windows.
    pub fn supervisor(&self) -> PathBuf {
        if cfg!(windows) {
            PathBuf::from(format!(r"\\.\pipe\cmux-remote-{}", self.leaf()))
        } else {
            self.dir.join("s.sock")
        }
    }

    /// The Computer Use worker's endpoint.
    pub fn worker_socket(&self) -> PathBuf {
        if cfg!(windows) {
            PathBuf::from(format!(r"\\.\pipe\cmux-remote-{}-cu", self.leaf()))
        } else {
            self.dir.join("w-cu.sock")
        }
    }

    /// The folder acpmux reads `endpoint.json` from (`CMUX_NEXT_CUA_V2_DIR`).
    pub fn endpoint_dir(&self) -> PathBuf {
        self.dir.join("cu")
    }

    pub fn log(&self) -> PathBuf {
        self.dir.join("host.log")
    }
}

#[derive(Clone, Copy, Debug)]
struct Switches {
    computer_use: bool,
    screen_sharing: bool,
    headless: bool,
}

/// One approval question the host routes.
struct Question {
    request: ApprovalRequest,
    /// The worker generation that asked (a restarted worker's ids start again).
    generation: u64,
    task: Option<tokio::task::AbortHandle>,
}

/// The host's state and request handling.
pub struct HostCore {
    secret: Vec<u8>,
    bootstrap: Bootstrap,
    pub layout: Layout,
    state_dir: PathBuf,
    switches: Mutex<Switches>,
    /// The daemon's connection (one at a time) and its generation.
    daemon: Mutex<Option<(u64, mpsc::UnboundedSender<Value>)>>,
    connections: AtomicU64,
    draining: AtomicBool,
    pub shutdown: Notify,
    worker: WorkerLink,
    collectors: Mutex<Collectors>,
    questions: Mutex<HashMap<u64, Question>>,
    /// When each question was last shown through `computer_use.approvals.prompt`.
    prompted: Mutex<HashMap<u64, tokio::time::Instant>>,
    /// Held across each read, change and write of the saved list.
    saved_lock: Mutex<()>,
    /// The device hub collector's state, for status.
    hub_state: Mutex<crate::hub::HubState>,
    hub_socket: Mutex<Option<cmux_device_hub_client::UserSocket>>,
    acpmux_daemons: Mutex<Vec<crate::platform::ProcessStamp>>,
}

impl HostCore {
    /// `worker_exe`: this executable, which runs the worker; None runs none (tests).
    pub fn new(bootstrap: Bootstrap, layout: Layout, state_dir: PathBuf, worker_exe: Option<PathBuf>) -> Arc<Self> {
        let switches = Switches {
            computer_use: bootstrap.computer_use,
            screen_sharing: false,
            headless: bootstrap.headless,
        };
        Arc::new_cyclic(|weak| Self {
            secret: bootstrap.supervisor_secret.clone(),
            worker: WorkerLink::new(weak.clone(), worker_exe, layout.clone(), state_dir.join("worker")),
            bootstrap,
            layout,
            state_dir,
            switches: Mutex::new(switches),
            daemon: Mutex::new(None),
            connections: AtomicU64::new(0),
            draining: AtomicBool::new(false),
            shutdown: Notify::new(),
            collectors: Mutex::new(Collectors::default()),
            questions: Mutex::new(HashMap::new()),
            prompted: Mutex::new(HashMap::new()),
            saved_lock: Mutex::new(()),
            hub_state: Mutex::new(crate::hub::HubState::Off("not started".into())),
            hub_socket: Mutex::new(None),
            acpmux_daemons: Mutex::new(Vec::new()),
        })
    }

    /// Starts what the bootstrap asked for and looks for the local collector.
    pub fn start(self: &Arc<Self>) {
        lock(&self.collectors).local = Collectors::detect().local;
        let wanted = lock(&self.switches).computer_use;
        self.worker.set_wanted(wanted);
        self.start_device_hub();
        self.arm_orphan_timer();
    }

    /// The device hub collector, when the owner's config sets it up with at
    /// least one pinned approver (fail closed otherwise; status says why).
    fn start_device_hub(self: &Arc<Self>) {
        let config = crate::config::load();
        let state = crate::hub::HubState::of(&config);
        *lock(&self.hub_state) = state.clone();
        let (crate::hub::HubState::Ready, Ok(config)) = (state, config) else { return };
        let Some(hub_config) = config.device_hub.clone() else { return };
        let core = Arc::downgrade(self);
        tokio::spawn(async move {
            let machine = crate::platform::machine_name();
            match crate::hub::connect(&hub_config, &config.approvers, &machine).await {
                Ok((remote, socket)) => {
                    let Some(core) = core.upgrade() else { return };
                    core.set_remote_approver(Arc::new(remote));
                    // The socket lives as long as the host (its runtime ends it).
                    *lock(&core.hub_socket) = Some(socket);
                    core.status_changed();
                }
                Err(error) => {
                    eprintln!("cmux-remote-host: device hub: {error}");
                    if let Some(core) = core.upgrade() {
                        *lock(&core.hub_state) = crate::hub::HubState::Off(error);
                        core.status_changed();
                    }
                }
            }
        });
    }

    /// Sets the device hub collector (tests set their own).
    pub fn set_remote_approver(&self, approver: Arc<dyn RemoteApprover>) {
        lock(&self.collectors).remote = Some(approver);
    }

    fn client(&self) -> String {
        self.bootstrap.client.clone().unwrap_or_else(|| "cmux".into())
    }

    /// The acpmux images the worker admits (this build's, by SHA-256).
    pub(crate) fn acpmux_hashes(&self) -> Vec<String> {
        self.bootstrap.acpmux.as_deref().and_then(|path| wire::sha256_file(path).ok()).into_iter().collect()
    }

    pub(crate) fn acpmux_daemons(&self) -> Vec<crate::platform::ProcessStamp> {
        lock(&self.acpmux_daemons).iter().copied().filter(crate::platform::ProcessStamp::is_alive).collect()
    }

    // MARK: Saved approvals (per client; written only after a protected collector's Always)

    fn approvals_path(&self) -> PathBuf {
        let client: String = self
            .client()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() || c == '.' || c == '-' { c } else { '_' })
            .collect();
        self.state_dir.join("approvals").join(format!("{client}.json"))
    }

    pub(crate) fn saved_apps(&self) -> Vec<Target> {
        crate::platform::read_private(&self.approvals_path())
            .ok()
            .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
            .and_then(|value| value.get("apps").and_then(Value::as_array).cloned())
            .map(|apps| apps.iter().filter_map(Target::from_app_entry).collect())
            .unwrap_or_default()
    }

    fn write_saved(&self, apps: &[Target]) {
        let value = json!({"apps": apps.iter().map(Target::app_entry).collect::<Vec<_>>()});
        if let Ok(bytes) = serde_json::to_vec_pretty(&value)
            && let Err(error) = crate::platform::write_private(&self.approvals_path(), &bytes)
        {
            eprintln!("cmux-remote-host: cannot save approvals: {error}");
        }
    }

    // MARK: Status

    pub fn status(&self) -> Value {
        let switches = *lock(&self.switches);
        let config = crate::config::load();
        let mut computer_use = json!({
            "mode": config.as_ref().map(|config| config.mode.as_str()).unwrap_or("invalid"),
            "collectors": lock(&self.collectors).names(),
            "pending": lock(&self.questions).len(),
            "saved": self.saved_apps().len(),
            "endpoint_dir": self.layout.endpoint_dir().display().to_string(),
            "client": self.client(),
        });
        computer_use["device_hub"] = lock(&self.hub_state).status(&config);
        match &config {
            Ok(config) => computer_use["config"] = json!(config.source.as_ref().map(|path| path.display().to_string())),
            Err(error) => computer_use["config_error"] = json!(error),
        }
        json!({
            "protocol": wire::PROTOCOL_MAX,
            "build": env!("CARGO_PKG_VERSION"),
            "pid": std::process::id(),
            "platform": std::env::consts::OS,
            "name": "cmux Remote",
            "busy": false,
            "workers": {
                "computer-use": self.worker.status(),
                "screen-sharing": {"state": "unsupported"},
            },
            "config": {
                "computer_use": switches.computer_use,
                "screen_sharing": switches.screen_sharing,
                "headless": switches.headless,
            },
            "permissions": crate::platform::permissions(&self.state_dir.join("worker")),
            "computer_use": computer_use,
        })
    }

    fn send_event(&self, name: &str, fields: Map<String, Value>) {
        if let Some((_, sender)) = lock(&self.daemon).as_ref() {
            let _ = sender.send(wire::event(name, fields));
        }
    }

    pub(crate) fn status_changed(&self) {
        let mut fields = Map::new();
        fields.insert("status".into(), self.status());
        self.send_event("status", fields);
        if self.draining.load(Ordering::Relaxed) {
            // Nothing on Windows and Linux is busy (no Screen Sharing session): drain is exit.
            self.shutdown.notify_one();
        }
    }

    // MARK: Daemon presence

    fn arm_orphan_timer(self: &Arc<Self>) {
        let generation = self.connections.load(Ordering::Relaxed);
        let core = Arc::downgrade(self);
        tokio::spawn(async move {
            // A one-shot deadline; a daemon that connects meanwhile changes the generation.
            tokio::time::sleep(ADOPTION_GRACE).await;
            let Some(core) = core.upgrade() else { return };
            if lock(&core.daemon).is_none() && core.connections.load(Ordering::Relaxed) == generation {
                eprintln!("cmux-remote-host: no daemon adopted this host within {} s; exiting", ADOPTION_GRACE.as_secs());
                core.shutdown.notify_one();
            }
        });
    }

    // MARK: Supervisor link

    /// Serves one supervisor connection. `peer_is_daemon`: the kernel's view
    /// of the peer (Linux: the process serving the daemon socket; Windows: the
    /// daemon executable), checked by the caller; the secret alone is not
    /// enough (the record that keeps it is readable by this user's processes).
    pub async fn serve_supervisor<S>(self: &Arc<Self>, stream: S, peer_is_daemon: bool)
    where
        S: AsyncRead + AsyncWrite + Send + 'static,
    {
        let (reader, mut writer) = tokio::io::split(stream);
        let mut reader = BufReader::new(reader);
        let hello = tokio::time::timeout(HELLO_TIMEOUT, wire::read_object(&mut reader)).await;
        let hello = match hello {
            Ok(Ok(Some(hello))) => hello,
            _ => {
                let _ = writer.write_all(&wire::encode(&wire::failure(&Value::Null, "refused", "bad hello"))).await;
                return;
            }
        };
        let secret_ok = hello.get("type").and_then(Value::as_str) == Some("hello")
            && hello
                .get("secret")
                .and_then(Value::as_str)
                .and_then(wire::unhex)
                .is_some_and(|given| wire::same_secret(&given, &self.secret));
        if !secret_ok || !peer_is_daemon {
            let _ = writer.write_all(&wire::encode(&wire::failure(&Value::Null, "refused", "bad hello"))).await;
            return;
        }
        let minimum = hello.get("min").and_then(Value::as_u64).unwrap_or(1);
        let maximum = hello.get("max").and_then(Value::as_u64).unwrap_or(1);
        let Some(version) = wire::negotiate(minimum, maximum) else {
            let message = format!("no common protocol (host speaks {}...{})", wire::PROTOCOL_MIN, wire::PROTOCOL_MAX);
            let _ = writer.write_all(&wire::encode(&wire::failure(&Value::Null, "protocol", message))).await;
            return;
        };
        let (sender, mut outgoing) = mpsc::unbounded_channel::<Value>();
        let generation = self.connections.fetch_add(1, Ordering::Relaxed) + 1;
        // One daemon at a time: a handoff's new daemon replaces the old one's link.
        *lock(&self.daemon) = Some((generation, sender.clone()));
        let mut reply = Map::new();
        reply.insert("type".into(), json!("hello"));
        reply.insert("protocol".into(), json!(version));
        if let Value::Object(status) = self.status() {
            for (key, value) in status {
                reply.entry(key).or_insert(value);
            }
        }
        let _ = sender.send(Value::Object(reply));
        let writing = tokio::spawn(async move {
            while let Some(line) = outgoing.recv().await {
                if writer.write_all(&wire::encode(&line)).await.is_err() {
                    break;
                }
            }
        });
        while let Ok(Some(request)) = wire::read_object(&mut reader).await {
            if !matches!(lock(&self.daemon).as_ref(), Some((current, _)) if *current == generation) {
                break; // replaced by a newer daemon
            }
            let core = Arc::clone(self);
            let sender = sender.clone();
            tokio::spawn(async move {
                let id = request.get("id").cloned().unwrap_or(Value::Null);
                let method = request.get("method").and_then(Value::as_str).unwrap_or_default().to_owned();
                let params = request.get("params").cloned().unwrap_or_else(|| json!({}));
                let drain = method == "drain";
                let answer = core.handle(&id, &method, &params).await;
                let _ = sender.send(answer);
                if drain {
                    core.draining.store(true, Ordering::Relaxed);
                    core.status_changed();
                }
            });
        }
        let alone = {
            let mut daemon = lock(&self.daemon);
            if matches!(daemon.as_ref(), Some((current, _)) if *current == generation) {
                *daemon = None;
            }
            daemon.is_none()
        };
        drop(sender);
        writing.abort();
        if alone {
            self.arm_orphan_timer();
        }
    }

    async fn handle(self: &Arc<Self>, id: &Value, method: &str, params: &Value) -> Value {
        match method {
            "status" => wire::answer(id, self.status()),
            "refresh" => {
                self.status_changed();
                wire::answer(id, self.status())
            }
            "request" => match params.get("permission").and_then(Value::as_str) {
                Some("accessibility" | "screen-recording") => wire::answer(id, json!({"outcome": "not_needed"})),
                Some("portal") => wire::answer(id, json!({"outcome": "on_first_use"})),
                _ => wire::failure(id, "bad_request", "permission must be accessibility, screen-recording or portal"),
            },
            "open_settings" => wire::failure(id, "unsupported", "no settings pane on this platform"),
            "restart" => match params.get("worker").and_then(Value::as_str) {
                Some("computer-use") => {
                    self.worker.restart();
                    wire::answer(id, self.status())
                }
                Some("screen-sharing") => wire::answer(id, self.status()),
                _ => wire::failure(id, "bad_request", "worker must be computer-use or screen-sharing"),
            },
            "config" => {
                let next = {
                    let mut switches = lock(&self.switches);
                    if let Some(value) = params.get("computer_use").and_then(Value::as_bool) {
                        switches.computer_use = value;
                    }
                    if let Some(value) = params.get("headless").and_then(Value::as_bool) {
                        switches.headless = value;
                    }
                    *switches
                };
                self.worker.set_wanted(next.computer_use);
                self.status_changed();
                wire::answer(id, self.status())
            }
            "app_grant" => wire::failure(id, "unsupported", "no app socket on this platform"),
            "drain" => wire::answer(id, json!({"busy": false})),
            "computer_use.status" => wire::answer(id, self.status()),
            "computer_use.approvals.pending" => {
                let pending: Vec<Value> = lock(&self.questions)
                    .values()
                    .map(|question| {
                        json!({"id": short_id(&question.request.digest), "request": question.request.to_value()})
                    })
                    .collect();
                wire::answer(id, json!({"pending": pending}))
            }
            "computer_use.approvals.list" => {
                let apps: Vec<Value> = self.saved_apps().iter().map(Target::app_entry).collect();
                wire::answer(id, json!({"client": self.client(), "apps": apps}))
            }
            "computer_use.approvals.revoke" => self.revoke(id, params),
            "computer_use.approvals.deny" => match self.question_named(params) {
                Some((question, digest)) => {
                    self.deliver(question, Some(ApproverDecision { decision: Decision::Deny, digest, via: "cli".into() }));
                    wire::answer(id, json!({"ok": true}))
                }
                None => wire::failure(id, "not_found", "no waiting Computer Use question with that id"),
            },
            "computer_use.approvals.prompt" => self.collect(id, params).await,
            "computer_use.register_acpmux" => self.register_acpmux(id, params),
            _ if method.starts_with("screen.") => {
                wire::failure(id, "unsupported", "Screen Sharing runs on macOS only")
            }
            _ => wire::failure(id, "unknown_method", format!("unknown method {method}")),
        }
    }

    /// The pending question `params.id` names: the first 16 hex digits of its
    /// digest (what `computer_use.approvals.pending` lists, as on macOS), or the
    /// whole digest. Returns its worker question id and digest.
    fn question_named(&self, params: &Value) -> Option<(u64, String)> {
        let wanted = params.get("id").and_then(Value::as_str).filter(|id| id.len() >= 16)?;
        lock(&self.questions).iter().find_map(|(question, entry)| {
            let digest = &entry.request.digest;
            (digest == wanted || short_id(digest) == wanted).then(|| (*question, digest.clone()))
        })
    }

    /// Lowering trust: always allowed from the CLI and MCP.
    fn revoke(&self, id: &Value, params: &Value) -> Value {
        let all = params.get("all").and_then(Value::as_bool) == Some(true);
        let app = params.get("app").and_then(Target::from_app_entry);
        if !all && app.is_none() {
            return wire::failure(id, "bad_request", "computer_use.approvals.revoke needs app {executable|bundle_id} or all: true");
        }
        let (before, after) = {
            let _saved = lock(&self.saved_lock);
            let mut apps = self.saved_apps();
            let before = apps.len();
            apps.retain(|saved| !all && app.as_ref().is_none_or(|app| app.key() != saved.key()));
            self.write_saved(&apps);
            (before, apps.len())
        };
        let mut message = json!({"type": "revoke", "scope": if all { "all" } else { "app" }});
        if let Some(app) = &app {
            message["app"] = app.app_entry();
        }
        self.worker.send(message);
        wire::answer(id, json!({"revoked": before - after}))
    }

    /// Opens the local protected collector for a pending question with the
    /// person's chosen scope; it decides only when the person confirms there.
    async fn collect(self: &Arc<Self>, id: &Value, params: &Value) -> Value {
        let Some((question, _)) = self.question_named(params) else {
            return wire::failure(id, "not_found", "no waiting Computer Use question with that id");
        };
        // Any local caller reaches this, an agent's shell too: it may choose a
        // narrower scope, never Always (the phone or Mac offers that).
        let offered = match params.get("decision").filter(|decision| !decision.is_null()) {
            None => Decision::Session,
            Some(decision) => match decision.as_str().and_then(Decision::parse) {
                Some(offered @ (Decision::Once | Decision::Session)) => offered,
                Some(Decision::Always) => {
                    return wire::failure(id, "bad_request", "a prompt offers once or session; Always is chosen on the phone or Mac");
                }
                Some(Decision::Deny) => {
                    return wire::failure(id, "bad_request", "deny needs no collector: use computer_use.approvals.deny");
                }
                None => return wire::failure(id, "bad_request", "decision is once or session"),
            },
        };
        let Some(request) = lock(&self.questions).get(&question).map(|question| question.request.clone()) else {
            return wire::failure(id, "not_found", "no waiting Computer Use question with that id");
        };
        let Some(local) = lock(&self.collectors).local.clone() else {
            return wire::failure(id, "no_collector", "this machine has no local approval dialog; answer on your phone or Mac");
        };
        {
            let now = tokio::time::Instant::now();
            let mut prompted = lock(&self.prompted);
            if prompted.get(&question).is_some_and(|last| now.duration_since(*last) < PROMPT_COOLDOWN) {
                return wire::failure(
                    id,
                    "cooldown",
                    format!("that question was shown less than {} s ago", PROMPT_COOLDOWN.as_secs()),
                );
            }
            prompted.insert(question, now);
        }
        match local.ask(&request, offered).await {
            Some(answer) => {
                let decision = answer.decision;
                self.deliver(question, Some(answer));
                wire::answer(id, json!({"decision": decision.as_str()}))
            }
            None => wire::failure(id, "no_answer", "the dialog could not be shown"),
        }
    }

    /// Registers the acpmux daemon serving `socket` (Linux) or with `pid`,
    /// after checking it runs this build's acpmux.
    fn register_acpmux(&self, id: &Value, params: &Value) -> Value {
        let pid = params
            .get("socket")
            .and_then(Value::as_str)
            .and_then(|socket| crate::platform::listener_pid(Path::new(socket)))
            .or_else(|| params.get("pid").and_then(Value::as_u64).and_then(|pid| u32::try_from(pid).ok()));
        let Some(pid) = pid else {
            return wire::failure(id, "bad_request", "computer_use.register_acpmux needs a live socket or pid");
        };
        let hashes = self.acpmux_hashes();
        let image = crate::platform::process_exe_sha256(pid);
        if !image.as_ref().is_some_and(|image| hashes.contains(image)) {
            return wire::failure(id, "refused", "that process does not run this build's acpmux");
        }
        let Some(stamp) = crate::platform::ProcessStamp::of(pid) else {
            return wire::failure(id, "refused", "the acpmux daemon is gone");
        };
        {
            let mut daemons = lock(&self.acpmux_daemons);
            daemons.retain(crate::platform::ProcessStamp::is_alive);
            if !daemons.contains(&stamp) {
                daemons.push(stamp);
            }
        }
        self.worker.send(json!({"type": "register_acpmux", "pid": stamp.pid, "start": stamp.start}));
        wire::answer(id, json!({"pid": stamp.pid}))
    }

    // MARK: Approval questions from the worker

    pub(crate) fn worker_asked(self: &Arc<Self>, generation: u64, message: &Value) {
        let Some(id) = message.get("id").and_then(Value::as_u64) else { return };
        let request = match message.get("request").map(ApprovalRequest::parse_verified) {
            Some(Ok(request)) => request,
            _ => {
                self.worker.send(json!({"type": "app_approval", "id": id, "ok": false}));
                return;
            }
        };
        let collectors = lock(&self.collectors).clone();
        let core = Arc::downgrade(self);
        let asking = request.clone();
        // Recorded before the collectors run: an instant "nobody can answer" must find it.
        lock(&self.questions).insert(id, Question { request: request.clone(), generation, task: None });
        let task = tokio::spawn(async move {
            let deadline = Duration::from_millis(asking.answerable_until_ms.saturating_sub(crate::approval::now_ms()));
            let answer = tokio::time::timeout(deadline, collectors.ask(&asking)).await.ok().flatten();
            if let Some(core) = core.upgrade() {
                core.deliver(id, answer);
            }
        });
        match lock(&self.questions).get_mut(&id) {
            Some(question) => question.task = Some(task.abort_handle()),
            None => task.abort(), // already answered
        }
        let mut fields = Map::new();
        fields.insert("id".into(), json!(id));
        fields.insert("request".into(), request.to_value());
        self.send_event("app_approval", fields);
    }

    pub(crate) fn worker_cancelled(&self, message: &Value) {
        let Some(id) = message.get("id").and_then(Value::as_u64) else { return };
        lock(&self.prompted).remove(&id);
        if let Some(question) = lock(&self.questions).remove(&id)
            && let Some(task) = question.task
        {
            task.abort();
        }
        let mut fields = Map::new();
        fields.insert("id".into(), json!(id));
        fields.insert("outcome".into(), json!("cancelled"));
        self.send_event("app_approval_done", fields);
    }

    /// A restarted worker's questions are gone.
    pub(crate) fn worker_gone(&self, generation: u64) {
        let mut questions = lock(&self.questions);
        questions.retain(|_, question| {
            let keep = question.generation != generation;
            if !keep && let Some(task) = &question.task {
                task.abort();
            }
            keep
        });
    }

    /// The first answer for question `id` (or none): to the worker, once.
    fn deliver(&self, id: u64, answer: Option<ApproverDecision>) {
        let Some(question) = lock(&self.questions).remove(&id) else { return };
        lock(&self.prompted).remove(&id);
        if let Some(task) = &question.task {
            task.abort();
        }
        let message = match &answer {
            Some(answer) => {
                if answer.decision == Decision::Always {
                    let _saved = lock(&self.saved_lock);
                    let mut apps = self.saved_apps();
                    if !apps.iter().any(|app| app.key() == question.request.target.key()) {
                        apps.push(question.request.target.clone());
                        self.write_saved(&apps);
                    }
                }
                json!({"type": "app_approval", "id": id, "ok": true, "decision": answer.decision.as_str(),
                       "digest": answer.digest, "via": answer.via})
            }
            None => json!({"type": "app_approval", "id": id, "ok": false}),
        };
        self.worker.send_to_generation(question.generation, message);
        let mut fields = Map::new();
        fields.insert("id".into(), json!(id));
        fields.insert("outcome".into(), json!(answer.as_ref().map(|answer| answer.decision.as_str()).unwrap_or("unanswered")));
        self.send_event("app_approval_done", fields);
    }

    /// Writes `endpoint.json` for acpmux once the worker serves.
    pub(crate) fn publish_endpoint(&self, socket: &str, secret: &[u8], pid: u32) {
        let start = crate::platform::process_start(pid).unwrap_or(0);
        let endpoint = json!({"socket": socket, "secret": wire::hex(secret), "pid": pid, "start": start});
        let path = self.layout.endpoint_dir().join("endpoint.json");
        if let Err(error) = serde_json::to_vec(&endpoint).map_err(|error| error.to_string()).and_then(|bytes| crate::platform::write_private(&path, &bytes)) {
            eprintln!("cmux-remote-host: cannot write {}: {error}", path.display());
        }
    }

    pub(crate) fn withdraw_endpoint(&self) {
        let _ = std::fs::remove_file(self.layout.endpoint_dir().join("endpoint.json"));
    }

    /// Stops the worker and removes the endpoints.
    pub fn stop(&self) {
        self.worker.set_wanted(false);
        self.withdraw_endpoint();
        if cfg!(unix) {
            let _ = std::fs::remove_file(self.layout.supervisor());
        }
    }
}

/// Whether a supervisor peer is the daemon this host was started for.
pub fn peer_is_daemon(bootstrap: &Bootstrap, same_user: bool, pid: u32) -> bool {
    if !same_user {
        return false;
    }
    #[cfg(unix)]
    {
        let _ = &bootstrap.daemon_exe;
        bootstrap
            .daemon_socket
            .as_deref()
            .and_then(crate::platform::listener_pid)
            .is_some_and(|listener| listener == pid)
    }
    #[cfg(windows)]
    {
        let normalize = |path: &Path| path.to_string_lossy().to_ascii_lowercase();
        let runs_daemon_exe = match (crate::platform::process_exe(pid), bootstrap.daemon_exe.as_deref()) {
            (Some(running), Some(expected)) => normalize(&running) == normalize(expected),
            _ => false,
        };
        let serving_socket = bootstrap
            .daemon_socket
            .as_deref()
            .and_then(crate::platform::listener_pid)
            .is_some_and(|listener| listener == pid);
        windows_daemon_peer(bootstrap, runs_daemon_exe, crate::platform::ProcessStamp::of(pid), serving_socket)
    }
}

/// The Windows rule: the peer runs the daemon's executable and is either the
/// daemon that started this host (its pid and creation time from the bootstrap,
/// so a recycled pid or another copy of the same executable does not pass) or
/// the process now serving the daemon's socket (a handoff's new daemon).
pub fn windows_daemon_peer(
    bootstrap: &Bootstrap,
    runs_daemon_exe: bool,
    peer: Option<crate::platform::ProcessStamp>,
    serving_daemon_socket: bool,
) -> bool {
    let Some(peer) = peer else { return false };
    let started_us = bootstrap
        .daemon_pid
        .zip(bootstrap.daemon_start)
        .is_some_and(|(pid, start)| peer.pid == pid && peer.start == start);
    runs_daemon_exe && (started_us || serving_daemon_socket)
}

/// `cmux-remote-host host`: serves until drained or orphaned.
pub async fn run(core: Arc<HostCore>) -> Result<(), String> {
    let endpoint = core.layout.supervisor();
    let listener = crate::platform::listen(&endpoint)?;
    core.start();
    // The daemon waits for this before it connects (systemd: READY=1; else a line on stdout).
    let leaf = core.layout.dir.file_name().map(|leaf| leaf.to_string_lossy().into_owned()).unwrap_or_default();
    if !crate::platform::notify_ready(&leaf) {
        let mut stdout = tokio::io::stdout();
        let _ = stdout.write_all(b"ready\n").await;
        let _ = stdout.flush().await;
    }
    eprintln!("cmux-remote-host: ready pid={} endpoint={}", std::process::id(), endpoint.display());
    let accepting = {
        let core = Arc::clone(&core);
        tokio::spawn(async move {
            loop {
                let Ok(stream) = crate::platform::accept(&listener).await else {
                    // A persistent accept error (EMFILE, no pipe instance) must not spin a core.
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    continue;
                };
                let core = Arc::clone(&core);
                tokio::spawn(async move {
                    let daemon = crate::platform::peer_of(&stream)
                        .is_some_and(|(same_user, pid)| peer_is_daemon(&core.bootstrap, same_user, pid));
                    core.serve_supervisor(stream, daemon).await;
                });
            }
        })
    };
    core.shutdown.notified().await;
    accepting.abort();
    core.stop();
    Ok(())
}

/// A question's id for people and the CLI: the first 16 hex digits of its digest.
fn short_id(digest: &str) -> String {
    digest.chars().take(16).collect()
}

#[cfg(test)]
mod tests;
