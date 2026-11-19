//! Capture only (looks-threads-console helper, not for a PR): runs the threads and console
//! New Tab looks (public repos manaflow-ai/cmux-newtab-{threads,console}-look, customize/main.js)
//! in the native host's QuickJS VM with fixture chats, and writes each state's scene ops to
//! $FAST_CHECKS_OUT/ops/<look>-<state>.json for the gallery to draw with the web SceneRenderer.

mod common;

use cmux_app_host::Limits;
use common::Harness;
use serde_json::{Value, json};

const TITLES: [&str; 12] = [
    "Add retries to the fetch helper",
    "Fix the flaky sidebar drag test",
    "Localize the changes view",
    "Why does the build cache miss on CI?",
    "Draft the release notes for 0.42",
    "Port the settings page to React Aria",
    "Profile the transcript scroll jank",
    "Review PR 17516 route tiers",
    "Make the composer location row smaller",
    "Clean up the old maclease scripts",
    "Explain the pane protocol handshake",
    "Add a dark theme screenshot test",
];
const PAGE_TITLES: [&str; 8] = [
    "cmux-next chief",
    "Browser use and cmux computer use for cmux-next",
    "/loop keep improving things until we are at the theoretical limit for iteration speed",
    "cx-4eho scope watch test",
    "does it work for me? can i try it?",
    "iMessage clone Swift demo for cmux",
    "subscription extra usage: how much per account?",
    "GPUI CEF browser with libghostty tabs",
];
const PROJECTS: [&str; 3] =
    ["/Users/you/src/cmux", "/Users/you/src/cmux-web", "/Users/you/.acpmux/tags/dev/unattended"];

fn now() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

fn chat(
    id: String,
    title: String,
    state: &str,
    unread: bool,
    cwd: &str,
    ago_min: u64,
    harness: &str,
) -> Value {
    let at = now() - ago_min * 60_000;
    let project = cwd.rsplit('/').next().unwrap_or("");
    json!({ "id": id, "title": title, "state": state, "unread": unread, "unread_turns": 0, "pinned": false,
            "ci_failing": null, "harness": harness, "project": project, "cwd": cwd, "workspace": null, "machine": null,
            "parent": null, "step": null, "error": null, "since_ms": at, "updated_ms": at, "created_ms": at,
            "pull_requests": [] })
}

/// The gallery's manySessions(n): working, unread, needs input, then done.
fn sessions(n: usize) -> Vec<Value> {
    (0..n)
        .map(|i| {
            let state = match i {
                0 => "working",
                2 => "input",
                _ => "idle",
            };
            let cwd = if i % 4 == 3 { "/Users/you/src/cmux" } else { "/Users/you/src/atlas-web" };
            chat(
                format!("s{i}"),
                TITLES[i % 12].into(),
                state,
                i == 1,
                cwd,
                3 + i as u64 * 47,
                if i % 3 == 1 { "codex" } else { "claude" },
            )
        })
        .collect()
}

/// The gallery's All Chats page: `n` older chats across three projects.
fn page(n: usize, numbered: bool) -> Vec<Value> {
    (0..n)
        .map(|i| {
            let title = if numbered {
                format!("{} {i}", PAGE_TITLES[i % 8])
            } else {
                PAGE_TITLES[i % 8].into()
            };
            chat(
                format!("p{i}"),
                title,
                "idle",
                false,
                PROJECTS[i % 3],
                if i < 3 { 0 } else { i as u64 * 2 } + 1,
                if i % 3 == 1 { "codex" } else { "claude" },
            )
        })
        .collect()
}

fn closed() -> Value {
    let t = now();
    json!([
        { "id": "closed_1", "kind": "tab", "name": "PR #17516", "closed_at_ms": (t - 60_000).to_string(), "screens": [], "members": [], "member_count": 1, "index": 0, "workspace_id": null, "pane_id": null, "window": null },
        { "id": "closed_2", "kind": "tab", "name": "zsh", "closed_at_ms": (t - 240_000).to_string(), "screens": [], "members": [], "member_count": 1, "index": 1, "workspace_id": null, "pane_id": null, "window": null },
        { "id": "closed_3", "kind": "workspace", "name": "Fix the flaky upload test", "closed_at_ms": (t - 900_000).to_string(), "screens": [], "members": [], "member_count": 1, "index": 2, "workspace_id": null, "pane_id": null, "window": null }
    ])
}

fn render(look: &str, state: &str, chats: Vec<Value>, closed_items: Value) -> usize {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/newtab_looks")
        .join(format!("{look}.js"));
    let main = std::fs::read_to_string(&path).unwrap();
    let init = json!({ "app": { "id": "local/customize", "version": "1.0.0" } });
    let mut h = Harness::with(&main, init, Limits::default());
    let body = json!({ "value": { "chats": chats } });
    h.handle("agent_chat.list", move |_, _| (true, body.clone()));
    let closed_body = json!({ "value": closed_items });
    h.handle("closed.list", move |_, _| (true, closed_body.clone()));
    let started = std::time::Instant::now();
    assert_eq!(
        h.mount(
            "m",
            "renderNewTab",
            json!({ "surface": "newTab", "cwd": "/Users/you/src/atlas-web" })
        ),
        None,
        "{look} {state} failed to mount: {:?}",
        h.logs
    );
    let ms = started.elapsed().as_millis();
    let ops: Vec<Value> = h.batches("m").iter().flatten().cloned().collect();
    let n = ops.len();
    let out = std::env::var("FAST_CHECKS_OUT").unwrap_or_else(|_| "/tmp/newtab-looks".into());
    let dir = std::path::Path::new(&out).join("ops");
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join(format!("{look}-{state}.json")), serde_json::to_string(&ops).unwrap())
        .unwrap();
    println!("LOOK {look} {state}: {n} ops, mount {ms} ms, logs {:?}", h.logs);
    // The fleet keeps no $FAST_CHECKS_OUT files: the ops also go to the log, one line each.
    println!("OPS {look}-{state} {}", serde_json::to_string(&ops).unwrap());
    assert!(h.fatal.is_none(), "{look} {state}: {:?}", h.fatal);
    n
}

#[test]
fn newtab_looks_render_every_state() {
    for look in ["threads", "console"] {
        render(look, "empty", vec![], json!([]));
        let mut few = sessions(3);
        few.extend(page(3, false));
        render(look, "few", few.clone(), json!([]));
        render(look, "recently-closed", few, closed());
        let mut six = sessions(6);
        six.extend(page(40, false));
        render(look, "six", six, json!([]));
        let mut many = sessions(14);
        many.extend(page(10_000, true));
        render(look, "10k", many, json!([]));
    }
}
