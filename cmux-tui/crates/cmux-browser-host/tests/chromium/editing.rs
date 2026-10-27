//! The REPL keyboard is macOS's on every engine and platform: the runtime
//! maps ControlOrMeta to Meta, so Meta+A selects all, Meta+Z undoes and
//! Meta+B/I/U format rich text also where Chromium's own key bindings are
//! Control based (Linux). A page that handles the key itself keeps it.
//! Classic cmux did the same (BrowserReplFrameGate+EditingShortcut and
//! +FormattingShortcut). A module of the `chromium` test target.

use super::files::{chrome, eval_in};
use super::*;

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

/// `/editing`: a field, a rich text editor, and an editor whose page takes
/// every Meta key itself (`preventDefault`).
pub fn editing_page() -> String {
    "<!doctype html><title>Editing</title><input id=keys>\
     <div id=rich contenteditable>alpha beta</div><div id=own contenteditable>mine</div>\
     <script>document.getElementById('own').addEventListener('keydown', (e) => { if (e.metaKey) e.preventDefault(); });</script>"
        .to_owned()
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn mac_editing_and_formatting_shortcuts_work_on_every_platform() {
    let port = serve();
    let out = run(
        "editing",
        &format!(
            "await page.goto('http://127.0.0.1:{port}/editing'); \
             const keys = page.locator('#keys'); \
             await keys.fill('hello world'); await keys.press('Meta+a'); \
             await page.keyboard.press('Backspace'); await page.keyboard.type('x'); \
             console.log('select-all=' + await keys.inputValue()); \
             await keys.fill('again'); await keys.press('ControlOrMeta+a'); await page.keyboard.type('y'); \
             console.log('control-or-meta=' + await keys.inputValue()); \
             await page.keyboard.press('Meta+z'); \
             console.log('undo=' + await keys.inputValue()); \
             const rich = page.locator('#rich'); await rich.click(); \
             await page.keyboard.press('Meta+a'); await page.keyboard.press('Meta+b'); \
             await page.keyboard.press('Meta+i'); await page.keyboard.press('Meta+u'); \
             await page.keyboard.press('ArrowRight'); await page.keyboard.type(' end'); \
             console.log('bold=' + await rich.evaluate((e) => (e.querySelector('b,strong') || {{}}).textContent || '')); \
             console.log('italic=' + await rich.evaluate((e) => !!e.querySelector('i,em'))); \
             console.log('underline=' + await rich.evaluate((e) => !!e.querySelector('u'))); \
             const own = page.locator('#own'); await own.click(); \
             await page.keyboard.press('Meta+a'); await page.keyboard.press('Meta+b'); \
             console.log('page-kept=' + await own.evaluate((e) => e.innerHTML));"
        ),
    );
    for line in [
        "select-all=x",
        "control-or-meta=y",
        "undo=again",
        "bold=alpha beta end",
        "italic=true",
        "underline=true",
        "page-kept=mine",
    ] {
        assert!(out.contains(line), "missing {line:?} in {out}");
    }
}
