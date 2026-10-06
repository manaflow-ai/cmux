//! Uploads and file choosers on the shared headless browser (parity 10 and
//! 11, driver-protocol.md "Files, dialogs, downloads"): `input.setFiles`,
//! `filechooser.opened` routed like a dialog, `filechooser.respond` only
//! from the session the chooser went to, and D2 for a chooser no session
//! takes (cancelled and logged). A module of the `chromium` test target.

use super::*;

/// `/files`: a visible single and multiple input, a hidden input opened by
/// a button now (`#picker`) or 1.5 s after the click (`#later`, inside the
/// click's user activation, after the call is over). Each input writes
/// `<id>: <name>=<text>,...` on change and `<id>: cancel` on cancel.
pub fn files_page() -> String {
    "<!doctype html><title>Files</title>\
     <button id=picker style=\"position:fixed;left:0;top:0;width:200px;height:100px\" \
       onclick=\"document.getElementById('hidden').click()\">Pick</button>\
     <button id=later style=\"position:fixed;left:300px;top:0;width:200px;height:100px\" \
       onclick=\"setTimeout(() => document.getElementById('hidden').click(), 1500)\">Later</button>\
     <input id=one type=file style=\"position:fixed;left:0;top:120px\">\
     <input id=many type=file multiple style=\"position:fixed;left:0;top:160px\">\
     <input id=hidden type=file style=\"display:none\">\
     <p id=files style=\"position:fixed;left:0;top:220px\">none</p>\
     <script>window.ready = true; for (const el of document.querySelectorAll('input[type=file]')) {\
       el.addEventListener('change', async () => { const parts = [];\
         for (const f of el.files) parts.push(f.name + '=' + await f.text());\
         document.getElementById('files').textContent = el.id + ': ' + parts.join(','); });\
       el.addEventListener('cancel', () => { document.getElementById('files').textContent = el.id + ': cancel'; });\
     }</script>"
        .to_owned()
}

fn chrome() -> String {
    std::env::var("CMUX_BROWSER_HOST_TEST_CHROME")
        .ok()
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary")
}

/// Runs `code` in `session` of the host on `socket` (cmux-browser-host eval).
fn eval_in(
    socket: &std::path::Path,
    dir: &std::path::Path,
    chrome: &str,
    session: &str,
    code: &str,
) -> String {
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
        .args(["eval", "--engine", "headless", "--session", session, "--socket"])
        .arg(socket)
        .arg("-")
        .current_dir(dir)
        .env("CMUX_BROWSER_HOST_CHROMIUM", chrome)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .expect("run cmux-browser-host eval");
    child.stdin.take().unwrap().write_all(code.as_bytes()).unwrap();
    let out = child.wait_with_output().unwrap();
    format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr))
}

/// The runtime's uploads on headless: `setInputFiles` from memory, a
/// chooser with a listener, a held chooser (no listener) and its cancel.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn uploads_and_file_choosers_work_on_headless() {
    let chrome = chrome();
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-files-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("host.sock");
    // The test's own host: stopped (exact PID) when the test ends, also on failure.
    let _host = HostGuard::start(&socket, &chrome);
    let out = eval_in(
        &socket,
        &dir,
        &chrome,
        "a",
        &format!(
            "const text = () => page.locator('#files').textContent(); \
             const until = (p) => page.waitForFunction((p) => document.getElementById('files').textContent.startsWith(p), p, {{ timeout: 5000 }}); \
             await page.goto('http://127.0.0.1:{port}/files'); \
             await page.locator('#one').setInputFiles({{ name: 'mem.txt', mimeType: 'text/plain', buffer: 'in memory' }}); \
             await until('one:'); console.log('single=' + await text()); \
             const chooserP = page.waitForEvent('filechooser'); \
             await page.locator('#picker').click(); \
             const chooser = await chooserP; console.log('multiple=' + chooser.isMultiple()); \
             await chooser.setFiles({{ name: 'b.txt', mimeType: 'text/plain', buffer: 'beta' }}); \
             await until('hidden:'); console.log('chooser=' + await text()); \
             await page.locator('#many').click(); \
             const held = page.fileChooser(); console.log('held=' + (held && held.multiple)); \
             await held.cancel(); await until('many:'); \
             console.log('cancelled=' + await text() + ' ' + page.fileChooser());"
        ),
    );
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
    for line in [
        "single=one: mem.txt=in memory",
        "multiple=false",
        "chooser=hidden: b.txt=beta",
        "held=true",
        "cancelled=many: cancel null",
    ] {
        assert!(out.contains(line), "missing {line:?} in {out}");
    }
}

/// D2 (ff, 2026-10-06): a chooser no session takes (a kept tab, no
/// handler, no call in flight) is cancelled, so the page sees `cancel`,
/// and is logged in the policy log of the session that opened the tab.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn an_unrouted_file_chooser_is_cancelled_and_logged() {
    let chrome = chrome();
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-chooser-d2-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("host.sock");
    let _host = HostGuard::start(&socket, &chrome);
    // waitForTimeout is the runtime's own timer: no call is in flight on the
    // tab when the page opens the chooser.
    let out = eval_in(
        &socket,
        &dir,
        &chrome,
        "a",
        &format!(
            "await page.goto('http://127.0.0.1:{port}/files'); await page.keep(); \
             await page.locator('#later').click(); await page.waitForTimeout(3500); \
             console.log('page=' + await page.locator('#files').textContent() + ' held=' + !!page.fileChooser()); \
             const log = session.blockedNavigations().filter((b) => b.blocked === 'unrouted'); \
             console.log('a-log=' + JSON.stringify(log.map((b) => [b.event, b.action, b.url.endsWith('/files')])));"
        ),
    );
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(out.contains("page=hidden: cancel held=false"), "{out}");
    assert!(out.contains("a-log=[[\"filechooser.opened\",\"cancelled\",true]]"), "{out}");
}

/// Only the session a chooser went to answers it (another session gets
/// `not_found` and the chooser stays open); when that session leaves, its
/// chooser is cancelled.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn only_the_choosers_session_answers_it_and_its_end_cancels_it() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSession, HeadlessSource};
    let port = serve();
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(chrome().into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let open = |name: &str, events: Arc<Mutex<Vec<DriverEvent>>>| {
        let lease = cmux_browser_host::lease::LeaseCaller {
            session: name.into(),
            actor: "t".into(),
            on_behalf_of: None,
            origin: "cli".into(),
            label: String::new(),
            implicit_session: false,
            engine: "headless".into(),
        };
        let sink: cmux_browser_host::driver::EventSink =
            Arc::new(move |event| events.lock().unwrap().push(event));
        HeadlessSession::new(source.clone(), &browsers, Arc::from(AGENT), sink, lease).unwrap()
    };
    let read = |session: &HeadlessSession, target: &str| -> String {
        session
            .call(
                "frame.evaluate",
                &json!({"targetId": target, "world": "agent",
                    "source": "() => document.getElementById('files').textContent"}),
            )
            .unwrap()
            .as_str()
            .unwrap_or("")
            .to_owned()
    };
    let click = |session: &HeadlessSession, target: &str| {
        session
            .call("input.mouse", &json!({"targetId": target, "type": "move", "x": 50, "y": 50}))
            .unwrap();
        for kind in ["down", "up"] {
            session
                .call(
                    "input.mouse",
                    &json!({"targetId": target, "type": kind, "x": 50, "y": 50,
                        "button": "left", "clickCount": 1}),
                )
                .unwrap();
        }
    };
    let (a_events, b_events) = (Arc::default(), Arc::default());
    let a = open("a", Arc::clone(&a_events));
    let b = open("b", Arc::clone(&b_events));
    let target = a
        .call("tabs.open", &json!({"url": format!("http://127.0.0.1:{port}/files")}))
        .unwrap()["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    // a created the tab: its chooser goes to a.
    // tabs.open returns before the page loads: click once its script ran.
    let deadline = Instant::now() + Duration::from_secs(10);
    while a
        .call(
            "frame.evaluate",
            &json!({"targetId": target, "world": "page", "source": "() => window.ready === true"}),
        )
        .ok()
        != Some(json!(true))
    {
        assert!(Instant::now() < deadline, "the page never loaded");
        std::thread::sleep(Duration::from_millis(20));
    }
    // The chooser's event, or a failure that shows what each session got.
    let chooser_event = |events: &Mutex<Vec<DriverEvent>>, others: &Mutex<Vec<DriverEvent>>| {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let found = events
                .lock()
                .unwrap()
                .iter()
                .rev()
                .find(|e| e.name == "filechooser.opened")
                .cloned();
            if let Some(event) = found {
                return event;
            }
            let names = |list: &Mutex<Vec<DriverEvent>>| -> Vec<String> {
                list.lock().unwrap().iter().map(|e| e.name.clone()).collect()
            };
            assert!(
                Instant::now() < deadline,
                "no filechooser.opened: this session got {:?}, the other {:?}",
                names(events),
                names(others)
            );
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    click(&a, &target);
    let opened = chooser_event(&a_events, &b_events);
    assert_eq!(opened.payload["multiple"], false, "{opened:?}");
    assert!(opened.payload["element"].is_string(), "{opened:?}");
    let chooser = opened.payload["chooserId"].clone();
    assert!(
        !b_events.lock().unwrap().iter().any(|e| e.name == "filechooser.opened"),
        "only a gets the chooser"
    );
    let refused = b
        .call(
            "filechooser.respond",
            &json!({"targetId": target, "chooserId": chooser, "cancel": true}),
        )
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::NotFound, "{refused:?}");
    assert_eq!(read(&a, &target), "none", "b's answer left the chooser open");
    a.call(
        "filechooser.respond",
        &json!({"targetId": target, "chooserId": chooser,
            "files": [{"name": "a.txt", "mimeType": "text/plain", "base64": "YWxwaGE="}]}),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while read(&a, &target) != "hidden: a.txt=alpha" {
        assert!(Instant::now() < deadline, "a's files never arrived: {}", read(&a, &target));
        std::thread::sleep(Duration::from_millis(20));
    }
    // a keeps the tab; b handles its choosers, so the next one is b's, and
    // b's end cancels it.
    a.call("tab.keep", &json!({"targetId": target})).unwrap();
    b.call("tab.handleEvents", &json!({"targetId": target, "events": ["filechooser"]})).unwrap();
    click(&a, &target);
    let second = chooser_event(&b_events, &a_events);
    assert_ne!(second.payload["chooserId"], chooser, "a new chooser");
    b.end_session();
    drop(b);
    let deadline = Instant::now() + Duration::from_secs(5);
    while read(&a, &target) != "hidden: cancel" {
        assert!(Instant::now() < deadline, "b's end left the chooser open: {}", read(&a, &target));
        std::thread::sleep(Duration::from_millis(20));
    }
}
