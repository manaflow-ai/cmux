//! The Computer Use worker (`cmux-remote-host worker computer-use`), a child
//! of the host on Windows and Linux, the counterpart of the macOS worker
//! (`CmuxRemoteComputerUse`). Upstream Cua Driver runs in this process.
//!
//! Its stdin and stdout are the host's control lines (EOF stops it):
//!
//! ```text
//! host -> worker  {"type":"configure","socket":S,"secret":HEX,"acpmux_hashes":[HEX],"client":C,"machine":M,
//!                  "config":{"config":{...}}|{"error":TEXT}}   (the host's reading of the owner's config)
//!                 {"type":"register_acpmux","pid":N,"start":N}
//!                 {"type":"app_approval","id":N,"ok":true,"decision":D,"digest":HEX,"via":V} | {"type":"app_approval","id":N,"ok":false}
//!                 {"type":"approved_apps","apps":[{"bundle_id"|"executable","name"}]}
//!                 {"type":"revoke","scope":"all"|"app","app":{...}}
//! worker -> host  {"type":"ready","protocol":1,"pid":N,"socket":S,"mode":M,"driver":"ready"|REASON}
//!                 {"type":"ack","of":"register_acpmux","ok":BOOL}
//!                 {"type":"app_approval","id":N,"request":{...}}
//!                 {"type":"app_approval_cancel","id":N}
//!                 {"type":"error","error":TEXT}
//! ```
//!
//! Its socket (Linux `<layout>/w-cu.sock`, Windows a named pipe) admits only
//! acpmux bridges ([`admission`]); one admitted connection is one agent
//! session with its own trusted upstream session, destroyed with the
//! connection. Requests, as the macOS helper's (the acpmux `cua-mcp` bridge):
//!
//! ```text
//! {"secret":HEX} -> {"ok":true,"protocol":1,"capabilities":["app-approval-v1"]}
//! {"id":0,"method":"session/hello","params":{"agent","workspace","client"}}
//! {"id":N,"method":"tools/list"} | {"id":N,"method":"machine/consent"}
//! {"id":N,"method":"tools/call","name":T,"arguments":{...}}
//! -> {"id":N,"ok":true,"result":...} | {"id":N,"ok":false,"error":TEXT,"code":C}
//! ```

pub mod admission;
pub mod broker;
pub mod discovery;
pub mod driver;
pub mod target_guard;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

use async_trait::async_trait;
use serde_json::{Value, json};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;

use crate::approval::{Decision, Question, Target};
use crate::config::{ComputerUseConfig, Mode};
use crate::platform::{PeerFacts, ProcessStamp};
use crate::policy;
use admission::{AdmissionConfig, Refusal};
use discovery::Enumerator;
use broker::{Broker, GrantSink, Outcome};
use driver::{CallError, Ceiling, Driver, DriverSession, Residual, ResidualAuthority, SessionMode, SessionSpec};
use target_guard::TargetResolver;

pub const PROTOCOL: u64 = 1;
pub const CAPABILITY: &str = "app-approval-v1";
/// An `ask` session's lifetime and idle timeout (the contract's 8h and 30m).
const ASK_TTL_SECONDS: u64 = 8 * 3600;
const IDLE_TTL_SECONDS: u64 = 30 * 60;
/// Upstream's longest session (bounded boxes set up once use it).
const MAX_TTL_SECONDS: u64 = 24 * 3600;
const OUTSIDE_MANIFEST: &str = "bounded_resource_outside_manifest";

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

/// The environment the worker must run upstream with (as the macOS helper's
/// `HelperEnvironment`): no telemetry, no update check, a short window-change
/// wait, no opaque `run_script`.
pub const DRIVER_ENV: &[(&str, &str)] = &[
    ("CUA_DRIVER_RS_TELEMETRY_ENABLED", "0"),
    ("CUA_TELEMETRY_ENABLED", "false"),
    ("CUA_DRIVER_RS_UPDATE_CHECK", "false"),
    ("CUA_DRIVER_WINDOW_CHANGE_TIMEOUT_MS", "100"),
    ("CUA_DRIVER_DISABLE_RUN_SCRIPT", "1"),
];

/// One agent session's labels (display only, never authority).
#[derive(Clone, Debug, Default)]
struct Labels {
    agent: String,
    workspace: String,
}

/// An upstream session and the (session version, saved generation) it was built for.
type BuiltSession = ((u64, u64), Arc<dyn DriverSession>);

/// One admitted connection.
pub struct Session {
    id: String,
    labels: Mutex<Labels>,
    /// Apps this session may use beyond the saved list.
    grants: Mutex<Vec<Target>>,
    /// One call each: a once answered after every call stopped waiting, so the
    /// agent's retry runs (as the macOS broker's credits).
    credits: Mutex<Vec<Target>>,
    version: AtomicU64,
    /// The upstream session and the (session version, saved generation) it was built for.
    handle: tokio::sync::Mutex<Option<BuiltSession>>,
}

impl Session {
    fn new(id: String) -> Self {
        Self {
            id,
            labels: Mutex::new(Labels::default()),
            grants: Mutex::new(Vec::new()),
            credits: Mutex::new(Vec::new()),
            version: AtomicU64::new(0),
            handle: tokio::sync::Mutex::new(None),
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub async fn close(&self) {
        if let Some((_, handle)) = self.handle.lock().await.take() {
            handle.close();
        }
    }
}

/// The worker's state once configured.
pub struct Worker {
    config: Result<ComputerUseConfig, String>,
    driver: Arc<dyn Driver>,
    driver_state: String,
    /// The inventory's tool names but opaque dispatch (set once at configure).
    tools: OnceLock<Vec<String>>,
    /// Apps in the owner's bounded manifest (set once at configure).
    owner_apps: OnceLock<Vec<Target>>,
    /// Whether the owner's bounded manifest grants desktop display observation.
    owner_display: OnceLock<bool>,
    /// The desktop as the worker lists it before an app is allowed (D21).
    discovery: Arc<dyn Enumerator>,
    manifest_dir: PathBuf,
    client: String,
    machine: String,
    saved: Mutex<Vec<Target>>,
    saved_generation: AtomicU64,
    sessions: Mutex<HashMap<String, Arc<Session>>>,
    next_session: AtomicU64,
    broker: OnceLock<Arc<Broker>>,
    admission: Mutex<AdmissionConfig>,
    /// The acpmux daemon's socket: a bridge outside every registered tree
    /// makes the worker register the daemon serving it (if it runs a trusted image).
    acpmux_socket: Option<PathBuf>,
}

struct Sink(std::sync::Weak<Worker>);

impl GrantSink for Sink {
    fn grant(&self, session: &str, target: &Target, decision: Decision) {
        let Some(worker) = self.0.upgrade() else { return };
        if decision == Decision::Always {
            worker.add_saved(target.clone());
        }
        if decision == Decision::Once {
            // Only a late once reaches the sink: one call's credit.
            if let Some(session) = lock(&worker.sessions).get(session).cloned() {
                let mut credits = lock(&session.credits);
                if !credits.iter().any(|credit| credit.key() == target.key()) {
                    credits.push(target.clone());
                }
            }
            return;
        }
        if let Some(session) = lock(&worker.sessions).get(session).cloned() {
            let mut grants = lock(&session.grants);
            if !grants.iter().any(|granted| granted.key() == target.key()) {
                grants.push(target.clone());
                session.version.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

/// Standard mode's residual boundaries ask the same collectors.
struct Residuals(std::sync::Weak<Worker>);

#[async_trait]
impl ResidualAuthority for Residuals {
    async fn authorize(&self, residual: Residual) -> Option<bool> {
        let worker = self.0.upgrade()?;
        let session = lock(&worker.sessions).get(&residual.public_session).cloned()?;
        let pid = residual
            .resource
            .get("pid")
            .or_else(|| residual.resource.pointer("/fingerprint/pid"))
            .and_then(Value::as_u64)
            .and_then(|pid| u32::try_from(pid).ok());
        let target = pid.and_then(target_of_pid).unwrap_or(Target {
            bundle_id: None,
            executable: None,
            name: residual.adapter.clone(),
        });
        if target.executable.is_some()
            && policy::refusal(&target, &worker.allow_terminals()).is_some()
        {
            return Some(false);
        }
        match worker.ask(&session, target, &residual.adapter, &residual.risk).await {
            Outcome::Decided(decision) => Some(decision.allows()),
            Outcome::Timeout | Outcome::Unavailable => None,
        }
    }
}

/// The target a process id names: its running executable, never the agent's words.
pub fn target_of_pid(pid: u32) -> Option<Target> {
    let executable = crate::platform::process_exe(pid)?;
    let name = executable
        .file_stem()
        .map(|stem| stem.to_string_lossy().into_owned())
        .unwrap_or_else(|| executable.display().to_string());
    Some(Target { bundle_id: None, executable: Some(executable.display().to_string()), name })
}

/// The pid of `window_id` in a `list_windows` result.
fn pid_of_window(value: &Value, window_id: u64) -> Option<u32> {
    match value {
        Value::Object(object) => {
            if object.get("window_id").and_then(Value::as_u64) == Some(window_id)
                && let Some(pid) = object.get("pid").and_then(Value::as_u64)
            {
                return u32::try_from(pid).ok();
            }
            object.values().find_map(|child| pid_of_window(child, window_id))
        }
        Value::Array(items) => items.iter().find_map(|child| pid_of_window(child, window_id)),
        _ => None,
    }
}

/// The pid upstream named in an out-of-manifest refusal ("... pid 1234 ...").
fn pid_in_message(message: &str) -> Option<u32> {
    let mut words = message.split_whitespace();
    while let Some(word) = words.next() {
        if word == "pid" {
            return words.next()?.trim_matches(|c: char| !c.is_ascii_digit()).parse().ok();
        }
    }
    None
}

/// The executable `name` names: a path as given, else the first match on
/// `PATH` (Windows: also `name.exe`), with symlinks resolved, so the never-allowed
/// list sees the real program (`x-terminal-emulator` is a terminal).
pub fn executable_named(name: &str) -> Option<std::path::PathBuf> {
    let is_file = |path: &Path| path.is_file().then(|| std::fs::canonicalize(path).ok()).flatten();
    if name.contains(['/', '\\']) {
        let path = Path::new(name);
        return if path.is_absolute() { is_file(path) } else { None };
    }
    let mut names = vec![name.to_owned()];
    if cfg!(windows) && !name.to_ascii_lowercase().ends_with(".exe") {
        names.push(format!("{name}.exe"));
    }
    let lower = name.to_ascii_lowercase();
    if lower != name {
        names.push(lower);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).find_map(|dir| names.iter().find_map(|name| is_file(&dir.join(name))))
}

/// The worker's resolver: pids and windows of this machine, as the driver sees them.
struct LiveResolver<'a> {
    worker: &'a Worker,
    session: &'a Session,
}

#[async_trait]
impl TargetResolver for LiveResolver<'_> {
    async fn app_for_pid(&self, pid: u32) -> Option<Target> {
        let discovery = Arc::clone(&self.worker.discovery);
        tokio::task::spawn_blocking(move || discovery.app_for_pid(pid)).await.ok().flatten().map(|app| app.target())
    }

    async fn app_for_window(&self, window_id: u32) -> Option<Target> {
        // The worker's own window list first: under ask and bounded upstream refuses an unscoped list.
        let discovery = Arc::clone(&self.worker.discovery);
        let listed = tokio::task::spawn_blocking(move || discovery::pid_of_window(&*discovery, u64::from(window_id)))
            .await
            .ok()
            .flatten();
        if let Some(pid) = listed {
            return self.app_for_pid(pid).await;
        }
        let handle = self.worker.handle(self.session).await.ok()?;
        let windows = handle.call("list_windows", json!({})).await.ok()?;
        target_of_pid(pid_of_window(&windows, u64::from(window_id))?)
    }

    async fn app_named(&self, name: &str) -> Option<Target> {
        let executable = executable_named(name)?;
        let stem = executable.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default();
        Some(Target { bundle_id: None, executable: Some(executable.display().to_string()), name: stem })
    }

    async fn app_for_bundle_id(&self, _bundle_id: &str) -> Option<Target> {
        // Windows and Linux apps have no bundle id.
        None
    }
}

/// A capability manifest (version 3) as JSON text, which upstream's YAML loader reads.
pub fn manifest_json(tools: &[String], apps: &[Target], ttl_seconds: u64) -> Value {
    let apps: Vec<Value> = apps
        .iter()
        .map(|app| {
            let mut entry = json!({"windows": "all"});
            if let Some(bundle) = &app.bundle_id {
                entry["bundle_id"] = json!(bundle);
            } else if let Some(executable) = &app.executable {
                entry["executable"] = json!(executable);
            }
            entry
        })
        .collect();
    json!({
        "version": 3,
        "expires_after": format!("{}m", ttl_seconds / 60),
        "idle_timeout": format!("{}m", IDLE_TTL_SECONDS / 60),
        "resources": {"apps": apps, "desktop": {"display": false}},
        "allow": {"tools": tools},
    })
}

/// The owner's manifest with `apps` added to `resources.apps`.
fn merged_manifest(owner: &Value, apps: &[Target]) -> Value {
    let mut merged = owner.clone();
    let extra = manifest_json(&[], apps, MAX_TTL_SECONDS)["resources"]["apps"].clone();
    if merged.get("resources").is_none() {
        merged["resources"] = json!({});
    }
    let resources = &mut merged["resources"];
    if !resources.get("apps").is_some_and(Value::is_array) {
        resources["apps"] = json!([]);
    }
    if let (Some(list), Some(extra)) = (resources["apps"].as_array_mut(), extra.as_array()) {
        list.extend(extra.iter().cloned());
    }
    merged
}

/// Whether an owner's manifest grants desktop display observation (upstream then answers discovery).
fn manifest_grants_display(manifest: &Value) -> bool {
    manifest.pointer("/resources/desktop/display").and_then(Value::as_bool) == Some(true)
}

fn apps_of_manifest(manifest: &Value) -> Vec<Target> {
    manifest
        .pointer("/resources/apps")
        .and_then(Value::as_array)
        .map(|apps| apps.iter().filter_map(Target::from_app_entry).collect())
        .unwrap_or_default()
}

impl Worker {
    fn mode(&self) -> Result<Mode, String> {
        self.config.as_ref().map(|config| config.mode).map_err(Clone::clone)
    }

    fn allow_terminals(&self) -> Vec<String> {
        self.config.as_ref().map(|config| config.allow_terminals.clone()).unwrap_or_default()
    }

    fn add_saved(&self, target: Target) {
        let mut saved = lock(&self.saved);
        if !saved.iter().any(|app| app.key() == target.key()) {
            saved.push(target);
            self.saved_generation.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Spends the session's credit for `target`, if it has one.
    fn take_credit(&self, session: &Session, target: &Target) -> bool {
        let mut credits = lock(&session.credits);
        let before = credits.len();
        credits.retain(|credit| credit.key() != target.key());
        credits.len() != before
    }

    fn allowed(&self, session: &Session, target: &Target) -> bool {
        let key = target.key();
        lock(&session.grants).iter().any(|app| app.key() == key)
            || lock(&self.saved).iter().any(|app| app.key() == key)
            || self.owner_apps.get().is_some_and(|apps| apps.iter().any(|app| app.key() == key))
    }

    fn broker(&self) -> Option<&Arc<Broker>> {
        self.broker.get()
    }

    async fn ask(&self, session: &Session, target: Target, tool: &str, risk: &str) -> Outcome {
        let Some(broker) = self.broker() else { return Outcome::Unavailable };
        let labels = lock(&session.labels).clone();
        broker
            .ask(Question {
                client: self.client.clone(),
                machine: self.machine.clone(),
                session: session.id.clone(),
                agent: labels.agent,
                workspace: labels.workspace,
                target,
                tool: tool.to_owned(),
                risk: risk.to_owned(),
            })
            .await
    }

    /// The upstream session spec for `session` with `extra` apps (Allow Once).
    fn spec(&self, session: &Session, extra: &[Target]) -> Result<SessionSpec, String> {
        let mode = self.mode()?;
        let mut apps = lock(&session.grants).clone();
        apps.extend(lock(&self.saved).iter().cloned());
        apps.extend(extra.iter().cloned());
        let version = self.next_session.fetch_add(1, Ordering::Relaxed);
        let path = self.manifest_dir.join(format!("{}-{version}.yaml", session.id));
        let (mode, manifest, ttl) = match mode {
            Mode::Ask => {
                let manifest = manifest_json(self.tools.get().map_or(&[][..], Vec::as_slice), &apps, ASK_TTL_SECONDS);
                (SessionMode::Bounded, Some(manifest), ASK_TTL_SECONDS)
            }
            Mode::Bounded => {
                let owner = self.owner_manifest()?;
                (SessionMode::Bounded, Some(merged_manifest(&owner, &apps)), MAX_TTL_SECONDS)
            }
            Mode::Standard => (SessionMode::Standard, None, MAX_TTL_SECONDS),
            Mode::Unrestricted => (SessionMode::Unrestricted, None, MAX_TTL_SECONDS),
        };
        let manifest = match manifest {
            Some(manifest) => {
                let text = serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?;
                crate::platform::write_private(&path, &text)?;
                Some(path)
            }
            None => None,
        };
        Ok(SessionSpec {
            public_session: session.id.clone(),
            mode,
            manifest,
            ttl_seconds: ttl,
            idle_ttl_seconds: IDLE_TTL_SECONDS.min(ttl),
        })
    }

    fn owner_manifest(&self) -> Result<Value, String> {
        let path = self.config.as_ref().ok().and_then(|config| config.manifest.clone()).ok_or("no owner manifest")?;
        let text = crate::config::read_trusted(&path)?;
        serde_yaml_ng::from_str(&text).map_err(|error| format!("{}: {error}", path.display()))
    }

    /// The session's upstream handle, rebuilt when its grants or the saved list changed.
    async fn handle(&self, session: &Session) -> Result<Arc<dyn DriverSession>, CallError> {
        let wanted = (session.version.load(Ordering::Relaxed), self.saved_generation.load(Ordering::Relaxed));
        let mut current = session.handle.lock().await;
        if let Some((built, handle)) = current.as_ref()
            && *built == wanted
        {
            return Ok(Arc::clone(handle));
        }
        let spec = self.spec(session, &[]).map_err(|error| CallError::new("driver_unavailable", error))?;
        let handle = self.driver.session(&spec).map_err(|error| CallError::new("driver_unavailable", error))?;
        if let Some((_, old)) = current.replace((wanted, Arc::clone(&handle))) {
            old.close();
        }
        Ok(handle)
    }

    /// The approval gate for `target`; Ok(Some(app)) when only this call may use it (Allow Once).
    async fn gate(&self, session: &Session, target: &Target, tool: &str) -> Result<Option<Target>, CallError> {
        if let Some(reason) = policy::refusal(target, &self.allow_terminals()) {
            return Err(CallError::new("target_refused", format!("{}: {reason}", target.name)));
        }
        let mode = self.mode().map_err(|error| CallError::new("config_invalid", error))?;
        if !matches!(mode, Mode::Ask | Mode::Bounded) || self.allowed(session, target) {
            return Ok(None);
        }
        if self.take_credit(session, target) {
            return Ok(Some(target.clone()));
        }
        match self.ask(session, target.clone(), tool, "R1").await {
            Outcome::Decided(Decision::Once) => Ok(Some(target.clone())),
            Outcome::Decided(Decision::Session | Decision::Always) => Ok(None),
            Outcome::Decided(Decision::Deny) => {
                Err(CallError::new("approval_denied", format!("the person denied {} for this call", target.name)))
            }
            Outcome::Timeout => Err(CallError::new(
                "approval_timeout",
                format!("waiting for the person to allow {}; retry after they answer", target.name),
            )),
            Outcome::Unavailable => Err(CallError::new(
                "approval_unavailable",
                format!("nobody can approve {} on this machine now", target.name),
            )),
        }
    }

    async fn call_with(&self, session: &Session, once: &[Target], tool: &str, arguments: &Value) -> Result<Value, CallError> {
        if once.is_empty() {
            return self.handle(session).await?.call(tool, arguments.clone()).await;
        }
        let spec = self.spec(session, once).map_err(|error| CallError::new("driver_unavailable", error))?;
        let handle = self.driver.session(&spec).map_err(|error| CallError::new("driver_unavailable", error))?;
        let result = handle.call(tool, arguments.clone()).await;
        handle.close();
        result
    }

    /// The approval gate for every app of one call, in order; the apps only this call may use.
    async fn gate_all(&self, session: &Session, targets: &[Target], tool: &str) -> Result<Vec<Target>, CallError> {
        let mut once = Vec::new();
        for target in targets {
            once.extend(self.gate(session, target, tool).await?);
        }
        Ok(once)
    }

    /// One `tools/call`: resolve and check every app the call names
    /// ([`target_guard`], the macOS `CuaTargetGuard`), ask for each app outside
    /// the session before any of it runs, then run it in the session's upstream session.
    pub async fn call(&self, session: &Session, tool: &str, arguments: Value) -> Result<Value, CallError> {
        if policy::OPAQUE_TOOLS.contains(&tool) {
            return Err(CallError::new("tool_refused", format!("{tool} is not available through cmux")));
        }
        let resolver = LiveResolver { worker: self, session };
        let checked = target_guard::check(tool, &arguments, &resolver, &self.allow_terminals()).await?;
        if let Some(answer) = self.discover(session, tool, &arguments, &checked.targets).await {
            return answer;
        }
        // An action with no resolvable target (screen coordinates, the focused window) could
        // land on a never-allowed app (a terminal): refused in every mode. Ask and bounded
        // sessions also have upstream's display grant off, so this only adds the check to
        // standard and unrestricted.
        if checked.targets.is_empty() && !self.read_only(tool).await {
            return Err(CallError::new(
                "target_unresolved",
                format!("{tool} needs a pid or window_id of the app it acts on"),
            ));
        }
        let once = self.gate_all(session, &checked.targets, tool).await?;
        // The checked arguments: `launch_app` runs the executable the guard resolved.
        let arguments = checked.arguments.clone();
        let result = self.call_with(session, &once, tool, &arguments).await;
        // Upstream resolved a target the arguments did not name: ask about it, then retry once.
        // Never for a batch: its earlier steps already ran, and every app it names was asked
        // about before it started.
        if let Err(error) = &result
            && !target_guard::is_batch(tool)
            && error.code.as_deref() == Some(OUTSIDE_MANIFEST)
            && let Some(target) = pid_in_message(&error.message).and_then(target_of_pid)
            && !checked.targets.iter().any(|known| known.key() == target.key())
        {
            let mut once = once;
            once.extend(self.gate(session, &target, tool).await?);
            return self.call_with(session, &once, tool, &arguments).await;
        }
        result
    }

    /// Discovery before approval (D21, [`discovery`]): under ask, and under bounded
    /// when the owner's manifest does not grant the display, the worker answers
    /// `list_apps` and `list_windows` itself with metadata only, except
    /// `list_windows` of an app this session may use, which upstream answers
    /// with titles. None: upstream answers.
    async fn discover(
        &self,
        session: &Session,
        tool: &str,
        arguments: &Value,
        targets: &[Target],
    ) -> Option<Result<Value, CallError>> {
        if tool != "list_apps" && tool != "list_windows" {
            return None;
        }
        match self.mode().ok()? {
            Mode::Ask => {}
            Mode::Bounded if !self.owner_display.get().copied().unwrap_or(false) => {}
            _ => return None,
        }
        let pid = arguments.get("pid").and_then(Value::as_u64).and_then(|pid| u32::try_from(pid).ok());
        let scope = match (tool, pid, targets) {
            ("list_apps", _, []) => None,
            ("list_windows", None, []) => None,
            ("list_windows", Some(pid), [target]) if !self.allowed(session, target) => Some(pid),
            _ => return None,
        };
        let enumerator = Arc::clone(&self.discovery);
        let terminals = self.allow_terminals();
        let apps = tool == "list_apps";
        let answer = tokio::task::spawn_blocking(move || {
            if apps { discovery::list_apps(&*enumerator, &terminals) } else { discovery::list_windows(&*enumerator, &terminals, scope) }
        })
        .await
        .map_err(|error| CallError::new("discovery_failed", error.to_string()));
        Some(answer)
    }

    /// A session outside any connection (tests and the live check); `close` ends it.
    pub fn open_session(&self, id: &str) -> Arc<Session> {
        let session = Arc::new(Session::new(id.to_owned()));
        lock(&self.sessions).insert(session.id.clone(), Arc::clone(&session));
        session
    }

    /// What "Allow for This Session" does to `session` (the broker's grant sink).
    pub fn allow_for_session(&self, session: &Session, target: Target) {
        let mut grants = lock(&session.grants);
        if !grants.iter().any(|granted| granted.key() == target.key()) {
            grants.push(target);
            session.version.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Whether the driver's own inventory declares `tool` read only (never the caller's word).
    async fn read_only(&self, tool: &str) -> bool {
        let Ok(tools) = self.driver.tools().await else { return false };
        let mut matching = tools.as_array().into_iter().flatten().filter(|entry| entry["name"].as_str() == Some(tool));
        matching.next().is_some_and(|entry| entry["annotations"]["readOnlyHint"] == true) && matching.next().is_none()
    }

    async fn tools_list(&self) -> Result<Value, CallError> {
        let tools = self.driver.tools().await.map_err(|error| CallError::new("driver_unavailable", error))?;
        let filtered: Vec<Value> = tools
            .as_array()
            .map(|tools| {
                tools
                    .iter()
                    .filter(|tool| !tool["name"].as_str().is_some_and(|name| policy::OPAQUE_TOOLS.contains(&name)))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default();
        Ok(json!({"tools": filtered}))
    }

    fn revoke(&self, message: &Value) {
        let all = message.get("scope").and_then(Value::as_str) == Some("all");
        let app = message.get("app").and_then(Target::from_app_entry);
        let keep = |target: &Target| !all && app.as_ref().is_none_or(|app| app.key() != target.key());
        lock(&self.saved).retain(keep);
        self.saved_generation.fetch_add(1, Ordering::Relaxed);
        for session in lock(&self.sessions).values() {
            lock(&session.grants).retain(keep);
            lock(&session.credits).retain(keep);
            session.version.fetch_add(1, Ordering::Relaxed);
        }
        // Revocation stops in-flight work: every upstream session is closed now.
        let sessions: Vec<Arc<Session>> = lock(&self.sessions).values().cloned().collect();
        tokio::spawn(async move {
            for session in sessions {
                session.close().await;
            }
        });
    }

    fn set_saved(&self, message: &Value) {
        let apps: Vec<Target> = message
            .get("apps")
            .and_then(Value::as_array)
            .map(|apps| apps.iter().filter_map(Target::from_app_entry).collect())
            .unwrap_or_default();
        *lock(&self.saved) = apps;
        self.saved_generation.fetch_add(1, Ordering::Relaxed);
    }
}

/// Serves one admitted connection until it closes.
pub async fn serve_session<S: AsyncRead + AsyncWrite + Unpin>(worker: Arc<Worker>, stream: S) {
    let (reader, mut writer) = tokio::io::split(stream);
    let mut reader = BufReader::new(reader);
    let config = lock(&worker.admission).clone();
    let presented = match crate::wire::read_object(&mut reader).await {
        Ok(Some(object)) => object.get("secret").and_then(Value::as_str).and_then(crate::wire::unhex),
        _ => None,
    };
    if let Some(refusal) = admission::check_secret(presented.as_deref(), &config) {
        let _ = writer.write_all(&refused(refusal)).await;
        return;
    }
    let Ok(random) = crate::wire::make_secret() else {
        let _ = writer.write_all(&crate::wire::encode(&json!({"ok": false, "error": "no randomness for a session id"}))).await;
        return;
    };
    let id = format!("cu-{}", crate::wire::hex(&random[..8]));
    let session = worker.open_session(&id);
    let hello = json!({"ok": true, "protocol": PROTOCOL, "capabilities": [CAPABILITY]});
    if writer.write_all(&crate::wire::encode(&hello)).await.is_ok() {
        while let Ok(Some(request)) = crate::wire::read_object(&mut reader).await {
            let request = Value::Object(request);
            let reply = handle_request(&worker, &session, &request).await;
            if writer.write_all(&crate::wire::encode(&reply)).await.is_err() {
                break;
            }
        }
    }
    // The connection is the session: its questions, grants and upstream session end with it.
    lock(&worker.sessions).remove(&id);
    if let Some(broker) = worker.broker() {
        broker.cancel_session(&id);
    }
    session.close().await;
}

fn refused(refusal: Refusal) -> Vec<u8> {
    crate::wire::encode(&json!({"ok": false, "error": "refused", "reason": refusal.as_str()}))
}

async fn handle_request(worker: &Worker, session: &Session, request: &Value) -> Value {
    let id = request.get("id").cloned().unwrap_or(Value::Null);
    let method = request.get("method").and_then(Value::as_str).unwrap_or_default();
    let result = match method {
        "session/hello" => {
            let params = &request["params"];
            let label = |key: &str| params.get(key).and_then(Value::as_str).unwrap_or_default().chars().take(80).collect();
            *lock(&session.labels) = Labels { agent: label("agent"), workspace: label("workspace") };
            Ok(json!({"session": session.id}))
        }
        "tools/list" => worker.tools_list().await,
        // Windows and Linux have no app machine consent: approvals bind each app instead.
        "machine/consent" => Ok(json!({"consentRequired": false, "consent": {"screen": "none", "control": "none"}})),
        "tools/call" => match request.get("name").and_then(Value::as_str).filter(|name| !name.is_empty()) {
            Some(name) => worker.call(session, name, request.get("arguments").cloned().unwrap_or_else(|| json!({}))).await,
            None => Err(CallError::new("bad_request", "tools/call needs a name")),
        },
        other => Err(CallError::new("bad_request", format!("unknown method {other}"))),
    };
    match result {
        Ok(result) => json!({"id": id, "ok": true, "result": result}),
        Err(error) => {
            let mut reply = json!({"id": id, "ok": false, "error": error.message});
            if let Some(code) = error.code {
                reply["code"] = json!(code);
            }
            reply
        }
    }
}

/// The checks at accept, before a byte is read.
fn admit_identity(worker: &Worker, same_user: bool, pid: u32) -> Option<Refusal> {
    let Some(facts) = PeerFacts::of(pid, same_user) else { return Some(Refusal::ForeignUser) };
    let config = lock(&worker.admission).clone();
    match admission::check_identity(&facts, Some(&config)) {
        Some(Refusal::OutsideAcpmuxTree) if worker.register_acpmux_daemon(&config) => {
            admission::check_identity(&facts, Some(&lock(&worker.admission).clone()))
        }
        other => other,
    }
}

impl Worker {
    /// Registers the process serving the acpmux socket when it runs a trusted
    /// acpmux image; true when a new daemon was added.
    fn register_acpmux_daemon(&self, config: &AdmissionConfig) -> bool {
        let Some(pid) = self.acpmux_socket.as_deref().and_then(crate::platform::listener_pid) else { return false };
        let trusted = crate::platform::process_exe_sha256(pid).is_some_and(|hash| config.acpmux_hashes.contains(&hash));
        let Some(stamp) = ProcessStamp::of(pid).filter(|_| trusted) else { return false };
        lock(&self.admission).daemons.insert(stamp)
    }
}

/// The runtime ceiling for the configured mode (docs/computer-use-approvals.md:
/// the configured mode, plus bounded under ask; unrestricted acknowledged only for unrestricted).
fn ceiling(mode: Mode, compatibility_manifest: &Path) -> Ceiling {
    let (allowed, compatibility) = match mode {
        Mode::Ask | Mode::Bounded => (vec![SessionMode::Bounded], SessionMode::Bounded),
        Mode::Standard => (vec![SessionMode::Standard], SessionMode::Standard),
        Mode::Unrestricted => (vec![SessionMode::Unrestricted], SessionMode::Unrestricted),
    };
    Ceiling {
        allowed,
        compatibility,
        compatibility_manifest: (compatibility == SessionMode::Bounded).then(|| compatibility_manifest.to_path_buf()),
        unrestricted_acknowledged: mode == Mode::Unrestricted,
        max_session_ttl_seconds: MAX_TTL_SECONDS,
        max_idle_ttl_seconds: IDLE_TTL_SECONDS,
    }
}

/// Builds the driver for `config`.
fn make_driver(config: &Result<ComputerUseConfig, String>, state_dir: &Path, residual: Arc<dyn ResidualAuthority>) -> (Arc<dyn Driver>, String) {
    let mode = match config {
        Ok(config) => config.mode,
        Err(error) => return (Arc::new(driver::Unavailable(error.clone())), format!("config: {error}")),
    };
    let compatibility = state_dir.join("manifests").join("compatibility.yaml");
    let empty = manifest_json(&[], &[], MAX_TTL_SECONDS);
    if let Err(error) = serde_json::to_vec(&empty).map_err(|error| error.to_string()).and_then(|bytes| crate::platform::write_private(&compatibility, &bytes)) {
        return (Arc::new(driver::Unavailable(error.clone())), error);
    }
    #[cfg(feature = "driver")]
    {
        match driver::CuaDriverRuntime::create(&ceiling(mode, &compatibility), residual) {
            Ok(runtime) => (Arc::new(runtime), "ready".into()),
            Err(error) => (Arc::new(driver::Unavailable(error.clone())), error),
        }
    }
    #[cfg(not(feature = "driver"))]
    {
        let _ = (mode, residual, ceiling(mode, &compatibility));
        let reason = "this build has no Cua Driver (feature `driver`)".to_owned();
        (Arc::new(driver::Unavailable(reason.clone())), reason)
    }
}

/// `cmux-remote-host worker computer-use`: serves until the host closes stdin.
pub async fn run(layout_dir: PathBuf, state_dir: PathBuf) -> Result<(), String> {
    let (to_host, mut outgoing) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = outgoing.recv().await {
            if stdout.write_all(&crate::wire::encode(&line)).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    let mut stdin = BufReader::new(tokio::io::stdin());
    let mut worker: Option<Arc<Worker>> = None;
    while let Ok(Some(message)) = crate::wire::read_object(&mut stdin).await {
        let message = Value::Object(message);
        match message.get("type").and_then(Value::as_str).unwrap_or_default() {
            "configure" if worker.is_none() => match configure(&message, &layout_dir, &state_dir, to_host.clone()).await {
                Ok(configured) => worker = Some(configured),
                Err(error) => {
                    let _ = to_host.send(json!({"type": "error", "error": error}));
                }
            },
            "configure" => {
                let _ = to_host.send(json!({"type": "error", "error": "already configured"}));
            }
            "register_acpmux" => {
                let stamp = message
                    .get("pid")
                    .and_then(Value::as_u64)
                    .and_then(|pid| u32::try_from(pid).ok())
                    .zip(message.get("start").and_then(Value::as_u64))
                    .map(|(pid, start)| ProcessStamp { pid, start });
                let ok = match (&worker, stamp) {
                    (Some(worker), Some(stamp)) if stamp.is_alive() => {
                        lock(&worker.admission).daemons.insert(stamp);
                        true
                    }
                    _ => false,
                };
                let _ = to_host.send(json!({"type": "ack", "of": "register_acpmux", "ok": ok}));
            }
            "app_approval" => {
                if let Some(broker) = worker.as_ref().and_then(|worker| worker.broker()) {
                    broker.answer(&message);
                }
            }
            "approved_apps" => {
                if let Some(worker) = &worker {
                    worker.set_saved(&message);
                }
            }
            "revoke" => {
                if let Some(worker) = &worker {
                    worker.revoke(&message);
                }
            }
            other => {
                let _ = to_host.send(json!({"type": "error", "error": format!("unknown control message {other}")}));
            }
        }
    }
    drop(to_host);
    let _ = writer.await;
    Ok(())
}

async fn configure(message: &Value, layout_dir: &Path, state_dir: &Path, to_host: mpsc::UnboundedSender<Value>) -> Result<Arc<Worker>, String> {
    let socket = message.get("socket").and_then(Value::as_str).map(PathBuf::from).ok_or("configure needs socket")?;
    let secret = message
        .get("secret")
        .and_then(Value::as_str)
        .and_then(crate::wire::unhex)
        .filter(|secret| secret.len() >= 16)
        .ok_or("configure needs a secret of at least 16 bytes")?;
    let hashes = message
        .get("acpmux_hashes")
        .and_then(Value::as_array)
        .map(|hashes| hashes.iter().filter_map(Value::as_str).map(str::to_ascii_lowercase).collect())
        .unwrap_or_default();
    let text = |key: &str| message.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    // The host's reading of the owner's config (one reading for the host, its
    // device hub collector and this worker; `computer_use.reload` makes a new one).
    let config = match message.get("config") {
        Some(snapshot) => crate::config::snapshot_of(snapshot),
        None => crate::config::load(),
    };
    let manifest_dir = state_dir.join("manifests");
    crate::platform::make_private_dir(&manifest_dir)?;
    let worker = Arc::new_cyclic(|weak: &std::sync::Weak<Worker>| {
        let (driver, driver_state) = make_driver(&config, state_dir, Arc::new(Residuals(weak.clone())));
        let mut worker = Worker::assemble(config, driver, driver_state, discovery::live(), manifest_dir);
        worker.client = text("client");
        worker.machine = if text("machine").is_empty() { crate::platform::machine_name() } else { text("machine") };
        worker.admission = Mutex::new(AdmissionConfig { acpmux_hashes: hashes, daemons: Default::default(), secret });
        worker.acpmux_socket = message.get("acpmux_socket").and_then(Value::as_str).map(PathBuf::from);
        worker
    });
    let _ = worker.broker.set(Broker::new(to_host.clone(), Arc::new(Sink(Arc::downgrade(&worker)))));
    worker.load_fixed().await;
    serve(&worker, &socket, layout_dir)?;
    let mode = worker.mode().map(Mode::as_str).unwrap_or("invalid");
    let _ = to_host.send(json!({
        "type": "ready", "protocol": PROTOCOL, "pid": std::process::id(),
        "socket": socket.display().to_string(), "mode": mode, "driver": worker.driver_state,
    }));
    Ok(worker)
}

impl Worker {
    fn assemble(
        config: Result<ComputerUseConfig, String>,
        driver: Arc<dyn Driver>,
        driver_state: String,
        discovery: Arc<dyn Enumerator>,
        manifest_dir: PathBuf,
    ) -> Worker {
        Worker {
            owner_apps: OnceLock::new(),
            owner_display: OnceLock::new(),
            discovery,
            config,
            driver,
            driver_state,
            tools: OnceLock::new(),
            manifest_dir,
            client: String::new(),
            machine: String::new(),
            saved: Mutex::new(Vec::new()),
            saved_generation: AtomicU64::new(0),
            sessions: Mutex::new(HashMap::new()),
            next_session: AtomicU64::new(1),
            broker: OnceLock::new(),
            admission: Mutex::new(AdmissionConfig::default()),
            acpmux_socket: None,
        }
    }

    /// The inventory and the owner's manifest facts, once (fixed for the worker's life).
    async fn load_fixed(&self) {
        let tools: Vec<String> = self
            .driver
            .tools()
            .await
            .ok()
            .and_then(|tools| tools.as_array().map(|tools| tools.iter().filter_map(|tool| tool["name"].as_str().map(str::to_owned)).collect()))
            .unwrap_or_default();
        let tools: Vec<String> = tools.into_iter().filter(|name| !policy::OPAQUE_TOOLS.contains(&name.as_str())).collect();
        let owner = if self.mode() == Ok(Mode::Bounded) { self.owner_manifest().ok() } else { None };
        let _ = self.tools.set(tools);
        let _ = self.owner_apps.set(owner.as_ref().map(apps_of_manifest).unwrap_or_default());
        let _ = self.owner_display.set(owner.as_ref().is_some_and(manifest_grants_display));
    }

    /// A worker with no host link and no socket (tests and the live check):
    /// nobody can answer a question, so an app outside a session is refused
    /// `approval_unavailable`.
    pub async fn detached(
        config: Result<ComputerUseConfig, String>,
        driver: Arc<dyn Driver>,
        discovery: Arc<dyn Enumerator>,
        manifest_dir: PathBuf,
    ) -> Result<Arc<Worker>, String> {
        crate::platform::make_private_dir(&manifest_dir)?;
        let worker = Arc::new(Worker::assemble(config, driver, "ready".into(), discovery, manifest_dir));
        worker.load_fixed().await;
        Ok(worker)
    }
}

/// Accepts on the worker's socket; identity is checked at accept.
fn serve(worker: &Arc<Worker>, socket: &Path, _layout_dir: &Path) -> Result<(), String> {
    let listener = crate::platform::listen(socket)?;
    let worker = Arc::clone(worker);
    tokio::spawn(async move {
        loop {
            let stream = match crate::platform::accept(&listener).await {
                Ok(stream) => stream,
                Err(_) => {
                    // A persistent accept error must not spin a core.
                    tokio::time::sleep(std::time::Duration::from_millis(100)).await;
                    continue;
                }
            };
            let worker = Arc::clone(&worker);
            tokio::spawn(async move {
                let mut stream = stream;
                let refusal = match crate::platform::peer_of(&stream) {
                    Some((same_user, pid)) => admit_identity(&worker, same_user, pid),
                    None => Some(Refusal::ForeignUser),
                };
                if let Some(refusal) = refusal {
                    let _ = stream.write_all(&refused(refusal)).await;
                    return;
                }
                serve_session(worker, stream).await;
            });
        }
    });
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_manifest_lists_tools_apps_and_no_display() {
        let app = Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() };
        let manifest = manifest_json(&["click".into()], &[app], ASK_TTL_SECONDS);
        assert_eq!(manifest["version"], 3);
        assert_eq!(manifest["expires_after"], "480m");
        assert_eq!(manifest["idle_timeout"], "30m");
        assert_eq!(manifest["resources"]["apps"][0], json!({"executable": "/usr/bin/gedit", "windows": "all"}));
        assert_eq!(manifest["resources"]["desktop"]["display"], false);
        assert_eq!(manifest["allow"]["tools"], json!(["click"]));
    }

    #[test]
    fn owner_manifests_keep_their_apps_and_gain_grants() {
        let owner: Value = serde_yaml_ng::from_str("version: 3\nresources:\n  apps:\n    - executable: /usr/bin/xed\nallow:\n  tools: [click]\n").unwrap();
        let app = Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "gedit".into() };
        let merged = merged_manifest(&owner, &[app]);
        assert_eq!(merged["resources"]["apps"].as_array().unwrap().len(), 2);
        assert_eq!(apps_of_manifest(&owner)[0].executable.as_deref(), Some("/usr/bin/xed"));
    }

    #[test]
    fn targets_come_from_the_window_list_and_refusal_text() {
        let windows = json!({"windows": [{"pid": 41, "window_id": 7}, {"pid": 42, "window_id": 8}]});
        assert_eq!(pid_of_window(&windows, 8), Some(42));
        assert_eq!(pid_of_window(&windows, 9), None);
        assert_eq!(pid_in_message("desktop pid 1234 window 7 is outside the capability manifest"), Some(1234));
        assert_eq!(pid_in_message("nothing here"), None);
    }

    #[test]
    fn the_ceiling_allows_only_the_configured_mode() {
        let path = Path::new("/x/compat.yaml");
        let ask = ceiling(Mode::Ask, path);
        assert_eq!(ask.allowed, vec![SessionMode::Bounded]);
        assert!(!ask.unrestricted_acknowledged);
        assert!(ask.compatibility_manifest.is_some());
        let open = ceiling(Mode::Unrestricted, path);
        assert_eq!(open.allowed, vec![SessionMode::Unrestricted]);
        assert!(open.unrestricted_acknowledged);
    }
}
