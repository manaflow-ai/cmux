//! CdpDriver against a scripted in-process browser: the CDP each driver
//! method sends, and the driver results and events it derives from replies.

use cmux_browser_host::cdp::{AGENT_WORLD, CdpConnection, CdpDriver, CdpWire};
use cmux_browser_host::driver::Driver;
use cmux_browser_host::protocol::{DriverEvent, ErrorCode};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};
use std::io;
use std::sync::{Arc, Mutex, OnceLock, Weak};

const AGENT_SOURCE: &str = "globalThis.__cmuxPageAgent = { resolveHandle: (id) => null };";
/// A page value in the page's key order, nested objects and arrays included.
const KEY_ORDER: &str = r#"{"title":"cmux","url":"https://example.com/cmux","snippet":"s","nested":{"z":1,"a":[{"y":2,"b":0.1}]}}"#;
const PNG_1X1: &str = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";

#[derive(Default)]
struct FakeTab {
    history: Vec<String>,
    index: usize,
    loaders: u64,
}

#[derive(Default)]
struct Browser {
    next_target: u64,
    tabs: HashMap<String, FakeTab>,
    /// Every message the driver sent, in order.
    sent: Vec<Value>,
    /// When each message in `sent` arrived.
    sent_at: Vec<std::time::Instant>,
    /// Chromium's double report: after the agent world's context (20) a
    /// second context with the same name (21) where the agent script never ran.
    empty_agent_world: bool,
    /// Agent-world contexts that hold the page agent.
    agent_in: HashSet<i64>,
    /// A host fetch's request is held (no reply) until its tab closes.
    hold_fetch: bool,
    /// The held fetch request: (message id, session).
    held: Option<(Value, String)>,
    /// Every new tab's setup fails (`Page.enable` errors).
    fail_setup: bool,
}

struct FakeWire {
    conn: OnceLock<Weak<CdpConnection>>,
    browser: Mutex<Browser>,
}

struct WireHandle(Arc<FakeWire>);

impl CdpWire for WireHandle {
    fn send(&self, message: &str) -> io::Result<()> {
        let message: Value = serde_json::from_str(message).expect("driver sends JSON");
        let (reply, events) = self.0.respond(&message);
        let conn = self.0.conn.get().and_then(Weak::upgrade).expect("connection alive");
        for event in events {
            conn.receive(&event.to_string());
        }
        // A held request gets no reply now; a text reply is sent verbatim.
        match reply {
            Value::Null => {}
            Value::String(text) => conn.receive(&text),
            reply => conn.receive(&reply.to_string()),
        }
        Ok(())
    }
}

fn session_event(session: &str, method: &str, params: Value) -> Value {
    json!({"sessionId": session, "method": method, "params": params})
}

fn target_of(session: &str) -> String {
    session.replacen('S', "T", 1)
}

impl FakeWire {
    fn respond(&self, message: &Value) -> (Value, Vec<Value>) {
        let mut browser = self.browser.lock().unwrap();
        browser.sent.push(message.clone());
        browser.sent_at.push(std::time::Instant::now());
        let id = message["id"].clone();
        let method = message["method"].as_str().unwrap_or("");
        let params = &message["params"];
        let session = message["sessionId"].as_str().unwrap_or("").to_owned();
        let ok = |result: Value| json!({"id": id, "result": result});
        let mut events = Vec::new();
        let result = match method {
            "Target.setDiscoverTargets" | "Target.setAutoAttach" => json!({}),
            "Target.getTargets" => json!({"targetInfos": []}),
            "Target.createTarget" => {
                browser.next_target += 1;
                let n = browser.next_target;
                let target = format!("T{n}");
                let created = params["url"].as_str().unwrap_or("about:blank").to_owned();
                browser.tabs.insert(
                    target.clone(),
                    FakeTab { history: vec!["about:blank".into()], index: 0, loaders: 0 },
                );
                events.push(json!({"method": "Target.attachedToTarget", "params": {
                    "sessionId": format!("S{n}"),
                    "targetInfo": {"targetId": target, "type": "page", "url": created, "title": ""},
                    "waitingForDebugger": true,
                }}));
                json!({"targetId": target})
            }
            "Target.closeTarget" => {
                let target = params["targetId"].as_str().unwrap().to_owned();
                browser.tabs.remove(&target);
                // A request held on the closed tab fails, as Chromium's do.
                if let Some((held, _)) =
                    browser.held.take_if(|(_, on)| *on == target.replacen('T', "S", 1))
                {
                    events.push(
                        json!({"id": held, "error": {"code": -32000, "message": "Target closed"}}),
                    );
                }
                events.push(json!({"method": "Target.detachedFromTarget", "params": {"sessionId": target.replacen('T', "S", 1)}}));
                events.push(
                    json!({"method": "Target.targetDestroyed", "params": {"targetId": target}}),
                );
                json!({"success": true})
            }
            "Page.enable" if browser.fail_setup => {
                return (
                    json!({"id": id, "error": {"code": -32000, "message": "setup failed"}}),
                    events,
                );
            }
            "Page.createIsolatedWorld" => json!({"executionContextId": 30}),
            "Target.activateTarget"
            | "Network.setBypassServiceWorker"
            | "Target.detachFromTarget"
            | "Page.enable"
            | "Page.setLifecycleEventsEnabled"
            | "Page.setInterceptFileChooserDialog"
            | "Browser.setPermission"
            | "Runtime.addBinding"
            | "Emulation.setFocusEmulationEnabled"
            | "Runtime.runIfWaitingForDebugger"
            | "Input.dispatchMouseEvent"
            | "Input.dispatchKeyEvent"
            | "Input.insertText"
            | "Emulation.setDeviceMetricsOverride"
            | "Runtime.releaseObjectGroup"
            | "Fetch.enable"
            | "Fetch.disable"
            | "Fetch.failRequest"
            | "Fetch.continueRequest"
            | "Network.enable"
            | "Network.setBlockedURLs" => json!({}),
            "Page.getFrameTree" => {
                let target = target_of(&session);
                json!({"frameTree": {
                    "frame": {"id": format!("F-{target}"), "loaderId": "L0", "url": "https://a.test/", "securityOrigin": "https://a.test"},
                    "childFrames": [
                        {"frame": {"id": "SAME", "parentId": format!("F-{target}"), "url": "https://a.test/inner", "securityOrigin": "https://a.test", "name": "inner"}},
                        {"frame": {"id": "CROSS", "parentId": format!("F-{target}"), "url": "https://b.test/", "securityOrigin": "https://b.test"},
                         "childFrames": [{"frame": {"id": "DEEP", "parentId": "CROSS", "url": "https://b.test/deep", "securityOrigin": "https://b.test"}}]}
                    ]
                }})
            }
            "Runtime.enable" => {
                let target = target_of(&session);
                events.push(session_event(&session, "Runtime.executionContextCreated", json!({"context": {
                    "id": 10, "name": "", "auxData": {"frameId": format!("F-{target}"), "isDefault": true}}})));
                json!({})
            }
            "Page.addScriptToEvaluateOnNewDocument" => {
                let target = target_of(&session);
                events.push(session_event(&session, "Runtime.executionContextCreated", json!({"context": {
                    "id": 20, "name": AGENT_WORLD, "auxData": {"frameId": format!("F-{target}"), "isDefault": false}}})));
                browser.agent_in.insert(20);
                if browser.empty_agent_world {
                    events.push(session_event(&session, "Runtime.executionContextCreated", json!({"context": {
                        "id": 21, "name": AGENT_WORLD, "auxData": {"frameId": format!("F-{target}"), "isDefault": false}}})));
                }
                json!({"identifier": "1"})
            }
            "Runtime.evaluate" if params["expression"] == AGENT_SOURCE => {
                let context = params["contextId"].as_i64().unwrap_or(0);
                browser.agent_in.insert(context);
                json!({"result": {"type": "undefined"}})
            }
            "Runtime.evaluate"
                if params["expression"].as_str().is_some_and(|e| e.contains("__cmuxPageAgent")) =>
            {
                let context = params["contextId"].as_i64().unwrap_or(0);
                json!({"result": {"type": "boolean", "value": browser.agent_in.contains(&context)}})
            }
            "Page.navigate" => {
                let url = params["url"].as_str().unwrap().to_owned();
                if url.contains("unresolvable") {
                    json!({"frameId": "F", "loaderId": "LX", "errorText": "net::ERR_NAME_NOT_RESOLVED"})
                } else {
                    let target = target_of(&session);
                    let tab = browser.tabs.get_mut(&target).unwrap();
                    // A server redirect that lands on a browser page.
                    let url = if url.contains("redirect-to-browser-page") {
                        "chrome://password-manager/passwords".to_owned()
                    } else {
                        url
                    };
                    tab.history.truncate(tab.index + 1);
                    tab.history.push(url.clone());
                    tab.index = tab.history.len() - 1;
                    let loader = load(tab, &session, &target, &url, &mut events);
                    json!({"frameId": format!("F-{target}"), "loaderId": loader})
                }
            }
            "Page.reload" => {
                let target = target_of(&session);
                let tab = browser.tabs.get_mut(&target).unwrap();
                let url = tab.history[tab.index].clone();
                load(tab, &session, &target, &url, &mut events);
                json!({})
            }
            "Page.getNavigationHistory" => {
                let tab = &browser.tabs[&target_of(&session)];
                let entries: Vec<Value> = tab
                    .history
                    .iter()
                    .enumerate()
                    .map(|(i, url)| json!({"id": i, "url": url}))
                    .collect();
                json!({"currentIndex": tab.index, "entries": entries})
            }
            "Page.navigateToHistoryEntry" => {
                let target = target_of(&session);
                let tab = browser.tabs.get_mut(&target).unwrap();
                tab.index = params["entryId"].as_u64().unwrap() as usize;
                let url = tab.history[tab.index].clone();
                load(tab, &session, &target, &url, &mut events);
                json!({})
            }
            "Page.getLayoutMetrics" => json!({
                "cssLayoutViewport": {"clientWidth": 1280, "clientHeight": 800},
                "layoutViewport": {"clientWidth": 2560, "clientHeight": 1600},
                "cssContentSize": {"width": 1280, "height": 3000},
            }),
            "Page.captureScreenshot" => json!({"data": PNG_1X1}),
            "Page.handleJavaScriptDialog" => {
                events.push(session_event(
                    &session,
                    "Page.javascriptDialogClosed",
                    json!({"result": params["accept"]}),
                ));
                json!({})
            }
            "Runtime.callFunctionOn" => {
                let declaration = params["functionDeclaration"].as_str().unwrap_or("");
                let first = &params["arguments"][0]["value"];
                if declaration.contains("key-order") {
                    // Chromium's text, in the page's key order.
                    let text = format!(
                        r#"{{"id":{id},"result":{{"result":{{"type":"object","value":{KEY_ORDER}}}}}}}"#
                    );
                    return (Value::String(text), events);
                }
                if declaration.contains("cmux-fetch-cancel") {
                    // The host aborts its fetch: the held request rejects.
                    if let Some((held, _)) = browser.held.take() {
                        events.push(json!({"id": held, "result": {"result": {"type": "object"},
                            "exceptionDetails": {"text": "Uncaught", "exception": {"description": "AbortError: aborted"}}}}));
                    }
                    return (
                        json!({"id": id, "result": {"result": {"type": "boolean", "value": true}}}),
                        events,
                    );
                }
                if declaration.contains("__cmuxFetch") && declaration.contains("AbortController") {
                    if browser.hold_fetch {
                        browser.held = Some((id, session));
                        return (Value::Null, events);
                    }
                    json!({"result": {"type": "object", "value": {"id": "b1", "size": 0, "url": first["url"],
                        "status": 200, "statusText": "OK", "redirected": false, "headers": []}}})
                } else if declaration
                    .contains("return a && a.resolveHandle ? a.resolveHandle(id) : null")
                {
                    match first.as_str() {
                        Some("dead") => {
                            json!({"result": {"type": "object", "subtype": "null", "value": null}})
                        }
                        Some(handle) => {
                            json!({"result": {"type": "object", "subtype": "node", "objectId": format!("obj-{handle}")}})
                        }
                        None => json!({"result": {"type": "undefined"}}),
                    }
                } else if declaration.contains("throw-type-error") {
                    json!({"result": {"type": "object"}, "exceptionDetails": {"text": "Uncaught", "exception": {
                        "className": "TypeError", "description": "TypeError: boom\n    at <anonymous>:1:1"}}})
                } else if declaration.contains("alert(") {
                    events.push(session_event(&session, "Page.javascriptDialogOpening", json!({
                        "url": "https://a.test/", "message": "hello", "type": "alert", "hasBrowserHandler": false})));
                    json!({"result": {"type": "undefined"}})
                } else {
                    json!({"result": {"type": "string", "value": "ok"}})
                }
            }
            "DOM.describeNode" => {
                let object = params["objectId"].as_str().unwrap_or("");
                if object == "obj-iframe" {
                    json!({"node": {"backendNodeId": 7, "nodeName": "IFRAME", "frameId": "CHILD"}})
                } else {
                    json!({"node": {"backendNodeId": 42, "nodeName": "BUTTON"}})
                }
            }
            "DOM.resolveNode" => {
                json!({"object": {"type": "object", "objectId": format!("page-{}", params["backendNodeId"])}})
            }
            _ => {
                return (
                    json!({"id": id, "error": {"code": -32601, "message": format!("'{method}' wasn't found")}}),
                    events,
                );
            }
        };
        (ok(result), events)
    }
}

/// Commits a new document and reports its lifecycle.
fn load(
    tab: &mut FakeTab,
    session: &str,
    target: &str,
    url: &str,
    events: &mut Vec<Value>,
) -> String {
    tab.loaders += 1;
    let loader = format!("L{}-{target}", tab.loaders);
    let frame = format!("F-{target}");
    events.push(session_event(
        session,
        "Page.frameNavigated",
        json!({"frame": {"id": frame, "loaderId": loader, "url": url}, "type": "Navigation"}),
    ));
    for name in ["DOMContentLoaded", "load", "networkIdle"] {
        events.push(session_event(
            session,
            "Page.lifecycleEvent",
            json!({"frameId": frame, "loaderId": loader, "name": name, "timestamp": 1}),
        ));
    }
    loader
}

struct Harness {
    driver: CdpDriver,
    wire: Arc<FakeWire>,
    events: Arc<Mutex<Vec<DriverEvent>>>,
    _conn: Arc<CdpConnection>,
}

impl Harness {
    fn new() -> Harness {
        Harness::with_browser(Browser::default())
    }

    fn with_browser(browser: Browser) -> Harness {
        let wire = Arc::new(FakeWire { conn: OnceLock::new(), browser: Mutex::new(browser) });
        let conn = CdpConnection::new(Box::new(WireHandle(wire.clone())));
        wire.conn.set(Arc::downgrade(&conn)).ok().unwrap();
        let events = Arc::new(Mutex::new(Vec::new()));
        let sink = events.clone();
        let driver = CdpDriver::attach_browser(
            conn.clone(),
            AGENT_SOURCE,
            Arc::new(move |e| sink.lock().unwrap().push(e)),
        )
        .expect("attach");
        Harness { driver, wire, events, _conn: conn }
    }

    fn call(&self, method: &str, params: Value) -> Value {
        self.driver.call(method, &params).unwrap_or_else(|e| panic!("{method} failed: {e}"))
    }

    fn open(&self, url: Option<&str>) -> String {
        let mut params = json!({});
        if let Some(url) = url {
            params["url"] = json!(url);
        }
        self.call("tabs.open", params)["targetId"].as_str().unwrap().to_owned()
    }

    /// Messages sent since `mark`, as `(method, params)`.
    fn sent_since(&self, mark: usize) -> Vec<(String, Value)> {
        let browser = self.wire.browser.lock().unwrap();
        browser.sent[mark..]
            .iter()
            .map(|m| (m["method"].as_str().unwrap().to_owned(), m["params"].clone()))
            .collect()
    }

    /// Events arrive on the driver's dispatcher thread: wait until `name` has
    /// been delivered `count` times, then return a snapshot.
    fn events_after(&self, name: &str, count: usize) -> Vec<DriverEvent> {
        for _ in 0..2000 {
            let events = self.events.lock().unwrap().clone();
            if events.iter().filter(|e| e.name == name).count() >= count {
                return events;
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        panic!("{name} was not delivered {count} time(s)");
    }

    fn mark(&self) -> usize {
        self.wire.browser.lock().unwrap().sent.len()
    }

    fn methods_since(&self, mark: usize) -> Vec<String> {
        self.sent_since(mark).into_iter().map(|(m, _)| m).collect()
    }
}

#[test]
fn new_tabs_get_domains_and_the_agent_world_before_they_run() {
    let h = Harness::new();
    let mark = h.mark();
    let target = h.open(None);
    assert_eq!(target, "T1");
    let methods = h.methods_since(mark);
    let pos = |name: &str| {
        methods
            .iter()
            .position(|m| m == name)
            .unwrap_or_else(|| panic!("{name} not sent: {methods:?}"))
    };
    assert!(pos("Page.enable") < pos("Runtime.runIfWaitingForDebugger"));
    assert!(pos("Page.addScriptToEvaluateOnNewDocument") < pos("Runtime.runIfWaitingForDebugger"));
    assert!(pos("Emulation.setFocusEmulationEnabled") < pos("Runtime.runIfWaitingForDebugger"));
    let script = h
        .sent_since(mark)
        .into_iter()
        .find(|(m, _)| m == "Page.addScriptToEvaluateOnNewDocument")
        .unwrap()
        .1;
    assert_eq!(script["worldName"], AGENT_WORLD);
    assert_eq!(script["source"], AGENT_SOURCE);
    assert_eq!(script["runImmediately"], true);
}

#[test]
fn open_with_url_navigates_and_info_reports_the_document() {
    let h = Harness::new();
    let target = h.open(Some("https://a.test/start"));
    let tabs = h.call("tabs.list", json!({}));
    assert_eq!(tabs.as_array().unwrap().len(), 1);
    assert_eq!(tabs[0]["targetId"], target.as_str());
    assert_eq!(tabs[0]["active"], true);

    let result = h.call(
        "tab.navigate",
        json!({"targetId": target, "url": "https://a.test/next", "waitUntil": "load"}),
    );
    assert_eq!(result["url"], "https://a.test/next");
    let info = h.call("tab.info", json!({"targetId": target}));
    assert_eq!(info["url"], "https://a.test/next");
    assert_eq!(info["loadState"], "load");
    assert_eq!(info["viewport"], json!({"width": 1280.0, "height": 800.0}));
    assert_eq!(info["deviceScaleFactor"], 2.0);

    let names: Vec<String> =
        h.events_after("tab.loadState", 1).iter().map(|e| e.name.clone()).collect();
    assert!(names.contains(&"tab.navigated".to_string()));
    assert!(names.contains(&"tab.loadState".to_string()));
    assert!(!names.contains(&"tab.created".to_string()), "tabs.open is not a popup");
}

#[test]
fn navigation_errors_are_invalid_with_the_network_error() {
    let h = Harness::new();
    let target = h.open(None);
    let error = h
        .driver
        .call("tab.navigate", &json!({"targetId": target, "url": "https://unresolvable.test/"}))
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Invalid);
    assert_eq!(error.message, "net::ERR_NAME_NOT_RESOLVED at https://unresolvable.test/");
}

#[test]
fn history_skips_the_blank_start_page() {
    let h = Harness::new();
    let target = h.open(None);
    h.call("tab.navigate", json!({"targetId": target, "url": "https://a.test/1"}));
    h.call("tab.navigate", json!({"targetId": target, "url": "https://a.test/2"}));
    let back = h.call("tab.history", json!({"targetId": target, "delta": -1}));
    assert_eq!(back["url"], "https://a.test/1");
    assert_eq!(h.call("tab.history", json!({"targetId": target, "delta": -1})), Value::Null);
    let forward = h.call("tab.history", json!({"targetId": target, "delta": 1}));
    assert_eq!(forward["url"], "https://a.test/2");
    assert_eq!(h.call("tab.history", json!({"targetId": target, "delta": 1})), Value::Null);
    h.call("tab.reload", json!({"targetId": target, "waitUntil": "domcontentloaded"}));
}

#[test]
fn agent_world_evaluation_uses_the_agent_context() {
    let h = Harness::new();
    let target = h.open(None);
    let mark = h.mark();
    let value = h.call(
        "frame.evaluate",
        json!({"targetId": target, "world": "agent", "source": "() => 1", "args": [1, "x"]}),
    );
    assert_eq!(value, "ok");
    let sent = h.sent_since(mark);
    let (_, call) = sent.iter().find(|(m, _)| m == "Runtime.callFunctionOn").unwrap();
    assert_eq!(call["executionContextId"], 20);
    assert_eq!(call["functionDeclaration"], "() => 1");
    assert_eq!(call["arguments"], json!([{"value": 1}, {"value": "x"}]));
    assert_eq!(call["returnByValue"], true);
    assert_eq!(call["awaitPromise"], true);
}

#[test]
fn agent_calls_install_the_agent_in_an_agent_world_context_that_lacks_it() {
    let h = Harness::with_browser(Browser { empty_agent_world: true, ..Browser::default() });
    let target = h.open(None);
    let mark = h.mark();
    h.call("frame.evaluate", json!({"targetId": target, "world": "agent", "source": "() => 1"}));
    let sent = h.sent_since(mark);
    let installed =
        sent.iter().position(|(m, p)| m == "Runtime.evaluate" && p["expression"] == AGENT_SOURCE);
    let called = sent.iter().position(|(m, _)| m == "Runtime.callFunctionOn").unwrap();
    assert!(
        installed.is_some_and(|i| i < called),
        "the agent goes into context 21 first: {sent:?}"
    );
    assert_eq!(sent[installed.unwrap()].1["contextId"], 21);
    assert_eq!(sent[called].1["executionContextId"], 21);
    // The context is checked once.
    let mark = h.mark();
    h.call("frame.evaluate", json!({"targetId": target, "world": "agent", "source": "() => 2"}));
    assert_eq!(h.methods_since(mark).iter().filter(|m| *m == "Runtime.evaluate").count(), 0);
}

#[test]
fn agent_handles_resolve_inside_the_agent_world() {
    let h = Harness::new();
    let target = h.open(None);
    let mark = h.mark();
    h.call(
        "frame.evaluate",
        json!({"targetId": target, "source": "(el, n) => n", "handles": ["h1"], "args": [3]}),
    );
    let sent = h.sent_since(mark);
    let (_, call) = sent.iter().find(|(m, _)| m == "Runtime.callFunctionOn").unwrap();
    let declaration = call["functionDeclaration"].as_str().unwrap();
    assert!(declaration.contains("resolveHandle(h)"), "{declaration}");
    assert!(declaration.contains("((el, n) => n)(...els, ...args)"), "{declaration}");
    assert_eq!(call["arguments"], json!([{"value": ["h1"]}, {"value": 3}]));
}

#[test]
fn page_world_handles_move_through_backend_nodes() {
    let h = Harness::new();
    let target = h.open(None);
    // The first agent call checks the agent world once; keep that out of
    // the sequence below.
    h.call("frame.evaluate", json!({"targetId": target, "world": "agent", "source": "() => 0"}));
    let mark = h.mark();
    h.call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "(el) => el.id", "handles": ["h7"]}),
    );
    let sent = h.sent_since(mark);
    let methods: Vec<&str> = sent.iter().map(|(m, _)| m.as_str()).collect();
    assert_eq!(
        methods,
        vec![
            "Runtime.callFunctionOn",
            "DOM.describeNode",
            "DOM.resolveNode",
            "Runtime.callFunctionOn",
            "Runtime.releaseObjectGroup"
        ]
    );
    assert_eq!(sent[0].1["executionContextId"], 20, "handles resolve in the agent world");
    assert_eq!(sent[0].1["returnByValue"], false);
    assert_eq!(sent[1].1["objectId"], "obj-h7");
    let group = sent[0].1["objectGroup"].clone();
    assert_eq!(
        sent[2].1,
        json!({"backendNodeId": 42, "executionContextId": 10, "objectGroup": group})
    );
    assert_eq!(sent[3].1["executionContextId"], 10);
    assert_eq!(sent[3].1["arguments"], json!([{"objectId": "page-42"}]));
    assert_eq!(sent[4].1["objectGroup"], group, "the call releases its own group");
    // Frames in one process share a session: a call that released a shared
    // group killed a concurrent call's objects (parity 31 lost a frame), so
    // every call has a group of its own.
    let mark = h.mark();
    h.call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "(el) => el.id", "handles": ["h7"]}),
    );
    let again = h.sent_since(mark);
    assert_ne!(again[0].1["objectGroup"], group, "each call has its own object group");
    assert_eq!(again[4].1["objectGroup"], again[0].1["objectGroup"]);
}

#[test]
fn dead_handles_and_exceptions_map_to_protocol_errors() {
    let h = Harness::new();
    let target = h.open(None);
    let stale = h
        .driver
        .call("frame.evaluate", &json!({"targetId": target, "world": "page", "source": "(e) => e", "handles": ["dead"]}))
        .unwrap_err();
    assert_eq!(stale.code, ErrorCode::Stale);
    let thrown = h
        .driver
        .call(
            "frame.evaluate",
            &json!({"targetId": target, "source": "() => { 'throw-type-error' }"}),
        )
        .unwrap_err();
    assert_eq!(thrown.code, ErrorCode::Evaluation);
    assert_eq!(thrown.message, "boom");
    assert_eq!(thrown.error_name.as_deref(), Some("TypeError"));
    let bad_world = h
        .driver
        .call("frame.evaluate", &json!({"targetId": target, "world": "x", "source": "() => 1"}))
        .unwrap_err();
    assert_eq!(bad_world.code, ErrorCode::Invalid);
}

#[test]
fn frames_list_is_breadth_first_with_cross_origin_flags() {
    let h = Harness::new();
    let target = h.open(None);
    let frames = h.call("frames.list", json!({"targetId": target}));
    let ids: Vec<&str> =
        frames.as_array().unwrap().iter().map(|f| f["frameId"].as_str().unwrap()).collect();
    assert_eq!(ids, vec!["F-T1", "SAME", "CROSS", "DEEP"]);
    assert_eq!(frames[0]["parentFrameId"], Value::Null);
    assert_eq!(frames[1]["crossOrigin"], false);
    assert_eq!(frames[1]["name"], "inner");
    assert_eq!(frames[2]["crossOrigin"], true);
    assert_eq!(frames[3]["parentFrameId"], "CROSS");
}

#[test]
fn content_frames_answer_per_handle() {
    let h = Harness::new();
    let target = h.open(None);
    let frames = h.call(
        "frame.contentFrames",
        json!({"targetId": target, "elements": ["iframe", "button", "dead"]}),
    );
    assert_eq!(frames, json!([{"frameId": "CHILD"}, null, null]));
}

#[test]
fn mouse_clicks_track_pressed_buttons_and_modifiers() {
    let h = Harness::new();
    let target = h.open(None);
    let mark = h.mark();
    h.call("input.mouse", json!({"targetId": target, "type": "move", "x": 10, "y": 20}));
    h.call("input.mouse", json!({"targetId": target, "type": "down", "x": 10, "y": 20, "button": "left", "clickCount": 2, "modifiers": ["Shift"]}));
    h.call("input.mouse", json!({"targetId": target, "type": "move", "x": 15, "y": 25}));
    h.call("input.mouse", json!({"targetId": target, "type": "up", "x": 15, "y": 25, "button": "left", "clickCount": 2}));
    h.call("input.mouse", json!({"targetId": target, "type": "wheel", "deltaY": 120}));
    // Input events only (a release also makes one renderer round trip).
    let events: Vec<Value> = h
        .sent_since(mark)
        .into_iter()
        .filter(|(m, _)| m.starts_with("Input."))
        .map(|(_, p)| p)
        .collect();
    assert_eq!(events[0]["type"], "mouseMoved");
    assert_eq!(events[0]["button"], "none");
    assert_eq!(events[1]["type"], "mousePressed");
    assert_eq!(events[1]["buttons"], 1);
    assert_eq!(events[1]["clickCount"], 2);
    assert_eq!(events[1]["modifiers"], 8);
    assert_eq!(events[2]["button"], "left", "a drag moves with the button held");
    assert_eq!(events[3]["type"], "mouseReleased");
    assert_eq!(events[3]["buttons"], 0);
    assert_eq!(events[4]["type"], "mouseWheel");
    assert_eq!((events[4]["x"].as_f64(), events[4]["y"].as_f64()), (Some(15.0), Some(25.0)));
    assert_eq!(events[4]["deltaY"], 120.0);
}

#[test]
fn keys_carry_virtual_codes_and_text_only_when_they_insert_text() {
    let h = Harness::new();
    let target = h.open(None);
    let mark = h.mark();
    h.call(
        "input.key",
        json!({"targetId": target, "type": "down", "key": "Enter", "code": "Enter"}),
    );
    h.call(
        "input.key",
        json!({"targetId": target, "type": "down", "key": "ArrowLeft", "code": "ArrowLeft"}),
    );
    h.call(
        "input.key",
        json!({"targetId": target, "type": "down", "key": "a", "code": "KeyA", "text": "a"}),
    );
    h.call("input.key", json!({"targetId": target, "type": "up", "key": "a", "code": "KeyA"}));
    h.call("input.insertText", json!({"targetId": target, "text": "héllo"}));
    // Input events only (Enter also makes one renderer round trip).
    let sent: Vec<Value> = h
        .sent_since(mark)
        .into_iter()
        .filter(|(m, _)| m.starts_with("Input."))
        .map(|(_, p)| p)
        .collect();
    assert_eq!(sent[0]["type"], "keyDown");
    assert_eq!(sent[0]["text"], "\r");
    assert_eq!(sent[0]["windowsVirtualKeyCode"], 13);
    assert_eq!(sent[1]["type"], "rawKeyDown");
    assert_eq!(sent[1]["windowsVirtualKeyCode"], 37);
    assert_eq!(sent[2]["text"], "a");
    assert_eq!(sent[2]["windowsVirtualKeyCode"], 65);
    assert_eq!(sent[3]["type"], "keyUp");
    assert_eq!(sent[4], json!({"text": "héllo"}));
}

#[test]
fn screenshots_report_png_dimensions() {
    let h = Harness::new();
    let target = h.open(None);
    let shot = h.call("tab.screenshot", json!({"targetId": target}));
    assert_eq!(shot["base64"], PNG_1X1);
    assert_eq!((shot["width"].as_f64(), shot["height"].as_f64()), (Some(1.0), Some(1.0)));
    let mark = h.mark();
    h.call(
        "tab.screenshot",
        json!({"targetId": target, "fullPage": true, "format": "jpeg", "quality": 70}),
    );
    let sent = h.sent_since(mark);
    let capture = &sent.iter().find(|(m, _)| m == "Page.captureScreenshot").unwrap().1;
    assert_eq!(capture["clip"]["height"], 3000.0);
    assert_eq!(capture["captureBeyondViewport"], true);
    assert_eq!(capture["quality"], 70);
}

#[test]
fn dialogs_are_reported_and_answered() {
    let h = Harness::new();
    let target = h.open(None);
    h.call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => alert('hello')"}),
    );
    let opened = h
        .events_after("dialog.opened", 1)
        .iter()
        .find(|e| e.name == "dialog.opened")
        .cloned()
        .expect("dialog.opened");
    assert_eq!(opened.payload["message"], "hello");
    assert_eq!(opened.payload["targetId"], target.as_str());
    let dialog_id = opened.payload["dialogId"].as_str().unwrap().to_owned();
    let mark = h.mark();
    h.call("dialog.respond", json!({"targetId": target, "dialogId": dialog_id, "accept": true}));
    assert_eq!(
        h.sent_since(mark)[0],
        ("Page.handleJavaScriptDialog".to_string(), json!({"accept": true}))
    );
    let again = h
        .driver
        .call("dialog.respond", &json!({"targetId": target, "dialogId": dialog_id, "accept": true}))
        .unwrap_err();
    assert_eq!(again.code, ErrorCode::NotFound);
}

#[test]
fn closing_a_tab_removes_it_and_reports_tab_closed() {
    let h = Harness::new();
    let first = h.open(None);
    let second = h.open(None);
    h.call("tabs.close", json!({"targetId": first}));
    let tabs = h.call("tabs.list", json!({}));
    assert_eq!(tabs.as_array().unwrap().len(), 1);
    assert_eq!(tabs[0]["targetId"], second.as_str());
    let closed: Vec<Value> = h
        .events_after("tab.closed", 1)
        .iter()
        .filter(|e| e.name == "tab.closed")
        .map(|e| e.payload.clone())
        .collect();
    assert_eq!(closed, vec![json!({"targetId": first})]);
    let gone = h.driver.call("tab.info", &json!({"targetId": first})).unwrap_err();
    assert_eq!(gone.code, ErrorCode::NotFound);
}

#[test]
fn unknown_methods_and_browser_level_raw_cdp_are_refused() {
    let h = Harness::new();
    let target = h.open(None);
    assert_eq!(
        h.driver.call("no.such.method", &json!({"targetId": target})).unwrap_err().code,
        ErrorCode::Unsupported
    );
    let raw = h
        .driver
        .call("cdp", &json!({"targetId": target, "method": "Target.closeTarget", "params": {}}))
        .unwrap_err();
    assert_eq!(raw.code, ErrorCode::Forbidden);
    assert_eq!(h.driver.capabilities(), vec!["cdp"]);
}

#[test]
fn a_request_filter_intercepts_and_decides_every_request() {
    let h = Harness::new();
    let target = h.open(None);
    // The filter sees the tab each request belongs to.
    let seen = Arc::new(Mutex::new(Vec::<(String, String)>::new()));
    let record = seen.clone();
    let filter: cmux_browser_host::driver::RequestFilter = Arc::new(move |request| {
        let (target, url) = (request.target, request.url);
        record.lock().unwrap().push((target.to_owned(), url.to_owned()));
        url.contains("evil.test").then(|| "not in session.allowedDomains (example.com)".to_owned())
    });
    let mark = h.mark();
    assert!(h.driver.set_request_filter(Some(filter)));
    let enabled = h.sent_since(mark);
    assert!(
        enabled.iter().any(|(m, p)| m == "Fetch.enable" && p["patterns"][0]["urlPattern"] == "*"),
        "{enabled:?}"
    );
    let session = format!("S{}", &target[1..]);
    let mark = h.mark();
    for (id, url) in [("r1", "https://evil.test/beacon"), ("r2", "https://example.com/app.js")] {
        h._conn.receive(&json!({"sessionId": session, "method": "Fetch.requestPaused", "params": {"requestId": id, "request": {"url": url}, "resourceType": "Script"}}).to_string());
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let sent = h.sent_since(mark);
        if sent.len() >= 2 {
            let seen = seen.lock().unwrap().clone();
            assert!(seen.iter().all(|(t, _)| t == &target), "requests name their tab: {seen:?}");
            assert!(
                sent.contains(&(
                    "Fetch.failRequest".to_string(),
                    json!({"requestId": "r1", "errorReason": "BlockedByClient"})
                )),
                "{sent:?}"
            );
            assert!(
                sent.contains(&("Fetch.continueRequest".to_string(), json!({"requestId": "r2"}))),
                "{sent:?}"
            );
            break;
        }
        assert!(std::time::Instant::now() < deadline, "no decisions sent: {sent:?}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    // New tabs get interception before they run.
    let mark = h.mark();
    h.open(None);
    assert!(h.methods_since(mark).iter().any(|m| m == "Fetch.enable"));
    let mark = h.mark();
    assert!(h.driver.set_request_filter(None));
    let disabled = h.sent_since(mark);
    assert!(disabled.iter().any(|(m, _)| m == "Fetch.disable"));
    assert!(disabled.iter().any(|(m, p)| m == "Network.setBlockedURLs" && p["urls"] == json!([])));
}

#[test]
fn workers_and_prerenders_are_intercepted_before_they_run() {
    let h = Harness::new();
    h.open(None);
    let filter: cmux_browser_host::driver::RequestFilter = Arc::new(|_| None);
    assert!(h.driver.set_request_filter(Some(filter)));
    let mark = h.mark();
    for (session, kind, subtype) in [("W1", "worker", ""), ("P1", "page", "prerender")] {
        h._conn.receive(&json!({"sessionId": "S1", "method": "Target.attachedToTarget", "params": {
            "sessionId": session,
            "targetInfo": {"targetId": format!("{session}-target"), "type": kind, "subtype": subtype, "url": "https://a.test/"},
            "waitingForDebugger": true,
        }}).to_string());
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let browser = h.wire.browser.lock().unwrap();
        let sent: Vec<(String, String)> = browser.sent[mark..]
            .iter()
            .map(|m| {
                (
                    m["sessionId"].as_str().unwrap_or("").to_owned(),
                    m["method"].as_str().unwrap().to_owned(),
                )
            })
            .collect();
        drop(browser);
        let order = |session: &str| -> Vec<String> {
            sent.iter().filter(|(s, _)| s == session).map(|(_, m)| m.clone()).collect()
        };
        if order("W1").len() >= 4 && order("P1").len() >= 4 {
            for session in ["W1", "P1"] {
                let steps = order(session);
                assert_eq!(
                    steps.first().map(String::as_str),
                    Some("Fetch.enable"),
                    "{session}: {steps:?}"
                );
                assert_eq!(
                    steps.last().map(String::as_str),
                    Some("Runtime.runIfWaitingForDebugger"),
                    "{session}: {steps:?}"
                );
            }
            break;
        }
        assert!(std::time::Instant::now() < deadline, "{sent:?}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

/// Browser pages (chrome://, chrome-extension://, chrome-untrusted://,
/// devtools://) hold saved passwords and settings; the relay never lets an
/// agent open one, run script in one, or read one (P0, 2026-10-03).
fn privileged_tab(h: &Harness) -> String {
    let target = h.open(Some("https://a.test/"));
    // The user (or an earlier step) left the tab on the password manager.
    let session = target.replacen('T', "S", 1);
    let event = session_event(
        &session,
        "Page.frameNavigated",
        json!({"frame": {"id": format!("F-{target}"), "loaderId": "LP", "url": "chrome://password-manager/passwords"}, "type": "Navigation"}),
    );
    h._conn.receive(&event.to_string());
    for _ in 0..2000 {
        if h.call("tab.info", json!({"targetId": target}))["url"]
            == "chrome://password-manager/passwords"
        {
            return target;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    panic!("the tab did not report the browser page");
}

#[test]
fn agents_cannot_navigate_or_open_tabs_to_browser_pages() {
    let h = Harness::new();
    let target = h.open(Some("https://a.test/"));
    for url in [
        "chrome://password-manager/passwords",
        "CHROME://settings",
        "chrome-extension://abc/options.html",
        "chrome-untrusted://print/",
        "devtools://devtools/bundled/inspector.html",
    ] {
        let mark = h.mark();
        let error =
            h.driver.call("tab.navigate", &json!({"targetId": target, "url": url})).unwrap_err();
        assert_eq!(error.code, ErrorCode::Forbidden, "{url}");
        let error = h.driver.call("tabs.open", &json!({"url": url})).unwrap_err();
        assert_eq!(error.code, ErrorCode::Forbidden, "{url}");
        let sent = h.methods_since(mark);
        assert!(
            !sent.iter().any(|m| m == "Page.navigate" || m == "Target.createTarget"),
            "{url}: {sent:?}"
        );
    }
}

#[test]
fn agents_cannot_run_script_in_or_read_a_browser_page() {
    let h = Harness::new();
    let target = privileged_tab(&h);
    let mark = h.mark();
    for (method, params) in [
        (
            "frame.evaluate",
            json!({"targetId": target, "world": "page", "source": "() => 1", "args": []}),
        ),
        (
            "frame.evaluate",
            json!({"targetId": target, "world": "agent", "source": "() => 1", "args": []}),
        ),
        (
            "cdp",
            json!({"targetId": target, "method": "Runtime.evaluate", "params": {"expression": "1"}}),
        ),
        (
            "cdp",
            json!({"targetId": target, "method": "Runtime.callFunctionOn", "params": {"functionDeclaration": "() => 1"}}),
        ),
        ("cdp", json!({"targetId": target, "method": "DOM.getDocument", "params": {}})),
        ("frames.list", json!({"targetId": target})),
        ("input.insertText", json!({"targetId": target, "text": "x"})),
        ("tab.screenshot", json!({"targetId": target})),
    ] {
        let error = h.driver.call(method, &params).unwrap_err();
        assert_eq!(error.code, ErrorCode::Forbidden, "{method} {params}");
    }
    let sent = h.methods_since(mark);
    assert!(
        !sent.iter().any(|m| m.starts_with("Runtime.")
            || m.starts_with("DOM.")
            || m.starts_with("Input.")
            || m == "Page.captureScreenshot"),
        "{sent:?}"
    );
    // Leaving the page stays possible.
    h.call("tab.navigate", json!({"targetId": target, "url": "https://b.test/"}));
    assert_eq!(
        h.call(
            "frame.evaluate",
            json!({"targetId": target, "world": "agent", "source": "() => 1", "args": []})
        ),
        "ok"
    );
}

#[test]
fn history_never_returns_an_agent_to_a_browser_page() {
    let h = Harness::new();
    let target = h.open(Some("https://a.test/"));
    {
        let mut browser = h.wire.browser.lock().unwrap();
        let tab = browser.tabs.get_mut(&target).unwrap();
        tab.history = vec![
            "https://a.test/".into(),
            "chrome://password-manager/passwords".into(),
            "https://b.test/".into(),
        ];
        tab.index = 2;
    }
    let mark = h.mark();
    let error =
        h.driver.call("tab.history", &json!({"targetId": target, "delta": -1})).unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    assert!(!h.methods_since(mark).iter().any(|m| m == "Page.navigateToHistoryEntry"));
}

#[test]
fn a_redirect_onto_a_browser_page_is_left_and_refused() {
    let h = Harness::new();
    let target = h.open(Some("https://a.test/"));
    let mark = h.mark();
    let error = h
        .driver
        .call(
            "tab.navigate",
            &json!({"targetId": target, "url": "https://a.test/redirect-to-browser-page"}),
        )
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    let leave = h
        .sent_since(mark)
        .into_iter()
        .filter(|(m, _)| m == "Page.navigate")
        .map(|(_, p)| p["url"].as_str().unwrap_or("").to_owned())
        .collect::<Vec<_>>();
    assert_eq!(leave.last().map(String::as_str), Some("about:blank"), "{leave:?}");
    assert_eq!(h.call("tab.info", json!({"targetId": target}))["url"], "about:blank");
}

#[test]
fn the_relay_detaches_from_browser_page_targets() {
    let h = Harness::new();
    h.open(Some("https://a.test/"));
    let mark = h.mark();
    let attached = json!({"method": "Target.attachedToTarget", "params": {
        "sessionId": "SPM",
        "targetInfo": {"targetId": "TPM", "type": "page", "url": "chrome://password-manager/passwords", "title": ""},
        "waitingForDebugger": true,
    }});
    h._conn.receive(&attached.to_string());
    for _ in 0..2000 {
        if h.methods_since(mark).iter().any(|m| m == "Target.detachFromTarget") {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    let sent = h.sent_since(mark);
    let detach = sent.iter().find(|(m, _)| m == "Target.detachFromTarget");
    assert_eq!(detach.map(|(_, p)| p["sessionId"].clone()), Some(json!("SPM")), "{sent:?}");
    assert!(
        !sent
            .iter()
            .any(|(m, _)| m == "Page.addScriptToEvaluateOnNewDocument" || m == "Runtime.enable"),
        "{sent:?}"
    );
    let tabs = h.call("tabs.list", json!({}));
    assert!(!tabs.to_string().contains("TPM"), "{tabs}");
}

fn receive(h: &Harness, event: Value) {
    h._conn.receive(&event.to_string());
}

fn wait_until(mut done: impl FnMut() -> bool, what: &str) {
    for _ in 0..2000 {
        if done() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(1));
    }
    panic!("{what}");
}

#[test]
fn a_pending_url_does_not_unlock_a_committed_browser_page() {
    let h = Harness::new();
    let target = privileged_tab(&h);
    // A slow navigation away is still pending: Chromium reports its URL in
    // targetInfoChanged before anything commits.
    receive(
        &h,
        json!({"method": "Target.targetInfoChanged", "params": {"targetInfo": {
        "targetId": target, "type": "page", "url": "https://b.test/slow", "title": "Password Manager"}}}),
    );
    wait_until(
        || h.call("tabs.list", json!({})).to_string().contains("https://b.test/slow"),
        "targetInfoChanged was not applied",
    );
    for (method, params) in [
        (
            "frame.evaluate",
            json!({"targetId": target, "world": "page", "source": "() => 1", "args": []}),
        ),
        (
            "cdp",
            json!({"targetId": target, "method": "Runtime.evaluate", "params": {"expression": "1"}}),
        ),
        ("tab.reload", json!({"targetId": target})),
    ] {
        let error = h.driver.call(method, &params).unwrap_err();
        assert_eq!(error.code, ErrorCode::Forbidden, "{method}");
    }
}

#[test]
fn frames_that_show_browser_pages_are_refused_and_released() {
    let h = Harness::new();
    let target = h.open(Some("https://a.test/"));
    let session = target.replacen('T', "S", 1);
    // An in-process child frame commits an extension page.
    receive(
        &h,
        session_event(
            &session,
            "Page.frameNavigated",
            json!({"frame": {
        "id": "XF", "parentId": format!("F-{target}"), "loaderId": "LX", "url": "chrome-extension://abc/menu.html"}, "type": "Navigation"}),
        ),
    );
    wait_until(
        || {
            h.events
                .lock()
                .unwrap()
                .iter()
                .any(|e| e.payload.to_string().contains("chrome-extension://abc/menu.html"))
        },
        "the frame navigation was not applied",
    );
    let error = h
        .driver
        .call("frame.evaluate", &json!({"targetId": target, "frameId": "XF", "world": "page", "source": "() => 1", "args": []}))
        .unwrap_err();
    assert_eq!(error.code, ErrorCode::Forbidden);
    // The page itself stays usable.
    assert_eq!(
        h.call(
            "frame.evaluate",
            json!({"targetId": target, "world": "agent", "source": "() => 1", "args": []})
        ),
        "ok"
    );

    // An out-of-process child frame attached at a web URL, then committed an
    // extension page: the relay detaches it through its parent session.
    receive(
        &h,
        json!({"sessionId": session, "method": "Target.attachedToTarget", "params": {
        "sessionId": "CX", "targetInfo": {"targetId": "OOP", "type": "iframe", "url": "https://x.test/"}, "waitingForDebugger": true}}),
    );
    let mark = h.mark();
    receive(
        &h,
        session_event(
            "CX",
            "Page.frameNavigated",
            json!({"frame": {
        "id": "OOP", "parentId": format!("F-{target}"), "loaderId": "LO", "url": "chrome-extension://abc/menu.html"}, "type": "Navigation"}),
        ),
    );
    wait_until(
        || h.methods_since(mark).iter().any(|m| m == "Target.detachFromTarget"),
        "the extension frame was not detached",
    );
    let browser = h.wire.browser.lock().unwrap();
    let detach =
        browser.sent[mark..].iter().find(|m| m["method"] == "Target.detachFromTarget").unwrap();
    assert_eq!(detach["params"]["sessionId"], "CX");
    assert_eq!(
        detach["sessionId"],
        json!(session),
        "a child session is detached through its parent"
    );
}

/// New headless takes its window chrome out of --window-size (1280x661),
/// so every headless tab gets the protocol's 1280x800 viewport before it
/// runs, and a viewport reset returns to it (parity 14).
#[test]
fn headless_tabs_get_the_hidden_tab_viewport() {
    let h = Harness::new();
    let mark = h.mark();
    let target = h.open(None);
    let sent = h.sent_since(mark);
    let pos = |name: &str| sent.iter().position(|(m, _)| m == name);
    let metrics = pos("Emulation.setDeviceMetricsOverride").expect("a viewport override");
    assert!(metrics < pos("Runtime.runIfWaitingForDebugger").unwrap());
    assert_eq!(sent[metrics].1["width"], 1280);
    assert_eq!(sent[metrics].1["height"], 800);
    let mark = h.mark();
    h.call("tab.setViewport", json!({"targetId": target, "reset": true}));
    let sent = h.sent_since(mark);
    assert!(
        sent.iter().any(|(m, p)| m == "Emulation.setDeviceMetricsOverride" && p["height"] == 800),
        "a reset returns to the hidden-tab size: {sent:?}"
    );
    assert!(!sent.iter().any(|(m, _)| m == "Emulation.clearDeviceMetricsOverride"));
}

/// RequestKind (5c): a main-frame document is Document, an iframe's document
/// SubframeDocument, everything else Subresource.
#[test]
fn request_kinds_tell_main_frame_documents_from_iframes() {
    use cmux_browser_host::driver::RequestKind;
    let h = Harness::new();
    let target = h.open(None);
    let seen = Arc::new(Mutex::new(Vec::<RequestKind>::new()));
    let record = seen.clone();
    let filter: cmux_browser_host::driver::RequestFilter = Arc::new(move |request| {
        record.lock().unwrap().push(request.kind);
        None
    });
    assert!(h.driver.set_request_filter(Some(filter)));
    let session = format!("S{}", &target[1..]);
    let main = format!("F-{target}");
    for (id, frame, kind) in [
        ("r1", main.as_str(), "Document"),
        ("r2", "CROSS", "Document"),
        ("r3", main.as_str(), "Script"),
    ] {
        h._conn.receive(&json!({"sessionId": session, "method": "Fetch.requestPaused", "params": {
            "requestId": id, "frameId": frame, "request": {"url": "https://a.test/x", "method": "GET", "headers": {}},
            "resourceType": kind}}).to_string());
    }
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while seen.lock().unwrap().len() < 3 {
        assert!(std::time::Instant::now() < deadline, "the filter saw {:?}", seen.lock().unwrap());
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert_eq!(
        *seen.lock().unwrap(),
        vec![RequestKind::Document, RequestKind::SubframeDocument, RequestKind::Subresource]
    );
}

/// The sent messages since `mark` with their sessions: (method, session, params).
fn sent_with_sessions(h: &Harness, mark: usize) -> Vec<(String, String, Value)> {
    let browser = h.wire.browser.lock().unwrap();
    browser.sent[mark..]
        .iter()
        .map(|m| {
            let session = m["sessionId"].as_str().unwrap_or("").to_owned();
            (m["method"].as_str().unwrap().to_owned(), session, m["params"].clone())
        })
        .collect()
}

/// a9 shell-tab condition (b): the shell tab of a tab-less fetch bypasses
/// service workers before its navigation (a worker could answer the shell
/// document or the fetch); (d) it closes after a fetch that succeeded.
#[test]
fn the_fetch_shell_bypasses_service_workers_before_it_navigates() {
    let h = Harness::new();
    let mark = h.mark();
    let out = h.call("net.fetch", json!({"url": "https://a.test/data", "timeoutMs": 2000}));
    assert_eq!(out["status"], 200, "{out}");
    let sent = sent_with_sessions(&h, mark);
    let bypass = sent
        .iter()
        .position(|(m, on, p)| {
            m == "Network.setBypassServiceWorker" && on == "S1" && p["bypass"] == true
        })
        .unwrap_or_else(|| panic!("no service worker bypass on the shell: {sent:?}"));
    let navigate = sent
        .iter()
        .position(|(m, on, _)| m == "Page.navigate" && on == "S1")
        .unwrap_or_else(|| panic!("the shell never navigated: {sent:?}"));
    assert!(bypass < navigate, "the bypass comes before the navigation: {sent:?}");
    assert!(
        sent.iter().any(|(m, _, p)| m == "Target.closeTarget" && p["targetId"] == "T1"),
        "the shell closes after the fetch: {sent:?}"
    );
}

/// a9 shell-tab conditions (c, d): the shell is hidden from the session (not
/// listed, no events, no page agent, every call refused) and closes when
/// the session ends while its fetch runs.
#[test]
fn the_fetch_shell_is_hidden_and_closes_when_the_session_ends() {
    let h = Harness::with_browser(Browser { hold_fetch: true, ..Browser::default() });
    let mark = h.mark();
    std::thread::scope(|scope| {
        let fetch = scope.spawn(|| {
            h.driver.call("net.fetch", &json!({"url": "https://a.test/data", "timeoutMs": 2000}))
        });
        wait_until(|| h.wire.browser.lock().unwrap().held.is_some(), "the fetch never started");
        assert_eq!(h.call("tabs.list", json!({})), json!([]), "the shell is listed");
        for (method, params) in [
            ("tab.info", json!({"targetId": "T1"})),
            ("tab.screenshot", json!({"targetId": "T1"})),
            ("tabs.activate", json!({"targetId": "T1"})),
            ("frame.evaluate", json!({"targetId": "T1", "source": "() => 1"})),
            ("tab.navigate", json!({"targetId": "T1", "url": "https://a.test/"})),
            ("cdp", json!({"targetId": "T1", "method": "DOM.getDocument"})),
            ("tabs.close", json!({"targetId": "T1"})),
        ] {
            let error = h.driver.call(method, &params).expect_err(method);
            assert_eq!(error.code, ErrorCode::NotFound, "{method}: {error}");
        }
        h.driver.end_session();
        let ended = fetch.join().unwrap();
        assert!(ended.is_err(), "the fetch ends with its shell: {ended:?}");
    });
    let sent = h.sent_since(mark);
    assert!(
        sent.iter().any(|(m, p)| m == "Target.closeTarget" && p["targetId"] == "T1"),
        "{sent:?}"
    );
    assert!(
        !sent.iter().any(|(m, _)| m == "Page.addScriptToEvaluateOnNewDocument"),
        "the shell runs no page agent: {sent:?}"
    );
    // Events are delivered in order: a later tab's navigation is a barrier.
    let later = h.open(Some("https://a.test/later"));
    wait_until(
        || h.events.lock().unwrap().iter().any(|e| e.payload["targetId"] == later.as_str()),
        "the later tab's events never arrived",
    );
    let events = h.events.lock().unwrap().clone();
    assert!(
        events.iter().all(|e| e.payload["targetId"] != "T1"),
        "the shell emitted events: {events:?}"
    );
}

/// a9 shell-tab condition (d): a shell whose setup failed is closed too.
#[test]
fn the_fetch_shell_closes_when_its_setup_fails() {
    let h = Harness::with_browser(Browser { fail_setup: true, ..Browser::default() });
    let mark = h.mark();
    let error = h
        .driver
        .call("net.fetch", &json!({"url": "https://a.test/data", "timeoutMs": 2000}))
        .expect_err("the shell's setup failed");
    assert_eq!(error.code, ErrorCode::Closed, "{error}");
    let sent = h.sent_since(mark);
    assert!(
        sent.iter().any(|(m, p)| m == "Target.closeTarget" && p["targetId"] == "T1"),
        "the shell leaked: {sent:?}"
    );
}

/// a9 raw_value: frame.evaluate hands the page's value on as the JSON text
/// Chromium sent, in the page's key order (scenario 32's search results).
#[test]
fn script_values_keep_the_page_key_order() {
    use cmux_browser_host::driver::Reply;
    let h = Harness::new();
    let target = h.open(None);
    let reply = h
        .driver
        .call_reply_announced(
            "frame.evaluate",
            &json!({"targetId": target, "source": "() => 'key-order'"}),
            &mut || {},
        )
        .expect("frame.evaluate");
    match reply {
        Reply::Json(raw) => assert_eq!(raw.get(), KEY_ORDER),
        Reply::Value(value) => panic!("the value was parsed (keys sorted): {value}"),
    }
}

/// Classic main: a cancelled fetch stops at once. A shell fetch closes its
/// shell (the detached session fails the pending call).
#[test]
fn a_cancelled_shell_fetch_closes_its_shell_at_once() {
    let h = Harness::with_browser(Browser { hold_fetch: true, ..Browser::default() });
    let mark = h.mark();
    std::thread::scope(|scope| {
        let fetch = scope.spawn(|| {
            h.driver.call(
                "net.fetch",
                &json!({"url": "https://a.test/data", "fetchId": "f1", "timeoutMs": 2000}),
            )
        });
        wait_until(|| h.wire.browser.lock().unwrap().held.is_some(), "the fetch never started");
        let _ = h.driver.call("net.fetch.cancel", &json!({"fetchId": "f1"}));
        wait_until(
            || {
                h.sent_since(mark)
                    .iter()
                    .any(|(m, p)| m == "Target.closeTarget" && p["targetId"] == "T1")
            },
            "the cancel did not close the shell",
        );
        assert!(fetch.join().unwrap().is_err(), "a cancelled fetch fails");
    });
}

/// Classic main: a cancelled in-tab fetch is aborted in the host world.
#[test]
fn a_cancelled_tab_fetch_is_aborted_at_once() {
    let h = Harness::with_browser(Browser { hold_fetch: true, ..Browser::default() });
    let target = h.open(None);
    std::thread::scope(|scope| {
        let fetch = scope.spawn(|| {
            h.driver.call(
                "net.fetch",
                &json!({"targetId": target, "url": "https://a.test/data", "fetchId": "f2", "timeoutMs": 2000}),
            )
        });
        wait_until(|| h.wire.browser.lock().unwrap().held.is_some(), "the fetch never started");
        let _ = h.driver.call("net.fetch.cancel", &json!({"fetchId": "f2"}));
        wait_until(
            || h.wire.browser.lock().unwrap().held.is_none(),
            "the cancel did not abort the fetch",
        );
        assert!(fetch.join().unwrap().is_err(), "a cancelled fetch fails");
    });
}

/// A shell never reports the host world's context, so a tab-less fetch
/// creates the world at once instead of waiting the context grace (500 ms)
/// first.
#[test]
fn a_shell_fetch_creates_the_host_world_without_waiting() {
    let h = Harness::new();
    let mark = h.mark();
    h.call("net.fetch", json!({"url": "https://a.test/data", "timeoutMs": 2000}));
    let browser = h.wire.browser.lock().unwrap();
    let at = |method: &str| {
        (mark..browser.sent.len())
            .find(|&i| browser.sent[i]["method"] == method)
            .map(|i| browser.sent_at[i])
            .unwrap_or_else(|| panic!("no {method}"))
    };
    let waited = at("Page.createIsolatedWorld").duration_since(at("Page.navigate"));
    assert!(
        waited < std::time::Duration::from_millis(250),
        "the shell waited {waited:?} for a context it never reports"
    );
}
