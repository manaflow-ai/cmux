//! `open {live}`: a shown page file reloads its tab when the file changes.

use std::sync::{Arc, Mutex};

use super::*;

pub(super) const PANE: &str = "pane_00000000000000000000000000000007";
pub(super) const OLD_TAB: &str = "tab_0000000000000000000000000000000a";
pub(super) const NEW_TAB: &str = "tab_0000000000000000000000000000000b";
pub(super) const OLD_BROWSER: &str = "browser_0000000000000000000000000000000a";
pub(super) const NEW_BROWSER: &str = "browser_0000000000000000000000000000000b";

pub(super) fn open_actions() -> Value {
    let mut actions = fixture_actions();
    actions["actions"].as_array_mut().unwrap().push(json!({
        "id": "file.open", "title": "Open File", "cli_name": "file open", "cli": true,
        "targets": ["pane"], "arguments": [{"name": "path", "kind": "string", "required": false}],
        crate::app_identity::ACTION_SURFACE_PLAN: {"cli": "offered", "mcp": "offered"},
    }));
    actions
}

pub(super) fn tab(id: &str, browser: &str) -> Value {
    json!({"id": id, "pane_id": PANE, "name": null, "index": 0, "focused": false,
           "content_kind": "browser", "content_id": browser})
}

/// A server whose pane shows one browser tab before the open and two after it.
fn server(reloads: &Arc<Mutex<Vec<Value>>>) -> Server<Fake> {
    let before = json!([tab(OLD_TAB, OLD_BROWSER)]);
    let after = json!([tab(OLD_TAB, OLD_BROWSER), tab(NEW_TAB, NEW_BROWSER)]);
    let fake = Fake {
        actions: open_actions(),
        resource_result: Some(json!({"pane_id": PANE, "id": NEW_TAB})),
        tab_lists: RefCell::new([before, after].into()),
        reloads: Some(reloads.clone()),
        ..Fake::default()
    };
    Server::new(fake, None)
}

fn open(server: &mut Server<Fake>, arguments: Value) -> Value {
    let result = server.call(&json!({"name": "open", "arguments": arguments})).expect("a result");
    assert_ne!(result["isError"], true, "{result}");
    result
}

/// Waits for `count` reloads (bounded), then a quiet period longer than the debounce,
/// and answers every reload sent.
pub(super) fn reloads_after(reloads: &Arc<Mutex<Vec<Value>>>, count: usize) -> Vec<Value> {
    let deadline = Instant::now() + Duration::from_secs(10);
    while reloads.lock().unwrap().len() < count && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }
    settled(reloads)
}

/// Every reload sent, after a quiet period longer than the debounce.
fn settled(reloads: &Arc<Mutex<Vec<Value>>>) -> Vec<Value> {
    std::thread::sleep(live_file::QUIET * 4);
    reloads.lock().unwrap().clone()
}

/// A shown HTML file: the receipt says live, a burst of writes is one reload of the
/// tab the open made (not the pane's other tab), and a delete then recreate reloads again.
#[test]
fn a_shown_page_file_reloads_its_tab_once_per_burst_of_writes() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let path = folder.path().join("slides.html");
    std::fs::write(&path, "<section>1</section>").unwrap();
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let mut server = server(&reloads);
    let result = open(
        &mut server,
        json!({"kind": "file", "path": path.to_str().unwrap(), "where": "below"}),
    );
    assert_eq!(result["structuredContent"]["live"], true, "{result}");
    assert_eq!(result["structuredContent"]["live_browser"], NEW_BROWSER, "{result}");
    let watched = server.live_files.borrow().as_ref().map(|live| live.watched());
    assert_eq!(watched.map(|w| w.len()), Some(1));

    for slide in 2..8 {
        std::fs::write(&path, format!("<section>{slide}</section>")).unwrap();
    }
    let sent = reloads_after(&reloads, 1);
    assert_eq!(sent.len(), 1, "one reload for a burst: {sent:?}");
    assert_eq!(sent[0]["operation"], "browser.reload", "{}", sent[0]);
    assert_eq!(sent[0]["params"]["browser"], NEW_BROWSER, "{}", sent[0]);

    // An atomic replace (write a temp file, rename it over) is seen through the folder.
    let temporary = folder.path().join(".slides.html.tmp");
    std::fs::write(&temporary, "<section>9</section>").unwrap();
    std::fs::rename(&temporary, &path).unwrap();
    assert_eq!(reloads_after(&reloads, 2).len(), 2);

    // Deleted, the reload shows Chromium's "file not found"; recreated, it reloads again.
    std::fs::remove_file(&path).unwrap();
    assert_eq!(reloads_after(&reloads, 3).len(), 3);
    std::fs::write(&path, "<section>back</section>").unwrap();
    assert_eq!(reloads_after(&reloads, 4).len(), 4);

    // Another file in the folder is not this tab's.
    std::fs::write(folder.path().join("other.html"), "x").unwrap();
    assert_eq!(settled(&reloads).len(), 4);
}

/// A file the browser tab does not render (Markdown) is not watched, and neither is a
/// page or a diff; `live: false` turns the watch off for a page file.
#[test]
fn non_page_kinds_and_live_false_do_not_watch() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let notes = folder.path().join("notes.md");
    std::fs::write(&notes, "# notes").unwrap();
    let page = folder.path().join("page.html");
    std::fs::write(&page, "<p>").unwrap();
    let reloads = Arc::new(Mutex::new(Vec::new()));
    for arguments in [
        json!({"kind": "file", "path": notes.to_str().unwrap(), "where": "below"}),
        json!({"kind": "file", "path": page.to_str().unwrap(), "where": "below", "live": false}),
    ] {
        let mut server = server(&reloads);
        let result = open(&mut server, arguments);
        assert!(result["structuredContent"].get("live").is_none(), "{result}");
        assert!(server.live_files.borrow().is_none());
        let sent = server.backend.sent.borrow();
        let lists = sent.iter().filter(|s| s["request"]["operation"] == "tab.list").count();
        assert_eq!(lists, 0, "no tab lists without a watch: {sent:?}");
    }
    std::fs::write(&notes, "# changed").unwrap();
    std::fs::write(&page, "<p>changed").unwrap();
    assert!(settled(&reloads).is_empty());

    // A `live` that is not a boolean is refused.
    let mut server = server(&reloads);
    let result = server
        .call(&json!({"name": "open", "arguments": {"kind": "file", "path": "/a.html",
                                                     "live": "yes"}}))
        .expect("a result");
    assert_eq!(result["isError"], true, "{result}");
    assert!(live_file::renders_in_browser("/a/Deck.HTML"));
    assert!(live_file::renders_in_browser("chart.svg"));
    assert!(!live_file::renders_in_browser("notes.md"));
}

/// No new browser tab after the open (the viewer is not a page): the receipt says
/// `live: false` and nothing is watched.
#[test]
fn no_new_browser_tab_is_not_live() {
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let same = json!([tab(OLD_TAB, OLD_BROWSER)]);
    let fake = Fake {
        actions: open_actions(),
        resource_result: Some(json!({"pane_id": PANE, "id": NEW_TAB})),
        tab_lists: RefCell::new([same.clone(), same].into()),
        reloads: Some(reloads),
        ..Fake::default()
    };
    let mut server = Server::new(fake, None);
    let result =
        open(&mut server, json!({"kind": "file", "path": "/work/a.svg", "where": "below"}));
    assert_eq!(result["structuredContent"]["live"], false, "{result}");
    assert!(server.live_files.borrow().is_none());
}

/// At most `MAX_WATCHES` files are watched; the oldest is dropped.
#[test]
fn watches_are_bounded_and_drop_the_oldest() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let sender: live_file::Sender = {
        let reloads = reloads.clone();
        Arc::new(move |plan: RequestPlan| {
            reloads.lock().unwrap().push(request_value(&plan).unwrap());
            Ok(json!({}))
        })
    };
    let mut watches = live_file::Watches::start(sender).expect("a watcher");
    // Every file exists before any watch, so writing them reloads nothing.
    let paths: Vec<_> = (0..=live_file::MAX_WATCHES)
        .map(|index| folder.path().join(format!("{index}.html")))
        .collect();
    for path in &paths {
        std::fs::write(path, "x").unwrap();
    }
    for (index, path) in paths.iter().enumerate() {
        watches.add(path.to_str().unwrap(), &format!("browser_{index:032x}")).unwrap();
    }
    // The same file again stays one watch.
    let last = folder.path().join(format!("{}.html", live_file::MAX_WATCHES));
    watches
        .add(last.to_str().unwrap(), &format!("browser_{:032x}", live_file::MAX_WATCHES))
        .unwrap();
    let watched = watches.watched();
    assert_eq!(watched.len(), live_file::MAX_WATCHES, "{watched:?}");
    assert!(
        !watched.iter().any(|(_, browser)| browser == &format!("browser_{:032x}", 0)),
        "{watched:?}"
    );
    assert!(settled(&reloads).is_empty());
    std::fs::write(&paths[0], "changed").unwrap();
    assert!(settled(&reloads).is_empty(), "the dropped watch is gone");
    // A kept watch still reloads its own browser.
    std::fs::write(&paths[1], "changed").unwrap();
    let sent = reloads_after(&reloads, 1);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["params"]["browser"], format!("browser_{:032x}", 1), "{}", sent[0]);
}

/// One request to the deck viewer: the status line, the head, the body.
pub(super) fn fetch(
    port: u16,
    method: &str,
    target: &str,
    host: &str,
) -> (String, String, Vec<u8>) {
    use std::io::{Read as _, Write as _};
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).expect("the viewer");
    write!(stream, "{method} {target} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n")
        .unwrap();
    let mut bytes = Vec::new();
    stream.read_to_end(&mut bytes).unwrap();
    let split = bytes.windows(4).position(|w| w == b"\r\n\r\n").expect("a head");
    let head = String::from_utf8_lossy(&bytes[..split]).into_owned();
    let status = head.lines().next().unwrap_or_default().to_owned();
    (status, head, bytes[split + 4..].to_vec())
}

/// A .pptx opens as a browser tab on the loopback viewer: the page runs only its own
/// script and reaches only itself and the CDN, the deck's bytes come from the same token,
/// nothing else is served, a change reloads the tab, and a deleted deck is a 404 the page
/// shows as a notice.
#[test]
fn a_pptx_opens_in_the_loopback_deck_viewer_and_reloads() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let path = folder.path().join("Q4 <plan>.pptx");
    std::fs::write(&path, b"PK\x03\x04 first").unwrap();
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let mut actions = open_actions();
    actions["actions"].as_array_mut().unwrap().push(json!({
        "id": "openBrowser", "title": "New Browser Tab", "cli_name": "tab new-browser",
        "cli": true, "targets": ["tab"],
        "arguments": [{"name": "url", "kind": "string", "required": false}],
        crate::app_identity::ACTION_SURFACE_PLAN: {"cli": "offered", "mcp": "offered"},
    }));
    let before = json!([tab(OLD_TAB, OLD_BROWSER)]);
    let after = json!([tab(OLD_TAB, OLD_BROWSER), tab(NEW_TAB, NEW_BROWSER)]);
    let fake = Fake {
        actions,
        resource_result: Some(json!({"pane_id": PANE, "id": NEW_TAB})),
        // The shown tab the page opens beside, then the watch's before and after.
        tab_lists: RefCell::new([before.clone(), before, after].into()),
        reloads: Some(reloads.clone()),
        ..Fake::default()
    };
    let mut server = Server::new(fake, None);
    let result = open(
        &mut server,
        json!({"kind": "file", "path": path.to_str().unwrap(), "where": "below"}),
    );
    assert_eq!(result["structuredContent"]["live"], true, "{result}");
    assert_eq!(result["structuredContent"]["live_browser"], NEW_BROWSER, "{result}");
    let sent = server.backend.sent.borrow().clone();
    let run = sent.iter().find(|s| s["method"] == "action.run").expect("an action run");
    assert_eq!(run["params"]["target"], OLD_TAB, "{run}");
    let url = run["params"].to_string();
    let url = url.split("http://127.0.0.1:").nth(1).expect("a loopback url");
    let (port, rest) = url.split_once('/').unwrap();
    let port: u16 = port.parse().unwrap();
    let token = rest.split('/').next().unwrap();
    assert_eq!(token.len(), 32, "{rest}");
    let host = format!("127.0.0.1:{port}");

    let (status, head, body) = fetch(port, "GET", &format!("/{token}/"), &host);
    assert!(status.contains("200"), "{status}");
    let html = String::from_utf8(body).unwrap();
    assert!(html.contains("<title>Q4 &lt;plan&gt;.pptx</title>"), "the name is escaped");
    assert!(html.contains(pptx_view::RENDERER_URL) && html.contains(pptx_view::RENDERER_SRI));
    assert!(
        head.contains(&format!("script-src 'sha256-{}' blob:", pptx_view::script_hash(&html))),
        "{head}"
    );
    assert!(head.contains("connect-src 'self' https://cdn.jsdelivr.net;"), "{head}");
    assert!(html.len() < 8 * 1024, "the viewer page stays small: {}", html.len());

    let (status, _, body) = fetch(port, "GET", &format!("/{token}/deck.pptx"), &host);
    assert!(status.contains("200"), "{status}");
    assert_eq!(body, b"PK\x03\x04 first");
    // Nothing else: another token, another path, another host, a write.
    assert!(fetch(port, "GET", &format!("/{}/deck.pptx", "0".repeat(32)), &host).0.contains("404"));
    assert!(fetch(port, "GET", &format!("/{token}/../x"), &host).0.contains("404"));
    assert!(fetch(port, "GET", &format!("/{token}/"), "evil.test").0.contains("421"));
    assert!(fetch(port, "POST", &format!("/{token}/deck.pptx"), &host).0.contains("405"));
    let (status, head, body) = fetch(port, "HEAD", &format!("/{token}/deck.pptx"), &host);
    assert!(status.contains("200") && head.contains("Content-Length: 10") && body.is_empty());
    // A connection that sends nothing is closed unanswered (never a stray 400).
    let mut idle = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    idle.shutdown(std::net::Shutdown::Write).unwrap();
    let mut nothing = Vec::new();
    idle.read_to_end(&mut nothing).unwrap();
    assert!(nothing.is_empty(), "{}", String::from_utf8_lossy(&nothing));

    // A changed deck reloads its tab and serves the new bytes; a second open is the same page.
    std::fs::write(&path, b"PK\x03\x04 second").unwrap();
    let sent = reloads_after(&reloads, 1);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["params"]["browser"], NEW_BROWSER, "{}", sent[0]);
    assert_eq!(fetch(port, "GET", &format!("/{token}/deck.pptx"), &host).2, b"PK\x03\x04 second");
    let again = server.decks.borrow().as_ref().unwrap().url(&path, pptx_view::Kind::Pptx).unwrap();
    assert_eq!(again, format!("http://127.0.0.1:{port}/{token}/"));

    // Deleted: a reload, and the deck is a 404 the page shows as "was deleted or moved".
    std::fs::remove_file(&path).unwrap();
    assert_eq!(reloads_after(&reloads, 2).len(), 2);
    assert!(fetch(port, "GET", &format!("/{token}/deck.pptx"), &host).0.contains("404"));

    // A deck that is not there is refused before any split.
    let result = server
        .call(&json!({"name": "open", "arguments": {"kind": "file", "path": "/no/such.pptx"}}))
        .expect("a result");
    assert_eq!(result["isError"], true, "{result}");
    assert!(pptx_view::is_deck("/a/Deck.PPTX") && !pptx_view::is_deck("/a/deck.ppt"));
}
