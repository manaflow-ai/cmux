//! The script's side: a QuickJS engine on its own thread, as code mode's
//! `cmux_exec` runs one (cmux-tui `cli/mcp/code_mode.rs`). Its host
//! functions only send requests to the driver and wait for the answer; the
//! driver owns the journal, the host and every step. While the script has no
//! job to run, the engine asks the driver for the next finished step and
//! settles that step's promise.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use rquickjs::{CatchResultExt, Context, Function, Object, Runtime};
use serde_json::{Map, Value, json};

use crate::driver::{Limits, StepKind};

/// The engine's stack, inside a thread stack of `THREAD_STACK`.
const MAX_STACK: usize = 1 << 20;
const THREAD_STACK: usize = 8 << 20;
/// The longest tool name a script may call.
const MAX_TOOL_NAME_BYTES: usize = 128;

pub(crate) enum Request {
    /// `cmux.call(name, arguments)`; answered `{ok, value}` or `{ok: false, message, error}`.
    Call { name: String, arguments: Map<String, Value> },
    /// `agent()` or `machine()`; answered `{ok, id}` or `{ok: false, error}`.
    Start { kind: StepKind, input: String, options: Value, phase: Option<String> },
    /// The script waits on its steps: the next one that finished.
    Wait,
}

pub(crate) enum Notice {
    Meta(Value),
    Phase(String),
    Log(String),
}

pub(crate) enum Reply {
    Value(Value),
    Deliver {
        id: u64,
        ok: bool,
        value: Value,
    },
    /// No step is running or queued: nothing will settle the script's promise.
    Idle,
    /// The host stopped the run (pause).
    Stopped,
}

pub(crate) enum ToDriver {
    Request(Request, mpsc::Sender<Reply>),
    Notice(Notice),
    Done(Ending),
}

pub(crate) enum Ending {
    Returned(Value),
    Threw(Value),
    Paused,
}

/// Starts the engine for `script` and returns the channel its requests
/// arrive on. The thread ends after it sends `Done`.
pub(crate) fn spawn(
    script: String,
    args: Option<Value>,
    limits: Limits,
) -> Result<mpsc::Receiver<ToDriver>, String> {
    let (to_driver, from_engine) = mpsc::channel();
    std::thread::Builder::new()
        .name("cmux-workflow".into())
        .stack_size(THREAD_STACK)
        .spawn(move || {
            let ending = run(&script, args, limits, &to_driver);
            let _ = to_driver.send(ToDriver::Done(ending));
        })
        .map_err(|error| format!("cannot start the workflow engine: {error}"))?;
    Ok(from_engine)
}

/// `export const meta = …` becomes a statement the engine reports, so the
/// script stays the same file Claude Code runs.
pub(crate) fn rewrite_meta(script: &str) -> String {
    let mut at = 0;
    while let Some(found) = script[at..].find("export") {
        let start = at + found;
        let rest = &script[start + "export".len()..];
        let after_const = rest.trim_start().strip_prefix("const");
        let after_meta = after_const
            .filter(|r| r.starts_with(char::is_whitespace))
            .and_then(|r| r.trim_start().strip_prefix("meta"))
            .map(str::trim_start)
            .filter(|r| r.starts_with('=') && !r.starts_with("=="));
        if let Some(tail) = after_meta {
            let value = &tail[1..];
            return format!("{}const meta = globalThis.__cmuxMeta ={value}", &script[..start]);
        }
        at = start + "export".len();
    }
    script.to_owned()
}

const PRELUDE: &str = include_str!("prelude.js");

fn run(
    script: &str,
    args: Option<Value>,
    limits: Limits,
    to_driver: &mpsc::Sender<ToDriver>,
) -> Ending {
    let threw =
        |message: String, code: &str| Ending::Threw(json!({"code": code, "message": message}));
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => return threw(format!("engine: {error}"), "script.engine"),
    };
    runtime.set_memory_limit(limits.memory);
    runtime.set_max_stack_size(MAX_STACK);
    let progress = Arc::new(Mutex::new(Instant::now()));
    let stopped = Arc::new(Mutex::new(false));
    {
        let progress = progress.clone();
        let stopped = stopped.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            let over = progress.lock().map(|at| at.elapsed() > limits.compute).unwrap_or(true);
            if over && let Ok(mut stopped) = stopped.lock() {
                *stopped = true;
            }
            over
        })));
    }
    let context = match Context::full(&runtime) {
        Ok(context) => context,
        Err(error) => return threw(format!("engine: {error}"), "script.engine"),
    };
    let done = Rc::new(RefCell::new(None::<Result<Value, Value>>));
    let ask = {
        let to_driver = to_driver.clone();
        let progress = progress.clone();
        move |request: Request| -> Reply {
            let (reply, answer) = mpsc::channel();
            let answered = if to_driver.send(ToDriver::Request(request, reply)).is_ok() {
                answer.recv().ok()
            } else {
                None
            };
            if let Ok(mut at) = progress.lock() {
                *at = Instant::now();
            }
            answered.unwrap_or(Reply::Stopped)
        }
    };
    let calls = Rc::new(RefCell::new(0usize));
    let source = format!(
        "((finish) => {{ delete globalThis.__cmuxFinish; finish((async () => {{\n{}\n}})()); }})(globalThis.__cmuxFinish);",
        rewrite_meta(script)
    );
    let evaluated = context.with(|ctx| -> Result<(), String> {
        let native = Object::new(ctx.clone()).map_err(|e| e.to_string())?;
        let set = |name: &str, function| put(&native, name, function);
        if let Some(args) = &args {
            native.set("args", args.to_string()).map_err(|e| e.to_string())?;
        }
        let call_ask = ask.clone();
        let max_calls = limits.max_calls;
        set(
            "call",
            Function::new(ctx.clone(), move |name: String, arguments: String| -> String {
                if name.len() > MAX_TOOL_NAME_BYTES {
                    return failure("usage.invalid", "no tool has a name that long");
                }
                let mut used = calls.borrow_mut();
                if *used >= max_calls {
                    return failure(
                        "script.too_many_calls",
                        &format!("one run of a workflow makes at most {max_calls} cmux calls"),
                    );
                }
                *used += 1;
                drop(used);
                let arguments = match serde_json::from_str::<Value>(&arguments) {
                    Ok(Value::Object(arguments)) => arguments,
                    _ => return failure("usage.invalid", "tool arguments must be an object"),
                };
                match call_ask(Request::Call { name, arguments }) {
                    Reply::Value(value) => value.to_string(),
                    _ => failure("workflow.stopped", "the workflow stopped"),
                }
            }),
        )?;
        let start_ask = ask.clone();
        set(
            "start",
            Function::new(
                ctx.clone(),
                move |kind: String, input: String, options: String, phase: String| -> String {
                    let kind = if kind == "machine" { StepKind::Machine } else { StepKind::Agent };
                    let options = match serde_json::from_str::<Value>(&options) {
                        Ok(options @ Value::Object(_)) => options,
                        _ => return failure("usage.invalid", "step options must be an object"),
                    };
                    let phase = Some(phase).filter(|phase| !phase.is_empty());
                    match start_ask(Request::Start { kind, input, options, phase }) {
                        Reply::Value(value) => value.to_string(),
                        _ => failure("workflow.stopped", "the workflow stopped"),
                    }
                },
            ),
        )?;
        let notice = |to_driver: mpsc::Sender<ToDriver>, make: fn(String) -> Notice| {
            move |text: String| {
                let _ = to_driver.send(ToDriver::Notice(make(text)));
            }
        };
        set("phase", Function::new(ctx.clone(), notice(to_driver.clone(), Notice::Phase)))?;
        let log_driver = to_driver.clone();
        set(
            "log",
            Function::new(ctx.clone(), move |level: String, text: String| {
                let line = if level == "log" { text } else { format!("[{level}] {text}") };
                let _ = log_driver.send(ToDriver::Notice(Notice::Log(line)));
            }),
        )?;
        let meta_driver = to_driver.clone();
        set(
            "meta",
            Function::new(ctx.clone(), move |text: String| {
                let value = serde_json::from_str(&text).unwrap_or(Value::Null);
                let _ = meta_driver.send(ToDriver::Notice(Notice::Meta(value)));
            }),
        )?;
        let done_sink = done.clone();
        set(
            "done",
            Function::new(ctx.clone(), move |ok: bool, text: String| {
                let value = serde_json::from_str::<Value>(&text).unwrap_or(Value::String(text));
                *done_sink.borrow_mut() = Some(if ok { Ok(value) } else { Err(value) });
            }),
        )?;
        ctx.globals().set("__cmuxNative", native).map_err(|e| e.to_string())?;
        ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(|e| format!("prelude: {e}"))?;
        ctx.eval::<(), _>(source.as_str()).catch(&ctx).map_err(|e| e.to_string())?;
        Ok(())
    });
    let interrupted = || stopped.lock().map(|stopped| *stopped).unwrap_or(false);
    if let Err(message) = evaluated {
        let code = if interrupted() { "script.timeout" } else { "script.error" };
        return threw(message, code);
    }
    loop {
        loop {
            match runtime.execute_pending_job() {
                Ok(true) => {}
                Ok(false) => break,
                Err(error) => {
                    let _ = to_driver
                        .send(ToDriver::Notice(Notice::Log(format!("[error] job: {error}"))));
                }
            }
            if done.borrow().is_some() || interrupted() {
                break;
            }
        }
        if interrupted() {
            return threw(
                format!(
                    "the script computed for {} ms without a step or call",
                    limits.compute.as_millis()
                ),
                "script.timeout",
            );
        }
        if let Some(result) = done.borrow_mut().take() {
            return match result {
                Ok(value) => Ending::Returned(value),
                Err(error)
                    if error["message"].as_str().is_some_and(|m| m.contains("out of memory")) =>
                {
                    threw(
                        format!("the script used more than {} MiB", limits.memory >> 20),
                        "script.memory",
                    )
                }
                Err(error) => Ending::Threw(error),
            };
        }
        match ask(Request::Wait) {
            Reply::Deliver { id, ok, value } => {
                let delivered = context.with(|ctx| -> Result<(), String> {
                    let deliver: Function =
                        ctx.globals().get("__cmuxDeliver").map_err(|e| e.to_string())?;
                    deliver
                        .call::<_, ()>((id, ok, value.to_string()))
                        .catch(&ctx)
                        .map_err(|e| e.to_string())
                });
                if let Err(message) = delivered {
                    return threw(message, "script.error");
                }
            }
            Reply::Idle => {
                return threw(
                    "the script ended while it still awaited a promise that nothing resolves"
                        .into(),
                    "script.unfinished",
                );
            }
            Reply::Stopped => return Ending::Paused,
            Reply::Value(_) => {
                return threw("the driver answered out of turn".into(), "script.engine");
            }
        }
    }
}

fn put<'js>(
    native: &Object<'js>,
    name: &str,
    function: rquickjs::Result<Function<'js>>,
) -> Result<(), String> {
    native.set(name, function.map_err(|e| e.to_string())?).map_err(|e| e.to_string())
}

fn failure(code: &str, message: &str) -> String {
    json!({"ok": false, "message": message, "error": {"error": {"code": code, "message": message}, "state": "not_run"}})
        .to_string()
}
