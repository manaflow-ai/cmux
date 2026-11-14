//! Detector: no list is read with one request. `_acpmux/sessions`, `_acpmux/watch`, ACP
//! `session/list` and `_acpmux/process/list` answer a list past one page (`rpc::REPLY_PAGE_BYTES`,
//! 1 MiB) in pages with the `nextCursor` of the rest; one request reads only the first page, and
//! the caller takes it for the whole list. On 2026-11-11 the Chief stopped a chat by killing the
//! rows of one unpaged process list, so older running processes left out of it kept running;
//! `acpmux process show` could not find an older process; `deliver::sessions` read one page of
//! sessions. A list is read with `Client::whole_list` / `call_whole_list` / the Chief's
//! `whole_list`, or a `limit` and `cursor` loop.
//!
//! This scans every Rust source under `cmux-tui/crates` and `Native/OptChat` (test files left
//! out) for a `.request(` / `.call(` / `.send_request(` that names one of those methods, and fails
//! on any not in [`ALLOWED`], each with why it reads only what it asks for. A new single-shot read
//! fails here: page it, or add it below with the reason it needs one page only.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// Each allowed call: the file (from the repo root), the method as written, how many such calls
/// the file holds, and why each reads only what it asks for.
const ALLOWED: &[(&str, &str, usize, &str)] = &[
    (
        "cmux-tui/crates/acpmux/src/client.rs",
        "method::MUX_SESSIONS",
        1,
        "`Client::whole_list` itself: each later page from its cursor",
    ),
    (
        "cmux-tui/crates/acpmux/src/peer_runtime_io.rs",
        "method::MUX_WATCH",
        1,
        "`watch_pages`: the link's watch, its cursor followed page by page",
    ),
    (
        "cmux-tui/crates/acpmux/src/tui/run.rs",
        "method::MUX_WATCH",
        1,
        "turns watching on, `limit: 1`",
    ),
    (
        "cmux-tui/crates/acpmux/src/cli/process.rs",
        "method::MUX_PROCESS_LIST",
        3,
        "a chat's list in a `limit`/`cursor` loop; every chat's at once does not page and says \
         how many it `omitted`",
    ),
    (
        "cmux-tui/crates/acpmux/src/cli/run/ls.rs",
        "method::MUX_SESSIONS",
        1,
        "`acpmux ls`'s page fetcher: one `limit` page per call, its cursor followed",
    ),
    (
        "cmux-tui/crates/cmux-tui-core/src/server/agent_session_link.rs",
        "\"_acpmux/sessions\"",
        1,
        "`call_whole_list` itself: each later page from its cursor",
    ),
    (
        "cmux-tui/crates/cmux-tui-core/src/server/agent_session_stream.rs",
        "\"_acpmux/watch\"",
        1,
        "turns watching on with `limit: 1`; the list is read by `call_whole_list`",
    ),
    (
        "cmux-tui/crates/cmux-tui-core/src/server/mobile_chat.rs",
        "\"_acpmux/sessions\"",
        1,
        "forwards the phone's own bounded page (`bounded_page_params`), its cursor returned",
    ),
];

fn repo_root() -> PathBuf {
    // cmux-tui/crates/acpmux
    Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(3).unwrap().to_path_buf()
}

fn sources(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().into_owned();
        if path.is_dir() {
            if !matches!(name.as_str(), "target" | "tests" | "benches" | "node_modules" | ".git") {
                sources(&path, out);
            }
        } else if name.ends_with(".rs")
            && !name.ends_with("_tests.rs")
            && !name.ends_with("_test.rs")
            && !name.contains("bench")
        {
            out.push(path);
        }
    }
}

#[test]
fn no_list_is_read_with_one_request() {
    let root = repo_root();
    let crates = root.join("cmux-tui/crates");
    assert!(crates.join("acpmux/src/client.rs").is_file(), "no sources under {}", crates.display());
    let mut files = Vec::new();
    sources(&crates, &mut files);
    sources(&root.join("Native/OptChat"), &mut files);
    let call = regex::Regex::new(
        r#"\.(?:request|call|send_request)\(\s*(method::(?:MUX_SESSIONS|MUX_WATCH|MUX_PROCESS_LIST|SESSION_LIST)\b|"(?:_acpmux/sessions|_acpmux/watch|_acpmux/process/list|session/list)")"#,
    )
    .unwrap();
    let mut found: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    for path in &files {
        let Ok(text) = std::fs::read_to_string(path) else { continue };
        let rel = path.strip_prefix(&root).unwrap().to_string_lossy().replace('\\', "/");
        for hit in call.captures_iter(&text) {
            let at = hit.get(0).unwrap().start();
            let line = text[..at].matches('\n').count() + 1;
            found.entry((rel.clone(), hit[1].to_owned())).or_default().push(line);
        }
    }
    let mut wrong = Vec::new();
    for ((file, method), lines) in &found {
        let allowed = ALLOWED
            .iter()
            .find(|(f, m, _, _)| f == file && m == method)
            .map_or(0, |(_, _, n, _)| *n);
        if lines.len() > allowed {
            wrong.push(format!("{file}:{lines:?} reads {method} with one request"));
        }
    }
    assert!(
        wrong.is_empty(),
        "a list read with one request takes its first page for the whole list. Read it with \
         `whole_list` / `call_whole_list` or a `limit` and `cursor` loop, or add it to ALLOWED \
         with why one page is all it needs:\n{}",
        wrong.join("\n")
    );
}

/// Each use of the v1 list methods (`_acpmux/sessions`, `_acpmux/watch`, ACP `session/list`) in
/// the acpmux crate outside `src/server/` and `src/hub/`, direct or through `whole_list`: the
/// file (from the crate's `src/`), the method as written, how many uses the file holds, and why
/// it is a named fallback or no read (agent service v2, the design doc, row 7b). A list caller
/// reads through `cli/list_read.rs`; v1 is its path for a daemon without the list surface.
const V1_LIST_USES: &[(&str, &str, usize, &str)] = &[
    // The declarations, the schema and the capability ids: no read.
    ("rpc.rs", "\"session/list\"", 1, "the method's name"),
    ("rpc.rs", "\"_acpmux/sessions\"", 1, "the method's name"),
    ("rpc.rs", "\"_acpmux/watch\"", 1, "the method's name"),
    ("capabilities.rs", "method::MUX_SESSIONS", 3, "the capability ids, no read"),
    ("capabilities.rs", "method::MUX_WATCH", 2, "the capability ids, no read"),
    ("pairing/read_only.rs", "method::SESSION_LIST", 1, "a paired device's read-only methods"),
    ("pairing/read_only.rs", "method::MUX_SESSIONS", 1, "a paired device's read-only methods"),
    ("pairing/read_only.rs", "method::MUX_WATCH", 1, "a paired device's read-only methods"),
    ("protocol/mod.rs", "method::SESSION_LIST", 1, "the served protocol's schema"),
    ("protocol/mod.rs", "method::MUX_SESSIONS", 1, "the served protocol's schema"),
    ("protocol/mod.rs", "method::MUX_WATCH", 1, "the served protocol's schema"),
    // `whole_list` itself: the v1 fallback's pager, kept whole until the shim goes.
    ("client.rs", "method::MUX_SESSIONS", 1, "`Client::whole_list`, each page after the first"),
    // The peer link's reads: row 8's, which moves them to the list stream on the link.
    ("peer.rs", "method::MUX_SESSIONS", 2, "row 8: the peer link's watch pages"),
    ("peer.rs", "method::MUX_WATCH", 4, "row 8: the peer link's watch"),
    ("peer_runtime_io.rs", "method::MUX_WATCH", 1, "row 8: the link's watch, page by page"),
    // `deliver::sessions` has no caller outside its own test.
    ("deliver.rs", "method::MUX_SESSIONS", 3, "`deliver::sessions` and its test; no caller"),
    // Row 7b part one's callers, moved to `cli/list_read.rs`: each v1 read is the fallback for a
    // daemon without the list surface or `info-rows-v1` (`Via::open` gave none).
    ("cli/run/ls.rs", "method::MUX_SESSIONS", 1, "`ls`'s fallback (`V1_PAGES`)"),
    ("cli/run/standard.rs", "method::MUX_SESSIONS", 1, "`pending`'s fallback"),
    ("cli/run/fanout.rs", "method::MUX_SESSIONS", 1, "`send --tag`'s fallback"),
    ("acpmux_mcp.rs", "method::MUX_SESSIONS", 1, "MCP `ls`'s fallback"),
    // v1 read kept: `ls --cursor C` reads one v1 page.
    (
        "cli/run/ls.rs",
        "method::MUX_SESSIONS",
        1,
        "v1 read kept: moves before the v1 list is deleted",
    ),
    // Part two of row 7b: callers that want one chat, which then read no list.
    ("acpmux_mcp_send.rs", "method::MUX_SESSIONS", 1, "7b part two: MCP send's tag read"),
    ("cli/orchestrate.rs", "method::MUX_SESSIONS", 1, "7b part two: ensure by name"),
    ("cli/place.rs", "method::MUX_SESSIONS", 1, "7b part two: placement"),
    ("cli/run/session_move.rs", "method::MUX_SESSIONS", 1, "7b part two: a session's move"),
    // Part three of row 7b: the TUI, which follows a mirror once it gives v1 rows.
    ("tui/mod.rs", "method::MUX_SESSIONS", 2, "7b part three: the TUI's list"),
    ("tui/run.rs", "method::MUX_SESSIONS", 1, "7b part three: the TUI's list"),
    ("tui/run.rs", "method::MUX_WATCH", 2, "7b part three: the TUI's watch"),
];

/// v1 while a hub machine is listed (decision 210): the one read that says whether the daemon
/// lists a hub machine whose rows its v2 list lacks, before a command's walk. Deleted with the
/// status read before row 13.
const V1_WHILE_HUB_LISTED: &[(&str, &str, &str)] = &[(
    "cli/list_read.rs",
    "const HOSTS_READ: &str = \"_acpmux/peers\";",
    "v1 while a hub machine is listed: deleted with the status read before row 13",
)];

/// The count that sends a walk of the whole view to v1 (decision 213), named once.
const V1_WHILE_CLOSED_REMOTE_LISTED: &[(&str, &str, &str)] = &[(
    "cli/list_read.rs",
    "const CLOSED_REMOTE: &str = \"closedRemoteListed\";",
    "v1 while another machine's closed row is listed: deleted with 8b (the relayed `page`)",
)];

#[test]
fn the_hub_machines_read_is_named_once() {
    let files = crate_sources();
    for (file, text, why) in V1_WHILE_HUB_LISTED.iter().chain(V1_WHILE_CLOSED_REMOTE_LISTED) {
        let found = files
            .iter()
            .find(|(rel, _)| rel == file)
            .map(|(_, source)| source.matches(text).count());
        assert_eq!(found, Some(1), "src/{file} names `{text}` once ({why})");
    }
}

/// The acpmux crate's directories that serve the methods: not scanned.
const SERVES_THE_METHODS: &[&str] = &["server/", "hub/"];

/// Each use of the v1 list methods in `cmux-tui-core` and the agent pane's policy, as
/// [`V1_LIST_USES`] (the file from `cmux-tui/crates/`): row 7c moves `cmux-tui-core`'s list
/// callers to its list source (`server/agent_session_list_source.rs`), and v1 is each one's path
/// for a daemon without the list surface. A use with a row named is moved by that row.
const TUI_CORE_V1_LIST_USES: &[(&str, &str, usize, &str)] = &[
    (
        "cmux-tui-core/src/server/agent_transfer/agent_update.rs",
        "\"_acpmux/sessions\"",
        1,
        "the update plan's fallback (7c part one)",
    ),
    (
        "cmux-tui-core/src/server/agent_session_link.rs",
        "\"_acpmux/sessions\"",
        2,
        "`call_whole_list`, the v1 fallbacks' pager: each page after the first, and its check",
    ),
    ("cmux-tui-core/src/server/agent_session_children.rs", "\"_acpmux/sessions\"", 1, "7c (b)"),
    ("cmux-tui-core/src/server/agent_session_stream.rs", "\"_acpmux/sessions\"", 1, "7c (b)"),
    (
        "cmux-tui-core/src/server/agent_session_stream.rs",
        "\"_acpmux/watch\"",
        2,
        "7c (c): the attach's push, a follow of `live` (decision 248)",
    ),
    ("cmux-tui-core/src/server/chief_work.rs", "\"_acpmux/sessions\"", 1, "7c (b): chief-work"),
    (
        "cmux-tui-core/src/mux/agent_chat_notices.rs",
        "\"_acpmux/sessions\"",
        4,
        "7c (c): the notices watch's pages (2), and its tests (2)",
    ),
    (
        "cmux-tui-core/src/mux/agent_chat_notices.rs",
        "\"_acpmux/watch\"",
        5,
        "7c (c): the notices watch (2), and its tests (3); `permission_pending` stays a rider",
    ),
    (
        "cmux-tui-core/src/server/mobile_chat.rs",
        "\"_acpmux/sessions\"",
        1,
        "row 7e: the phone's own page",
    ),
    (
        "cmux-agent-pane-policy/src/sessions.rs",
        "\"_acpmux/watch\"",
        1,
        "rider of row 7f: `tabSessionId` in a remote daemon's watch reply",
    ),
];

/// The uses in `files` (`(path from src/, text)`), outside the directories `skip` names, that
/// `named` does not hold, one line each.
fn unnamed_v1_list_uses(
    files: &[(String, String)],
    named: &[(&str, &str, usize, &str)],
    skip: &[&str],
) -> Vec<String> {
    let token = regex::Regex::new(
        r#"method::(?:MUX_SESSIONS|MUX_WATCH|SESSION_LIST)\b|"(?:_acpmux/sessions|_acpmux/watch|session/list)""#,
    )
    .unwrap();
    let mut found: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    for (rel, text) in files {
        if skip.iter().any(|dir| rel.starts_with(dir)) {
            continue;
        }
        for hit in token.find_iter(text) {
            let line = text[..hit.start()].matches('\n').count() + 1;
            found.entry((rel.clone(), hit.as_str().to_owned())).or_default().push(line);
        }
    }
    let mut wrong = Vec::new();
    for ((file, method), lines) in &found {
        // A file may name one method in several rows, each a use with its own reason.
        let allowed: usize = named
            .iter()
            .filter(|(f, m, _, _)| f == file && m == method)
            .map(|(_, _, n, _)| *n)
            .sum();
        if lines.len() != allowed {
            wrong.push(format!(
                "src/{file}:{lines:?} uses {method} {} time(s); the table names {allowed}",
                lines.len()
            ));
        }
    }
    for (file, method, _, _) in named {
        if !found.contains_key(&((*file).to_owned(), (*method).to_owned())) {
            wrong.push(format!("src/{file} no longer uses {method}: take it out of the table"));
        }
    }
    wrong
}

fn crate_sources() -> Vec<(String, String)> {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    sources_from(&src, std::slice::from_ref(&src))
}

/// The sources under each of `dirs` (test files left out), each path from `root`.
fn sources_from(root: &Path, dirs: &[PathBuf]) -> Vec<(String, String)> {
    let mut files = Vec::new();
    for dir in dirs {
        sources(dir, &mut files);
    }
    files
        .into_iter()
        .filter(|path| path.file_name().is_some_and(|name| name != "tests.rs"))
        .filter_map(|path| {
            let text = std::fs::read_to_string(&path).ok()?;
            let rel = path.strip_prefix(root).ok()?.to_string_lossy().replace('\\', "/");
            Some((rel, text))
        })
        .collect()
}

#[test]
fn every_v1_list_read_in_cmux_tui_core_is_a_named_fallback() {
    let crates = repo_root().join("cmux-tui/crates");
    let dirs = ["cmux-tui-core/src", "cmux-agent-pane-policy/src"].map(|dir| crates.join(dir));
    assert!(dirs[0].join("server/agent_session_link.rs").is_file(), "no sources under {crates:?}");
    let wrong = unnamed_v1_list_uses(&sources_from(&crates, &dirs), TUI_CORE_V1_LIST_USES, &[]);
    assert!(
        wrong.is_empty(),
        "a cmux-tui-core list caller reads through `server/agent_session_list_source.rs` (agent \
         service v2, row 7c); a v1 list read is its fallback for a daemon without the list \
         surface. Read through it, or name the use in TUI_CORE_V1_LIST_USES with its reason:\n{}",
        wrong.join("\n")
    );
}

#[test]
fn every_v1_list_read_outside_the_server_is_a_named_fallback() {
    let wrong = unnamed_v1_list_uses(&crate_sources(), V1_LIST_USES, SERVES_THE_METHODS);
    assert!(
        wrong.is_empty(),
        "a list caller reads through `cli/list_read.rs` (agent service v2, row 7b); a v1 list \
         read is its fallback for a daemon without the list surface. Read through it, or name \
         the use in V1_LIST_USES with its reason:\n{}",
        wrong.join("\n")
    );
}

#[test]
fn an_unnamed_v1_list_read_fails_the_scan() {
    let caller = vec![(
        "cli/new_caller.rs".to_owned(),
        "let all = client.whole_list(method::MUX_SESSIONS, json!({})).await?;".to_owned(),
    )];
    assert_eq!(
        unnamed_v1_list_uses(&caller, &[], SERVES_THE_METHODS),
        ["src/cli/new_caller.rs:[1] uses method::MUX_SESSIONS 1 time(s); the table names 0"]
    );
    let named = [("cli/new_caller.rs", "method::MUX_SESSIONS", 1, "a fallback")];
    assert!(unnamed_v1_list_uses(&caller, &named, SERVES_THE_METHODS).is_empty());
    // The server and the hub serve the methods: not scanned.
    let served = vec![("hub/new.rs".to_owned(), "method::MUX_WATCH".to_owned())];
    assert!(unnamed_v1_list_uses(&served, &[], SERVES_THE_METHODS).is_empty());
    // cmux-tui-core's callers are all under its `server/`: every directory there is scanned.
    let tui_core = vec![(
        "cmux-tui-core/src/server/new_caller.rs".to_owned(),
        "link.call_whole_list(\"_acpmux/sessions\", json!({}), T)".to_owned(),
    )];
    assert_eq!(unnamed_v1_list_uses(&tui_core, &[], &[]).len(), 1);
}
