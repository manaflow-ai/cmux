//! `cmux cloud codex-holder`: the app's one long-lived Codex holder process. JSON lines both
//! ways on private pipes (credentials never in argv):
//!
//! App to holder: the first line is `{"op":"config","root","user_home"}`; then
//! `{"op":"run","id","machine","scope","confirmed","force","ask_local"}`, `listed {"live":[ids]}`,
//! `delivers`, `revoke`, `deleted` (each with `machine` and `scope`), `scope_changed`,
//! `available {"enabled"}` (answered when it has an id), `sign_out`, `detach`, `shutdown`,
//! `local_access`, `cancel {"run"}`, and `answer {"id","value"}`. Any line may carry `"current": scope|null` (the signed-in scope
//! now) and `"acpmux": path` (the holder child's executable).
//!
//! A holder the app starts again (the last one ended) gets `restore {"scopes":[scope],"live":[ids]}`
//! right after the config, under the `current` the last one held: what that one knew. Every
//! later line but `answer` and `cancel` waits until the restore is done, so a sign-out, switch or
//! off switch that follows erases what the last holder delivered. An off switch still fences at
//! once (no renewal or write goes on); only its retirement waits.
//!
//! Holder to app: `{"reply":id,"ok":true,"value":V}` or
//! `{"reply":id,"ok":false,"error":code,"message":text}`, and questions
//! `{"ask":"credential"|"owner"|"live"|"consent"|"local_sign_in"|"device_code","id",...}` the
//! app answers; `{"cancel_ask":id}` ends one (its prompt closes).
//!
//! End of input (the app quit or died) detaches: delivered access stays on each machine.

use std::collections::{HashMap, HashSet, VecDeque};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};

use async_trait::async_trait;
use futures_util::FutureExt as _;
use serde_json::{Map, Value, json};
use tokio::io::{AsyncBufReadExt as _, AsyncRead, AsyncWrite, AsyncWriteExt as _};
use tokio::sync::{mpsc, oneshot};

use crate::adapter::{Adapter, AskFn, PresentFn};
use crate::broker::Launch;
use crate::cx::Cx;
use crate::error::{BrokerError, Error};
use crate::local_access;
use crate::registry::Registry;
use crate::target::{MachineTarget, Machines, Questions};
use crate::types::{Scope, now};

/// What the app tells the holder at start.
#[derive(Clone, Debug)]
pub struct Config {
    /// The app's Cloud folder; holders live in `root/codex-holders/<scope digest>`.
    pub root: PathBuf,
    pub user_home: PathBuf,
    /// The whole config line, for the machine routes' own fields (`api`, `cache_dir`, `app_version`).
    pub line: Value,
}

impl Config {
    fn from_json(value: &Value) -> Option<Self> {
        if value.get("op")?.as_str()? != "config" {
            return None;
        }
        let path = |key: &str| value.get(key).and_then(Value::as_str).map(PathBuf::from);
        Some(Self { root: path("root")?, user_home: path("user_home")?, line: value.clone() })
    }
}

/// The app's side of the pipe: questions it answers.
pub struct App {
    out: mpsc::UnboundedSender<String>,
    waiting: Mutex<HashMap<u64, oneshot::Sender<Value>>>,
    next: AtomicU64,
    /// Set at the end of input: no one answers any more, so every question ends at once.
    closed: AtomicBool,
}

impl App {
    fn waiting(&self) -> MutexGuard<'_, HashMap<u64, oneshot::Sender<Value>>> {
        self.waiting.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn send(&self, value: &Value) {
        let _ = self.out.send(value.to_string());
    }

    /// Asks the app `kind` and waits for its answer; none when the app is gone or `cx` cancels
    /// (the app is told, so a prompt it shows closes).
    pub async fn ask(&self, cx: &Cx, kind: &str, fields: Value) -> Option<Value> {
        let id = self.next.fetch_add(1, Ordering::SeqCst).saturating_add(1);
        let (sender, receiver) = oneshot::channel();
        {
            let mut waiting = self.waiting();
            if self.closed.load(Ordering::SeqCst) {
                return None;
            }
            waiting.insert(id, sender);
        }
        let mut message = match fields {
            Value::Object(map) => map,
            _ => Map::new(),
        };
        message.insert("ask".into(), Value::from(kind));
        message.insert("id".into(), Value::from(id));
        self.send(&Value::Object(message));
        tokio::select! {
            biased;
            () = cx.cancelled() => {
                self.waiting().remove(&id);
                self.send(&json!({ "cancel_ask": id }));
                None
            }
            answer = receiver => answer.ok(),
        }
    }

    fn answer(&self, id: u64, value: Value) {
        if let Some(sender) = self.waiting().remove(&id) {
            let _ = sender.send(value);
        }
    }

    /// The person's Cloud access token, from the app's sign-in (refreshed there as needed).
    pub async fn credential(&self) -> Option<String> {
        self.ask(&Cx::never(), "credential", json!({})).await?.as_str().map(str::to_owned)
    }

    async fn flag(&self, cx: &Cx, kind: &str, fields: Value) -> Result<bool, Error> {
        match self.ask(cx, kind, fields).await {
            Some(Value::Bool(answer)) => Ok(answer),
            Some(_) => Ok(false),
            None if cx.is_cancelled() => Err(Error::Interrupted),
            None => Err(BrokerError::BrokerUnavailable.into()),
        }
    }
}

struct AppQuestions(Arc<App>);

#[async_trait]
impl Questions for AppQuestions {
    async fn owns(&self, machine: &str) -> Result<bool, Error> {
        self.0.flag(&Cx::never(), "owner", json!({ "machine": machine })).await
    }
    async fn live(&self, machine: &str) -> Result<bool, Error> {
        self.0.flag(&Cx::never(), "live", json!({ "machine": machine })).await
    }
}

/// The holder's own state between lines.
struct Holder {
    adapter: Arc<Adapter>,
    app: Arc<App>,
    config: Config,
    current: Arc<Mutex<Option<Scope>>>,
    acpmux: Arc<Mutex<Option<PathBuf>>>,
    runs: Mutex<Runs>,
    /// Lines held while a restore runs, acted on in order once it is done.
    held: Mutex<Option<VecDeque<Value>>>,
}

/// The runs in flight by request id, and the highest request id read so far. The app numbers
/// its requests in the order it writes them, so a cancel for an id above that one is for a run
/// whose line is still on its way (its cancel overtook it): the run starts cancelled.
#[derive(Default)]
struct Runs {
    live: HashMap<u64, Cx>,
    highest: u64,
}

impl Runs {
    fn cancel(&mut self, run: u64) {
        if let Some(cx) = self.live.get(&run) {
            cx.cancel();
        } else if run > self.highest {
            let cx = Cx::new();
            cx.cancel();
            self.live.insert(run, cx);
        }
    }

    /// A request line read: a run's Cx (kept when a cancel came first).
    fn read(&mut self, id: u64, run: bool) {
        self.highest = self.highest.max(id);
        if run {
            self.live.entry(id).or_default();
        } else {
            // A cancel for this id was not for a run after all.
            self.live.remove(&id);
        }
    }
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// The first `codex` on PATH or in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`.
pub fn find_codex(path: Option<&str>, user_home: &Path) -> Option<PathBuf> {
    let mut search: Vec<PathBuf> = path.unwrap_or_default().split(':').map(PathBuf::from).collect();
    search.extend([
        user_home.join(".local/bin"),
        "/opt/homebrew/bin".into(),
        "/usr/local/bin".into(),
    ]);
    search.into_iter().filter(|dir| dir.is_absolute()).map(|dir| dir.join("codex")).find(|codex| {
        std::fs::metadata(codex).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    })
}

impl Holder {
    fn new(config: Config, app: Arc<App>, machines: Arc<dyn Machines>) -> Arc<Self> {
        let current: Arc<Mutex<Option<Scope>>> = Arc::default();
        let acpmux: Arc<Mutex<Option<PathBuf>>> = Arc::default();
        let scope_source = current.clone();
        let (launch_acpmux, user_home) = (acpmux.clone(), config.user_home.clone());
        let questions: Arc<dyn Questions> = Arc::new(AppQuestions(app.clone()));
        let adapter = Adapter::new(
            config.root.clone(),
            Arc::new(Registry::default()),
            Arc::new(move || lock(&scope_source).clone()),
            Arc::new(move || {
                let executable = lock(&launch_acpmux).clone();
                let user_home = user_home.clone();
                async move {
                    let executable =
                        executable.ok_or(Error::Broker(BrokerError::BrokerUnavailable))?;
                    let environment: HashMap<String, String> = std::env::vars().collect();
                    let codex = find_codex(environment.get("PATH").map(String::as_str), &user_home)
                        .ok_or(Error::Broker(BrokerError::BrokerUnavailable))?;
                    Ok(Launch { executable, prefix: Vec::new(), codex, environment, user_home })
                }
                .boxed()
            }),
            Arc::new(move |scope: &Scope, machine: &str| {
                Arc::new(MachineTarget {
                    machine: machine.to_owned(),
                    team: scope.team.clone(),
                    machines: machines.clone(),
                    questions: questions.clone(),
                }) as crate::target::TargetRef
            }),
        );
        let (consent_app, user_home) = (app.clone(), config.user_home.clone());
        adapter.set_local_sign_in(Some(Arc::new(move || {
            let (app, user_home) = (consent_app.clone(), user_home.clone());
            async move {
                // The Mac's access only while the person's yes stands.
                if app.ask(&Cx::never(), "consent", json!({})).await != Some(Value::Bool(true)) {
                    return None;
                }
                tokio::task::spawn_blocking(move || mac_access(&user_home)).await.ok().flatten()
            }
            .boxed()
        })));
        Arc::new(Self {
            adapter,
            app,
            config,
            current,
            acpmux,
            runs: Mutex::default(),
            held: Mutex::default(),
        })
    }

    /// Takes one app line. Returns false at a line that is not JSON.
    fn take(self: &Arc<Self>, line: &str) -> bool {
        let Ok(message) = serde_json::from_str::<Value>(line) else { return false };
        let op = message.get("op").and_then(Value::as_str).unwrap_or_default();
        // The off switch fences at once, even while a restore holds the lines after it: a renewal
        // already running stops there. Its retirement still comes in order (below).
        if op == "available" && message.get("enabled").and_then(Value::as_bool) == Some(false) {
            self.adapter.fence();
        }
        // A restore's own questions need their answers, and a cancel may end a held run.
        if op != "answer" && op != "cancel" {
            let mut held = lock(&self.held);
            if let Some(queue) = held.as_mut() {
                queue.push_back(message);
                return true;
            }
            if op == "restore" {
                *held = Some(VecDeque::new());
                drop(held);
                self.restore(message);
                return true;
            }
        }
        self.act(message);
        true
    }

    /// Takes back what the last holder knew, then acts on the lines held meanwhile.
    fn restore(self: &Arc<Self>, message: Value) {
        self.note(&message);
        let scopes: Vec<Scope> = message
            .get("scopes")
            .and_then(Value::as_array)
            .map(|all| all.iter().filter_map(Scope::from_json).collect())
            .unwrap_or_default();
        let live = ids(&message, "live");
        let this = self.clone();
        tokio::spawn(async move {
            this.adapter.restore(scopes, live).await;
            loop {
                let next = {
                    let mut held = lock(&this.held);
                    match held.as_mut().and_then(VecDeque::pop_front) {
                        Some(next) => next,
                        None => {
                            *held = None;
                            break;
                        }
                    }
                };
                this.act(next);
            }
        });
    }

    /// The scope and holder child a line names.
    fn note(&self, message: &Value) {
        if let Some(current) = message.get("current") {
            *lock(&self.current) = Scope::from_json(current);
        }
        if let Some(path) = message.get("acpmux").and_then(Value::as_str) {
            *lock(&self.acpmux) = Some(PathBuf::from(path));
        }
    }

    fn act(self: &Arc<Self>, message: Value) {
        self.note(&message);
        match message.get("op").and_then(Value::as_str).unwrap_or_default() {
            "answer" => {
                if let Some(id) = message.get("id").and_then(Value::as_u64) {
                    self.app.answer(id, message.get("value").cloned().unwrap_or(Value::Null));
                }
            }
            "cancel" => {
                let run = message.get("run").and_then(Value::as_u64).unwrap_or_default();
                lock(&self.runs).cancel(run);
            }
            "available" => {
                self.adapter
                    .set_available(message.get("enabled").and_then(Value::as_bool) != Some(false));
                // The app's own switch carries an id: the reply says the fence is in place.
                if let Some(id) = message.get("id").and_then(Value::as_u64) {
                    self.app.send(&json!({ "reply": id, "ok": true, "value": Value::Null }));
                }
            }
            "listed" => self.adapter.machines_listed(ids(&message, "live")),
            // Only a holder's first line after its config restores (above).
            "" | "restore" => {}
            op => {
                if let Some(id) = message.get("id").and_then(Value::as_u64) {
                    lock(&self.runs).read(id, op == "run");
                }
                let this = self.clone();
                tokio::spawn(async move { this.reply(message).await });
            }
        }
    }

    async fn reply(self: Arc<Self>, message: Value) {
        let Some(id) = message.get("id").and_then(Value::as_u64) else { return };
        let answer = self.perform(id, &message).await;
        let line = match answer {
            Ok(value) => json!({ "reply": id, "ok": true, "value": value }),
            Err(error) => {
                json!({ "reply": id, "ok": false, "error": error.code(), "message": error.message() })
            }
        };
        self.app.send(&line);
    }

    async fn perform(&self, id: u64, message: &Value) -> Result<Value, Error> {
        let text =
            |key: &str| message.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        let scope = message.get("scope").and_then(Scope::from_json);
        let scoped = || scope.clone().ok_or(Error::Other("a scope is needed".into()));
        match message.get("op").and_then(Value::as_str).unwrap_or_default() {
            "run" => {
                let cx = lock(&self.runs).live.get(&id).cloned().unwrap_or_else(Cx::new);
                let result = match scoped() {
                    Ok(scope) => self.run(&cx, id, message, &scope).await,
                    Err(error) => Err(error),
                };
                lock(&self.runs).live.remove(&id);
                result.map(|()| Value::Null)
            }
            "delivers" => Ok(Value::Bool(self.adapter.delivers(&text("machine"), &scoped()?))),
            "revoke" => {
                self.adapter.revoke(&text("machine"), &scoped()?).await.map(|()| Value::Null)
            }
            "deleted" => {
                self.adapter.machine_was_deleted(&text("machine"), &scoped()?);
                Ok(Value::Null)
            }
            "scope_changed" => {
                self.adapter.scope_did_change().await;
                Ok(Value::Null)
            }
            "sign_out" => {
                self.adapter.sign_out().await;
                Ok(Value::Null)
            }
            "detach" => {
                self.adapter.detach_for_quit().await;
                Ok(Value::Null)
            }
            "shutdown" => {
                self.adapter.shutdown().await;
                Ok(Value::Null)
            }
            "local_access" => {
                let user_home = self.config.user_home.clone();
                let has =
                    tokio::task::spawn_blocking(move || mac_access(&user_home).is_some()).await;
                Ok(Value::Bool(has.unwrap_or(false)))
            }
            "pending_cleanup" => {
                let mut ids: Vec<String> = self.adapter.pending_cleanup().into_iter().collect();
                ids.sort();
                Ok(json!(ids))
            }
            other => Err(Error::Other(format!("unknown holder op `{other}`"))),
        }
    }

    async fn run(&self, cx: &Cx, id: u64, message: &Value, scope: &Scope) -> Result<(), Error> {
        let flag = |key: &str| message.get(key).and_then(Value::as_bool).unwrap_or(false);
        let app = self.app.clone();
        let ask: Option<AskFn> = flag("ask_local").then(|| {
            let app = app.clone();
            let ask: AskFn = Arc::new(move |cx: Cx| {
                let app = app.clone();
                async move {
                    app.flag(&cx, "local_sign_in", json!({ "run": id })).await.unwrap_or(false)
                }
                .boxed()
            });
            ask
        });
        let present: PresentFn = Arc::new(move |cx: Cx, prompt| {
            let app = app.clone();
            async move {
                let fields =
                    json!({ "run": id, "url": prompt.verification_url, "code": prompt.user_code });
                app.flag(&cx, "device_code", fields).await.unwrap_or(false)
            }
            .boxed()
        });
        let machine = message.get("machine").and_then(Value::as_str).unwrap_or_default();
        self.adapter.run(cx, machine, scope, flag("confirmed"), flag("force"), ask, present).await
    }
}

/// The string ids in `message[key]`.
fn ids(message: &Value, key: &str) -> HashSet<String> {
    message
        .get(key)
        .and_then(Value::as_array)
        .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default()
}

fn mac_access(user_home: &Path) -> Option<crate::types::Grant> {
    let codex_home = std::env::var("CODEX_HOME").ok();
    local_access::read(&local_access::home(codex_home.as_deref(), user_home), now())
}

/// Serves one app until its input ends. `machines` makes the machine routes from the config and
/// the app (whose `credential` it asks for each call).
pub async fn serve<I, O>(
    input: I,
    mut output: O,
    machines: impl FnOnce(&Config, Arc<App>) -> Arc<dyn Machines>,
) -> Result<(), Error>
where
    I: AsyncRead + Unpin,
    O: AsyncWrite + Unpin + Send + 'static,
{
    let mut lines = tokio::io::BufReader::new(input).lines();
    let first = lines.next_line().await.ok().flatten().unwrap_or_default();
    let config = serde_json::from_str::<Value>(&first)
        .ok()
        .as_ref()
        .and_then(Config::from_json)
        .ok_or_else(|| Error::Other("the holder needs its config first".into()))?;
    let (out, mut outgoing) = mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        while let Some(line) = outgoing.recv().await {
            let written =
                output.write_all(line.as_bytes()).await.and(output.write_all(b"\n").await);
            if written.and(output.flush().await).is_err() {
                break;
            }
        }
    });
    let app = Arc::new(App {
        out,
        waiting: Mutex::new(HashMap::new()),
        next: AtomicU64::new(0),
        closed: AtomicBool::new(false),
    });
    let machines = machines(&config, app.clone());
    let holder = Holder::new(config, app.clone(), machines);
    while let Ok(Some(line)) = lines.next_line().await {
        holder.take(&line);
    }
    // The app is gone: every question ends (none can be answered), and a quit leaves delivered
    // access in place. Nothing reads the output any more, so the writer is not waited for.
    {
        let mut waiting = app.waiting();
        app.closed.store(true, Ordering::SeqCst);
        waiting.clear();
    }
    holder.adapter.detach_for_quit().await;
    drop(writer);
    Ok(())
}

#[cfg(test)]
#[path = "serve_tests.rs"]
mod tests;
