//! CdpDriver on a real headless Chromium over `--remote-debugging-pipe`.
//!
//! Ignored by default; the cmux-tui workflow's CDP browser smoke job runs it
//! with `CMUX_BROWSER_HOST_TEST_CHROME` set to Playwright's Chromium.

#![cfg(unix)]

use cmux_browser_host::cdp::CdpDriver;
use cmux_browser_host::cdp::pipe::{HeadlessChromium, HeadlessOptions};
use cmux_browser_host::driver::Driver;
use cmux_browser_host::protocol::{DriverEvent, ErrorCode};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// A minimal page agent: stable handle ids per element, resolvable while attached.
const AGENT: &str = r#"(() => {
  if (globalThis.__cmuxPageAgent) return;
  const byId = new Map(); const ids = new WeakMap(); let next = 0;
  Object.defineProperty(globalThis, "__cmuxPageAgent", { enumerable: false, value: {
    handleFor(el) { if (!ids.has(el)) { const id = "h" + (++next); ids.set(el, id); byId.set(id, new WeakRef(el)); } return ids.get(el); },
    resolveHandle(id) { const ref = byId.get(id); const el = ref && ref.deref(); return el && el.isConnected ? el : null; },
  }});
})();"#;

fn serve() -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").expect("bind fixture server");
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            // One thread per connection: Chromium opens speculative sockets
            // that never send a request, which would stall a serial server.
            std::thread::spawn(move || {
                let mut reader = BufReader::new(stream.try_clone().unwrap());
                let mut line = String::new();
                if reader.read_line(&mut line).is_err() {
                    return;
                }
                let path = line.split_whitespace().nth(1).unwrap_or("/").to_owned();
                loop {
                    let mut header = String::new();
                    if reader.read_line(&mut header).map(|n| n == 0).unwrap_or(true)
                        || header == "\r\n"
                    {
                        break;
                    }
                }
                // One hop to the other loopback origin (host fetch redirects).
                if path == "/redirect" {
                    let mut stream = stream;
                    let _ = write!(
                        stream,
                        "HTTP/1.1 302 Found\r\nLocation: http://localhost:{port}/second\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    );
                    return;
                }
                let body = match path.as_str() {
                    "/" => format!(
                        "<!doctype html><title>Host test</title>\
                         <button id=b style=\"width:120px;height:40px\" onclick=\"window.clicked = event.isTrusted\">Go</button>\
                         <input id=i><iframe id=f src=\"/child\" style=\"width:300px;height:100px\"></iframe>\
                         <iframe id=x src=\"http://localhost:{port}/cross\" style=\"width:300px;height:100px\"></iframe>"
                    ),
                    "/child" => "<!doctype html><p id=p>child frame</p>".to_owned(),
                    "/cross" => "<!doctype html><p id=c>cross-origin frame</p><input id=ci>".to_owned(),
                    "/dl" => "<!doctype html><title>Downloads</title><a id=d href=\"/report.txt\" download=\"report.txt\">Report</a>".to_owned(),
                    "/report.txt" => "report body".to_owned(),
                    "/second" => "<!doctype html><title>Second</title><p>second</p>".to_owned(),
                    "/script.js" => "window.__loaded = true;".to_owned(),
                    "/scripted" => "<!doctype html><html><head><title>Scripted</title><script src=\"/script.js\"></script></head><body><p>second</p><script>window.__inline = 1;</script></body></html>".to_owned(),
                    "/fields" => "<!doctype html><title>Fields</title>\
                         <label for=pw>Password</label><input id=pw type=password value=hunter2-default>\
                         <input id=otp autocomplete=one-time-code><input id=cc autocomplete=\"cc-number\">\
                         <input id=plain value=visible-value>"
                        .to_owned(),
                    _ => "<!doctype html><title>404</title>".to_owned(),
                };
                let mut stream = stream;
                let _ = write!(
                    stream,
                    "HTTP/1.1 {}\r\nContent-Type: {}; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    if path == "/missing" { "404 Not Found" } else { "200 OK" },
                    if path.ends_with(".js") { "text/javascript" } else { "text/html" },
                    body.len()
                );
            });
        }
    });
    port
}

fn wait_event(events: &Mutex<Vec<DriverEvent>>, name: &str) -> DriverEvent {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(event) = events.lock().unwrap().iter().find(|e| e.name == name).cloned() {
            return event;
        }
        assert!(Instant::now() < deadline, "no {name} event");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn browser_host_drives_headless_chromium_over_the_pipe() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");

    let started = Instant::now();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let events = Arc::new(Mutex::new(Vec::new()));
    let sink = events.clone();
    let driver = CdpDriver::attach_browser(
        chromium.connection().clone(),
        AGENT,
        Arc::new(move |event| sink.lock().unwrap().push(event)),
    )
    .expect("attach to Chromium");
    eprintln!("perf: launch+attach {} ms", started.elapsed().as_millis());
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };

    let started = Instant::now();
    let target = call("tabs.open", json!({"url": format!("{origin}/")}))["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let loaded = call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("{origin}/"), "waitUntil": "load"}),
    );
    assert_eq!(loaded["url"], format!("{origin}/"));
    eprintln!("perf: open+navigate {} ms", started.elapsed().as_millis());
    call("tab.setViewport", json!({"targetId": target, "width": 1024, "height": 700}));

    let info = call("tab.info", json!({"targetId": target}));
    assert_eq!(info["loadState"], "load");
    assert_eq!(info["title"], "Host test");
    assert_eq!(info["viewport"]["width"], 1024.0);

    let frames = call("frames.list", json!({"targetId": target}));
    let frames = frames.as_array().unwrap();
    assert_eq!(frames.len(), 3, "{frames:?}");
    assert_eq!(frames[1]["url"], format!("{origin}/child"));
    assert_eq!(frames[1]["crossOrigin"], false);
    let cross = frames
        .iter()
        .find(|f| f["url"].as_str().is_some_and(|u| u.ends_with("/cross")))
        .expect("the out-of-process frame is listed");
    assert_eq!(cross["crossOrigin"], true);
    let cross_text = call(
        "frame.evaluate",
        json!({"targetId": target, "frameId": cross["frameId"], "world": "agent", "source": "() => document.querySelector('#c').textContent"}),
    );
    assert_eq!(cross_text, "cross-origin frame", "cross-origin frames are reachable");
    let cross_box =
        call("frame.ownerBox", json!({"targetId": target, "frameId": cross["frameId"]}));
    assert!(cross_box["width"].as_f64().unwrap() > 290.0, "{cross_box}");
    let child_frame = frames[1]["frameId"].clone();

    let target_box = call(
        "frame.evaluate",
        json!({"targetId": target, "source": "() => { const b = document.querySelector('#b'); \
        const r = b.getBoundingClientRect(); return { h: globalThis.__cmuxPageAgent.handleFor(b), x: r.x + r.width / 2, y: r.y + r.height / 2, \
        frame: globalThis.__cmuxPageAgent.handleFor(document.querySelector('#f')), input: globalThis.__cmuxPageAgent.handleFor(document.querySelector('#i')) }; }"}),
    );
    let (x, y) = (target_box["x"].as_f64().unwrap(), target_box["y"].as_f64().unwrap());

    for kind in ["move", "down", "up"] {
        call(
            "input.mouse",
            json!({"targetId": target, "type": kind, "x": x, "y": y, "button": "left", "clickCount": 1}),
        );
    }
    let trusted = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => window.clicked"}),
    );
    assert_eq!(trusted, true, "the click must be a trusted event");
    // The agent world is isolated: it sees the DOM, not page globals.
    let probe = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "agent", "source": "() => typeof window.clicked"}),
    );
    assert_eq!(probe, "undefined");

    let tag = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "(el, suffix) => el.tagName + suffix", "handles": [target_box["h"]], "args": ["!"]}),
    );
    assert_eq!(tag, "BUTTON!");
    let child =
        call("frame.contentFrame", json!({"targetId": target, "element": target_box["frame"]}));
    assert_eq!(child["frameId"], child_frame);
    let child_text = call(
        "frame.evaluate",
        json!({"targetId": target, "frameId": child_frame, "world": "agent", "source": "() => document.querySelector('#p').textContent"}),
    );
    assert_eq!(child_text, "child frame");
    let owner = call("frame.ownerBox", json!({"targetId": target, "frameId": child_frame}));
    assert!(owner["width"].as_f64().unwrap() > 290.0, "{owner}");

    call(
        "frame.evaluate",
        json!({"targetId": target, "source": "(el) => el.focus()", "handles": [target_box["input"]]}),
    );
    call("input.insertText", json!({"targetId": target, "text": "héllo"}));
    for (kind, text) in [("down", Some("!")), ("up", None)] {
        let mut key = json!({"targetId": target, "type": kind, "key": "!", "code": "Digit1", "modifiers": ["Shift"]});
        if let Some(text) = text {
            key["text"] = json!(text);
        }
        call("input.key", key);
    }
    let value = call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => document.querySelector('#i').value"}),
    );
    assert_eq!(value, "héllo!");

    let started = Instant::now();
    let rounds = 50;
    for _ in 0..rounds {
        call("frame.evaluate", json!({"targetId": target, "source": "() => 1"}));
    }
    eprintln!(
        "perf: frame.evaluate round trip {:.2} ms",
        started.elapsed().as_secs_f64() * 1000.0 / f64::from(rounds)
    );

    let shot = call("tab.screenshot", json!({"targetId": target}));
    assert_eq!(shot["width"], 1024.0);
    assert_eq!(shot["height"], 700.0);

    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => { setTimeout(() => alert('hi'), 0); }"}),
    );
    let dialog = wait_event(&events, "dialog.opened");
    assert_eq!(dialog.payload["message"], "hi");
    call(
        "dialog.respond",
        json!({"targetId": target, "dialogId": dialog.payload["dialogId"], "accept": true}),
    );

    call("tab.navigate", json!({"targetId": target, "url": format!("{origin}/second")}));
    let stale = driver
        .call("frame.evaluate", &json!({"targetId": target, "world": "page", "source": "(el) => el", "handles": [target_box["h"]]}))
        .unwrap_err();
    assert_eq!(stale.code, ErrorCode::Stale, "handles die with their document");
    // Back may restore the first document from the back/forward cache.
    let back = call("tab.history", json!({"targetId": target, "delta": -1}));
    assert_eq!(back["url"], format!("{origin}/"));
    assert_eq!(call("tab.info", json!({"targetId": target}))["loadState"], "load");

    // A popup arrives as tab.created with its opener and is drivable.
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => { window.open('/second'); }"}),
    );
    let created = wait_event(&events, "tab.created");
    assert_eq!(created.payload["openerTargetId"], target.as_str());
    let popup = created.payload["targetId"].as_str().unwrap().to_owned();
    let popup_title = driver
        .call("frame.evaluate", &json!({"targetId": popup, "world": "agent", "source": "() => new Promise((r) => { const t = () => document.title ? r(document.title) : setTimeout(t, 20); t(); })", "timeoutMs": 10000}))
        .expect("the popup is set up and resumed");
    assert_eq!(popup_title, "Second");
    call("tabs.close", json!({"targetId": popup}));

    // frame.observe: only allowlisted page agent reads, and sensitive field
    // values never come back (browser-host.md, frame.observe).
    call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("{origin}/fields"), "waitUntil": "load"}),
    );
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source":
        "() => { pw.value = 's3cret-pass'; otp.value = '123456'; cc.value = '4111111111111111'; }"}),
    );
    // A stand-in page agent under the real symbol: handle ids are element ids.
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "agent", "source": r#"() => {
        const el = (id) => document.getElementById(id);
        globalThis[Symbol.for("cmux.browserRepl.agent")] = {
          element: el,
          retarget: (id) => (el(id).tagName === "LABEL" ? el(id).htmlFor : id),
          read: (id, what, arg) => what === "inputValue" ? el(id).value
            : what === "getAttribute" ? el(id).getAttribute(arg) : el(id)[what],
          snapshot: () => [...document.querySelectorAll("input")]
            .map((i) => `${i.id}=${i.value}|${i.getAttribute("value") || ""}`).join(" "),
          fill: (id, v) => { el(id).value = v; },
        };
      }"#}),
    );
    let observe = |method: &str, args: Value| {
        driver.call("frame.observe", &json!({"targetId": target, "method": method, "args": args}))
    };
    assert_eq!(observe("read", json!(["pw", "inputValue"])).unwrap(), "********");
    assert_eq!(observe("read", json!(["otp", "inputValue"])).unwrap(), "********");
    assert_eq!(observe("read", json!(["cc", "inputValue"])).unwrap(), "********");
    assert_eq!(observe("read", json!(["pw", "getAttribute", "value"])).unwrap(), "********");
    assert_eq!(observe("read", json!(["plain", "inputValue"])).unwrap(), "visible-value");
    let snapshot = observe("snapshot", json!([])).unwrap();
    let snapshot = snapshot.as_str().unwrap();
    for secret in ["s3cret-pass", "123456", "4111111111111111", "hunter2-default"] {
        assert!(!snapshot.contains(secret), "{secret} leaked: {snapshot}");
    }
    assert!(snapshot.contains("plain=visible-value"), "{snapshot}");
    let refused = observe("fill", json!(["plain", "x"])).unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
    assert_eq!(refused.error_name.as_deref(), Some("observe_not_allowed"));
    assert_eq!(observe("read", json!(["plain", "inputValue"])).unwrap(), "visible-value");

    call("tabs.close", json!({"targetId": target}));
    wait_event(&events, "tab.closed");
    assert!(
        call("tabs.list", json!({}))
            .as_array()
            .unwrap()
            .iter()
            .all(|tab| tab["targetId"] != target.as_str())
    );
}

/// The runtime's page agent (host::agent_bundle) is in the agent world of
/// every document the tab loads: the context the driver evaluates agent
/// calls in must hold it, whichever context Chromium reports last.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn the_agent_world_holds_the_agent_after_every_navigation() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(
        chromium.connection().clone(),
        cmux_browser_host::host::agent_bundle(),
        Arc::new(|_| {}),
    )
    .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({}))["targetId"].as_str().unwrap().to_owned();
    for url in [
        format!("http://localhost:{port}/second"),
        format!("http://127.0.0.1:{port}/second"),
        format!("http://localhost:{port}/second?again"),
        "data:text/html,<p>data</p>".to_owned(),
        format!("http://localhost:{port}/second?after-data"),
    ] {
        call("tab.navigate", json!({"targetId": target, "url": url, "waitUntil": "load"}));
        let has_agent = call(
            "frame.evaluate",
            json!({"targetId": target, "world": "agent", "source": "() => typeof globalThis[Symbol.for('cmux.browserRepl.agent')]"}),
        );
        assert_eq!(has_agent, "object", "no page agent in the agent world after loading {url}");
    }
}

/// The same through the whole host (gate, QuickJS runtime, headless engine)
/// as `cmux-browser-host eval` runs a cell: page-agent calls such as
/// snapshot() work on a page served from localhost and from 127.0.0.1.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn host_sessions_reach_the_page_agent_after_goto() {
    let binary = std::env::var("CMUX_BROWSER_HOST_TEST_CHROME")
        .ok()
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-agent-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("host.sock");
    let eval = |code: &str| -> String {
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
            .args(["eval", "--engine", "headless", "--socket"])
            .arg(&socket)
            .arg("-")
            .current_dir(&dir)
            .env("CMUX_BROWSER_HOST_CHROMIUM", &binary)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("run cmux-browser-host eval");
        child.stdin.take().unwrap().write_all(code.as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
    };
    for origin in [format!("http://localhost:{port}"), format!("http://127.0.0.1:{port}")] {
        let out = eval(&format!(
            "await page.goto({:?}); const s = await snapshot(); console.log('agent:' + s.tree.includes('second'));",
            format!("{origin}/scripted")
        ));
        assert!(out.contains("agent:true"), "{origin}: {out}");
    }
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A headless session starts with no tabs: the start tab Chromium opens is
/// not the session's and not listed (scenario 13 counts tabs from zero).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_headless_session_lists_no_start_tab() {
    use cmux_browser_host::host::Engines;
    let binary = std::env::var("CMUX_BROWSER_HOST_TEST_CHROME")
        .ok()
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    // SAFETY: set before the engine starts; nothing else reads it concurrently here.
    unsafe { std::env::set_var("CMUX_BROWSER_HOST_CHROMIUM", &binary) };
    let engines =
        cmux_browser_host::engines::HostEngines::new(cmux_browser_host::host::agent_bundle());
    let session = cmux_browser_host::host::SessionContext {
        name: "start-tab".into(),
        caller: cmux_browser_host::host::Caller {
            actor: "test".into(),
            on_behalf_of: None,
            origin: "cli".into(),
            locality: Default::default(),
        },
        label: "start-tab".into(),
        profile: cmux_browser_host::host::AGENT_PROFILE.into(),
    };
    let driver = engines.driver("headless", Arc::new(|_| {}), &session).expect("headless driver");
    let tabs = driver.call("tabs.list", &json!({})).expect("tabs.list");
    assert_eq!(tabs, json!([]), "the start tab is listed");
    let opened = driver.call("tabs.open", &json!({"url": "about:blank"})).expect("tabs.open");
    let tabs = driver.call("tabs.list", &json!({})).expect("tabs.list");
    assert_eq!(tabs.as_array().map(Vec::len), Some(1), "{tabs}");
    assert_eq!(tabs[0]["targetId"], opened["targetId"]);
}

/// `cmux-browser-host eval` without `--session` is a one-shot session, as
/// `cmux browser repl --eval` is: nothing carries over to the next call
/// (variables, tabs, the page agent's ref numbers).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn eval_without_a_session_is_one_shot() {
    let binary = std::env::var("CMUX_BROWSER_HOST_TEST_CHROME")
        .ok()
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let dir = std::env::temp_dir().join(format!("cmux-host-oneshot-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("host.sock");
    let eval = |args: &[&str], code: &str| -> String {
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
            .arg("eval")
            .args(args)
            .args(["--engine", "headless", "--socket"])
            .arg(&socket)
            .arg("-")
            .current_dir(&dir)
            .env("CMUX_BROWSER_HOST_CHROMIUM", &binary)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .expect("run cmux-browser-host eval");
        child.stdin.take().unwrap().write_all(code.as_bytes()).unwrap();
        let out = child.wait_with_output().unwrap();
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
    };
    let page = "await page.goto('data:text/html,<button>A</button>'); console.log(String(await snapshot()).includes('[ref=e1]'));";
    assert_eq!(eval(&[], &format!("var carried = 1; {page}")).trim(), "true");
    assert_eq!(
        eval(&[], &format!("console.log(typeof carried); {page}")).trim(),
        "undefined\ntrue"
    );
    // A named session keeps its state.
    eval(&["--session", "kept"], "var carried = 2;");
    assert_eq!(eval(&["--session", "kept"], "console.log(carried);").trim(), "2");
    let mut close = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = close.args(["close", "--session", "kept", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
}

/// A document navigation answers the main document's HTTP status, as
/// Playwright's goto() Response does (scenario 12); reload too.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn navigations_answer_the_document_status() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(chromium.connection().clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({}))["targetId"].as_str().unwrap().to_owned();
    let nav = |path: &str| {
        call(
            "tab.navigate",
            json!({"targetId": target, "url": format!("http://127.0.0.1:{port}{path}"), "waitUntil": "load"}),
        )
    };
    assert_eq!(nav("/second")["status"], 200);
    assert_eq!(nav("/missing")["status"], 404);
    assert_eq!(call("tab.reload", json!({"targetId": target, "waitUntil": "load"}))["status"], 404);
    let data = call(
        "tab.navigate",
        json!({"targetId": target, "url": "data:text/html,x", "waitUntil": "load"}),
    );
    assert!(data.get("status").is_none(), "a data: URL has no HTTP status: {data}");
}

/// a9 shell-tab conditions on a real Chromium: a tab-less fetch runs in a
/// hidden shell tab (its marker URL is seen at attach, so it is never
/// listed and emits no event) and returns the server's response.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_tab_less_fetch_runs_in_a_hidden_shell() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let events = Arc::new(Mutex::new(Vec::<DriverEvent>::new()));
    let sink = events.clone();
    let driver = CdpDriver::attach_browser(
        chromium.connection().clone(),
        AGENT,
        Arc::new(move |event| sink.lock().unwrap().push(event)),
    )
    .expect("attach to Chromium");
    let before = driver.call("tabs.list", &json!({})).expect("tabs.list");
    let url = format!("http://127.0.0.1:{port}/second");
    let out = driver.call("net.fetch", &json!({"url": url})).expect("net.fetch");
    assert_eq!(out["status"], 200, "{out}");
    assert!(!out["bodyBase64"].as_str().unwrap_or("").is_empty(), "{out}");
    assert_eq!(driver.call("tabs.list", &json!({})).expect("tabs.list"), before);
    // Events arrive in order: a later tab's navigation is a barrier.
    let later = driver.call("tabs.open", &json!({"url": url})).expect("tabs.open")["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let deadline = Instant::now() + Duration::from_secs(10);
    while !events.lock().unwrap().iter().any(|e| e.payload["targetId"] == later.as_str()) {
        assert!(Instant::now() < deadline, "the later tab's events never arrived");
        std::thread::sleep(Duration::from_millis(20));
    }
    let events = events.lock().unwrap();
    let leaked: Vec<&DriverEvent> = events
        .iter()
        .filter(|e| {
            let text = e.payload.to_string();
            text.contains("cmux-fetch-shell") || text.contains("cmux-shell-")
        })
        .collect();
    assert!(leaked.is_empty(), "the shell emitted events: {leaked:?}");
}

/// SHELL-REDIRECT-LNA option 1 on a real Chromium: a tab-less fetch whose
/// server redirects 127.0.0.1 -> localhost (another origin, a local
/// address) is followed by the host, each hop in a shell at its own origin,
/// so Local Network Access never blocks it; a Local caller gets the final
/// response.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_tab_less_fetch_follows_a_redirect_to_another_local_origin() {
    use cmux_browser_host::gate::{Gate, Grants};
    use cmux_browser_host::vm::VmHost;
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(chromium.connection().clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    let gate = Gate::new(Arc::new(driver), Grants::default());
    let out = gate
        .driver_call("net.fetch", json!({"url": format!("http://127.0.0.1:{port}/redirect")}))
        .expect("the redirect is followed");
    assert_eq!(out["status"], 200, "{out}");
    assert_eq!(out["url"], format!("http://localhost:{port}/second"));
    assert_eq!(out["redirected"], true);
}

/// HOP-ADDRESS guard: Chromium reports a Fetch-intercepted manual
/// redirect's address only through the next `requestWillBeSent`'s
/// `redirectResponse.remoteIPAddress`. A Chromium roll that drops it turns
/// this red (the host would fall back to waiting 1 s per hop and logging).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_manual_redirect_reports_its_address() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(chromium.connection().clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    // The gate installs a filter while a fetch runs (interception on).
    assert!(driver.set_request_filter(Some(Arc::new(|_| None))));
    let out = driver
        .call(
            "net.fetch",
            &json!({"url": format!("http://127.0.0.1:{port}/redirect"), "redirect": "manual",
                "fetchId": "guard", "timeoutMs": 10_000}),
        )
        .expect("net.fetch");
    assert_eq!(out["redirect"]["status"], 302, "{out}");
    assert_eq!(out["remoteIPAddress"], "127.0.0.1", "the redirect's address is gone: {out}");
}

/// The host's focus check for secret typing: a field focused inside an
/// out-of-process (cross-origin) frame is reported with that frame's URL.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn the_focused_field_is_found_in_a_cross_origin_frame() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let driver = CdpDriver::attach_browser(chromium.connection().clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({"url": format!("{origin}/")}))["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("{origin}/"), "waitUntil": "load"}),
    );

    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => document.querySelector('#i').focus()"}),
    );
    let top = call("frame.focused", json!({"targetId": target}));
    assert_eq!(top["url"], format!("{origin}/"), "{top}");

    let frames = call("frames.list", json!({"targetId": target}));
    let cross = frames
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["url"].as_str().is_some_and(|u| u.ends_with("/cross")))
        .expect("the out-of-process frame is listed")
        .clone();
    call(
        "frame.evaluate",
        json!({"targetId": target, "frameId": cross["frameId"], "world": "page", "source": "() => document.querySelector('#ci').focus()"}),
    );
    let inner = call("frame.focused", json!({"targetId": target}));
    assert_eq!(inner["url"], format!("http://localhost:{port}/cross"), "{inner}");
    assert_eq!(inner["frameId"], cross["frameId"]);
}

/// Downloads on headless Chromium: `download.started` and
/// `download.finished` reach the session, the file lands in the host's own
/// directory, and `download.path` answers once it completed.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_download_is_reported_and_saved() {
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(binary.into())).expect("launch Chromium");
    let (tx, rx) = std::sync::mpsc::channel::<DriverEvent>();
    let tx = Mutex::new(tx);
    let driver = CdpDriver::attach_browser(
        chromium.connection().clone(),
        AGENT,
        Arc::new(move |event| {
            if event.name.starts_with("download.") {
                let _ = tx.lock().unwrap().send(event);
            }
        }),
    )
    .expect("attach to Chromium");
    driver.save_downloads_in(chromium.downloads_dir()).expect("downloads go to the host");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target = call("tabs.open", json!({"url": format!("{origin}/dl")}))["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    call(
        "tab.navigate",
        json!({"targetId": target, "url": format!("{origin}/dl"), "waitUntil": "load"}),
    );
    call(
        "frame.evaluate",
        json!({"targetId": target, "world": "page", "source": "() => document.querySelector('#d').click()"}),
    );
    let started = rx.recv_timeout(Duration::from_secs(10)).expect("download.started");
    assert_eq!(started.name, "download.started");
    assert_eq!(started.payload["targetId"], target);
    assert_eq!(started.payload["url"], format!("{origin}/report.txt"));
    assert_eq!(started.payload["suggestedFilename"], "report.txt");
    let id = started.payload["downloadId"].clone();
    let path = call("download.path", json!({"downloadId": id, "timeoutMs": 10_000}));
    let path = path["path"].as_str().expect("a path").to_owned();
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "report body");
    let finished = rx.recv_timeout(Duration::from_secs(10)).expect("download.finished");
    assert_eq!(finished.name, "download.finished");
    assert_eq!(finished.payload["downloadId"], id);
    assert_eq!(finished.payload["path"], path.as_str());
    use std::os::unix::fs::PermissionsExt;
    let dir = std::path::Path::new(&path).parent().unwrap();
    assert_eq!(dir, chromium.downloads_dir());
    assert_eq!(std::fs::metadata(dir).unwrap().permissions().mode() & 0o777, 0o700);
}
