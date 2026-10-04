//! CdpDriver against a scripted in-process browser: the CDP each driver
//! method sends, and the driver results and events it derives from replies.

use cmux_browser_host::cdp::{AGENT_WORLD, CdpConnection, CdpDriver, CdpWire};
use cmux_browser_host::driver::Driver;
use cmux_browser_host::protocol::{DriverEvent, ErrorCode};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::io;
use std::sync::{Arc, Mutex, OnceLock, Weak};

const AGENT_SOURCE: &str = "globalThis.__cmuxPageAgent = { resolveHandle: (id) => null };";
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
        conn.receive(&reply.to_string());
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
                browser.tabs.insert(
                    target.clone(),
                    FakeTab { history: vec!["about:blank".into()], index: 0, loaders: 0 },
                );
                events.push(json!({"method": "Target.attachedToTarget", "params": {
                    "sessionId": format!("S{n}"),
                    "targetInfo": {"targetId": target, "type": "page", "url": "about:blank", "title": ""},
                    "waitingForDebugger": true,
                }}));
                json!({"targetId": target})
            }
            "Target.closeTarget" => {
                let target = params["targetId"].as_str().unwrap().to_owned();
                browser.tabs.remove(&target);
                events.push(json!({"method": "Target.detachedFromTarget", "params": {"sessionId": target.replacen('T', "S", 1)}}));
                events.push(
                    json!({"method": "Target.targetDestroyed", "params": {"targetId": target}}),
                );
                json!({"success": true})
            }
            "Target.activateTarget"
            | "Target.detachFromTarget"
            | "Page.enable"
            | "Page.setLifecycleEventsEnabled"
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
                json!({"identifier": "1"})
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
                if declaration.contains("return a && a.resolveHandle ? a.resolveHandle(id) : null")
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
        let wire =
            Arc::new(FakeWire { conn: OnceLock::new(), browser: Mutex::new(Browser::default()) });
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
    assert_eq!(
        sent[2].1,
        json!({"backendNodeId": 42, "executionContextId": 10, "objectGroup": "cmux-handles"})
    );
    assert_eq!(sent[3].1["executionContextId"], 10);
    assert_eq!(sent[3].1["arguments"], json!([{"objectId": "page-42"}]));
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
    let events: Vec<Value> = h.sent_since(mark).into_iter().map(|(_, p)| p).collect();
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
    let sent: Vec<Value> = h.sent_since(mark).into_iter().map(|(_, p)| p).collect();
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
        h.driver.call("clipboard.read", &json!({"targetId": target})).unwrap_err().code,
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
    let filter: cmux_browser_host::driver::RequestFilter = Arc::new(|url: &str| {
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
    let filter: cmux_browser_host::driver::RequestFilter = Arc::new(|_: &str| None);
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
