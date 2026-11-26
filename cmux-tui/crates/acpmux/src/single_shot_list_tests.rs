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

use crate::test_support::v1_list_scan::{sources, sources_from, unnamed_v1_list_uses};
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
        "cmux-tui/crates/acpmux-tui/src/run.rs",
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
        "cmux-tui/crates/acpmux/src/cli/run/board.rs",
        "method::MUX_SESSIONS",
        1,
        "the board's v1 page fetcher for `ls_pages::read`: one `limit` page per call, its cursor \
         followed",
    ),
    (
        "cmux-tui/crates/coord-sim/src/drive/readers.rs",
        "\"_acpmux/sessions\"",
        1,
        "the simulated pane's list: a `limit: 200` page per call, its `nextCursor` followed",
    ),
    (
        "cmux-tui/crates/coord-sim/src/degen/cases.rs",
        "\"_acpmux/sessions\"",
        1,
        "the degenerate-case reader's page loop: the daemon's own page size, its cursor followed",
    ),
    (
        "cmux-tui/crates/coord-sim/src/degen/sidebar.rs",
        "\"_acpmux/watch\"",
        1,
        "turns watching on for the rename timings; the sim reads the changes, not the list",
    ),
    (
        "cmux-tui/crates/coord-sim/src/fanin/ramp.rs",
        "\"_acpmux/sessions\"",
        2,
        "the sim times one whole read against the paged one (`limit` 100, its cursor followed)",
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
        2,
        "turns watching on with `limit: 1`, its page unread: on v1 the list is read by \
         `call_whole_list`, and on the v2 list the descendants by `page` with `family` (row 7c)",
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
    ("capabilities.rs", "method::MUX_SESSIONS", 5, "the capability ids, no read"),
    ("capabilities.rs", "method::MUX_WATCH", 3, "the capability ids and the batch wire, no read"),
    ("pairing/read_only.rs", "method::SESSION_LIST", 1, "a paired device's read-only methods"),
    ("pairing/read_only.rs", "method::MUX_SESSIONS", 1, "a paired device's read-only methods"),
    ("pairing/read_only.rs", "method::MUX_WATCH", 1, "a paired device's read-only methods"),
    ("protocol/mod.rs", "method::SESSION_LIST", 1, "the served protocol's schema"),
    ("protocol/mod.rs", "method::MUX_SESSIONS", 1, "the served protocol's schema"),
    ("protocol/mod.rs", "method::MUX_WATCH", 1, "the served protocol's schema"),
    // `whole_list` itself: the v1 fallback's pager, kept whole until the shim goes.
    ("client.rs", "method::MUX_SESSIONS", 1, "`Client::whole_list`, each page after the first"),
    // The peer link's reads: row 8's, which moves them to the list stream on the link.
    ("peer.rs", "method::MUX_SESSIONS", 1, "row 8: the peer link's watch pages"),
    ("peer_list_read.rs", "method::MUX_SESSIONS", 1, "row 8: the peer link's watch pages"),
    ("peer.rs", "method::MUX_WATCH", 4, "row 8: the peer link's watch"),
    ("peer_runtime_io.rs", "method::MUX_WATCH", 1, "row 8: the link's watch, page by page"),
    // `deliver::sessions` has no caller outside its own test.
    ("deliver.rs", "method::MUX_SESSIONS", 3, "`deliver::sessions` and its test; no caller"),
    // Row 7b part one's callers, moved to `cli/list_read.rs`: each v1 read is the fallback for a
    // daemon without the list surface or `info-rows-v1` (`Via::open` gave none).
    ("cli/run/ls.rs", "method::MUX_SESSIONS", 1, "`ls`'s fallback (`V1_PAGES`)"),
    ("cli/run/standard.rs", "method::MUX_SESSIONS", 1, "`pending`'s fallback"),
    ("cli/run/fanout.rs", "method::MUX_SESSIONS", 1, "`send --tag`'s fallback"),
    ("cli/search_all.rs", "method::MUX_SESSIONS", 1, "search's fallback for the whole view"),
    ("cli/run/board.rs", "method::MUX_SESSIONS", 1, "the board's fallback (`ls_pages::read`)"),
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
    // `rebalance`'s read of this machine's chats and their idle facts (`session-idle-facts-v1`
    // rides the v1 rows); v1 read kept: moves before the v1 list is deleted. The TUI's reads
    // (row 7b part three) left with it for the `acpmux-tui` crate (#54647).
    ("cli/run/rebalance.rs", "method::MUX_SESSIONS", 1, "v1 read kept: rebalance's idle facts"),
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

fn crate_sources() -> Vec<(String, String)> {
    let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
    sources_from(&src, std::slice::from_ref(&src))
}

#[test]
fn every_v1_list_read_outside_the_server_is_a_named_fallback() {
    let wrong = unnamed_v1_list_uses(&crate_sources(), V1_LIST_USES, SERVES_THE_METHODS).unwrap();
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
        unnamed_v1_list_uses(&caller, &[], SERVES_THE_METHODS).unwrap(),
        ["src/cli/new_caller.rs:[1] uses method::MUX_SESSIONS 1 time(s); the table names 0"]
    );
    let named = [("cli/new_caller.rs", "method::MUX_SESSIONS", 1, "a fallback")];
    assert!(unnamed_v1_list_uses(&caller, &named, SERVES_THE_METHODS).unwrap().is_empty());
    // The server and the hub serve the methods: not scanned.
    let served = vec![("hub/new.rs".to_owned(), "method::MUX_WATCH".to_owned())];
    assert!(unnamed_v1_list_uses(&served, &[], SERVES_THE_METHODS).unwrap().is_empty());
    // A scan that skips nothing (`cmux-tui-core`'s own) reads every directory.
    let tui_core = vec![(
        "cmux-tui-core/src/server/new_caller.rs".to_owned(),
        "link.call_whole_list(\"_acpmux/sessions\", json!({}), T)".to_owned(),
    )];
    assert_eq!(unnamed_v1_list_uses(&tui_core, &[], &[]).unwrap().len(), 1);
}
