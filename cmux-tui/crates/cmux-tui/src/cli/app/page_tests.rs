//! `cmux browser <tab_…|page> <verb>`: the page verbs that the app's
//! `browser.page.*` methods serve (CmuxNextControl BrowserPageService).

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

use super::tests::{args, call, fake_app, global_for};
use super::*;

fn call_timeout(command: &AppCommand) -> Option<Duration> {
    match command {
        AppCommand::Call { timeout, .. } => *timeout,
        _ => panic!("expected a call"),
    }
}

fn scratch_dir() -> PathBuf {
    let name = super::super::command::random_prefixed("t").unwrap();
    std::env::temp_dir().join(format!("cmux-shot-{name}"))
}

#[test]
fn page_waits_take_one_condition_and_the_cli_outwaits_their_timeout() {
    let command = parse(&args(&["browser", "tab_01ab", "wait", "#done", "--timeout-ms", "20000"]))
        .unwrap()
        .unwrap();
    // The app answers by the wait's own deadline; the CLI waits 5 s longer.
    assert_eq!(call_timeout(&command), Some(Duration::from_secs(25)));
    let (method, params) = call(command);
    assert_eq!(method, "browser.page.wait");
    assert_eq!(params, json!({ "tab": "tab_01ab", "selector": "#done", "timeout_ms": 20000 }));
    let (_, params) = call(
        parse(&args(&[
            "browser",
            "page",
            "wait",
            "--url-contains",
            "/done",
            "--load-state",
            "complete",
            "--timeout",
            "1.5",
        ]))
        .unwrap()
        .unwrap(),
    );
    assert_eq!(
        params,
        json!({ "url_contains": "/done", "load_state": "complete", "timeout_ms": 1500 })
    );
    // No condition: the app waits for the document to load, 5 s by default.
    let command = parse(&args(&["browser", "page", "wait"])).unwrap().unwrap();
    assert_eq!(call_timeout(&command), Some(Duration::from_secs(10)));
    assert_eq!(call(command).1, json!({}));
    assert!(parse(&args(&["browser", "page", "wait", "#a", "#b"])).is_err());
    assert!(parse(&args(&["browser", "page", "wait", "--timeout-ms", "soon"])).is_err());
}

#[test]
fn a_screenshot_asks_for_its_scope_and_writes_the_png_to_out() {
    let png = [0x89, b'P', b'N', b'G', 0, 1];
    let response = json!({ "id": 1, "ok": true, "result": {
        "tab": "tab_01ab", "png_base64": BASE64.encode(png), "width": 1, "height": 1 } });
    let (socket, app) = fake_app(vec![response]);
    let dir = scratch_dir();
    let out = dir.join("nested").join("shot.png");
    let words = [
        "browser",
        "tab_01ab",
        "screenshot",
        "--selector",
        "#hero",
        "--out",
        out.to_str().unwrap(),
    ];
    let command = parse(&args(&words)).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    assert_eq!(std::fs::read(&out).unwrap(), png);
    let connections = app.join().unwrap();
    assert_eq!(connections[0][0]["method"], "browser.page.screenshot");
    assert_eq!(connections[0][0]["params"]["tab"], "tab_01ab");
    assert_eq!(connections[0][0]["params"]["selector"], "#hero");
    let _ = std::fs::remove_dir_all(&dir);

    // --full-page asks for the whole page; it and --selector exclude each other.
    let response = json!({ "id": 1, "ok": true, "result": {
        "png_base64": BASE64.encode(png), "width": 1, "height": 1 } });
    let (socket, app) = fake_app(vec![response]);
    let dir = scratch_dir();
    let out = dir.join("full.png");
    let words = ["browser", "page", "screenshot", "--full-page", "--out", out.to_str().unwrap()];
    assert_eq!(run(&global_for(&socket), parse(&args(&words)).unwrap().unwrap()), 0);
    assert_eq!(app.join().unwrap()[0][0]["params"]["full_page"], true);
    let _ = std::fs::remove_dir_all(&dir);
    let both = ["browser", "page", "screenshot", "--selector", "#a", "--full-page"];
    assert!(parse(&args(&both)).is_err());
    assert!(parse(&args(&["browser", "page", "screenshot", "shot.png"])).is_err());
}

#[test]
fn a_large_screenshot_comes_as_the_apps_file_and_bad_image_data_fails() {
    let png = [0x89, b'P', b'N', b'G', 0, 1];
    let dir = scratch_dir();
    std::fs::create_dir_all(&dir).unwrap();
    let saved = dir.join("app.png");
    std::fs::write(&saved, png).unwrap();
    let response = json!({ "id": 1, "ok": true, "result": {
        "tab": "tab_01ab", "path": saved.to_str().unwrap(), "width": 1, "height": 1 } });

    // --out copies the app's file.
    let (socket, app) = fake_app(vec![response.clone()]);
    let copy = dir.join("copy.png");
    let words = ["browser", "page", "screenshot", "--out", copy.to_str().unwrap()];
    assert_eq!(run(&global_for(&socket), parse(&args(&words)).unwrap().unwrap()), 0);
    assert_eq!(std::fs::read(&copy).unwrap(), png);
    app.join().unwrap();

    // --out naming the app's own file leaves it whole.
    let (socket, app) = fake_app(vec![response]);
    let words = ["browser", "page", "screenshot", "--out", saved.to_str().unwrap()];
    assert_eq!(run(&global_for(&socket), parse(&args(&words)).unwrap().unwrap()), 0);
    assert_eq!(std::fs::read(&saved).unwrap(), png);
    app.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);

    let broken = json!({ "id": 1, "ok": true, "result": { "png_base64": "not base64!" } });
    let (socket, app) = fake_app(vec![broken]);
    let words = ["browser", "page", "screenshot", "--out", "-"];
    assert_eq!(run(&global_for(&socket), parse(&args(&words)).unwrap().unwrap()), 3);
    app.join().unwrap();
}

fn tab_page(words: &[&str]) -> Result<(&'static str, Value), UsageError> {
    let mut all = vec!["browser", "tab_01ab"];
    all.extend_from_slice(words);
    parse(&args(&all)).map(|command| call(command.unwrap()))
}

#[test]
fn cookies_and_storage_take_the_old_cli_forms() {
    let (method, params) = tab_page(&["cookies"]).unwrap();
    assert_eq!(method, "browser.page.cookies.get");
    assert_eq!(params, json!({ "tab": "tab_01ab" }));
    let (method, params) =
        tab_page(&["cookies", "get", "--name", "sid", "--domain=example"]).unwrap();
    assert_eq!(method, "browser.page.cookies.get");
    assert_eq!(params, json!({ "tab": "tab_01ab", "name": "sid", "domain": "example" }));
    let (method, params) = tab_page(&[
        "cookies",
        "set",
        "sid",
        "1",
        "--url",
        "https://cmux.com/",
        "--expires",
        "1900000000",
        "--secure",
        "--http-only",
    ])
    .unwrap();
    assert_eq!(method, "browser.page.cookies.set");
    assert_eq!(
        params,
        json!({ "tab": "tab_01ab", "name": "sid", "value": "1", "url": "https://cmux.com/",
                "expires": 1_900_000_000, "secure": true, "http_only": true })
    );
    let (_, params) = tab_page(&["cookies", "set", "--name", "a", "--value", "b"]).unwrap();
    assert_eq!(params, json!({ "tab": "tab_01ab", "name": "a", "value": "b" }));
    let (method, params) = tab_page(&["cookies", "clear", "--all"]).unwrap();
    assert_eq!(method, "browser.page.cookies.clear");
    assert_eq!(params, json!({ "tab": "tab_01ab", "all": true }));
    for bad in [
        &["cookies", "set", "sid"][..],
        &["cookies", "set", "a", "b", "--expires", "soon"],
        &["cookies", "get", "--all"],
        &["cookies", "get", "extra"],
        &["cookies", "eat"],
    ] {
        assert!(tab_page(bad).is_err(), "{bad:?}");
    }

    let (method, params) = tab_page(&["storage", "session", "get", "theme"]).unwrap();
    assert_eq!(method, "browser.page.storage.get");
    assert_eq!(params, json!({ "tab": "tab_01ab", "type": "session", "key": "theme" }));
    let (method, params) = tab_page(&["storage", "set", "theme", "dark"]).unwrap();
    assert_eq!(method, "browser.page.storage.set");
    assert_eq!(params, json!({ "tab": "tab_01ab", "key": "theme", "value": "dark" }));
    let (method, params) = tab_page(&["storage", "local", "clear"]).unwrap();
    assert_eq!(method, "browser.page.storage.clear");
    assert_eq!(params, json!({ "tab": "tab_01ab", "type": "local" }));
    assert_eq!(tab_page(&["storage"]).unwrap().0, "browser.page.storage.get");
    assert!(tab_page(&["storage", "local", "set", "k"]).is_err());
    assert!(tab_page(&["storage", "cookies"]).is_err());
}
