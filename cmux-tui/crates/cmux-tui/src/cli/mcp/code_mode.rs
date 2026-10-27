//! Code mode: `serve` offers two tools, `cmux_docs` and `cmux_exec`, in
//! place of one tool per operation (plans/cmux-next/code-mode.md). The
//! full tool list (daemon operations, browser host, agents, app actions)
//! stays the API: `cmux_docs` searches it and a `cmux_exec` script calls
//! it through the same `Server::call` path, so a script has exactly the
//! rights of a direct tool call and nothing else. 638 tool schemas were
//! about 208k tokens in every agent turn; these two are about 1k.
//!
//! A script runs in an embedded QuickJS engine on its own thread. The engine
//! has no file system, network, process or timer access: its only host
//! functions are `cmux.call`, `cmux.docs` and `console`. Each call goes back
//! to the server's thread over a channel and is answered there, one at a
//! time, in order.

use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rquickjs::{CatchResultExt, Context, Function, Object, Runtime};
use serde_json::{Map, Value, json};

pub(super) const DOCS: &str = "cmux_docs";
pub(super) const EXEC: &str = "cmux_exec";

/// The largest script source.
const MAX_SCRIPT_BYTES: usize = 256 << 10;
/// The engine's stack, inside a thread stack of `THREAD_STACK`.
const MAX_STACK: usize = 1 << 20;
const THREAD_STACK: usize = 8 << 20;
/// What one script may use.
#[derive(Clone, Copy, Debug)]
pub(super) struct Limits {
    /// The engine's heap.
    pub memory: usize,
    /// A script that computes this long without a cmux call is stopped (a
    /// loop that never ends). Time inside a call does not count: a call has
    /// its own owner deadline.
    pub compute: Duration,
    /// The whole script, calls included. While a script runs the server
    /// reads no other request, so this bounds that wait.
    pub total: Duration,
}

impl Default for Limits {
    fn default() -> Self {
        Self {
            memory: 64 << 20,
            compute: Duration::from_secs(30),
            total: Duration::from_secs(10 * 60),
        }
    }
}

/// Calls and docs searches in one script.
const MAX_CALLS: usize = 2_000;
/// Calls a result lists one by one; the rest are only counted.
const MAX_CALL_RECORDS: usize = 200;
/// The longest tool name a script may call (the longest real one is under 60).
const MAX_TOOL_NAME_BYTES: usize = 128;
/// Console text kept per script (each line counts one more byte, so empty
/// lines count too); later lines are dropped and counted.
const MAX_LOG_BYTES: usize = 64 << 10;
/// Tools with schemas in one docs answer, by default and at most.
const DOCS_DEFAULT_LIMIT: usize = 8;
const DOCS_MAX_LIMIT: usize = 30;
/// Further matching names a docs answer lists without schemas.
const DOCS_MORE_NAMES: usize = 60;

pub(super) const INSTRUCTIONS: &str = "cmux tools run in code mode, through cmux_exec. In a \
    script, `cmux.docs(query)` searches every cmux tool (workspaces, screens, panes, tabs, \
    terminals, browser, git, agents, notifications, keybindings, app actions) and returns its \
    input schema, and the script calls them: `await cmux.pane_split({...})`; put related steps in \
    one script and return what you need. Tools of the chat's other cmux servers (cua_*, \
    secrets_*, sessions_*, subsessions_*, forum_*) come with their rules in `servers` of a \
    cmux.docs answer: follow them. Objects have public ids (ws_…, pane_…, tab_…, term_…) \
    from the *_list tools; a unique prefix or <session>:<id> works. A change takes \
    idempotency_key: on in_progress, retry with the key from the error; another server's \
    call that fails in_progress has no key and may have run, so check its effect first. Tools \
    never move the \
    user's focus unless the call passes focus: true or the tool's purpose is focus. Name \
    workspaces and tabs to the person by title, never by id. When they must act in a tab \
    (log in, confirm, approve), tab_update {tab, attention: \"reason\"} marks it; tab_focus \
    it when they ask to go there. In a chat reply, show UI: ![alt](/abs/path.png) or an image \
    path or https address draws as a thumbnail.";

/// The one tool `serve` lists in code mode, `cmux_exec` (Lawrence 2026-10-23:
/// an agent sees no other cmux tool name; a script searches with
/// `cmux.docs`, and `cmux_docs` stays callable for older prompts). `tools`
/// is the full list, for the family summary in its description.
pub(super) fn descriptors(tools: &[Value]) -> Vec<Value> {
    let families = families(tools)
        .iter()
        .map(|(family, names)| format!("{family} ({})", names.len()))
        .collect::<Vec<_>>()
        .join(", ");
    vec![json!({
        "name": EXEC,
        "title": "Run a cmux script",
        "description": format!(
            "Run JavaScript that calls cmux tools and return its result. The script is \
             an async function body: use await and return a JSON value. \
             `cmux.docs(query)` finds tools with their input schemas (words such as \
             \"pane split\", or nothing for every name by family); \
             `cmux.call(name, args)` or `cmux.<tool_name>(args)` calls one and returns its \
             result; a failed call throws an Error whose `cmux` field has the error, its \
             state and its idempotency key. console.log output comes back in logs. There \
             is no file system, network or timer access. A failed script reports the calls \
             that already ran. Families: {families}."
        ),
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "script": {
                    "type": "string",
                    "minLength": 1,
                    "description": "JavaScript, an async function body",
                },
            },
            "required": ["script"],
        },
        "annotations": {"destructiveHint": true, "openWorldHint": false},
    })]
}

/// Tool names grouped by their first word (`pane_split` is `pane`).
fn families(tools: &[Value]) -> BTreeMap<String, Vec<String>> {
    let mut families = BTreeMap::<String, Vec<String>>::new();
    for name in tools.iter().filter_map(|tool| tool["name"].as_str()) {
        let family = name.split('_').next().unwrap_or(name);
        families.entry(family.to_owned()).or_default().push(name.to_owned());
    }
    families
}

/// `cmux_docs`: tools that match, with schemas; or every name by family.
pub(super) fn docs(tools: &[Value], arguments: &Map<String, Value>) -> Result<Value, String> {
    if let Some(name) =
        arguments.keys().find(|name| !matches!(name.as_str(), "query" | "names" | "limit"))
    {
        return Err(format!("{DOCS} has no argument {name:?}"));
    }
    let limit = match arguments.get("limit") {
        None => DOCS_DEFAULT_LIMIT,
        Some(value) => value
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .filter(|value| (1..=DOCS_MAX_LIMIT).contains(value))
            .ok_or_else(|| format!("{DOCS} limit must be an integer from 1 to {DOCS_MAX_LIMIT}"))?,
    };
    if let Some(names) = arguments.get("names") {
        let names = names
            .as_array()
            .and_then(|names| names.iter().map(Value::as_str).collect::<Option<Vec<_>>>())
            .ok_or_else(|| format!("{DOCS} names must be an array of strings"))?;
        if names.len() > DOCS_MAX_LIMIT {
            return Err(format!("{DOCS} names takes at most {DOCS_MAX_LIMIT} names"));
        }
        let mut found = Vec::new();
        let mut unknown = Vec::new();
        for name in names {
            match tools.iter().find(|tool| tool["name"] == name) {
                Some(tool) => found.push(tool.clone()),
                None => unknown.push(name),
            }
        }
        return Ok(json!({"tools": found, "unknown": unknown}));
    }
    let query = match arguments.get("query") {
        None => None,
        Some(Value::String(query)) => Some(query.trim().to_lowercase()).filter(|q| !q.is_empty()),
        Some(_) => return Err(format!("{DOCS} query must be a string")),
    };
    let Some(query) = query else {
        return Ok(json!({"families": families(tools)}));
    };
    Ok(search(tools, &query, limit))
}

/// Tools whose name, description or argument names contain every word of
/// `query`, best first: a word in the name counts most.
fn search(tools: &[Value], query: &str, limit: usize) -> Value {
    let terms = query
        .split(|c: char| c.is_whitespace() || matches!(c, '_' | '.' | '-'))
        .filter(|t| !t.is_empty())
        .collect::<Vec<_>>();
    let mut scored = tools
        .iter()
        .filter_map(|tool| {
            let name = tool["name"].as_str()?.to_lowercase();
            let description = tool["description"].as_str().unwrap_or_default().to_lowercase();
            let arguments = tool["inputSchema"]["properties"]
                .as_object()
                .map(|properties| properties.keys().cloned().collect::<Vec<_>>().join(" "))
                .unwrap_or_default()
                .to_lowercase();
            let mut score = 0;
            for term in &terms {
                score += match () {
                    () if name.contains(term) => 4,
                    () if description.contains(term) => 1,
                    () if arguments.contains(term) => 1,
                    () => return None,
                };
            }
            Some((score, tool))
        })
        .collect::<Vec<_>>();
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0).then_with(|| a.1["name"].as_str().cmp(&b.1["name"].as_str()))
    });
    let more = scored
        .iter()
        .skip(limit)
        .take(DOCS_MORE_NAMES)
        .filter_map(|(_, tool)| tool["name"].as_str())
        .collect::<Vec<_>>();
    let mut answer = json!({
        "query": query,
        "matches": scored.len(),
        "tools": scored.iter().take(limit).map(|(_, tool)| (*tool).clone()).collect::<Vec<_>>(),
        "more": more,
    });
    // A task no one tool answers (`cmux docs search` returns the same).
    let guides = super::super::docs::guides(query);
    if !guides.is_empty() {
        answer["guides"] = json!(guides);
    }
    answer
}

/// What a script asks the server for while it runs.
pub(super) enum Request {
    /// A tool call; the answer is `{ok, value}` or `{ok: false, message, error}`.
    Call { name: String, arguments: Map<String, Value> },
    /// `cmux.docs(query)`.
    Docs { query: String },
}

enum ToServer {
    Request(Request, mpsc::Sender<Value>),
    Done(Outcome),
}

struct Outcome {
    /// `Ok(value)` the script returned, or `Err(error)` it threw or hit.
    result: Result<Value, Value>,
    logs: Vec<String>,
    dropped_logs: usize,
}

/// `cmux_exec`: runs `arguments.script` and answers each of its requests
/// with `answer` on this thread. Returns the tool result.
pub(super) fn exec(
    arguments: &Map<String, Value>,
    limits: Limits,
    answer: &mut dyn FnMut(Request) -> Value,
) -> Result<Value, String> {
    if let Some(name) = arguments.keys().find(|name| name.as_str() != "script") {
        return Err(format!("{EXEC} has no argument {name:?}"));
    }
    let script = match arguments.get("script") {
        Some(Value::String(script)) if !script.trim().is_empty() => script.clone(),
        _ => return Err(format!("{EXEC} needs script, a non-empty string")),
    };
    if script.len() > MAX_SCRIPT_BYTES {
        return Err(format!("{EXEC} script is larger than {} KiB", MAX_SCRIPT_BYTES >> 10));
    }
    let (to_server, from_script) = mpsc::channel();
    let engine = std::thread::Builder::new()
        .name("cmux-mcp-code-mode".into())
        .stack_size(THREAD_STACK)
        .spawn(move || {
            let outcome = run_script(&script, limits, &to_server);
            let _ = to_server.send(ToServer::Done(outcome));
        })
        .map_err(|error| format!("{EXEC} cannot start its engine: {error}"))?;
    let mut calls = 0usize;
    // Whether a call may have changed something: one succeeded, or its
    // outcome is unknown (`in_progress`).
    let mut applied = false;
    let mut records = Vec::new();
    let mut outcome = None;
    for message in &from_script {
        match message {
            ToServer::Request(request, reply) => {
                let name = match &request {
                    Request::Call { name, .. } => Some(name.clone()),
                    Request::Docs { .. } => None,
                };
                let answered = answer(request);
                if let Some(name) = name {
                    calls += 1;
                    let ok = answered["ok"] == true;
                    let state = answered["error"]["state"].as_str().map(str::to_owned);
                    applied |= ok || state.as_deref() == Some("in_progress");
                    if records.len() < MAX_CALL_RECORDS {
                        let mut record = json!({"name": name, "ok": ok});
                        if let Some(state) = state {
                            record["state"] = json!(state);
                        }
                        if let Some(key) = answered["error"]["idempotency_key"].as_str() {
                            record["idempotency_key"] = json!(key);
                        }
                        records.push(record);
                    }
                }
                let _ = reply.send(answered);
            }
            ToServer::Done(done) => {
                outcome = Some(done);
                break;
            }
        }
    }
    let _ = crate::blocking::thread::join(engine);
    let Some(outcome) = outcome else {
        return Ok(super::tool_error(json!({
            "error": {
                "code": "script.engine",
                "message": "the script engine stopped",
                "details": {},
                "retryable": false,
            },
            "state": if applied { "partial" } else { "not_run" },
            "calls": calls,
            "call_log": records,
        })));
    };
    let mut value = json!({"calls": calls, "call_log": records, "logs": outcome.logs});
    if outcome.dropped_logs > 0 {
        value["dropped_logs"] = json!(outcome.dropped_logs);
    }
    Ok(match outcome.result {
        Ok(result) => {
            value["result"] = result;
            super::success(fit(value), applied)
        }
        Err(error) => {
            value["error"] = error;
            // `partial`: some call may have applied; `call_log` says which,
            // with each failed call's state and idempotency key.
            value["state"] = json!(if applied { "partial" } else { "not_run" });
            super::tool_error(fit(value))
        }
    })
}

/// Keeps a result under the server's limit: a large `result` becomes a
/// text preview, then logs are cut.
fn fit(mut value: Value) -> Value {
    let budget = super::MAX_RESULT_BYTES - (4 << 10);
    let size = |value: &Value| serde_json::to_vec(value).map(|bytes| bytes.len()).unwrap_or(0);
    if size(&value) <= budget {
        return value;
    }
    for key in ["result", "error"] {
        if let Some(inner) = value.get(key).filter(|inner| size(inner) > budget / 4) {
            let text = serde_json::to_string(inner).unwrap_or_default();
            // A quarter: the preview is escaped once more inside the result.
            let mut end = budget / 4;
            while !text.is_char_boundary(end) {
                end -= 1;
            }
            value[key] = json!({"truncated": true, "bytes": text.len(), "preview": &text[..end]});
        }
    }
    while size(&value) > budget
        && let Some(logs) = value["logs"].as_array_mut()
        && !logs.is_empty()
    {
        let keep = logs.len() / 2;
        logs.truncate(keep);
        value["logs_truncated"] = json!(true);
    }
    if size(&value) > budget
        && let Some(records) = value["call_log"].as_array_mut()
    {
        records.clear();
        value["call_log_truncated"] = json!(true);
    }
    value
}

const PRELUDE: &str = r#"
(() => {
  const native = globalThis.__cmuxNative;
  delete globalThis.__cmuxNative;
  const format = (value) => {
    if (typeof value === "string") return value;
    try { const text = JSON.stringify(value); return text === undefined ? String(value) : text; }
    catch { return String(value); }
  };
  const encode = (value) => {
    try { const text = JSON.stringify(value); return text === undefined ? "null" : text; }
    catch { return JSON.stringify(String(value)); }
  };
  const log = (level) => (...args) => native.log(level, args.map(format).join(" "));
  globalThis.console = { log: log("log"), info: log("info"), warn: log("warn"), error: log("error"), debug: log("debug") };
  const call = (name, args) => {
    const answer = JSON.parse(native.call(String(name), JSON.stringify(args ?? {})));
    if (answer.ok) return answer.value;
    const error = new Error(`${name}: ${answer.message}`);
    error.cmux = answer.error;
    throw error;
  };
  const base = { call, docs: (query) => JSON.parse(native.docs(String(query ?? ""))) };
  globalThis.cmux = new Proxy(base, {
    get(target, key) {
      if (key in target) return target[key];
      if (typeof key !== "string" || key === "then") return undefined;
      return (args) => call(key, args);
    },
  });
  globalThis.__cmuxFinish = (promise) => promise.then(
    (value) => native.done(true, encode(value)),
    (error) => native.done(false, encode({
      code: "script.error",
      message: String(error && error.message !== undefined ? error.message : error),
      stack: error && error.stack ? String(error.stack) : undefined,
      cmux: error && error.cmux,
    })),
  );
})();
"#;

/// Runs one script on this (the engine) thread.
fn run_script(script: &str, limits: Limits, to_server: &mpsc::Sender<ToServer>) -> Outcome {
    let logs = Rc::new(RefCell::new((Vec::<String>::new(), 0usize, 0usize)));
    let done = Rc::new(RefCell::new(None::<Result<Value, Value>>));
    let failed = |message: String| Outcome {
        result: Err(json!({"code": "script.engine", "message": message})),
        logs: Vec::new(),
        dropped_logs: 0,
    };
    let runtime = match Runtime::new() {
        Ok(runtime) => runtime,
        Err(error) => return failed(format!("engine: {error}")),
    };
    runtime.set_memory_limit(limits.memory);
    runtime.set_max_stack_size(MAX_STACK);
    let started = Instant::now();
    let progress = Arc::new(Mutex::new(started));
    let stopped = Arc::new(Mutex::new(false));
    {
        let progress = progress.clone();
        let stopped = stopped.clone();
        runtime.set_interrupt_handler(Some(Box::new(move || {
            let over = started.elapsed() > limits.total
                || progress.lock().map(|at| at.elapsed() > limits.compute).unwrap_or(true);
            if over && let Ok(mut stopped) = stopped.lock() {
                *stopped = true;
            }
            over
        })));
    }
    let context = match Context::full(&runtime) {
        Ok(context) => context,
        Err(error) => return failed(format!("engine: {error}")),
    };
    let calls = Rc::new(RefCell::new(0usize));
    let evaluated = context.with(|ctx| -> Result<(), String> {
        let native = Object::new(ctx.clone()).map_err(|e| e.to_string())?;
        let count = calls.clone();
        let request = {
            let to_server = to_server.clone();
            let progress = progress.clone();
            move |request: Request| -> String {
                let mut used = count.borrow_mut();
                if *used >= MAX_CALLS {
                    return failure(
                        "script.too_many_calls",
                        &format!("a script makes at most {MAX_CALLS} calls and docs searches"),
                    );
                }
                *used += 1;
                drop(used);
                if started.elapsed() > limits.total {
                    return failure(
                        "script.timeout",
                        &format!("a script runs at most {} s", limits.total.as_secs()),
                    );
                }
                let (reply, answer) = mpsc::channel();
                let value = if to_server.send(ToServer::Request(request, reply)).is_ok() {
                    cmux_blocking::sync::recv(&answer).unwrap_or_else(|_| closed())
                } else {
                    closed()
                };
                if let Ok(mut at) = progress.lock() {
                    *at = Instant::now();
                }
                value.to_string()
            }
        };
        let call_request = request.clone();
        native
            .set(
                "call",
                Function::new(ctx.clone(), move |name: String, arguments: String| -> String {
                    if name.len() > MAX_TOOL_NAME_BYTES {
                        return failure("usage.invalid", "no tool has a name that long");
                    }
                    let arguments = match serde_json::from_str::<Value>(&arguments) {
                        Ok(Value::Object(arguments)) => arguments,
                        _ => return failure("usage.invalid", "tool arguments must be an object"),
                    };
                    call_request(Request::Call { name, arguments })
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        native
            .set(
                "docs",
                Function::new(ctx.clone(), move |query: String| -> String {
                    request(Request::Docs { query })
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        let log_sink = logs.clone();
        native
            .set(
                "log",
                Function::new(ctx.clone(), move |level: String, text: String| {
                    let mut logs = log_sink.borrow_mut();
                    let line = if level == "log" { text } else { format!("[{level}] {text}") };
                    if logs.2 + line.len() + 1 > MAX_LOG_BYTES {
                        logs.1 += 1;
                    } else {
                        logs.2 += line.len() + 1;
                        logs.0.push(line);
                    }
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        let done_sink = done.clone();
        native
            .set(
                "done",
                Function::new(ctx.clone(), move |ok: bool, text: String| {
                    let value = serde_json::from_str::<Value>(&text).unwrap_or(Value::String(text));
                    *done_sink.borrow_mut() = Some(if ok { Ok(value) } else { Err(value) });
                })
                .map_err(|e| e.to_string())?,
            )
            .map_err(|e| e.to_string())?;
        ctx.globals().set("__cmuxNative", native).map_err(|e| e.to_string())?;
        ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(|e| format!("prelude: {e}"))?;
        // The body runs inside an async function so it can await and return.
        // `finish` leaves the global scope first, so the script cannot
        // report a result of its own through it.
        let source = format!(
            "((finish) => {{ delete globalThis.__cmuxFinish; finish((async () => {{\n{script}\n}})()); }})(globalThis.__cmuxFinish);"
        );
        ctx.eval::<(), _>(source).catch(&ctx).map_err(|e| e.to_string())?;
        Ok(())
    });
    if let Err(message) = evaluated {
        let mut outcome = take_logs(&logs);
        let interrupted = stopped.lock().map(|stopped| *stopped).unwrap_or(false);
        let code = if interrupted {
            "script.timeout"
        } else if message.contains("out of memory") {
            "script.memory"
        } else {
            "script.error"
        };
        outcome.result = Err(json!({"code": code, "message": message}));
        return outcome;
    }
    loop {
        match runtime.execute_pending_job() {
            Ok(true) => {}
            Ok(false) => break,
            Err(error) => {
                if let Ok(mut logs) = logs.try_borrow_mut() {
                    let line = format!("[error] job: {error}");
                    if logs.2 + line.len() + 1 > MAX_LOG_BYTES {
                        logs.1 += 1;
                    } else {
                        logs.2 += line.len() + 1;
                        logs.0.push(line);
                    }
                }
            }
        }
        if done.borrow().is_some() {
            break;
        }
    }
    let mut outcome = take_logs(&logs);
    let interrupted = stopped.lock().map(|stopped| *stopped).unwrap_or(false);
    let result = done.borrow_mut().take();
    outcome.result = if interrupted {
        // The interrupt also stops the rejection handler, so `done` may hold
        // the engine's bare "interrupted" or nothing.
        Err(json!({
            "code": "script.timeout",
            "message": format!(
                "the script computed for {} ms without a cmux call, or ran longer than {} s",
                limits.compute.as_millis(),
                limits.total.as_secs()
            ),
        }))
    } else {
        match result {
            Some(Err(error))
                if error["message"].as_str().is_some_and(|m| m.contains("out of memory")) =>
            {
                Err(json!({
                    "code": "script.memory",
                    "message": format!(
                        "the script used more than {} MiB",
                        limits.memory >> 20
                    ),
                }))
            }
            Some(result) => result,
            None => Err(json!({
                "code": "script.unfinished",
                "message": "the script ended while it still awaited a promise that nothing resolves",
            })),
        }
    };
    outcome
}

fn take_logs(logs: &Rc<RefCell<(Vec<String>, usize, usize)>>) -> Outcome {
    let mut logs = logs.borrow_mut();
    Outcome { result: Ok(Value::Null), logs: std::mem::take(&mut logs.0), dropped_logs: logs.1 }
}

fn failure(code: &str, message: &str) -> String {
    json!({"ok": false, "message": message, "error": {"error": {"code": code, "message": message}, "state": "not_run"}})
        .to_string()
}

fn closed() -> Value {
    json!({"ok": false, "message": "the server stopped", "error": {"state": "not_run"}})
}

/// Images a script's calls returned that one `cmux_exec` result carries
/// (a computer use screenshot), and their total base64 bytes.
const MAX_IMAGES: usize = 8;
const MAX_IMAGE_BYTES: usize = 8 << 20;

/// A tool result as a script sees it. A result without structured content
/// (another server's tool) becomes its JSON text, or `{content}`; its
/// images move to `images`, for the `cmux_exec` result, and the script
/// sees `{type: "image", image: <index>}` in their place.
pub(super) fn script_answer(
    result: Result<Value, (i64, String)>,
    images: &mut Vec<Value>,
) -> Value {
    let result = result.map(|result| {
        if result.get("structuredContent").is_some() {
            return result;
        }
        let mut result = result;
        let failed = result["isError"] == true;
        result["structuredContent"] = from_content(&result["content"], images, failed);
        result
    });
    match result {
        Err((_, message)) => json!({
            "ok": false,
            "message": message,
            "error": {"error": {"code": "usage.invalid", "message": message}, "state": "not_run"},
        }),
        Ok(result) if result["isError"] == true => {
            let error = result["structuredContent"].clone();
            let message = error["error"]["message"]
                .as_str()
                .or_else(|| error["error"]["code"].as_str())
                .unwrap_or("the call failed")
                .to_owned();
            json!({"ok": false, "message": message, "error": error})
        }
        Ok(result) => json!({"ok": true, "value": result["structuredContent"]}),
    }
}

/// The value of an MCP `content` list: one text block that is JSON is that
/// JSON; anything else is `{content}` with images moved to `images`. An
/// error result's text is its `error.message`.
fn from_content(content: &Value, images: &mut Vec<Value>, failed: bool) -> Value {
    let blocks = content.as_array().cloned().unwrap_or_default();
    if let [block] = blocks.as_slice()
        && !failed
        && block["type"] == "text"
        && let Some(value) = block["text"].as_str().and_then(|t| serde_json::from_str(t).ok())
    {
        return value;
    }
    let message =
        blocks.iter().find_map(|block| block["text"].as_str()).unwrap_or_default().to_owned();
    let used = |images: &Vec<Value>| -> usize {
        images.iter().map(|image| image["data"].as_str().map_or(0, str::len)).sum()
    };
    let blocks = blocks
        .into_iter()
        .map(|block| {
            if block["type"] != "image" {
                return block;
            }
            let size = block["data"].as_str().map_or(0, str::len);
            if images.len() >= MAX_IMAGES || used(images) + size > MAX_IMAGE_BYTES {
                return json!({"type": "image", "dropped": true, "mimeType": block["mimeType"]});
            }
            images.push(block.clone());
            json!({"type": "image", "image": images.len() - 1, "mimeType": block["mimeType"]})
        })
        .collect::<Vec<_>>();
    if failed {
        return json!({"content": blocks, "error": {"message": message}});
    }
    json!({"content": blocks})
}
