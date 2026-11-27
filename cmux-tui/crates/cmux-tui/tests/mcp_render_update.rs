//! `render` with an `id` updates a page in place (cx-ncc.94).
//!
//! The real `cmux-tui mcp serve` over stdio: a render returns its page's
//! id, a later render naming that id is an update of the same card (the
//! receipt carries the same id), an id no render returned is refused, and a
//! render without one is a new card as before. The id is the one the cmux
//! NEXT chat derives from the call's own input (webviews renderCall.ts), so
//! the page's id here is pinned to the same value the web test expects.
#![cfg(unix)]

use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

static NEXT_DIR: AtomicU64 = AtomicU64::new(0);

const FIRST: &str = "<title>Desk clamp</title><p>Jaw 3°</p>";
/// The id the chat gives `FIRST` (webviews test/render-update.test.tsx).
const FIRST_ID: &str = "r680bc59027";
const SECOND: &str = "<title>Desk clamp</title><p>Jaw 5°</p>";
/// `SECOND`'s own id, which the chat gives it only when it is drawn fresh.
const SECOND_ID: &str = "ra7e83ab227";

#[test]
fn a_render_naming_an_earlier_render_id_updates_that_page_in_place() {
    let answers = serve(&[
        json!({"html": FIRST, "title": "Desk clamp"}),
        json!({"id": FIRST_ID, "html": SECOND, "title": "Desk clamp, thicker jaw"}),
        json!({"id": "r0000000000", "html": SECOND}),
        json!({"html": SECOND}),
        json!({"id": 7, "html": SECOND}),
    ]);
    let [first, update, unknown, fresh, malformed] = answers.as_slice() else {
        panic!("five answers expected: {answers:?}")
    };

    assert_eq!(first["isError"], false, "{first}");
    assert_eq!(first["structuredContent"]["id"], FIRST_ID, "{first}");
    assert_eq!(first["structuredContent"]["updated"], false, "{first}");

    assert_eq!(update["isError"], false, "{update}");
    assert_eq!(
        update["structuredContent"]["id"], FIRST_ID,
        "the update keeps the card's id: {update}"
    );
    assert_eq!(update["structuredContent"]["updated"], true, "{update}");
    assert_eq!(update["structuredContent"]["bytes"], SECOND.len());

    assert_eq!(unknown["isError"], true, "{unknown}");
    assert_eq!(unknown["structuredContent"]["state"], "not_run");
    let message = unknown["structuredContent"]["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("r0000000000"), "the refusal names the id: {message}");

    assert_eq!(fresh["isError"], false, "{fresh}");
    assert_eq!(fresh["structuredContent"]["updated"], false, "{fresh}");
    let fresh_id = fresh["structuredContent"]["id"].as_str().unwrap_or_default();
    assert!(
        !fresh_id.is_empty() && fresh_id != FIRST_ID,
        "a render without an id is a new card: {fresh}"
    );

    assert_eq!(malformed["isError"], true, "{malformed}");
    assert_eq!(malformed["structuredContent"]["state"], "not_run");
}

#[test]
fn a_render_naming_an_updated_page_by_its_own_hash_is_refused_until_that_page_is_drawn_fresh() {
    let answers = serve(&[
        json!({"html": FIRST}),
        json!({"id": FIRST_ID, "html": SECOND}),
        json!({"id": SECOND_ID, "html": FIRST}),
        json!({"html": SECOND}),
        json!({"id": SECOND_ID, "html": FIRST}),
    ]);
    let [_, update, own_hash, fresh, named] = answers.as_slice() else {
        panic!("five answers expected: {answers:?}")
    };
    assert_eq!(update["structuredContent"]["id"], FIRST_ID, "{update}");
    // The update's page goes by its card's id; its own hash names no card.
    assert_eq!(own_hash["isError"], true, "{own_hash}");
    assert_eq!(own_hash["structuredContent"]["state"], "not_run");
    // Drawn fresh, the same page is a card of its own, and its id updates it.
    assert_eq!(fresh["structuredContent"]["id"], SECOND_ID, "{fresh}");
    assert_eq!(named["isError"], false, "{named}");
    assert_eq!(named["structuredContent"]["id"], SECOND_ID, "{named}");
    assert_eq!(named["structuredContent"]["updated"], true, "{named}");
}

/// One `tools/call` to `render` per argument set, in order, from one
/// `cmux mcp serve`; its answers in the same order.
fn serve(calls: &[Value]) -> Vec<Value> {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
    let sequence = NEXT_DIR.fetch_add(1, Ordering::Relaxed);
    let dir = PathBuf::from(format!("/tmp/cmux-mru-{}-{stamp}-{sequence}", std::process::id()));
    let runtime = dir.join("rt");
    std::fs::create_dir_all(&runtime).unwrap();
    let config = dir.join("cmux-next.json");
    std::fs::write(&config, r#"{"mcp": {"enabled": true}}"#).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .arg("--app-socket")
        .arg(dir.join("app.sock"))
        .args(["mcp", "serve"])
        .env("HOME", &dir)
        .env("CMUX_NEXT_CONFIG_FILE", &config)
        .env("XDG_RUNTIME_DIR", &runtime)
        .env("CMUX_TUI_SOCKET", dir.join("own.sock"))
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_MUX_SOCKET")
        .env_remove("CMUX_AGENT_SESSION")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut messages = vec![
        json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "cx-ncc.94", "version": "1"}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
    ];
    for (index, arguments) in calls.iter().enumerate() {
        messages.push(json!({"jsonrpc": "2.0", "id": index + 1, "method": "tools/call",
            "params": {"name": "render", "arguments": arguments}}));
    }
    for message in messages {
        writeln!(stdin, "{message}").unwrap();
    }
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    let answers: Vec<Value> = String::from_utf8_lossy(&output.stdout)
        .lines()
        .filter_map(|line| serde_json::from_str::<Value>(line).ok())
        .collect();
    (1..=calls.len())
        .map(|id| {
            answers
                .iter()
                .find(|message| message["id"] == id)
                .unwrap_or_else(|| panic!("no answer to call {id}; stderr: {stderr}"))["result"]
                .clone()
        })
        .collect()
}
