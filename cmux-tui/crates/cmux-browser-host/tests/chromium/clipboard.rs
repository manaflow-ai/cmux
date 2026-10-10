//! The per-tab virtual clipboard on the shared headless browser (parity 19,
//! driver-protocol.md `clipboard.read` / `clipboard.write`): Meta+C, Meta+X
//! and Meta+V run Copy, Cut and Paste against the tab's clipboard, never the
//! browser's; a dialog during the command is dismissed and reported; a
//! command the page does not finish within 5 s fails with `timeout`; a
//! user's tab refuses them. A module of the `chromium` test target.

use super::files::{chrome, eval_in};
use super::*;

/// `/clip`: a field to copy from (`#keys`) and one to paste into (`#clip`),
/// which records whether each `input` event is trusted.
pub fn clip_page() -> String {
    "<!doctype html><title>Clip</title><input id=keys><input id=clip>\
     <script>window.inputs = []; document.getElementById('clip')\
       .addEventListener('input', (e) => inputs.push(e.isTrusted)); window.ready = true;</script>"
        .to_owned()
}

fn run(name: &str, code: &str) -> String {
    let chrome = chrome();
    let dir = std::env::temp_dir().join(format!("cmux-host-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("host.sock");
    // The test's own host: stopped (exact PID) when the test ends, also on failure.
    let _host = HostGuard::start(&socket, &chrome);
    let out = eval_in(&socket, &dir, &chrome, "a", code);
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
    out
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn the_tab_clipboard_copies_cuts_and_pastes_on_headless() {
    let port = serve();
    let out = run(
        "clip",
        &format!(
            "const keys = page.locator('#keys'); \
             await page.goto('http://127.0.0.1:{port}/clip'); \
             await page.clipboard.writeText('clip text'); \
             console.log('read=' + await page.clipboard.readText()); \
             await page.locator('#clip').click(); await page.keyboard.press('Meta+v'); \
             console.log('pasted=' + await page.locator('#clip').inputValue() + ' trusted=' + await page.evaluate(() => inputs.join())); \
             await keys.fill('copy me'); await keys.selectText(); await page.keyboard.press('Meta+c'); \
             console.log('copied=' + await page.clipboard.readText()); \
             await page.keyboard.press('Meta+x'); \
             console.log('cut=' + await page.clipboard.readText() + '|' + await keys.inputValue()); \
             await page.evaluate(() => document.getElementById('keys').addEventListener('copy', (e) => {{ \
               e.clipboardData.setData('text/plain', 'custom'); e.clipboardData.setData('text/html', '<b>x</b>'); e.preventDefault(); }})); \
             await keys.fill('abc'); await keys.selectText(); await page.keyboard.press('Meta+c'); \
             console.log('custom=' + JSON.stringify((await page.clipboard.read()).map((i) => [i.type, i.data.toString()]))); \
             await page.evaluate(() => addEventListener('keydown', (e) => {{ if (e.metaKey && e.key === 'c') e.preventDefault(); }})); \
             await page.clipboard.writeText('kept'); await keys.selectText(); await page.keyboard.press('Meta+c'); \
             console.log('prevented=' + await page.clipboard.readText()); \
             await page.evaluate(() => document.getElementById('keys').addEventListener('cut', (e) => {{ \
               e.clipboardData.setData('text/plain', 'after ' + String(confirm('cut?'))); e.preventDefault(); }})); \
             await keys.selectText(); await page.keyboard.press('Meta+x'); \
             console.log('confirm=' + await page.clipboard.readText() + ' held=' + !!page.dialog());"
        ),
    );
    for line in [
        "read=clip text",
        "pasted=clip text trusted=true",
        "copied=copy me",
        "cut=copy me|",
        "custom=[[\"text/plain\",\"custom\"],[\"text/html\",\"<b>x</b>\"]]",
        "prevented=kept",
        "confirm=after false held=false",
    ] {
        assert!(out.contains(line), "missing {line:?} in {out}");
    }
}

/// A Copy the page has not finished within 5 s fails with `timeout` and
/// leaves the tab's clipboard as it was; a user's tab (kept: no session
/// created it) refuses Copy, Cut and Paste before a key reaches the page.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_late_copy_times_out_and_a_users_tab_refuses_the_shortcuts() {
    let port = serve();
    let out = run(
        "clip-late",
        &format!(
            "const keys = page.locator('#keys'); \
             await page.goto('http://127.0.0.1:{port}/clip'); \
             await page.clipboard.writeText('before'); \
             await page.evaluate(() => document.getElementById('keys').addEventListener('copy', () => {{ \
               const end = Date.now() + 7000; while (Date.now() < end) {{}} }})); \
             await keys.fill('never'); await keys.selectText(); \
             const late = await page.keyboard.press('Meta+c').then(() => 'finished', (e) => e.code); \
             await page.waitForFunction(() => true, null, {{ timeout: 10000 }}); \
             console.log('late=' + late + ' ' + await page.clipboard.readText()); \
             await page.goto('http://127.0.0.1:{port}/clip'); await page.keep(); \
             const user = []; \
             for (const key of ['Meta+c', 'Meta+x', 'Meta+v']) user.push(await page.keyboard.press(key).then(() => 'ran', (e) => e.code + ':' + /in a user's tab/.test(e.message))); \
             console.log('user=' + user.join());"
        ),
    );
    for line in ["late=timeout before", "user=unsupported:true,unsupported:true,unsupported:true"] {
        assert!(out.contains(line), "missing {line:?} in {out}");
    }
}

/// `/leak`: page scripts that try to write the clipboard during an agent
/// click: the page's `navigator.clipboard` (`#api`), and a fresh iframe's
/// native API and `execCommand("copy")` (`#frame`). `#src` holds a control
/// value, `#sink` receives pastes, `#r` the scripts' outcomes.
pub fn leak_page() -> String {
    "<!doctype html><title>Leak</title>\
     <button id=api style=\"position:fixed;left:0;top:0;width:200px;height:60px\" \
       onclick=\"navigator.clipboard.writeText('leak-guarded').then(() => r('api ok'), (e) => r('api ' + e.name))\">api</button>\
     <button id=frame style=\"position:fixed;left:0;top:80px;width:200px;height:60px\" onclick=\"frameCopy()\">frame</button>\
     <input id=src value=control-value style=\"position:fixed;left:0;top:160px\">\
     <textarea id=sink style=\"position:fixed;left:0;top:200px\"></textarea><p id=r style=\"position:fixed;left:0;top:260px\"></p>\
     <script>window.r = (t) => { document.getElementById('r').textContent += t + ';'; };\
       window.frameCopy = () => { const f = document.createElement('iframe'); document.body.append(f);\
         const d = f.contentDocument; const t = d.createElement('textarea'); t.value = 'leak-exec'; d.body.append(t); t.select();\
         const ok = d.execCommand('copy');\
         f.contentWindow.navigator.clipboard.writeText('leak-frame').then(() => r('frame ok ' + ok), (e) => r('frame ' + e.name + ' ' + ok)); };\
       window.ready = true;</script>"
        .to_owned()
}

/// Page scripts in a tab of a browser the host owns never reach the
/// browser's clipboard (the system's, or X11 on Xvfb), also during an
/// agent click: the page clipboard guard sends `navigator.clipboard`
/// writes to the tab's clipboard, the browser refuses the clipboard
/// permissions, and the raw `cdp` method refuses clipboard commands.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn page_scripts_never_reach_the_browser_clipboard() {
    let port = serve();
    let chromium =
        HeadlessChromium::launch(&HeadlessOptions::new(chrome().into())).expect("launch Chromium");
    let conn = chromium.connection().clone();
    let driver = CdpDriver::attach_browser(conn.clone(), AGENT, Arc::new(|_| {}))
        .expect("attach to Chromium");
    let call = |method: &str, params: Value| -> Value {
        driver.call(method, &params).unwrap_or_else(|error| panic!("{method}: {error}"))
    };
    let target =
        call("tabs.open", json!({"url": format!("http://127.0.0.1:{port}/leak")}))["targetId"]
            .as_str()
            .unwrap()
            .to_owned();
    let eval = |source: &str| {
        call("frame.evaluate", json!({"targetId": target, "world": "page", "source": source}))
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    while driver
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
    // The test's own CDP session: what is on the browser's clipboard shows
    // in a paste (the browser's own command, not the driver's).
    let raw = conn
        .call(
            None,
            "Target.attachToTarget",
            json!({"targetId": target, "flatten": true}),
            Duration::from_secs(5),
        )
        .unwrap()["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let command = |name: &str| {
        conn.call(
            Some(&raw),
            "Input.dispatchKeyEvent",
            json!({"type": "keyDown", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65, "commands": [name]}),
            Duration::from_secs(5),
        )
        .unwrap();
        conn.call(
            Some(&raw),
            "Input.dispatchKeyEvent",
            json!({"type": "keyUp", "key": "a", "code": "KeyA", "windowsVirtualKeyCode": 65}),
            Duration::from_secs(5),
        )
        .unwrap();
    };
    let pasted = || -> String {
        eval("() => { const s = document.getElementById('sink'); s.value = ''; s.focus(); }");
        command("paste");
        eval("() => document.getElementById('sink').value").as_str().unwrap_or("").to_owned()
    };
    // Control: the browser's clipboard works and holds the control value.
    eval("() => { const s = document.getElementById('src'); s.focus(); s.select(); }");
    command("copy");
    assert_eq!(pasted(), "control-value", "the paste channel works");
    // The page's writes during agent clicks.
    let click = |y: i64| {
        call("input.mouse", json!({"targetId": target, "type": "move", "x": 50, "y": y}));
        for kind in ["down", "up"] {
            call(
                "input.mouse",
                json!({"targetId": target, "type": kind, "x": 50, "y": y, "button": "left", "clickCount": 1}),
            );
        }
    };
    click(30);
    click(110);
    let deadline = Instant::now() + Duration::from_secs(5);
    let outcomes = loop {
        let text = eval("() => document.getElementById('r').textContent");
        let text = text.as_str().unwrap_or("").to_owned();
        if text.matches(';').count() >= 2 {
            break text;
        }
        assert!(Instant::now() < deadline, "the page's writes did not finish: {text}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(
        pasted(),
        "control-value",
        "a page write reached the browser's clipboard: {outcomes}"
    );
    // The guard sent the page's writes (also the fresh iframe's: the guard
    // runs there too) to the tab's clipboard; the last one is there.
    let tab = call("clipboard.read", json!({"targetId": target}));
    let text = tab["items"]
        .as_array()
        .and_then(|items| items.iter().find(|i| i["type"] == "text/plain"))
        .and_then(|i| i["base64"].as_str())
        .and_then(cmux_browser_host::fs_sandbox::base64_decode)
        .map(|bytes| String::from_utf8_lossy(&bytes).into_owned());
    assert!(
        matches!(text.as_deref(), Some("leak-guarded" | "leak-exec" | "leak-frame")),
        "{tab} {outcomes}"
    );
    // The agent's raw CDP cannot run the browser's clipboard commands.
    for name in ["copy", "cut", "paste"] {
        let refused = driver
            .call(
                "cdp",
                &json!({"targetId": target, "method": "Input.dispatchKeyEvent",
                    "params": {"type": "keyDown", "key": "a", "commands": [name]}}),
            )
            .unwrap_err();
        assert_eq!(refused.code, ErrorCode::Forbidden, "{name}: {refused:?}");
    }
}
