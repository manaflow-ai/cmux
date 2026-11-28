//! An action whose run ends only when its work is done (a server round trip: pause, resume)
//! must say so with `waits_for_result` (or `waits_for_person`, `starts_terminal`), so the
//! control socket gives it a deadline sized to that work. Without the flag the app's 2 s
//! control-plane deadline answered `action.run did not finish within 1999 ms` while the
//! pause or resume was still in flight (`cmux vm pause`, 2026-11-11T00:01:47Z).
//!
//! Detector for the class: every description that promises "the run ends when" its work is
//! done is checked against the flags.

use cmux_action_catalog::{actions, find};

fn waits(action: &cmux_action_catalog::Action) -> bool {
    action.waits_for_result || action.waits_for_person || action.starts_terminal
}

#[test]
fn a_run_that_promises_to_end_with_its_work_waits_for_it() {
    let short: Vec<&str> = actions()
        .filter(|action| action.description.is_some_and(|text| text.contains("the run ends when")))
        .filter(|action| !waits(action))
        .map(|action| action.id)
        .collect();
    assert!(
        short.is_empty(),
        "these actions promise the run ends with their work but get the 2 s control-plane deadline; set waits_for_result: {short:?}"
    );
}

#[test]
fn pause_and_resume_wait_for_the_server() {
    for id in ["cloudPauseMachine", "cloudResumeMachine"] {
        let action = find(id).unwrap_or_else(|| panic!("{id} is in the catalog"));
        assert!(action.waits_for_result, "{id} must wait for the server's answer");
    }
}

/// `cmux cloud move --wait` (and bring-back, transfer-local, move-to-machine) copies a folder and
/// moves a chat: minutes, never 2 s. Without the flag the app answered `action.run did not finish
/// within 1999 ms` two seconds into the CLI's 45 s wait, so the caller never heard how the move
/// ended (cloud-session-move-to-cloud-production, 40 failed runs to 2026-11-24T23:47:53Z).
#[test]
fn cloud_moves_wait_for_their_result() {
    for id in ["cloudMove", "cloudBringBack", "cloudTransferLocal", "cloudMoveToMachine"] {
        let action = find(id).unwrap_or_else(|| panic!("{id} is in the catalog"));
        assert!(action.waits_for_result, "{id} must get the waited-run deadline, not the 2 s one");
    }
}

/// The app's handlers, where a run hands its work to the registry (`registry.track`,
/// `runTracked`) for an `action.run` caller to await.
fn handler_sources() -> Vec<(String, String)> {
    // affected-reads: Packages/macOS/CmuxNext/Sources/CmuxNextApp cmux-tui/crates/cmux-action-catalog
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Sources/CmuxNextApp");
    let mut files = Vec::new();
    let mut dirs = vec![root];
    while let Some(dir) = dirs.pop() {
        for entry in
            std::fs::read_dir(&dir).unwrap_or_else(|e| panic!("read {}: {e}", dir.display()))
        {
            let path = entry.expect("dir entry").path();
            if path.is_dir() {
                dirs.push(path);
            } else if path.extension().is_some_and(|ext| ext == "swift") {
                let text = std::fs::read_to_string(&path).expect("swift source");
                files.push((path.file_name().unwrap().to_string_lossy().into_owned(), text));
            }
        }
    }
    files.sort();
    files
}

/// The end of the bracketed span opening at `start` (`open` there).
fn span_end(text: &[u8], start: usize, open: u8, close: u8) -> usize {
    let mut depth = 0usize;
    for (offset, byte) in text[start..].iter().enumerate() {
        if *byte == open {
            depth += 1;
        } else if *byte == close {
            depth -= 1;
            if depth == 0 {
                return start + offset + 1;
            }
        }
    }
    text.len()
}

/// Each `bind("ID", …)` call with its trailing closure, as (id, the call's text).
fn binds(text: &str) -> Vec<(&str, &str)> {
    let bytes = text.as_bytes();
    let mut found = Vec::new();
    let mut from = 0;
    while let Some(at) = text[from..].find("bind(\"").map(|at| from + at) {
        from = at + 6;
        if at > 0 && (bytes[at - 1].is_ascii_alphanumeric() || bytes[at - 1] == b'_') {
            continue; // `rebind(`, `bindHidden(`: not this call
        }
        let Some(id_end) = text[from..].find('"').map(|end| from + end) else { break };
        let id = &text[from..id_end];
        let mut end = span_end(bytes, at + 4, b'(', b')');
        let mut next = end;
        while next < bytes.len() && (bytes[next] == b' ' || bytes[next] == b'\t') {
            next += 1;
        }
        if next < bytes.len() && bytes[next] == b'{' {
            end = span_end(bytes, next, b'{', b'}');
        }
        found.push((id, &text[at..end]));
    }
    found
}

/// Tracked work that finishes inside the 2 s control-plane deadline, or that waits on a
/// person's panel (where `waits_for_person` is the flag, once a CLI run needs it). Each says why.
const FINISHES_WITHIN_CONTROL_DEADLINE: &[(&str, &str)] = &[
    ("quit", "the app quits; nobody hears the answer"),
    ("agentPane.copyLastCodeBlock", "a script in the chat's own page, then the pasteboard"),
    ("agentPane.markUnread", "one request to the local acpmux"),
    ("bookmark.toggleBar", "a local settings write"),
    ("fileEditor.importEditorSettings", "a local settings write"),
    ("layout.undo", "one daemon request; a person's confirm only for the person's own run"),
    ("music.open", "a person's open panel"),
    ("attachTextBoxFile", "a person's open panel"),
    ("palette.makeDefaultTerminal", "the system's default-app prompt, a person's"),
    ("palette.makeDefaultBrowser", "the system's default-app prompt, a person's"),
    ("server.addServer", "person-only: the descriptor refuses every CLI, MCP and script run"),
];

/// The class after `cloudMove` (cmux#55173, 40 failed probe runs): an action whose handler
/// hands the run awaited work, which a waited `action.run` (every `cmux <noun> <verb>`, `--wait`
/// by default) awaits, must declare the wait, or the app answers `did not finish within 1999 ms`
/// while the work goes on. Found at build time, never by a probe one run at a time.
#[test]
fn every_handler_that_hands_back_awaited_work_declares_the_wait() {
    let exempt: std::collections::HashMap<&str, &str> =
        FINISHES_WITHIN_CONTROL_DEADLINE.iter().copied().collect();
    let mut short = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let sources = handler_sources();
    for (file, text) in &sources {
        for (id, call) in binds(text) {
            let hands_back = call.contains("track(")
                || call.contains("runTracked(")
                || call.contains("await cloud.");
            if !(hands_back && call.contains("await")) {
                continue;
            }
            let Some(action) = find(id) else { continue };
            if action.cli_name.is_empty() {
                continue; // no `cmux <noun> <verb>` runs it waited
            }
            seen.insert(id.to_owned());
            if !waits(action) && !action.waits_for_keyed_create && !exempt.contains_key(id) {
                short.push(format!("{id} ({file})"));
            }
        }
    }
    assert!(
        short.is_empty(),
        "these handlers hand a waited run awaited work but the action declares no wait, so the run is cut at 2 s; set waits_for_result (and add tests/awaiting-repin/fields/<id> with /waitsForResult), or list it in FINISHES_WITHIN_CONTROL_DEADLINE with why: {short:?}"
    );
    let stale: Vec<&str> = exempt
        .keys()
        .copied()
        .filter(|id| !seen.contains(*id) || find(id).is_some_and(waits))
        .collect();
    assert!(
        stale.is_empty(),
        "FINISHES_WITHIN_CONTROL_DEADLINE names actions the check no longer finds unwaited; drop them: {stale:?}"
    );
}
