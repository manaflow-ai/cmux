//! Undoable cookie clears through the whole host (private data P2;
//! Lawrence via ff, 2026-10-07): clearCookies() backs up what it deletes in
//! an encrypted 0600 file in the host state directory and returns restore
//! ids; restoreCookies() puts the cookies back (a cookie set since the clear
//! is kept) and removes the backup. A module of the `chromium` test target.

use super::*;

/// `cmux-browser-host serve` with its own state directory; stopped (exact
/// PID) when the test ends, also on failure.
struct StateHost(std::process::Child);

impl Drop for StateHost {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[cfg(unix)]
fn mode(path: &std::path::Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_cookie_clear_is_backed_up_encrypted_and_restored() {
    let binary = std::env::var("CMUX_BROWSER_HOST_TEST_CHROME")
        .ok()
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let dir = std::env::temp_dir().join(format!("cmux-cookie-undo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let state = dir.join("state");
    let socket = dir.join("host.sock");
    let _host = StateHost(
        std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
            .args(["serve", "--socket"])
            .arg(&socket)
            .env("CMUX_BROWSER_HOST_CHROMIUM", &binary)
            .env("CMUX_BROWSER_HOST_STATE_DIR", &state)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("start cmux-browser-host serve"),
    );
    let deadline = Instant::now() + Duration::from_secs(10);
    while std::os::unix::net::UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "the test host never listened");
        std::thread::sleep(Duration::from_millis(20));
    }
    let eval = |code: &str| -> String {
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"))
            .args(["eval", "--session", "cookie-undo", "--engine", "headless", "--socket"])
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
    let line = |out: &str, tag: &str| -> String {
        out.lines()
            .find_map(|l| l.strip_prefix(tag))
            .unwrap_or_else(|| panic!("no {tag} in {out}"))
            .to_owned()
    };

    let cleared = eval(&format!(
        "await page.goto('http://127.0.0.1:{port}/second');
         await page.evaluate(() => {{ document.cookie = 'sid=s3cret-cookie-1; max-age=3600'; document.cookie = 'keep=old; max-age=3600'; }});
         const r = await page.context().clearCookies();
         console.log('CLEAR:' + JSON.stringify(r));
         console.log('AFTER:' + await page.evaluate(() => document.cookie));
         console.log('NAV:' + JSON.stringify(session.blockedNavigations()));"
    ));
    let result: Value = serde_json::from_str(&line(&cleared, "CLEAR:")).unwrap();
    let ids = result["restoreIds"].as_array().cloned().unwrap_or_default();
    assert_eq!(ids.len(), 1, "one restore id: {cleared}");
    assert!(ids[0].as_str().unwrap().starts_with("host:"), "{cleared}");
    assert_eq!(line(&cleared, "AFTER:"), "", "the site's cookies are cleared");
    // The clear's policy-log entry is not a blocked navigation.
    assert_eq!(line(&cleared, "NAV:"), "[]", "{cleared}");

    // The backup: one 0600 file that holds no cookie value in the clear,
    // and a separate 0600 key file.
    let files: Vec<_> = std::fs::read_dir(state.join("cookie-backups"))
        .expect("the backup directory")
        .flatten()
        .map(|entry| entry.path())
        .collect();
    assert_eq!(files.len(), 1, "{files:?}");
    let bytes = std::fs::read(&files[0]).unwrap();
    assert!(
        !String::from_utf8_lossy(&bytes).contains("s3cret-cookie-1"),
        "the backup is encrypted"
    );
    assert_eq!(mode(&files[0]), 0o600);
    assert_eq!(mode(&state.join("cookie-backup.key")), 0o600);

    let restored = eval(&format!(
        "await page.evaluate(() => {{ document.cookie = 'keep=new; max-age=3600'; }});
         console.log('RESTORE:' + JSON.stringify(await page.context().restoreCookies({})));
         console.log('NOW:' + await page.evaluate(() => document.cookie.split('; ').sort().join('; ')));",
        serde_json::to_string(&result).unwrap()
    ));
    let summary: Value = serde_json::from_str(&line(&restored, "RESTORE:")).unwrap();
    assert_eq!(summary, json!({"restored": 1, "kept": 1, "expired": 0}), "{restored}");
    assert_eq!(line(&restored, "NOW:"), "keep=new; sid=s3cret-cookie-1", "a newer cookie is kept");
    assert_eq!(
        std::fs::read_dir(state.join("cookie-backups")).unwrap().count(),
        0,
        "restored once"
    );

    let again = eval(&format!(
        "try {{ await page.context().restoreCookies({}); console.log('AGAIN:restored'); }} catch (e) {{ console.log('AGAIN:' + e.message); }}",
        serde_json::to_string(&result).unwrap()
    ));
    assert!(line(&again, "AGAIN:").contains("no cookie backup"), "{again}");
    let mut close = std::process::Command::new(env!("CARGO_BIN_EXE_cmux-browser-host"));
    let _ = close.args(["close", "--session", "cookie-undo", "--socket"]).arg(&socket).output();
    let _ = std::fs::remove_dir_all(&dir);
}
