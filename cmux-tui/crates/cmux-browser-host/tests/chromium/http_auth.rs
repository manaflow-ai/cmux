//! An HTTP sign-in (401 with `WWW-Authenticate`) on a tab nobody watches:
//! cmux never types a password for an agent, so the navigation fails with
//! a message that says the site wants a sign-in and that the person signs
//! in, instead of Chromium's bare `net::ERR_INVALID_AUTH_CREDENTIALS`.
//! Credentials the agent's own URL carries (`http://user:pass@host/`) still
//! answer the challenge, as in classic cmux (BrowserReplHTTPCredentials).
//! A module of the `chromium` test target.

use super::files::{chrome, eval_in};
use super::*;

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn an_http_sign_in_is_handed_to_the_person() {
    let chrome = chrome();
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-host-auth-{}", std::process::id()));
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
            "try {{ await page.goto('http://127.0.0.1:{port}/basic'); console.log('loaded'); }} \
             catch (e) {{ console.log('refused=' + e.message.split('\\n')[0]); }} \
             const r = await page.goto('http://user:pass@127.0.0.1:{port}/basic'); \
             console.log('url-credentials=' + r.status() + ' ' + await page.locator('#r').innerText());"
        ),
    );
    let mut stop = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = stop.args(["close", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
    let refused = format!(
        "refused=page.goto: http://127.0.0.1:{port}/basic asks for an HTTP sign-in (realm \"parity\"). \
         cmux never types a password for an agent: ask the person to sign in"
    );
    assert!(out.contains(&refused), "missing {refused:?} in {out}");
    assert!(out.contains("url-credentials=200 signed in"), "{out}");
}
