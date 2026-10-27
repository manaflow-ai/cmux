//! cmux-browser-host's CDP driver evaluating in a page (`cdp/evaluate.rs`):
//! `frame.evaluate` in the agent, page and host worlds (handles moved
//! between worlds, stale contexts retried), `frames.list` (out-of-process
//! subtrees grafted), `frame.focused`, `frame.contentFrame(s)` and
//! `frame.ownerBox`, against a browser whose every answer on that path, and
//! the events around it (contexts created, destroyed and cleared, frames
//! navigated and detached, sessions attached and detached), come from the
//! input. The browser is a scripted CDP wire; one tab is opened with the
//! answers Chromium gives, then the input takes over the answers the
//! evaluate path reads. Calls from the driver's own threads (a new target's
//! setup) keep the scripted answers, so a run never depends on thread timing.
//!
//! Invariants past "no panic": a call returns within its deadline (the
//! browser always answers, so nothing may wait past `timeoutMs`), and a
//! script value the driver passes on as JSON text is JSON.
#![no_main]

use std::collections::VecDeque;
use std::sync::{Arc, Mutex, OnceLock, PoisonError, Weak};
use std::thread::ThreadId;
use std::time::{Duration, Instant};

use arbitrary::Arbitrary;
use cmux_browser_host::cdp::{AGENT_WORLD, CdpConnection, CdpDriver, CdpWire, HOST_WORLD};
use cmux_browser_host::driver::{Driver, Reply, discard_events};
use libfuzzer_sys::fuzz_target;
use serde_json::value::RawValue;
use serde_json::{Value, json};

const AGENT_SOURCE: &str = "globalThis.__cmuxPageAgent = { resolveHandle: (id) => null };";
/// The most driver calls one input makes.
const MAX_CALLS: usize = 8;
/// Slack past a call's own deadline for the work after its last wait.
const SLACK: Duration = Duration::from_secs(1);
/// The methods whose answers the input gives once the tab is open: what the
/// evaluate path sends and reads.
const FUZZED_METHODS: &[&str] = &[
    "Runtime.callFunctionOn",
    "Runtime.evaluate",
    "DOM.describeNode",
    "DOM.resolveNode",
    "DOM.getFrameOwner",
    "DOM.getDocument",
    "DOM.performSearch",
    "DOM.getSearchResults",
    "Page.getFrameTree",
    "Page.createIsolatedWorld",
];

#[derive(Arbitrary, Debug)]
enum WorldName {
    Agent,
    Page,
    Host,
    Other(String),
}

#[derive(Arbitrary, Debug)]
enum Call {
    Evaluate {
        world: Option<WorldName>,
        frame: Option<String>,
        source: String,
        handles: Vec<String>,
        args: Vec<String>,
        await_promise: Option<bool>,
        closed_roots: bool,
        /// Through `call_reply_announced`: the value as JSON text.
        raw: bool,
    },
    FramesList,
    Focused,
    ContentFrame {
        handle: String,
        frame: Option<String>,
    },
    ContentFrames {
        handles: Vec<String>,
    },
    OwnerBox {
        frame: String,
    },
}

#[derive(Arbitrary, Debug)]
struct DriverCall {
    call: Call,
    /// 1..=64 ms.
    timeout_ms: u8,
    /// Names a tab the driver never opened.
    unknown_tab: bool,
}

#[derive(Arbitrary, Debug)]
enum Session {
    Tab,
    Other(String),
    Browser,
}

#[derive(Arbitrary, Debug)]
enum Event {
    ContextCreated {
        id: i64,
        world: Option<WorldName>,
        frame: Option<String>,
        default: bool,
    },
    ContextDestroyed {
        id: i64,
    },
    ContextsCleared,
    FrameNavigated {
        frame: Option<String>,
        parent: Option<String>,
        loader: String,
        url: String,
    },
    FrameDetached {
        frame: Option<String>,
    },
    /// An out-of-process frame's session.
    AttachedFrame {
        session: String,
        frame: String,
        waiting: bool,
    },
    DetachedFromTarget {
        session: Session,
    },
    Raw {
        method: String,
        params: String,
    },
}

#[derive(Arbitrary, Debug)]
enum Answer {
    /// A reply's `result`, as JSON text.
    Result(String),
    Error {
        code: i32,
        message: String,
    },
}

#[derive(Arbitrary, Debug)]
struct Step {
    session: Session,
    events: Vec<Event>,
    answer: Answer,
}

#[derive(Arbitrary, Debug)]
struct Input {
    calls: Vec<DriverCall>,
    answers: Vec<Step>,
}

struct Script {
    /// Set once the tab is open: from then on the fuzz thread's calls on
    /// `FUZZED_METHODS` take the input's answers.
    fuzzing: Option<ThreadId>,
    answers: VecDeque<Step>,
}

struct Wire {
    conn: OnceLock<Weak<CdpConnection>>,
    script: Mutex<Script>,
}

struct WireHandle(Arc<Wire>);

fn lock<T>(mutex: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

fn session_of(session: &Session) -> Option<String> {
    match session {
        Session::Tab => Some("S1".into()),
        Session::Other(other) => Some(other.clone()),
        Session::Browser => None,
    }
}

fn world_name(world: &Option<WorldName>) -> Value {
    match world {
        Some(WorldName::Agent) => json!(AGENT_WORLD),
        Some(WorldName::Host) => json!(HOST_WORLD),
        Some(WorldName::Page) | None => json!(""),
        Some(WorldName::Other(other)) => json!(other),
    }
}

fn frame_or_main(frame: &Option<String>) -> String {
    frame.clone().unwrap_or_else(|| "F-T1".into())
}

fn event_message(session: Option<String>, event: &Event) -> String {
    let (method, params) = match event {
        Event::ContextCreated { id, world, frame, default } => (
            "Runtime.executionContextCreated",
            json!({"context": {"id": id, "name": world_name(world),
                "auxData": {"frameId": frame_or_main(frame), "isDefault": default}}}),
        ),
        Event::ContextDestroyed { id } => {
            ("Runtime.executionContextDestroyed", json!({"executionContextId": id}))
        }
        Event::ContextsCleared => ("Runtime.executionContextsCleared", json!({})),
        Event::FrameNavigated { frame, parent, loader, url } => {
            let mut frame = json!({"id": frame_or_main(frame), "loaderId": loader, "url": url,
                "securityOrigin": url});
            if let Some(parent) = parent {
                frame["parentId"] = json!(parent);
            }
            ("Page.frameNavigated", json!({"frame": frame, "type": "Navigation"}))
        }
        Event::FrameDetached { frame } => {
            ("Page.frameDetached", json!({"frameId": frame_or_main(frame), "reason": "remove"}))
        }
        Event::AttachedFrame { session, frame, waiting } => (
            "Target.attachedToTarget",
            json!({"sessionId": session, "waitingForDebugger": waiting,
                "targetInfo": {"targetId": frame, "type": "iframe", "url": "https://b.test/", "title": ""}}),
        ),
        Event::DetachedFromTarget { session: detached } => (
            "Target.detachedFromTarget",
            json!({"sessionId": session_of(detached).unwrap_or_default()}),
        ),
        Event::Raw { method, params } => {
            let params = serde_json::from_str::<Value>(params).unwrap_or(Value::Null);
            let mut message = json!({"method": method, "params": params});
            if let Some(session) = session {
                message["sessionId"] = json!(session);
            }
            return message.to_string();
        }
    };
    let mut message = json!({"method": method, "params": params});
    if let Some(session) = session {
        message["sessionId"] = json!(session);
    }
    message.to_string()
}

/// What Chromium answers while a tab opens, and what the driver's own
/// threads get afterwards.
fn scripted(method: &str, session: Option<&str>, events: &mut Vec<String>) -> Value {
    let on = |method: &str, params: Value| {
        let mut message = json!({"method": method, "params": params});
        if let Some(session) = session {
            message["sessionId"] = json!(session);
        }
        message.to_string()
    };
    match method {
        "Target.getTargets" => json!({"targetInfos": []}),
        "Target.createTarget" => {
            events.push(
                json!({"method": "Target.attachedToTarget", "params": {"sessionId": "S1",
                    "targetInfo": {"targetId": "T1", "type": "page", "url": "about:blank", "title": ""},
                    "waitingForDebugger": true}})
                .to_string(),
            );
            json!({"targetId": "T1"})
        }
        "Runtime.enable" => {
            events.push(on(
                "Runtime.executionContextCreated",
                json!({"context": {"id": 10, "name": "", "auxData": {"frameId": "F-T1", "isDefault": true}}}),
            ));
            json!({})
        }
        "Page.addScriptToEvaluateOnNewDocument" => {
            events.push(on(
                "Runtime.executionContextCreated",
                json!({"context": {"id": 20, "name": AGENT_WORLD, "auxData": {"frameId": "F-T1", "isDefault": false}}}),
            ));
            json!({"identifier": "1"})
        }
        "Page.createIsolatedWorld" => json!({"executionContextId": 30}),
        "Runtime.evaluate" => json!({"result": {"type": "boolean", "value": true}}),
        "Page.getFrameTree" => json!({"frameTree": {"frame": {"id": "F-T1", "loaderId": "L0",
            "url": "https://a.test/", "securityOrigin": "https://a.test"}}}),
        _ => json!({}),
    }
}

impl Wire {
    /// The inbound messages for one sent message: events first, then the reply.
    fn respond(&self, message: &Value) -> Vec<String> {
        let id = message["id"].as_u64().unwrap_or(0);
        let method = message["method"].as_str().unwrap_or("");
        let session = message["sessionId"].as_str();
        let mut script = lock(&self.script);
        let fuzzed =
            script.fuzzing == Some(std::thread::current().id()) && FUZZED_METHODS.contains(&method);
        let mut out = Vec::new();
        if fuzzed {
            let Some(step) = script.answers.pop_front() else {
                out.push(
                    json!({"id": id, "error": {"code": -32000, "message": "no answer"}})
                        .to_string(),
                );
                return out;
            };
            for event in &step.events {
                out.push(event_message(session_of(&step.session), event));
            }
            out.push(match &step.answer {
                Answer::Result(text) if serde_json::from_str::<&RawValue>(text).is_ok() => {
                    format!("{{\"id\":{id},\"result\":{text}}}")
                }
                Answer::Result(_) => {
                    json!({"id": id, "error": {"code": -32700, "message": "parse error"}})
                        .to_string()
                }
                Answer::Error { code, message } => {
                    json!({"id": id, "error": {"code": code, "message": message}}).to_string()
                }
            });
            return out;
        }
        let result = scripted(method, session, &mut out);
        out.push(json!({"id": id, "result": result}).to_string());
        out
    }
}

impl CdpWire for WireHandle {
    fn send(&self, message: &str) -> std::io::Result<()> {
        let message: Value = serde_json::from_str(message).map_err(std::io::Error::other)?;
        let inbound = self.0.respond(&message);
        let Some(conn) = self.0.conn.get().and_then(Weak::upgrade) else {
            return Err(std::io::Error::other("the connection is gone"));
        };
        for line in inbound {
            conn.receive(&line);
        }
        Ok(())
    }
}

fn params_of(call: &DriverCall) -> (&'static str, Value, bool) {
    let target = if call.unknown_tab { "T-unknown" } else { "T1" };
    let timeout = u64::from(call.timeout_ms % 64) + 1;
    let mut params = json!({"targetId": target, "timeoutMs": timeout});
    let (method, raw) = match &call.call {
        Call::Evaluate {
            world,
            frame,
            source,
            handles,
            args,
            await_promise,
            closed_roots,
            raw,
        } => {
            params["source"] = json!(source);
            params["world"] = match world {
                Some(WorldName::Agent) => json!("agent"),
                Some(WorldName::Page) => json!("page"),
                Some(WorldName::Host) => json!("host"),
                Some(WorldName::Other(other)) => json!(other),
                None => Value::Null,
            };
            if let Some(frame) = frame {
                params["frameId"] = json!(frame);
            }
            params["handles"] = json!(handles);
            params["args"] = Value::Array(
                args.iter().map(|a| serde_json::from_str(a).unwrap_or_else(|_| json!(a))).collect(),
            );
            if let Some(await_promise) = await_promise {
                params["awaitPromise"] = json!(await_promise);
            }
            params["closedRoots"] = json!(closed_roots);
            ("frame.evaluate", *raw)
        }
        Call::FramesList => ("frames.list", false),
        Call::Focused => ("frame.focused", false),
        Call::ContentFrame { handle, frame } => {
            params["element"] = json!(handle);
            if let Some(frame) = frame {
                params["frameId"] = json!(frame);
            }
            ("frame.contentFrame", false)
        }
        Call::ContentFrames { handles } => {
            params["elements"] = json!(handles);
            ("frame.contentFrames", false)
        }
        Call::OwnerBox { frame } => {
            params["frameId"] = json!(frame);
            ("frame.ownerBox", false)
        }
    };
    (method, params, raw)
}

fuzz_target!(|input: Input| {
    let wire = Arc::new(Wire {
        conn: OnceLock::new(),
        script: Mutex::new(Script { fuzzing: None, answers: input.answers.into() }),
    });
    let conn = CdpConnection::new(Box::new(WireHandle(wire.clone())));
    if wire.conn.set(Arc::downgrade(&conn)).is_err() {
        return;
    }
    let driver = CdpDriver::attach_browser(conn.clone(), AGENT_SOURCE, discard_events())
        .expect("the scripted browser attaches");
    let opened = driver.call("tabs.open", &json!({"timeoutMs": 5000})).expect("the tab opens");
    assert_eq!(opened["targetId"], "T1");
    lock(&wire.script).fuzzing = Some(std::thread::current().id());

    for call in input.calls.iter().take(MAX_CALLS) {
        let (method, params, raw) = params_of(call);
        let deadline = Duration::from_millis(params["timeoutMs"].as_u64().unwrap_or(0));
        let started = Instant::now();
        if raw {
            if let Ok(Reply::Json(text)) = driver.call_reply_announced(method, &params, &mut || {})
            {
                assert!(
                    serde_json::from_str::<Value>(text.get()).is_ok(),
                    "a script value that is not JSON: {}",
                    text.get()
                );
            }
        } else {
            let _ = driver.call(method, &params);
        }
        let took = started.elapsed();
        assert!(took <= deadline + SLACK, "{method} took {took:?} with a {deadline:?} deadline");
    }
    conn.close("the fuzz input ended");
});
