//! One app's QuickJS VM with the runtime ABI (`js/ABI.md`) implemented natively.
//!
//! The VM is untrusted. It sees only `__cmuxAppNative`; every native call is
//! turned into a [`FromHost`] message in an outbox that the caller drains and
//! forwards to the supervisor, which checks scopes and grants per call.
//! Limits apply per VM: the counting allocator refuses allocations past the
//! memory limit, the interrupt handler stops an entry point past its
//! deadline, and the pending-call cap rejects calls beyond it. Hitting the
//! memory or interrupt limit kills this VM only ([`AppVm::dead`]); other VMs
//! in the same process keep running.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use rquickjs::allocator::{Allocator, RustAllocator};
use rquickjs::{CatchResultExt, Context, Ctx, Function, Object, Runtime};
use serde_json::{Value, json};

use crate::protocol::{AppInfo, FatalReason, FromHost};

/// The engine-neutral runtime, built from `js/src` by `js/build.ts`.
pub const RUNTIME_JS: &str = include_str!("../js/dist/cmux-app-runtime.js");

/// Longest log message kept; longer ones are cut.
const MAX_LOG_CHARS: usize = 4096;
/// Bytes of messages one entry point may produce; more kills the VM (the
/// outbox lives outside the counted engine heap).
const MAX_OUTBOX_BYTES: usize = 8 * 1024 * 1024;
/// Armed timers and live subscriptions per VM; more kills the VM.
const MAX_TIMERS: usize = 256;
const MAX_SUBSCRIPTIONS: usize = 256;
/// One-shot timers fire no sooner than this, so a self-rearming timer cannot
/// spin the host.
const MIN_TIMER: Duration = Duration::from_millis(50);

/// Per-VM limits (plans/cmux-next/app-platform.md section 13.1).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Limits {
    pub memory_bytes: usize,
    pub entry_deadline: Duration,
    pub max_pending_calls: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            memory_bytes: 32 * 1024 * 1024,
            entry_deadline: Duration::from_millis(250),
            max_pending_calls: 64,
        }
    }
}

/// Everything `__cmuxAppInit` needs plus the app's main script.
#[derive(Debug, Clone, PartialEq)]
pub struct InitParams {
    pub app: AppInfo,
    pub settings: Value,
    pub api_version: String,
    /// Ops the grant allows; `None` skips the runtime's local filter.
    pub ops: Option<Vec<String>>,
    /// Every op this cmux knows; `None` skips the runtime's local filter.
    pub known_ops: Option<Vec<String>>,
    pub locale: Option<String>,
    pub strings: Value,
    pub main: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VmError {
    /// The VM is dead (limit or engine failure); drop it.
    Fatal { reason: FatalReason, entry: String },
    /// The app's main script or init failed; the VM never became usable.
    Init(String),
}

struct Timer {
    due: Instant,
    repeat: Option<Duration>,
}

#[derive(Default)]
struct Shared {
    outbox: Vec<FromHost>,
    next_sub: u64,
    next_timer: u64,
    timers: BTreeMap<u64, Timer>,
    pending_calls: BTreeSet<u64>,
    /// Calls refused by the pending-call cap; answered after the entry.
    overflow: Vec<u64>,
    max_pending_calls: usize,
    subscriptions: BTreeSet<u64>,
    outbox_bytes: usize,
    /// The VM produced more messages, timers or subscriptions than allowed.
    flooded: bool,
}

impl Shared {
    fn push(&mut self, message: FromHost, bytes: usize) {
        self.outbox_bytes = self.outbox_bytes.saturating_add(bytes);
        if self.outbox_bytes > MAX_OUTBOX_BYTES {
            self.flooded = true;
            return;
        }
        self.outbox.push(message);
    }

    fn log(&mut self, level: &str, message: &str) {
        let message: String = message.chars().take(MAX_LOG_CHARS).collect();
        let bytes = message.len();
        self.push(FromHost::Log { level: level.to_string(), message }, bytes);
    }
}

/// Counts every byte the VM holds and refuses to grow past the limit.
struct CountingAllocator {
    inner: RustAllocator,
    used: Arc<AtomicUsize>,
    limit: usize,
    exceeded: Arc<AtomicBool>,
}

impl CountingAllocator {
    fn admit(&self, current: usize, grow_to: usize) -> bool {
        let used = self.used.load(Ordering::Relaxed);
        if used.saturating_sub(current).saturating_add(grow_to) > self.limit {
            self.exceeded.store(true, Ordering::Relaxed);
            return false;
        }
        true
    }
}

// SAFETY: every pointer handed out comes from `RustAllocator`, which meets
// the trait's alignment and size rules; this wrapper only refuses requests
// (returns null) and keeps a byte count from `RustAllocator::usable_size`.
unsafe impl Allocator for CountingAllocator {
    fn alloc(&mut self, size: usize) -> *mut u8 {
        if !self.admit(0, size) {
            return std::ptr::null_mut();
        }
        let ptr = self.inner.alloc(size);
        if !ptr.is_null() {
            // SAFETY: `ptr` was just returned by `inner`.
            let got = unsafe { RustAllocator::usable_size(ptr) };
            self.used.fetch_add(got, Ordering::Relaxed);
        }
        ptr
    }

    fn calloc(&mut self, count: usize, size: usize) -> *mut u8 {
        let Some(total) = count.checked_mul(size) else { return std::ptr::null_mut() };
        if !self.admit(0, total) {
            return std::ptr::null_mut();
        }
        let ptr = self.inner.calloc(count, size);
        if !ptr.is_null() {
            // SAFETY: `ptr` was just returned by `inner`.
            let got = unsafe { RustAllocator::usable_size(ptr) };
            self.used.fetch_add(got, Ordering::Relaxed);
        }
        ptr
    }

    unsafe fn dealloc(&mut self, ptr: *mut u8) {
        if ptr.is_null() {
            return;
        }
        // SAFETY: the caller guarantees `ptr` came from this allocator, so from `inner`.
        let size = unsafe { RustAllocator::usable_size(ptr) };
        self.used.fetch_sub(size, Ordering::Relaxed);
        // SAFETY: as above.
        unsafe { self.inner.dealloc(ptr) };
    }

    unsafe fn realloc(&mut self, ptr: *mut u8, new_size: usize) -> *mut u8 {
        if ptr.is_null() {
            return self.alloc(new_size);
        }
        // SAFETY: the caller guarantees `ptr` came from this allocator.
        let old = unsafe { RustAllocator::usable_size(ptr) };
        if new_size > old && !self.admit(old, new_size) {
            return std::ptr::null_mut();
        }
        // SAFETY: as above.
        let out = unsafe { self.inner.realloc(ptr, new_size) };
        if !out.is_null() {
            // SAFETY: `out` was just returned by `inner`.
            let got = unsafe { RustAllocator::usable_size(out) };
            self.used.fetch_sub(old, Ordering::Relaxed);
            self.used.fetch_add(got, Ordering::Relaxed);
        }
        out
    }

    unsafe fn usable_size(ptr: *mut u8) -> usize
    where
        Self: Sized,
    {
        // SAFETY: forwarded; the caller guarantees `ptr` came from this allocator.
        unsafe { RustAllocator::usable_size(ptr) }
    }
}

/// One app's VM.
pub struct AppVm {
    // Field order matters: the context must drop before the runtime.
    context: Context,
    runtime: Runtime,
    shared: Rc<RefCell<Shared>>,
    base: Instant,
    /// Nanoseconds after `base` at which the running entry is interrupted; 0 = none.
    deadline: Arc<AtomicU64>,
    interrupted: Arc<AtomicBool>,
    memory_exceeded: Arc<AtomicBool>,
    memory_used: Arc<AtomicUsize>,
    limits: Limits,
    dead: Option<FatalReason>,
}

impl AppVm {
    /// Creates the VM and evaluates the runtime. Fails only when the engine
    /// cannot start (or the runtime does not fit the memory limit).
    pub fn new(limits: Limits) -> Result<Self, String> {
        let memory_used = Arc::new(AtomicUsize::new(0));
        let memory_exceeded = Arc::new(AtomicBool::new(false));
        let runtime = Runtime::new_with_alloc(CountingAllocator {
            inner: RustAllocator,
            used: memory_used.clone(),
            limit: limits.memory_bytes,
            exceeded: memory_exceeded.clone(),
        })
        .map_err(|e| format!("engine: {e}"))?;
        let base = Instant::now();
        let deadline = Arc::new(AtomicU64::new(0));
        let interrupted = Arc::new(AtomicBool::new(false));
        {
            let deadline = deadline.clone();
            let interrupted = interrupted.clone();
            runtime.set_interrupt_handler(Some(Box::new(move || {
                let due = deadline.load(Ordering::Relaxed);
                if due != 0 && nanos_since(base) > due {
                    interrupted.store(true, Ordering::Relaxed);
                    return true;
                }
                false
            })));
        }
        let context = Context::full(&runtime).map_err(|e| format!("engine: {e}"))?;
        let shared = Rc::new(RefCell::new(Shared {
            next_sub: 1,
            next_timer: 1,
            max_pending_calls: limits.max_pending_calls,
            ..Shared::default()
        }));
        let mut vm = Self {
            context,
            runtime,
            shared,
            base,
            deadline,
            interrupted,
            memory_exceeded,
            memory_used,
            limits,
            dead: None,
        };
        let shared = vm.shared.clone();
        vm.enter("runtime", move |ctx| {
            install_native(ctx, &shared)?;
            ctx.eval::<(), _>(RUNTIME_JS)
        })
        .map_err(|e| format!("{e:?}"))?
        .map_err(|e| format!("runtime: {e}"))?;
        Ok(vm)
    }

    /// Evaluates the app's main script and calls `__cmuxAppInit`.
    pub fn init(&mut self, params: InitParams) -> Result<(), VmError> {
        let main = params.main;
        if let Err(error) = self.enter("main", move |ctx| ctx.eval::<(), _>(main))? {
            return Err(VmError::Init(format!("main: {error}")));
        }
        let init = json!({
            "app": params.app,
            "settings": params.settings,
            "apiVersion": params.api_version,
            "ops": params.ops,
            "knownOps": params.known_ops,
            "locale": params.locale.unwrap_or_else(|| "en".to_string()),
            "strings": if params.strings.is_object() { params.strings } else { json!({}) },
        })
        .to_string();
        match self
            .enter("init", move |ctx| call_global::<_, String>(ctx, "__cmuxAppInit", (init,)))?
        {
            Ok(result) if result.is_empty() => Ok(()),
            Ok(result) => Err(VmError::Init(result)),
            Err(error) => Err(VmError::Init(error)),
        }
    }

    /// Mounts an export; `Ok(None)` when it rendered, `Ok(Some(message))` when the app refused.
    pub fn mount(
        &mut self,
        mount: &str,
        export: &str,
        ctx_json: &Value,
    ) -> Result<Option<String>, VmError> {
        let args = (mount.to_string(), export.to_string(), ctx_json.to_string());
        let result =
            self.enter("mount", move |ctx| call_global::<_, String>(ctx, "__cmuxAppMount", args))?;
        Ok(match result {
            Ok(message) if message.is_empty() => None,
            Ok(message) => Some(message),
            Err(error) => Some(error),
        })
    }

    pub fn unmount(&mut self, mount: &str) -> Result<(), VmError> {
        let args = (mount.to_string(),);
        self.entry_unit("unmount", move |ctx| call_global::<_, ()>(ctx, "__cmuxAppUnmount", args))
    }

    pub fn dispatch(
        &mut self,
        mount: &str,
        node: &str,
        event: &str,
        payload: &Value,
    ) -> Result<(), VmError> {
        let args = (mount.to_string(), node.to_string(), event.to_string(), payload.to_string());
        self.entry_unit("dispatch", move |ctx| call_global::<_, ()>(ctx, "__cmuxAppDispatch", args))
    }

    /// Answers one `call`. Unknown callback ids are ignored.
    pub fn resolve(&mut self, cb: u64, ok: bool, body: &Value) -> Result<(), VmError> {
        if !self.shared.borrow_mut().pending_calls.remove(&cb) {
            return Ok(());
        }
        let args = (cb as f64, ok, body.to_string());
        self.entry_unit("resolve", move |ctx| call_global::<_, ()>(ctx, "__cmuxAppResolve", args))
    }

    pub fn event(&mut self, sub: u64, body: &Value) -> Result<(), VmError> {
        let args = (sub as f64, body.to_string());
        self.entry_unit("event", move |ctx| call_global::<_, ()>(ctx, "__cmuxAppEvent", args))
    }

    pub fn set_settings(&mut self, values: &Value) -> Result<(), VmError> {
        let args = (values.to_string(),);
        self.entry_unit("settings", move |ctx| {
            call_global::<_, ()>(ctx, "__cmuxAppSetSettings", args)
        })
    }

    /// Runs a command export; the answer arrives as [`FromHost::Done`].
    /// `gesture` is the token of the user invocation, if there was one.
    pub fn run_command(
        &mut self,
        cb: u64,
        export: &str,
        args: &Value,
        gesture: Option<&str>,
    ) -> Result<(), VmError> {
        // The runtime takes the invocation context as JSON (`{gesture?}`).
        let ctx = serde_json::json!({ "gesture": gesture }).to_string();
        let call = (export.to_string(), args.to_string(), cb as f64, ctx);
        self.entry_unit("command", move |ctx| {
            call_global::<_, ()>(ctx, "__cmuxAppRunCommand", call)
        })
    }

    /// The earliest timer due time, if any timer is armed.
    pub fn next_timer_due(&self) -> Option<Instant> {
        self.shared.borrow().timers.values().map(|t| t.due).min()
    }

    /// Fires every timer due at `now` (repeating ones are re-armed first).
    pub fn fire_due_timers(&mut self, now: Instant) -> Result<(), VmError> {
        let due: Vec<u64> = {
            let mut shared = self.shared.borrow_mut();
            let ids: Vec<u64> =
                shared.timers.iter().filter(|(_, t)| t.due <= now).map(|(id, _)| *id).collect();
            for id in &ids {
                let repeat = shared.timers[id].repeat;
                match repeat {
                    Some(every) => shared.timers.get_mut(id).expect("timer").due = now + every,
                    None => {
                        shared.timers.remove(id);
                    }
                }
            }
            ids
        };
        for id in due {
            self.entry_unit("timer", move |ctx| {
                call_global::<_, ()>(ctx, "__cmuxAppTimer", (id as f64,))
            })?;
        }
        Ok(())
    }

    /// Messages produced since the last call, in order.
    pub fn take_outbox(&mut self) -> Vec<FromHost> {
        let mut shared = self.shared.borrow_mut();
        shared.outbox_bytes = 0;
        std::mem::take(&mut shared.outbox)
    }

    /// Calls forwarded and not answered yet.
    pub fn pending_calls(&self) -> usize {
        self.shared.borrow().pending_calls.len()
    }

    pub fn memory_used(&self) -> usize {
        self.memory_used.load(Ordering::Relaxed)
    }

    pub fn limits(&self) -> Limits {
        self.limits
    }

    /// Why the VM died, if it did. A dead VM refuses every entry.
    pub fn dead(&self) -> Option<FatalReason> {
        self.dead
    }

    /// Evaluates source in the VM (tests and diagnostics); returns its JSON.
    pub fn eval_json(&mut self, source: &str) -> Result<Result<Value, String>, VmError> {
        let source = format!("JSON.stringify(({source}))");
        self.enter("eval", move |ctx| ctx.eval::<Option<String>, _>(source)).map(|r| {
            r.map(|s| s.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null))
        })
    }

    fn entry_unit<F>(&mut self, name: &str, f: F) -> Result<(), VmError>
    where
        F: for<'js> FnOnce(&Ctx<'js>) -> rquickjs::Result<()>,
    {
        if let Err(error) = self.enter(name, f)? {
            self.shared.borrow_mut().log("error", &format!("{name}: {error}"));
        }
        Ok(())
    }

    /// Runs one entry point under the deadline, drains the job queue, answers
    /// calls refused by the pending cap, flushes the runtime, and checks the
    /// limits. The outer error is fatal; the inner one is a script error.
    fn enter<R, F>(&mut self, name: &str, f: F) -> Result<Result<R, String>, VmError>
    where
        F: for<'js> FnOnce(&Ctx<'js>) -> rquickjs::Result<R>,
    {
        if let Some(reason) = self.dead {
            return Err(VmError::Fatal { reason, entry: name.to_string() });
        }
        let due = nanos_since(self.base)
            .saturating_add(self.limits.entry_deadline.as_nanos() as u64)
            .max(1);
        self.deadline.store(due, Ordering::Relaxed);
        let result = self.context.with(|ctx| f(&ctx).catch(&ctx).map_err(|e| e.to_string()));
        self.settle();
        self.deadline.store(0, Ordering::Relaxed);
        self.check_limits(name)?;
        Ok(result)
    }

    fn settle(&mut self) {
        loop {
            self.drain_jobs();
            let overflow = std::mem::take(&mut self.shared.borrow_mut().overflow);
            if overflow.is_empty() {
                break;
            }
            for cb in overflow {
                let body = json!({"code": "app.limit", "message": "too many pending calls", "retryable": true}).to_string();
                let outcome = self.context.with(|ctx| {
                    call_global::<_, ()>(&ctx, "__cmuxAppResolve", (cb as f64, false, body))
                        .catch(&ctx)
                        .map_err(|e| e.to_string())
                });
                if let Err(error) = outcome {
                    self.shared.borrow_mut().log("error", &format!("resolve: {error}"));
                }
            }
            if self.limit_hit() {
                return;
            }
        }
        if self.limit_hit() {
            return;
        }
        let flushed = self.context.with(|ctx| {
            call_global::<_, ()>(&ctx, "__cmuxAppFlush", ()).catch(&ctx).map_err(|e| e.to_string())
        });
        if let Err(error) = flushed {
            self.shared.borrow_mut().log("error", &format!("flush: {error}"));
        }
        self.drain_jobs();
    }

    fn drain_jobs(&mut self) {
        loop {
            if self.limit_hit() {
                return;
            }
            match self.runtime.execute_pending_job() {
                Ok(true) => {}
                Ok(false) => return,
                Err(error) => self.shared.borrow_mut().log("error", &format!("job: {error}")),
            }
        }
    }

    fn limit_hit(&self) -> bool {
        self.interrupted.load(Ordering::Relaxed)
            || self.memory_exceeded.load(Ordering::Relaxed)
            || self.shared.borrow().flooded
    }

    fn check_limits(&mut self, entry: &str) -> Result<(), VmError> {
        let reason = if self.memory_exceeded.load(Ordering::Relaxed) || self.shared.borrow().flooded
        {
            FatalReason::Memory
        } else if self.interrupted.load(Ordering::Relaxed) {
            FatalReason::Interrupt
        } else {
            return Ok(());
        };
        self.dead = Some(reason);
        self.shared.borrow_mut().outbox.push(FromHost::Fatal { reason, entry: entry.to_string() });
        Err(VmError::Fatal { reason, entry: entry.to_string() })
    }
}

fn nanos_since(base: Instant) -> u64 {
    base.elapsed().as_nanos().min(u128::from(u64::MAX)) as u64
}

fn call_global<'js, A, R>(ctx: &Ctx<'js>, name: &str, args: A) -> rquickjs::Result<R>
where
    A: rquickjs::function::IntoArgs<'js>,
    R: rquickjs::FromJs<'js>,
{
    let f: Function = ctx.globals().get(name)?;
    f.call(args)
}

fn parse(json: &str) -> Value {
    serde_json::from_str(json).unwrap_or(Value::Null)
}

fn install_native<'js>(ctx: &Ctx<'js>, shared: &Rc<RefCell<Shared>>) -> rquickjs::Result<()> {
    let native = Object::new(ctx.clone())?;
    let s = shared.clone();
    native.set(
        "call",
        Function::new(
            ctx.clone(),
            move |name: String, params: String, options: String, cb: f64| {
                let cb = cb as u64;
                let mut shared = s.borrow_mut();
                // A repeated id (app code calling the native function itself)
                // never counts twice toward the cap or reaches the supervisor.
                if shared.pending_calls.contains(&cb) {
                    return;
                }
                if shared.pending_calls.len() >= shared.max_pending_calls {
                    shared.overflow.push(cb);
                    return;
                }
                shared.pending_calls.insert(cb);
                let bytes = name.len() + params.len() + options.len();
                shared.push(
                    FromHost::Call { cb, name, params: parse(&params), options: parse(&options) },
                    bytes,
                );
            },
        )?,
    )?;
    let s = shared.clone();
    native.set(
        "subscribe",
        Function::new(ctx.clone(), move |stream: String, filter: String| -> f64 {
            let mut shared = s.borrow_mut();
            let sub = shared.next_sub;
            shared.next_sub += 1;
            if shared.subscriptions.len() >= MAX_SUBSCRIPTIONS {
                shared.flooded = true;
                return sub as f64;
            }
            shared.subscriptions.insert(sub);
            let bytes = stream.len() + filter.len();
            shared.push(FromHost::Subscribe { sub, stream, filter: parse(&filter) }, bytes);
            sub as f64
        })?,
    )?;
    let s = shared.clone();
    native.set(
        "unsubscribe",
        Function::new(ctx.clone(), move |sub: f64| {
            let mut shared = s.borrow_mut();
            if shared.subscriptions.remove(&(sub as u64)) {
                shared.push(FromHost::Unsubscribe { sub: sub as u64 }, 16);
            }
        })?,
    )?;
    let s = shared.clone();
    native.set(
        "scene",
        Function::new(ctx.clone(), move |mount: String, ops: String| {
            let bytes = mount.len() + ops.len();
            s.borrow_mut().push(FromHost::Scene { mount, ops: parse(&ops) }, bytes);
        })?,
    )?;
    let s = shared.clone();
    native.set(
        "timer",
        Function::new(ctx.clone(), move |ms: f64, repeat: bool| -> f64 {
            let mut shared = s.borrow_mut();
            let id = shared.next_timer;
            shared.next_timer += 1;
            if shared.timers.len() >= MAX_TIMERS {
                shared.flooded = true;
                return id as f64;
            }
            let every =
                Duration::from_millis(if ms.is_finite() && ms > 0.0 { ms as u64 } else { 0 });
            let every =
                if repeat { every.max(Duration::from_millis(1000)) } else { every.max(MIN_TIMER) };
            shared
                .timers
                .insert(id, Timer { due: Instant::now() + every, repeat: repeat.then_some(every) });
            id as f64
        })?,
    )?;
    let s = shared.clone();
    native.set(
        "clearTimer",
        Function::new(ctx.clone(), move |id: f64| {
            s.borrow_mut().timers.remove(&(id as u64));
        })?,
    )?;
    let s = shared.clone();
    native.set(
        "log",
        Function::new(ctx.clone(), move |level: String, message: String| {
            let level = match level.as_str() {
                "debug" | "info" | "warn" | "error" => level,
                _ => "info".to_string(),
            };
            s.borrow_mut().log(&level, &message);
        })?,
    )?;
    let s = shared.clone();
    native.set(
        "commandDone",
        Function::new(ctx.clone(), move |cb: f64, ok: bool, json: String| {
            let bytes = json.len();
            s.borrow_mut().push(FromHost::Done { cb: cb as u64, ok, body: parse(&json) }, bytes);
        })?,
    )?;
    ctx.globals().set("__cmuxAppNative", native)?;
    Ok(())
}
