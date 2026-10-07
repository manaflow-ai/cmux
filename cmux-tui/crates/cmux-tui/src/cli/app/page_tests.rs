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

#[test]
fn input_verbs_take_the_old_cli_forms() {
    assert_eq!(
        tab_page(&["press", "Enter"]).unwrap(),
        ("browser.page.press", json!({ "tab": "tab_01ab", "key": "Enter" }))
    );
    assert_eq!(
        tab_page(&["press", "Space", "--selector", "#agree"]).unwrap(),
        ("browser.page.press", json!({ "tab": "tab_01ab", "key": "Space", "selector": "#agree" }))
    );
    assert_eq!(
        tab_page(&["hover", "#menu"]).unwrap(),
        ("browser.page.hover", json!({ "tab": "tab_01ab", "selector": "#menu" }))
    );
    assert_eq!(
        tab_page(&["scroll-into-view", "e4"]).unwrap(),
        ("browser.page.scroll_into_view", json!({ "tab": "tab_01ab", "selector": "e4" }))
    );
    assert_eq!(
        tab_page(&["select", "#size", "m"]).unwrap(),
        ("browser.page.select", json!({ "tab": "tab_01ab", "selector": "#size", "value": "m" }))
    );
    assert_eq!(tab_page(&["check", "#a"]).unwrap().0, "browser.page.check");
    assert_eq!(tab_page(&["uncheck", "#a"]).unwrap().0, "browser.page.uncheck");
    assert_eq!(
        tab_page(&["scroll", "--dy", "400"]).unwrap(),
        ("browser.page.scroll", json!({ "tab": "tab_01ab", "dy": 400.0 }))
    );
    assert_eq!(
        tab_page(&["scroll", "#list", "--dx=-50"]).unwrap(),
        ("browser.page.scroll", json!({ "tab": "tab_01ab", "selector": "#list", "dx": -50.0 }))
    );
    // The old CLI's flag forms, flags first, and `scroll N`.
    assert_eq!(
        tab_page(&["press", "--selector", "#q", "--key", "Enter"]).unwrap(),
        ("browser.page.press", json!({ "tab": "tab_01ab", "key": "Enter", "selector": "#q" }))
    );
    assert_eq!(tab_page(&["key", "Tab"]).unwrap().0, "browser.page.press");
    assert_eq!(
        tab_page(&["select", "--selector", "#size", "--value", "m"]).unwrap(),
        ("browser.page.select", json!({ "tab": "tab_01ab", "selector": "#size", "value": "m" }))
    );
    assert_eq!(
        tab_page(&["scrollintoview", "--selector", "#f"]).unwrap(),
        ("browser.page.scroll_into_view", json!({ "tab": "tab_01ab", "selector": "#f" }))
    );
    assert_eq!(
        tab_page(&["scroll", "400"]).unwrap(),
        ("browser.page.scroll", json!({ "tab": "tab_01ab", "dy": 400.0 }))
    );
    assert_eq!(
        tab_page(&["scroll", "--dy", "-50", "#list"]).unwrap(),
        ("browser.page.scroll", json!({ "tab": "tab_01ab", "selector": "#list", "dy": -50.0 }))
    );
    for bad in [
        &["press"][..],
        &["scroll", "--dy", "inf"],
        &["scroll", "--dx", "NaN"],
        &["press", "a", "b"],
        &["press", "a", "--dy", "1"],
        &["scroll"],
        &["scroll", "--dy", "far"],
        &["scroll", "#a", "--selector", "#b", "--dy", "1"],
        &["select", "#size"],
        &["check"],
        &["hover", "#a", "--force"],
    ] {
        assert!(tab_page(bad).is_err(), "{bad:?}");
    }
}

#[test]
fn browser_tab_verbs_list_open_select_and_close_app_tabs() {
    let (method, params) =
        call(parse(&args(&["browser", "page", "tabs", "--all"])).unwrap().unwrap());
    assert_eq!(method, "browser.page.tabs");
    assert_eq!(params, json!({ "all": true }));
    // Open, select and close wait for the app's action unless --no-wait.
    let command =
        parse(&args(&["browser", "tab_01ab", "new-tab", "https://cmux.com"])).unwrap().unwrap();
    assert_eq!(call_timeout(&command), Some(WAITING_RUN_TIMEOUT));
    assert_eq!(
        call(command),
        ("browser.page.new_tab", json!({ "tab": "tab_01ab", "url": "https://cmux.com" }))
    );
    assert_eq!(
        call(parse(&args(&["browser", "page", "new-tab"])).unwrap().unwrap()),
        ("browser.page.new_tab", json!({}))
    );
    assert_eq!(
        call(parse(&args(&["browser", "tab_01ab", "switch"])).unwrap().unwrap()),
        ("browser.page.switch", json!({ "tab": "tab_01ab" }))
    );
    // `select` with no selector is not a tab verb: it picks a form option.
    assert!(parse(&args(&["browser", "tab_01ab", "select"])).is_err());
    assert_eq!(
        call(parse(&args(&["browser", "tab_01ab", "close"])).unwrap().unwrap()),
        ("browser.page.close", json!({ "tab": "tab_01ab" }))
    );
    assert!(parse(&args(&["browser", "page", "close", "tab_02"])).is_err());
    assert!(parse(&args(&["browser", "page", "tabs", "--bogus"])).is_err());
    let command = parse(&args(&["browser", "tab_01ab", "close", "--no-wait"])).unwrap().unwrap();
    assert_eq!(call_timeout(&command), Some(READ_TIMEOUT));
    assert_eq!(call(command), ("browser.page.close", json!({ "tab": "tab_01ab", "wait": false })));
    assert!(parse(&args(&["browser", "tab_01ab", "switch", "--all"])).is_err());
}

/// A retried open, select or close is one run: each carries a key.
#[test]
fn browser_tab_runs_carry_an_idempotency_key() {
    let response =
        json!({ "id": 1, "ok": true, "result": { "ran": true, "created": ["tab_02cd"] } });
    let (socket, app) = fake_app(vec![response]);
    let command =
        parse(&args(&["browser", "page", "new-tab", "https://cmux.com"])).unwrap().unwrap();
    assert_eq!(run(&global_for(&socket), command), 0);
    let connections = app.join().unwrap();
    let [request] = connections[0].as_slice() else { panic!("{connections:?}") };
    assert_eq!(request["method"], "browser.page.new_tab");
    assert!(request["params"]["idempotency_key"].as_str().is_some_and(|key| !key.is_empty()));
}
