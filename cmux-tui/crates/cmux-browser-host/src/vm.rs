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
    /// A synchronous host function (`secretSet`, `secretList`, `secretDelete`,
    /// `policyNarrow`, `policyGet`). Errors become JS exceptions.
    fn native(&self, name: &str, args: Value) -> Result<Value, String>;
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

enum Input {
    Eval { code: String, timeout: Duration, reply: mpsc::Sender<EvalOutcome> },
    Result { call_id: f64, outcome: Result<Value, DriverError> },
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
        let (reply, wait) = mpsc::channel();
        let sent = self.tx.send(Input::Eval { code: code.to_owned(), timeout, reply });
        let stopped =
            || EvalOutcome { output: Vec::new(), error: Some("the session stopped".into()) };
        if sent.is_err() {
            return stopped();
        }
        wait.recv().unwrap_or_else(|_| stopped())
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
}

impl Shared {
    fn set_timer(&mut self, id: f64, delay: Duration, repeat: bool) {
        self.clear_timer(id);
        self.timer_seq += 1;
        let key = (Instant::now() + delay, self.timer_seq);
        self.timers.insert(key, (id, repeat.then_some(delay)));
        self.timer_keys.insert(id.to_bits(), key);
    }

    fn clear_timer(&mut self, id: f64) {
        if let Some(key) = self.timer_keys.remove(&id.to_bits()) {
            self.timers.remove(&key);
        }
    }

    /// Ids of timers due now; repeating timers are scheduled again.
    fn due(&mut self, now: Instant) -> Vec<f64> {
        let mut fired = Vec::new();
        while let Some((&key, _)) = self.timers.iter().next() {
            if key.0 > now {
                break;
            }
            let (id, repeat) = self.timers.remove(&key).unwrap_or((0.0, None));
            self.timer_keys.remove(&id.to_bits());
            if let Some(every) = repeat {
                self.set_timer(id, every.max(Duration::from_millis(1)), true);
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

    let mut queued: VecDeque<(String, Duration, mpsc::Sender<EvalOutcome>)> = VecDeque::new();
    let mut running: Option<Running> = None;
    loop {
        // Start the next evaluation when none runs.
        if running.is_none()
            && let Some((code, timeout, reply)) = queued.pop_front()
        {
            if let Some(error) = &init_error {
                let _ = reply.send(EvalOutcome { output: Vec::new(), error: Some(error.clone()) });
                continue;
            }
            shared.borrow_mut().output.clear();
            let deadline = Instant::now() + timeout;
            interrupt_at.store(deadline.duration_since(base).as_millis() as u64, Ordering::Relaxed);
            let started = context.with(|ctx| -> Result<Persistent<Promise<'static>>, String> {
                let eval: Function = ctx
                    .globals()
                    .get("__cmuxReplEval")
                    .map_err(|_| "the REPL runtime did not define __cmuxReplEval".to_owned())?;
                let promise: Promise = eval.call((code,)).map_err(|error| caught(&ctx, error))?;
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

        // Run queued promise jobs, then fire due timers.
        loop {
            match runtime.execute_pending_job() {
                Ok(true) => continue,
                Ok(false) => break,
                Err(_) => continue,
            }
        }
        let due = shared.borrow_mut().due(Instant::now());
        if !due.is_empty() {
            context.with(|ctx| {
                if let Ok(on_timer) = ctx.globals().get::<_, Function>("__cmuxHostOnTimer") {
                    for id in due {
                        let _: rquickjs::Result<()> = on_timer.call((id,));
                    }
                }
            });
            continue;
        }

        // Settle the running evaluation.
        if let Some(current) = running.take() {
            let settled = context.with(|ctx| -> Option<Option<String>> {
                let promise = current.promise.clone().restore(&ctx).ok()?;
                match promise.result::<rquickjs::Value>()? {
                    Ok(_) => Some(None),
                    Err(error) => Some(Some(caught(&ctx, error))),
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
            Some(Input::Eval { code, timeout, reply }) => queued.push_back((code, timeout, reply)),
            Some(Input::Result { call_id, outcome }) => context.with(|ctx| {
                let (error, result) = match outcome {
                    Ok(value) => (None, Some(value.to_string())),
                    Err(error) => (Some(error.to_json().to_string()), None),
                };
                // The runtime checks `=== null`, so absent values are null, not undefined.
                let as_js = |text: Option<String>| -> rquickjs::Result<rquickjs::Value> {
                    match text {
                        Some(text) => rquickjs::IntoJs::into_js(text, &ctx),
                        None => Ok(rquickjs::Value::new_null(ctx.clone())),
                    }
                };
                if let (Ok(on_result), Ok(error), Ok(result)) = (
                    ctx.globals().get::<_, Function>("__cmuxHostOnResult"),
                    as_js(error),
                    as_js(result),
                ) {
                    let _: rquickjs::Result<()> = on_result.call((call_id, error, result));
                }
            }),
            Some(Input::Event { name, payload }) => context.with(|ctx| {
                if let Ok(on_event) = ctx.globals().get::<_, Function>("__cmuxHostOnEvent") {
                    let _: rquickjs::Result<()> = on_event.call((name, payload.to_string()));
                }
            }),
        }
    }
    // Persistent values must not outlive the runtime.
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
    native.set("tmpdir", std::env::temp_dir().display().to_string()).map_err(js)?;
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
    let sandbox = crate::fs_sandbox::FsSandbox::new(&config.cwd);
    native
        .set(
            "fs",
            Function::new(ctx.clone(), move |op: String, args: String| -> String {
                let args: Value = serde_json::from_str(&args).unwrap_or(json!({}));
                sandbox.call(&op, &args).to_string()
            })
            .map_err(js)?,
        )
        .map_err(js)?;
    // Native fetch (tab cookies, policy per redirect hop) is not built yet:
    // answer `unsupported` through the result callback, as an async call does.
    let fetch_results = tx.clone();
    native
        .set(
            "fetch",
            Function::new(ctx.clone(), move |call_id: f64, _request: String| {
                let _ = fetch_results.send(Input::Result {
                    call_id,
                    outcome: Err(DriverError::new(
                        crate::protocol::ErrorCode::Unsupported,
                        "fetch: the browser host does not fetch yet; use page.evaluate(() => fetch(...))",
                    )),
                });
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
                    delay as u64
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
                        let outcome = host.driver_call(&method, params);
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

    for name in [
        "secretSet",
        "secretList",
        "secretDelete",
        "policyNarrow",
        "policyGet",
        "policyLog",
        "policyCheck",
    ] {
        let host = host.clone();
        let function = Function::new(
            ctx.clone(),
            move |ctx: Ctx<'_>,
                  args: rquickjs::function::Rest<String>|
                  -> rquickjs::Result<Option<String>> {
                // Agreed ABI: secretSet(name, value, optionsJSON), policyNarrow(domainsJSON);
                // other arguments are plain strings.
                let json_at: &[usize] = match name {
                    "secretSet" => &[2],
                    "policyNarrow" => &[0],
                    _ => &[],
                };
                let mut parsed = Vec::with_capacity(args.0.len());
                for (index, arg) in args.0.iter().enumerate() {
                    if json_at.contains(&index) {
                        let value = serde_json::from_str(arg).map_err(|_| {
                            rquickjs::Exception::throw_message(
                                &ctx,
                                &format!("{name}: argument {index} must be JSON"),
                            )
                        })?;
                        parsed.push(value);
                    } else {
                        parsed.push(Value::String(arg.clone()));
                    }
                }
                let args = parsed;
                match host.native(name, Value::Array(args)) {
                    // policyCheck answers a message or null, not JSON.
                    Ok(Value::Null) if name == "policyCheck" => Ok(None),
                    Ok(Value::String(message)) if name == "policyCheck" => Ok(Some(message)),
                    Ok(value) => Ok(Some(value.to_string())),
                    Err(message) => Err(rquickjs::Exception::throw_message(&ctx, &message)),
                }
            },
        )
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
    Ok(())
}

#[cfg(test)]
#[path = "vm_tests.rs"]
mod tests;
