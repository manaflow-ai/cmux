//! A `window.open` popup that keeps its opener starts on an initial
//! `about:blank` that is same-origin with its first page, so the browser
//! keeps the window object for that page (HTML: the initial about:blank's
//! global is reused). The page agent installed on `about:blank` must not
//! answer for the new document: locators, clicks and `window.close()` work
//! in the popup as in any tab (differential case edge.window-open). A module
//! of the `chromium` test target.

use super::files::{chrome, eval_in};
use super::*;

/// `/opener`: buttons that open `/popup` with and without an opener.
pub fn opener_page() -> String {
    "<!doctype html><title>Opener</title>\
     <button id=features onclick=\"window.open('/popup', 'feat', 'width=400,height=300')\">With opener</button>\
     <button id=noopener onclick=\"window.open('/popup', '_blank', 'noopener')\">No opener</button>"
        .to_owned()
}

/// `/popup`: names whether it has an opener and closes itself on a click.
pub fn popup_page() -> String {
    "<!doctype html><title>Popup</title><p id=opener></p><button id=close onclick=\"window.close()\">Close</button>\
     <script>document.getElementById('opener').textContent = 'opener ' + (window.opener ? 'present' : 'null');</script>"
        .to_owned()
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_popup_that_keeps_its_opener_is_driven_like_any_tab() {
    let chrome = chrome();
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-popups-{}", std::process::id()));
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
            "await page.goto('http://127.0.0.1:{port}/opener'); \
             for (const button of ['#features', '#noopener']) {{ \
               const opened = page.waitForEvent('popup'); \
               await page.locator(button).click(); \
               const popup = await opened; await popup.waitForLoadState(); \
               console.log(button + '=' + await popup.locator('#opener').innerText({{timeout: 5000}})); \
               const closed = new Promise((resolve) => popup.once('close', () => resolve(true))); \
               await popup.locator('#close').click({{timeout: 5000}}); \
               console.log(button + ' closed=' + await Promise.race([closed, new Promise((r) => setTimeout(() => r(false), 3000))])); \
             }}"
        ),
    );
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
    for line in [
        "#features=opener present",
        "#features closed=true",
        "#noopener=opener null",
        "#noopener closed=true",
    ] {
        assert!(out.contains(line), "missing {line:?} in {out}");
    }
}
