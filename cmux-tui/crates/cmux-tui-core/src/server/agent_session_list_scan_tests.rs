//! Detector: every v1 list read in `cmux-tui-core` and the agent pane's policy is a named
//! fallback (agent service v2, row 7c). It runs here, not in acpmux, so a change to
//! `cmux-tui-core` alone runs it; the scanner is acpmux's `test-support` (`v1_list_scan`).

use acpmux::test_support::v1_list_scan::{Named, sources_from, unnamed_v1_list_uses};
use std::path::Path;

/// Each use of the v1 list methods in `cmux-tui-core` and the agent pane's policy (the file
/// from `cmux-tui/crates/`), as acpmux's `V1_LIST_USES`: row 7c moves `cmux-tui-core`'s list
/// callers to its list source (`server/agent_session_list_source.rs`), and v1 is each one's
/// path for a daemon without the list surface. A use with a row named is moved by that row.
const TUI_CORE_V1_LIST_USES: &[Named<'static>] = &[
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
    (
        "cmux-tui-core/src/server/agent_session_children.rs",
        "\"_acpmux/sessions\"",
        1,
        "the children verb's fallback (7c part two)",
    ),
    (
        "cmux-tui-core/src/server/agent_session_side_known.rs",
        "\"_acpmux/sessions\"",
        1,
        "the side chats a team list hides after a restart: every session's persisted `tags.side`",
    ),
    (
        "cmux-tui-core/src/server/agent_session_stream.rs",
        "\"_acpmux/sessions\"",
        1,
        "the attach's descendants, its fallback (7c part two)",
    ),
    (
        "cmux-tui-core/src/server/agent_session_stream.rs",
        "\"_acpmux/watch\"",
        3,
        "7c (c): the attach's push, a follow of `live` (decision 248); one is the v2 path's \
         one-row switch until then",
    ),
    (
        "cmux-tui-core/src/server/chief_work.rs",
        "\"_acpmux/sessions\"",
        1,
        "chief-work's fallback (7c part two)",
    ),
    (
        "cmux-tui-core/src/mux/agent_chat_notices.rs",
        "\"_acpmux/sessions\"",
        1,
        "7c (c): the notices watch's pages; its tests are in agent_chat_notices_tests.rs",
    ),
    (
        "cmux-tui-core/src/mux/agent_chat_notices.rs",
        "\"_acpmux/watch\"",
        1,
        "7c (c): the notices watch; its tests are in agent_chat_notices_tests.rs; `permission_pending` stays a rider",
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

#[test]
fn every_v1_list_read_in_cmux_tui_core_is_a_named_fallback() {
    // cmux-tui/crates/cmux-tui-core
    let crates = Path::new(env!("CARGO_MANIFEST_DIR")).parent().unwrap();
    let dirs = ["cmux-tui-core/src", "cmux-agent-pane-policy/src"].map(|dir| crates.join(dir));
    assert!(dirs[0].join("server/agent_session_link.rs").is_file(), "no sources under {crates:?}");
    let wrong =
        unnamed_v1_list_uses(&sources_from(crates, &dirs), TUI_CORE_V1_LIST_USES, &[]).unwrap();
    assert!(
        wrong.is_empty(),
        "a cmux-tui-core list caller reads through `server/agent_session_list_source.rs` (agent \
         service v2, row 7c); a v1 list read is its fallback for a daemon without the list \
         surface. Read through it, or name the use in TUI_CORE_V1_LIST_USES with its reason:\n{}",
        wrong.join("\n")
    );
}
