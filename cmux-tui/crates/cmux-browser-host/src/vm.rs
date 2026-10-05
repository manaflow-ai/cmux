//! One REPL session: a QuickJS-ng VM (rquickjs) on its own thread.
//!
//! The VM sees the `__cmuxNative` v1 ABI of PR #15570's driver-protocol.md
//! plus the host's secret and policy functions. Every `driverCall` goes to
//! [`VmHost::driver_call`], where the host applies policy and resolves secret
//! handles before any driver sees the call; the VM never holds a driver.

use crate::protocol::DriverError;
use rquickjs::{Context, Ctx, Function, Object, Persistent, Promise, Runtime};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant};

/// What the VM's native calls reach.
pub trait VmHost: Send + Sync {
    /// One driver protocol call, policy-checked. Blocks; runs on a worker thread.
    fn driver_call(&self, method: &str, params: Value) -> Result<Value, DriverError>;
    /// [`VmHost::driver_call`] with the result as JSON text where the engine
    /// kept it (a page script's value, in the page's key order).
    fn driver_call_reply(
        &self,
        method: &str,
        params: Value,
    ) -> Result<crate::driver::Reply, DriverError> {
        self.driver_call(method, params).map(crate::driver::Reply::Value)
    }
    /// A synchronous host function (`secretSet`, `secretList`, `secretDelete`,
    /// `policyNarrow`, `policyGet`). Errors become JS exceptions.
    fn native(&self, name: &str, args: Value) -> Result<Value, String>;
    /// Cell `cell` timed out: the fetches it started stop now (queued ones
    /// fail, running ones are cancelled in the engine), as classic's
    /// `cancelFetches(ofEval:)`. The default does nothing.
    fn cancel_fetches(&self, _cell: u64) {}
    /// Masks bytes that cross the VM's file boundary (files the VM writes
    /// and reads), so a secret value never lands in or comes back from a
    /// file. The default masks nothing.
    fn mask_bytes(&self, bytes: &[u8]) -> Vec<u8> {
        bytes.to_vec()
    }
}

#[derive(Debug, Clone)]
pub struct VmConfig {
    pub session_id: String,
    pub cwd: String,
    /// Bytes; 0 means no limit.
    pub memory_limit: usize,
    pub capabilities: Vec<String>,
    /// `(file name, source)` in load order (manifest `repl` list).
    pub scripts: Vec<(String, String)>,
    /// Bundled runtime files for `readResource` (relative path, text).
    pub resources: Vec<(String, String)>,
}

/// The result of one `eval`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EvalOutcome {
    /// Print output, in order (`[level, text]`).
    pub output: Vec<(String, String)>,
    /// The formatted uncaught error, if the evaluation failed.
    pub error: Option<String>,
}

/// Longest a timer or event callback may run outside an evaluation.
const CALLBACK_BUDGET: Duration = Duration::from_secs(5);
/// Longest timer delay (browsers clamp to 2^31-1 ms).
const MAX_TIMER_DELAY: Duration = Duration::from_millis(2_147_483_647);
/// Timers fired per loop pass, so input is read between passes.
const TIMERS_PER_PASS: usize = 64;

enum Input {
    Eval { code: String, options: String, timeout: Duration, reply: mpsc::Sender<EvalOutcome> },
    Stop,
    Result { call_id: f64, outcome: Result<crate::driver::Reply, DriverError> },
    Event { name: String, payload: Value },
}

/// A running session. Dropping it stops the VM thread.
pub struct VmSession {
    tx: mpsc::Sender<Input>,
}

impl VmSession {
    pub fn spawn(config: VmConfig, host: Arc<dyn VmHost>) -> io::Result<VmSession> {
        let (tx, rx) = mpsc::channel();
        let loop_tx = tx.clone();
        std::thread::Builder::new()
            .name(format!("cmux-browser-host-vm-{}", config.session_id))
            .spawn(move || run(config, host, rx, loop_tx))?;
        Ok(VmSession { tx })
    }

    /// Evaluates REPL code and waits for it (or its timeout).
    pub fn eval(&self, code: &str, timeout: Duration) -> EvalOutcome {
        self.eval_with(code, timeout, &json!({}))
    }

    /// `eval` with runtime options (`{"maxOutput": n}`, 0 for no limit).
    pub fn eval_with(&self, code: &str, timeout: Duration, options: &Value) -> EvalOutcome {
        let (reply, wait) = mpsc::channel();
        let input =
            Input::Eval { code: code.to_owned(), options: options.to_string(), timeout, reply };
        let stopped =
            || EvalOutcome { output: Vec::new(), error: Some("the session stopped".into()) };
        if self.tx.send(input).is_err() {
            return stopped();
        }
        // The VM answers at its own deadline; the grace covers a VM stuck in
        // a callback, so a caller never waits forever.
        match wait.recv_timeout(timeout.saturating_add(CALLBACK_BUDGET * 2)) {
            Ok(outcome) => outcome,
            Err(mpsc::RecvTimeoutError::Timeout) => EvalOutcome {
                output: Vec::new(),
                error: Some("Error: evaluation timed out (the session did not answer)".into()),
            },
            Err(mpsc::RecvTimeoutError::Disconnected) => stopped(),
        }
    }

    /// Delivers a driver event to the runtime (`__cmuxHostOnEvent`).
    pub fn event(&self, name: &str, payload: Value) {
        let _ = self.tx.send(Input::Event { name: name.to_owned(), payload });
    }

    /// A handle that delivers events from another thread.
    pub fn events(&self) -> VmEvents {
        VmEvents { tx: self.tx.clone() }
    }
}

impl Drop for VmSession {
    fn drop(&mut self) {
        // The VM's own closures hold senders too, so a closed channel alone
        // would never end its loop.
        let _ = self.tx.send(Input::Stop);
    }
}

/// Delivers driver events to a session's VM from any thread.
#[derive(Clone)]
pub struct VmEvents {
    tx: mpsc::Sender<Input>,
}

impl VmEvents {
    pub fn event(&self, name: &str, payload: Value) {
        let _ = self.tx.send(Input::Event { name: name.to_owned(), payload });
    }
}

#[derive(Default)]
struct Shared {
    output: Vec<(String, String)>,
    timers: BTreeMap<(Instant, u64), (f64, Option<Duration>)>,
    timer_keys: HashMap<u64, (Instant, u64)>,
    timer_seq: u64,
    /// The runtime's entry points, kept by the host after it removed the
    /// globals (install).
    entry_points: HashMap<&'static str, Persistent<Function<'static>>>,
}

impl Shared {
    fn set_timer(&mut self, id: f64, delay: Duration, repeat: bool) {
        self.clear_timer(id);
        self.timer_seq += 1;
        let now = Instant::now();
        let key = (now.checked_add(delay.min(MAX_TIMER_DELAY)).unwrap_or(now), self.timer_seq);
        self.timers.insert(key, (id, repeat.then_some(delay)));
        self.timer_keys.insert(id.to_bits(), key);
    }

    fn clear_timer(&mut self, id: f64) {
        if let Some(key) = self.timer_keys.remove(&id.to_bits()) {
            self.timers.remove(&key);
        }
    }

    /// Ids of timers due now (at most `TIMERS_PER_PASS`); repeating timers
    /// are scheduled again, after `now`, so they wait for the next pass.
    fn due(&mut self, now: Instant) -> Vec<f64> {
        let mut fired = Vec::new();
        while fired.len() < TIMERS_PER_PASS
            && let Some((&key, _)) = self.timers.iter().next()
        {
            if key.0 > now {
                break;
            }
            let (id, repeat) = self.timers.remove(&key).unwrap_or((0.0, None));
            self.timer_keys.remove(&id.to_bits());
            if let Some(every) = repeat {
                self.set_timer(id, every.max(Duration::from_millis(4)), true);
            }
            fired.push(id);
        }
        fired
    }

    fn next_deadline(&self) -> Option<Instant> {
        self.timers.keys().next().map(|key| key.0)
    }
}

struct Running {
    promise: Persistent<Promise<'static>>,
    reply: mpsc::Sender<EvalOutcome>,
    deadline: Instant,
}

const FORMAT_ERROR: &str = "(e) => { try { if (typeof globalThis.__cmuxFormatError === 'function') return String(globalThis.__cmuxFormatError(e)); const head = String(e); const stack = e && e.stack ? String(e.stack) : ''; return stack && !stack.startsWith(head) ? head + '\\n' + stack : (stack || head); } catch (x) { return String(e); } }";

fn run(
    config: VmConfig,
    host: Arc<dyn VmHost>,
    rx: mpsc::Receiver<Input>,
    tx: mpsc::Sender<Input>,
) {
    let Ok(runtime) = Runtime::new() else { return };
    if config.memory_limit > 0 {
        runtime.set_memory_limit(config.memory_limit);
    }
    // Interrupt the VM when the running evaluation passes its deadline.
    let base = Instant::now();
    let interrupt_at = Arc::new(AtomicU64::new(u64::MAX));
    {
        let interrupt_at = interrupt_at.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            let at = interrupt_at.load(Ordering::Relaxed);
            at != u64::MAX && base.elapsed().as_millis() as u64 >= at
        })));
    }
    let Ok(context) = Context::full(&runtime) else { return };
    let shared = Rc::new(RefCell::new(Shared::default()));
    let init_error = context.with(|ctx| install(&ctx, &config, &host, &shared, &tx).err());

    let mut queued: VecDeque<(String, String, Duration, mpsc::Sender<EvalOutcome>)> =
        VecDeque::new();
    // Callbacks outside an evaluation (timers, events, results) get a
    // budget of their own, so a spinning callback cannot hang the session.
    // Each callback runs under the earlier of its own budget and the running
    // evaluation's deadline; afterwards the evaluation's deadline applies again.
    let callback_deadline = |interrupt_at: &AtomicU64| {
        let at = (Instant::now() + CALLBACK_BUDGET).duration_since(base).as_millis() as u64;
        interrupt_at.store(at.min(interrupt_at.load(Ordering::Relaxed)), Ordering::Relaxed);
    };
    let restore_deadline = |interrupt_at: &AtomicU64, running: &Option<Running>| {
        let at = running
            .as_ref()
            .map_or(u64::MAX, |r| r.deadline.duration_since(base).as_millis() as u64);
        interrupt_at.store(at, Ordering::Relaxed);
    };
    let mut running: Option<Running> = None;
    loop {
        // Start the next evaluation when none runs.
        if running.is_none()
            && let Some((code, options, timeout, reply)) = queued.pop_front()
        {
            if let Some(error) = &init_error {
                let _ = reply.send(EvalOutcome { output: Vec::new(), error: Some(error.clone()) });
                continue;
            }
            shared.borrow_mut().output.clear();
            let now = Instant::now();
            let deadline =
                now.checked_add(timeout.min(Duration::from_secs(24 * 60 * 60))).unwrap_or(now);
            interrupt_at.store(deadline.duration_since(base).as_millis() as u64, Ordering::Relaxed);
            let started = context.with(|ctx| -> Result<Persistent<Promise<'static>>, String> {
                let eval = entry(&ctx, &shared, "__cmuxReplEval")
                    .ok_or_else(|| "the REPL runtime did not define __cmuxReplEval".to_owned())?;
                let promise: Promise =
                    eval.call((code, options)).map_err(|error| caught_in(&ctx, &shared, error))?;
                Ok(Persistent::save(&ctx, promise))
            });
            match started {
                Ok(promise) => running = Some(Running { promise, reply, deadline }),
                Err(error) => {
                    interrupt_at.store(u64::MAX, Ordering::Relaxed);
                    let output = std::mem::take(&mut shared.borrow_mut().output);
                    let _ = reply.send(EvalOutcome { output, error: Some(error) });
                }
            }
        }

        // Run queued promise jobs, then fire due timers. Outside an
        // evaluation the jobs are continuations of callbacks (driver
        // results, events, timers) and get the callback budget too.
        if running.is_none() && runtime.is_job_pending() {
            callback_deadline(&interrupt_at);
        }
        loop {
            match runtime.execute_pending_job() {
                Ok(true) => continue,
                Ok(false) => break,
                Err(_) => continue,
            }
        }
        restore_deadline(&interrupt_at, &running);
        let due = shared.borrow_mut().due(Instant::now());
        if !due.is_empty() {
            callback_deadline(&interrupt_at);
            context.with(|ctx| {
                if let Some(on_timer) = entry(&ctx, &shared, "__cmuxHostOnTimer") {
                    for id in due {
                        let _: rquickjs::Result<()> = on_timer.call((id,));
                    }
                }
            });
            // Jobs the timers queued (promise reactions) run before settling,
            // still under the callback budget.
            while !matches!(runtime.execute_pending_job(), Ok(false)) {}
            restore_deadline(&interrupt_at, &running);
        }

        // Settle the running evaluation.
        if let Some(current) = running.take() {
            let settled = context.with(|ctx| -> Option<Option<String>> {
                let promise = current.promise.clone().restore(&ctx).ok()?;
                match promise.result::<rquickjs::Value>()? {
                    Ok(_) => Some(None),
                    Err(error) => Some(Some(caught_in(&ctx, &shared, error))),
                }
            });
            let timed_out = Instant::now() >= current.deadline;
            match settled {
                Some(error) => finish(&shared, &interrupt_at, current.reply, error),
                None if timed_out => finish(
                    &shared,
                    &interrupt_at,
                    current.reply,
                    Some("Error: evaluation timed out".into()),
                ),
                None => running = Some(current),
            }
            if running.is_none() && !queued.is_empty() {
                continue;
            }
        }

        // Wait for input until the next timer or the evaluation deadline.
        let wake = [shared.borrow().next_deadline(), running.as_ref().map(|r| r.deadline)]
            .into_iter()
            .flatten()
            .min();
        // Read input before timers that are already due again (fairness).
        let wake = match wake {
            Some(at) if at <= Instant::now() => Some(Instant::now()),
            other => other,
        };
        let input = match wake {
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(input) => Some(input),
                Err(mpsc::RecvTimeoutError::Timeout) => None,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            },
            None => match rx.recv() {
                Ok(input) => Some(input),
                Err(_) => break,
            },
        };
        match input {
            None => {}
            Some(Input::Stop) => break,
            Some(Input::Eval { code, options, timeout, reply }) => {
                queued.push_back((code, options, timeout, reply));
            }
            Some(Input::Result { call_id, outcome }) => context.with(|ctx| {
                if running.is_none() {
                    callback_deadline(&interrupt_at);
                }
                let (error, result) = match outcome {
                    // A script's value is spliced in as the engine's JSON
                    // text (a9 raw_value: the page's key order).
                    Ok(reply) => (None, Some(reply.json_text())),
                    Err(error) => (Some(error.to_json().to_string()), None),
                };
                // The runtime checks `=== null`, so absent values are null, not undefined.
                let as_js = |text: Option<String>| -> rquickjs::Result<rquickjs::Value> {
                    match text {
                        Some(text) => rquickjs::IntoJs::into_js(text, &ctx),
                        None => Ok(rquickjs::Value::new_null(ctx.clone())),
                    }
                };
                if let (Some(on_result), Ok(error), Ok(result)) =
                    (entry(&ctx, &shared, "__cmuxHostOnResult"), as_js(error), as_js(result))
                {
                    let _: rquickjs::Result<()> = on_result.call((call_id, error, result));
                }
                if running.is_none() {
                    interrupt_at.store(u64::MAX, Ordering::Relaxed);
                }
            }),
            Some(Input::Event { name, payload }) => context.with(|ctx| {
                if running.is_none() {
                    callback_deadline(&interrupt_at);
                }
                if let Some(on_event) = entry(&ctx, &shared, "__cmuxHostOnEvent") {
                    let _: rquickjs::Result<()> = on_event.call((name, payload.to_string()));
                }
                if running.is_none() {
                    interrupt_at.store(u64::MAX, Ordering::Relaxed);
                }
            }),
        }
    }
    // Persistent values must not outlive the runtime.
    shared.borrow_mut().entry_points.clear();
    drop(running);
    drop(context);
}

fn finish(
    shared: &Rc<RefCell<Shared>>,
    interrupt_at: &AtomicU64,
    reply: mpsc::Sender<EvalOutcome>,
    error: Option<String>,
) {
    interrupt_at.store(u64::MAX, Ordering::Relaxed);
    let output = std::mem::take(&mut shared.borrow_mut().output);
    let _ = reply.send(EvalOutcome { output, error });
}

/// The pending exception as text.
/// Like `caught`, with the runtime's own error formatter when it defined one.
fn caught_in(ctx: &Ctx<'_>, shared: &Rc<RefCell<Shared>>, error: rquickjs::Error) -> String {
    if !matches!(error, rquickjs::Error::Exception) {
        return error.to_string();
    }
    let exception = ctx.catch();
    let formatted = entry(ctx, shared, "__cmuxFormatError")
        .map(|format| format.call::<_, String>((exception.clone(),)));
    match formatted {
        Some(Ok(text)) => text,
        _ => {
            let fallback: rquickjs::Result<Function> = ctx.eval(FORMAT_ERROR);
            fallback
                .and_then(|f| f.call::<_, String>((exception,)))
                .unwrap_or_else(|e| e.to_string())
        }
    }
}

fn caught(ctx: &Ctx<'_>, error: rquickjs::Error) -> String {
    if !matches!(error, rquickjs::Error::Exception) {
        return error.to_string();
    }
    let exception = ctx.catch();
    let format: rquickjs::Result<Function> = ctx.eval(FORMAT_ERROR);
    match format.and_then(|f| f.call::<_, String>((exception,))) {
        Ok(text) => text,
        Err(other) => other.to_string(),
    }
}

fn install(
    ctx: &Ctx<'_>,
    config: &VmConfig,
    host: &Arc<dyn VmHost>,
    shared: &Rc<RefCell<Shared>>,
    tx: &mpsc::Sender<Input>,
) -> Result<(), String> {
    let native = Object::new(ctx.clone()).map_err(|e| e.to_string())?;
    let js = |e: rquickjs::Error| e.to_string();
    native.set("version", 1).map_err(js)?;
    native.set("sessionId", config.session_id.clone()).map_err(js)?;
    native.set("cwd", config.cwd.clone()).map_err(js)?;
    native.set("capabilities", config.capabilities.clone()).map_err(js)?;
    let sandbox = Arc::new(crate::fs_sandbox::FsSandbox::new(&config.cwd));
    native.set("tmpdir", sandbox.tmp().display().to_string()).map_err(js)?;
    native.set("homedir", std::env::var("HOME").unwrap_or_else(|_| "/".into())).map_err(js)?;
    let resources: HashMap<String, String> = config.resources.iter().cloned().collect();
    native
        .set(
            "readResource",
            Function::new(ctx.clone(), move |path: String| -> Option<String> {
                resources.get(&path).cloned()
            })
            .map_err(js)?,
        )
        .map_err(js)?;
    native
        .set(
            "fs",
            Function::new(ctx.clone(), {
                let sandbox = sandbox.clone();
                let host = host.clone();
                move |op: String, args: String| -> String {
                    let mut args: Value = serde_json::from_str(&args).unwrap_or(json!({}));
                    let masked = |text: &str| {
                        crate::fs_sandbox::base64_decode(text)
                            .map(|bytes| crate::fs_sandbox::base64_encode(&host.mask_bytes(&bytes)))
                    };
                    if op == "writeFile"
                        && let Some(encoded) = args["base64"].as_str().and_then(masked)
                    {
                        args["base64"] = Value::String(encoded);
                    }
                    let mut result = sandbox.call(&op, &args);
                    if op == "readFile"
                        && let Some(encoded) = result["ok"].as_str().and_then(masked)
                    {
                        result["ok"] = Value::String(encoded);
                    }
                    result.to_string()
                }
            })
            .map_err(js)?,
        )
        .map_err(js)?;
    // Native fetch: the gate's `net.fetch` (policy and range checks, every
    // redirect hop, masking), run by the engine in the tab's context.
    let fetch_host = host.clone();
    let fetch_results = tx.clone();
    native
        .set(
            "fetch",
            Function::new(ctx.clone(), move |call_id: f64, request: String| {
                let host = fetch_host.clone();
                let results = fetch_results.clone();
                let sender = results.clone();
                let request: Value = serde_json::from_str(&request).unwrap_or(json!({}));
                let spawned = std::thread::Builder::new()
                    .name("cmux-browser-host-fetch".into())
                    .spawn(move || {
                        let outcome =
                            host.driver_call("net.fetch", request).map(crate::driver::Reply::Value);
                        let _ = sender.send(Input::Result { call_id, outcome });
                    });
                if spawned.is_err() {
                    let _ = results.send(Input::Result {
                        call_id,
                        outcome: Err(DriverError::closed("could not start a fetch")),
                    });
                }
            })
            .map_err(js)?,
        )
        .map_err(js)?;

    let out = shared.clone();
    native
        .set(
            "print",
            Function::new(ctx.clone(), move |level: String, text: String| {
                out.borrow_mut().output.push((level, text));
            })
            .map_err(js)?,
        )
        .map_err(js)?;
    let timers = shared.clone();
    native
        .set(
            "setTimer",
            Function::new(ctx.clone(), move |id: f64, delay: f64, repeat: bool| {
                let delay = Duration::from_millis(if delay.is_finite() && delay > 0.0 {
                    delay.min(2_147_483_647.0) as u64
                } else {
                    0
                });
                timers.borrow_mut().set_timer(id, delay, repeat);
            })
            .map_err(js)?,
        )
        .map_err(js)?;
    let timers = shared.clone();
    native
        .set(
            "clearTimer",
            Function::new(ctx.clone(), move |id: f64| timers.borrow_mut().clear_timer(id))
                .map_err(js)?,
        )
        .map_err(js)?;

    let driver_host = host.clone();
    let results = tx.clone();
    native
        .set(
            "driverCall",
            Function::new(ctx.clone(), move |call_id: f64, method: String, params: String| {
                let host = driver_host.clone();
                let results = results.clone();
                let sender = results.clone();
                let params: Value = serde_json::from_str(&params).unwrap_or(json!({}));
                let spawned = std::thread::Builder::new()
                    .name("cmux-browser-host-driver-call".into())
                    .spawn(move || {
                        let outcome = host.driver_call_reply(&method, params);
                        let _ = sender.send(Input::Result { call_id, outcome });
                    });
                if spawned.is_err() {
                    let _ = results.send(Input::Result {
                        call_id,
                        outcome: Err(DriverError::closed("could not start a driver call")),
                    });
                }
            })
            .map_err(js)?,
        )
        .map_err(js)?;

    // Main's synchronous natives (port plan D1): secrets(op, argsJSON) and
    // policy(op, argsJSON) answer {"ok": value} or {"error": {code, message}}.
    for name in ["secrets", "policy"] {
        let host = host.clone();
        let sandbox = sandbox.clone();
        let function = Function::new(ctx.clone(), move |op: String, args: String| -> String {
            let answer = |result: Result<Value, (&str, String)>| match result {
                Ok(value) => json!({"ok": value}).to_string(),
                Err((code, message)) => {
                    json!({"error": {"code": code, "message": message}}).to_string()
                }
            };
            let Ok(mut args) = serde_json::from_str::<Value>(&args) else {
                return answer(Err(("invalid", format!("{name}: the arguments must be JSON"))));
            };
            // secrets.load {path}: the file is read here, through the
            // session's fs sandbox, so its values never enter the VM.
            if name == "secrets"
                && op == "load"
                && let Some(path) = args["path"].as_str()
            {
                let read = sandbox.call("readFile", &json!({"path": path}));
                let Some(text) = read["ok"]
                    .as_str()
                    .and_then(crate::fs_sandbox::base64_decode)
                    .and_then(|bytes| String::from_utf8(bytes).ok())
                else {
                    let message =
                        read["error"]["message"].as_str().unwrap_or("could not read the file");
                    return answer(Err(("invalid", format!("secrets.load: {message}"))));
                };
                let Ok(object) = serde_json::from_str::<Value>(&text) else {
                    return answer(Err(("invalid", format!("secrets.load: {path} is not JSON"))));
                };
                args = json!({"object": object});
            }
            answer(host.native(name, json!({"op": op, "args": args})).map_err(|m| ("forbidden", m)))
        })
        .map_err(js)?;
        native.set(name, function).map_err(js)?;
    }

    ctx.globals().set("__cmuxNative", native).map_err(js)?;
    for (file, source) in &config.scripts {
        let loaded: rquickjs::Result<()> = ctx.eval(source.as_str());
        if let Err(error) = loaded {
            return Err(format!("{file}: {}", caught(ctx, error)));
        }
    }
    // The host keeps the entry points the runtime defined and removes them,
    // with __cmuxNative, before any cell runs: agent code cannot forge a
    // driver result, fire a timer or start a second evaluation.
    let globals = ctx.globals();
    let mut entries = shared.borrow_mut();
    for name in ENTRY_POINTS {
        if let Ok(function) = globals.get::<_, Function>(name) {
            entries.entry_points.insert(name, Persistent::save(ctx, function));
        }
        let _ = globals.remove(name);
    }
    let _ = globals.remove("__cmuxNative");
    Ok(())
}

/// The functions the runtime defines for the host (driver-protocol.md,
/// "Native host contract").
const ENTRY_POINTS: [&str; 5] = [
    "__cmuxReplEval",
    "__cmuxHostOnResult",
    "__cmuxHostOnTimer",
    "__cmuxHostOnEvent",
    "__cmuxFormatError",
];

/// A saved entry point, restored into `ctx`.
fn entry<'js>(ctx: &Ctx<'js>, shared: &Rc<RefCell<Shared>>, name: &str) -> Option<Function<'js>> {
    let saved = shared.borrow().entry_points.get(name).cloned()?;
    saved.restore(ctx).ok()
}

#[cfg(test)]
#[path = "vm_tests.rs"]
mod tests;
