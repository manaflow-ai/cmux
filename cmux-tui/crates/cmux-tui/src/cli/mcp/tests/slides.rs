//! `slides`: a Markdown deck written, compiled into the deck page, shown on the loopback
//! viewer beside the chat, and updated in place.

use std::sync::{Arc, Mutex};

use base64::Engine as _;
use sha2::Digest as _;

use super::live_open::{
    NEW_BROWSER, NEW_TAB, OLD_BROWSER, OLD_TAB, PANE, fetch, open_actions, tab,
};
use super::*;

const DECK: &str = "---
title: Q4 <plan>
slides: true
---

# Q4 plan
### Leo, November

<!-- Welcome everyone. -->

---

## Three bets

- Faster start
- Decks in the chat
- Export anywhere

Notes: say why each matters.
Then pause.

---

```text
--- not a slide break ---
```

---

<!-- _class: center -->
> One number: 42%

---

<div class=\"cols\"><div>left</div><div><img src=\"chart.png\" alt=\"chart\"></div></div>
";

#[test]
fn markdown_compiles_into_the_deck_page() {
    let html = md_deck::compile(DECK, "q4.slides.md");
    assert!(html.contains("<title>Q4 &lt;plan&gt;</title>"), "the front matter's title, escaped");
    assert_eq!(html.matches("<section").count(), 5, "{html}");
    assert_eq!(md_deck::slide_count(DECK), 5);
    // Only headings: a title slide; its comment is its notes.
    assert!(html.contains("<section class=\"title\">\n<h1>Q4 plan</h1>\n<h3>Leo, November</h3>"));
    assert!(html.contains("<aside class=\"notes\">Welcome everyone.</aside>"));
    // A Notes: line starts the notes; the list is the slide.
    assert!(html.contains("<li>Decks in the chat</li>"));
    assert!(html.contains("<aside class=\"notes\">say why each matters.\nThen pause.</aside>"));
    // A --- inside a fence is code, not a break.
    assert!(
        html.contains(
            "<pre><code class=\"language-text\">--- not a slide break ---\n</code></pre>"
        )
    );
    assert!(html.contains("<section class=\"center\">\n<blockquote>"));
    // Raw HTML passes through.
    assert!(html.contains("<div class=\"cols\"><div>left</div>"));
    // The runtime is the template's, last and unchanged.
    assert!(html.trim_end().ends_with("</html>"));
    assert!(html.contains(md_deck::runtime_script()));
    assert!(md_deck::runtime_script().contains("cmux deck runtime"));
    assert!(!html.contains("Deck title"), "none of the template's sample slides");
}

#[test]
fn a_deck_with_no_front_matter_takes_the_file_name_and_drops_bad_classes() {
    let html = md_deck::compile("<!-- _class: x\" onload=\"y -->\n## Only\n\ntext", "talk.md");
    assert!(html.contains("<title>talk.md</title>"));
    assert!(!html.contains("x\" onload"), "{html}");
    assert!(html.contains("<section>\n<h2>Only</h2>"), "{html}");
    // An unclosed front matter is text, not metadata.
    assert_eq!(md_deck::slide_count("---\ntitle: x\n# no end"), 1);
}

#[test]
fn deck_files_are_told_apart_from_documents() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let deck = folder.path().join("talk.md");
    std::fs::write(&deck, "---\nslides: true\n---\n# Hi\n").unwrap();
    let plain = folder.path().join("notes.md");
    std::fs::write(&plain, "---\ntitle: notes\n---\n# Hi\n").unwrap();
    assert!(md_deck::is_deck(deck.to_str().unwrap()));
    assert!(!md_deck::is_deck(plain.to_str().unwrap()));
    assert!(md_deck::is_deck("/no/such/Q4.SLIDES.md"));
    assert!(md_deck::is_deck("/no/such/q4.deck.md"));
    assert!(!md_deck::is_deck("/no/such/q4.slides.html"));
}

fn slides_server(reloads: &Arc<Mutex<Vec<Value>>>) -> Server<Fake> {
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
        tab_lists: RefCell::new([before.clone(), before, after].into()),
        reloads: Some(reloads.clone()),
        ..Fake::default()
    };
    Server::new(fake, None)
}

/// `slides` writes the deck and opens it on the loopback viewer: the page is the compiled
/// deck under a policy that runs only the runtime, pictures in the deck's folder are
/// served and nothing else is, and a second call rewrites the file and reloads the same
/// tab instead of opening another.
#[test]
fn slides_writes_opens_and_updates_a_deck_in_place() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let path = folder.path().join("talks").join("q4.md");
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path.parent().unwrap().join("chart.png"), b"\x89PNG").unwrap();
    std::fs::write(path.parent().unwrap().join("evil.js"), b"alert(1)").unwrap();
    std::fs::write(folder.path().join("secret.png"), b"\x89PNG").unwrap();
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let mut server = slides_server(&reloads);

    let result = server
        .call(&json!({"name": "slides", "arguments": {
            "path": path.to_str().unwrap(), "markdown": DECK, "where": "below"}}))
        .expect("a result");
    assert_ne!(result["isError"], true, "{result}");
    assert_eq!(result["structuredContent"]["slides"], 5, "{result}");
    assert_eq!(result["structuredContent"]["live_browser"], NEW_BROWSER, "{result}");
    assert_eq!(std::fs::read_to_string(&path).unwrap(), DECK);
    // A new deck tab takes the person's view: they asked for a deck.
    let shown = server.backend.sent.borrow().iter().any(|sent| {
        sent["method"] == "action.run" && sent["params"].to_string().contains("\"focus\":true")
    });
    assert!(shown, "{:?}", server.backend.sent.borrow());
    let url = result["structuredContent"]["deck_viewer"].as_str().expect("a viewer url").to_owned();
    let rest = url.strip_prefix("http://127.0.0.1:").unwrap();
    let (port, rest) = rest.split_once('/').unwrap();
    let port: u16 = port.parse().unwrap();
    let token = rest.trim_end_matches('/');
    let host = format!("127.0.0.1:{port}");

    let (status, head, body) = fetch(port, "GET", &format!("/{token}/"), &host);
    assert!(status.contains("200"), "{status}");
    let html = String::from_utf8(body).unwrap();
    assert!(html.contains("<h2>Three bets</h2>"));
    let hash = base64::engine::general_purpose::STANDARD
        .encode(sha2::Sha256::digest(md_deck::runtime_script().as_bytes()));
    assert!(
        head.contains(&format!(
            "script-src 'sha256-{hash}' https://cdn.jsdelivr.net/npm/pptxgenjs@4.0.1/dist/pptxgen.bundle.js;"
        )),
        "{head}"
    );
    assert!(head.contains("connect-src 'self';"), "{head}");

    assert!(fetch(port, "GET", &format!("/{token}/chart.png"), &host).0.contains("200"));
    for refused in [
        "evil.js",
        "../secret.png",
        "%2e%2e/secret.png",
        "..%2fsecret.png",
        "deck.pptx",
        "nope.png",
    ] {
        let target = format!("/{token}/{refused}");
        assert!(fetch(port, "GET", &target, &host).0.contains("404"), "{target}");
    }

    // Again with new text: the file changes, the open tab reloads, no new tab.
    let runs = |server: &Server<Fake>| {
        server.backend.sent.borrow().iter().filter(|s| s["method"] == "action.run").count()
    };
    let opened = runs(&server);
    let result = server
        .call(&json!({"name": "slides", "arguments": {
            "path": path.to_str().unwrap(), "markdown": "# One\n\n---\n\n## Two\n"}}))
        .expect("a result");
    assert_ne!(result["isError"], true, "{result}");
    assert_eq!(result["structuredContent"]["shown"], "updated in place", "{result}");
    assert_eq!(result["structuredContent"]["slides"], 2, "{result}");
    assert_eq!(runs(&server), opened, "no second tab");
    let sent = live_open::reloads_after(&reloads, 1);
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert_eq!(sent[0]["params"]["browser"], NEW_BROWSER);
    let html = String::from_utf8(fetch(port, "GET", &format!("/{token}/"), &host).2).unwrap();
    assert!(html.contains("<h2>Two</h2>") && !html.contains("Three bets"));
}

#[test]
fn slides_refuses_what_it_cannot_show() {
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let mut server = slides_server(&reloads);
    for arguments in [
        json!({}),
        json!({"path": "deck.html", "markdown": "# x"}),
        json!({"path": "/no/such/deck.md"}),
        json!({"path": "deck.md", "markdown": 3}),
        json!({"path": "deck.md", "open": "yes"}),
        json!({"path": "deck.md", "focus": "yes"}),
        json!({"path": "deck.md", "extra": true}),
    ] {
        let result =
            server.call(&json!({"name": "slides", "arguments": arguments})).expect("a result");
        assert_eq!(result["isError"], true, "{arguments}: {result}");
    }
    let tools = tool_list::first_party();
    assert!(tools.iter().any(|tool| tool["name"] == "slides"));
}

/// A deck the app cannot open leaves the file as it was: the write is not kept when the
/// open fails, so a saved deck is never replaced by text the person never saw.
#[test]
fn slides_keeps_the_saved_deck_when_the_open_fails() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let existing = folder.path().join("saved.md");
    std::fs::write(&existing, "# Saved\n").unwrap();
    let fresh = folder.path().join("fresh.md");
    let mut server = Server::new(Fake { refuse_actions: true, ..Fake::default() }, None);
    for (path, markdown) in [(&existing, "# Replacement\n"), (&fresh, "# New\n")] {
        let result = server
            .call(&json!({"name": "slides", "arguments": {
                "path": path.to_str().unwrap(), "markdown": markdown}}))
            .expect("a result");
        assert_eq!(result["isError"], true, "{result}");
    }
    assert_eq!(std::fs::read_to_string(&existing).unwrap(), "# Saved\n");
    assert!(!fresh.exists(), "a deck that never opened is not left behind");
    assert!(!folder.path().join("saved.md.cmux-slides-tmp").exists(), "no temporary file is left");
}

/// A deck's raw HTML cannot load a script from the CDN: the page's policy allows the
/// runtime's hash and the one PowerPoint writer file the runtime loads, not the whole host.
#[test]
fn a_deck_page_allows_only_the_writer_script_from_the_cdn() {
    let folder = tempfile::tempdir().expect("a temp dir");
    let path = folder.path().join("q4.md");
    let reloads = Arc::new(Mutex::new(Vec::new()));
    let mut server = slides_server(&reloads);
    let result = server
        .call(&json!({"name": "slides", "arguments": {
            "path": path.to_str().unwrap(),
            "markdown": "# Hi\n\n---\n\n<script src=\"https://cdn.jsdelivr.net/npm/any/x.js\"></script>\n"}}))
        .expect("a result");
    assert_ne!(result["isError"], true, "{result}");
    let url = result["structuredContent"]["deck_viewer"].as_str().expect("a viewer url");
    let rest = url.strip_prefix("http://127.0.0.1:").unwrap();
    let (port, rest) = rest.split_once('/').unwrap();
    let port: u16 = port.parse().unwrap();
    let host = format!("127.0.0.1:{port}");
    let (status, head, _) = fetch(port, "GET", &format!("/{}/", rest.trim_end_matches('/')), &host);
    assert!(status.contains("200"), "{status}");
    let hash = base64::engine::general_purpose::STANDARD
        .encode(sha2::Sha256::digest(md_deck::runtime_script().as_bytes()));
    let writer = "https://cdn.jsdelivr.net/npm/pptxgenjs@4.0.1/dist/pptxgen.bundle.js";
    assert!(
        head.contains(&format!("script-src 'sha256-{hash}' {writer};")),
        "script-src is the hash and the writer file only: {head}"
    );
    assert!(md_deck::runtime_script().contains(writer), "the runtime loads that writer");
}
