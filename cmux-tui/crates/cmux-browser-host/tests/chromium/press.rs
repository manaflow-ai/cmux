//! A click on a button the page re-renders faster than a person's press is
//! held lands: a press on a replaced target is never sent, and a click whose
//! target was replaced during the press is retried with an instant press
//! (differential case edge.detached-mid-click; classic cmux
//! BrowserReplPressTarget). A module of the `chromium` test target.

use super::files::{chrome, eval_in};
use super::*;

/// `/rerender`: a button replaced every 40 ms; each click counts in `#out`.
pub fn rerender_page() -> String {
    "<!doctype html><title>Rerender</title><div id=host></div><p id=out>idle</p><script>\
     let n = 0; const render = () => { document.getElementById('host').innerHTML = \
     '<button class=rerender onclick=\"document.getElementById(\\'out\\').textContent = \\'clicked \\' + ++n\">Again</button>'; }; \
     render(); setInterval(render, 40);</script>"
        .to_owned()
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_click_on_a_rerendering_button_lands() {
    let chrome = chrome();
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-press-{}", std::process::id()));
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
            "await page.goto('http://127.0.0.1:{port}/rerender'); \
             let landed = 0; \
             for (let i = 0; i < 5; i++) {{ \
               const before = await page.locator('#out').innerText(); \
               await page.locator('.rerender').click({{timeout: 5000}}); \
               if (await page.locator('#out').innerText() !== before) landed++; \
             }} \
             console.log('landed=' + landed);"
        ),
    );
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
    assert!(out.contains("landed=5"), "{out}");
}
