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
        "cmux-tui/crates/acpmux/src/peer.rs",
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
