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
    for line in [
        "late=timeout before",
        "user=unsupported:true,unsupported:true,unsupported:true",
    ] {
        assert!(out.contains(line), "missing {line:?} in {out}");
    }
}
