//! Counted work of the sidebar row face call, not its time: the bytes one batch moves across the Swift/Rust bridge
//! per row, and how many calls it takes. Leo, 2026-11-27: "what are minimally rigorous things we can be adding to
//! the app ci situation to be proving correctness and perf in fast fail open ways/targetted tests per type of
//! situation that things touch based off relevance".
//!
//! A count does not flake: a row that sends a per-row root path or a copied settings blob (the #59531 class, 157 KB
//! a row) moves the number by orders of magnitude on any machine. The test prints `bench_work=<n> bytes_per_row`;
//! `cmux-bench for-paths --run` reads it against the sidebar areas' `budget_work` in docs/benches/relevance-map.toml.
//! The test itself asserts only what is exact: one call for the whole batch, every row answered, and the bytes per
//! row flat from 100 rows to 1,104 (nothing grows with the batch).

use cmux_layout_reducer_ffi::sidebar_face::*;
use std::mem::size_of;

const ROWS: usize = 1_104;

/// A fleet-sized sidebar: each row one pane with one tab (a shell in a project folder), the shape a Chief-started
/// chat list has.
struct Batch {
    strings: Vec<u8>,
    tabs: Vec<CTab>,
    panes: Vec<CPane>,
    workspaces: Vec<CWorkspace>,
}

fn add(strings: &mut Vec<u8>, text: &str) -> CRange {
    let offset = strings.len() as u32;
    strings.extend_from_slice(text.as_bytes());
    CRange { offset, len: text.len() as u32 }
}

fn batch(rows: usize) -> (Batch, CRange) {
    let mut strings = Vec::new();
    let home = add(&mut strings, "/Users/me");
    let mut b = Batch { strings, tabs: Vec::new(), panes: Vec::new(), workspaces: Vec::new() };
    for i in 0..rows {
        let title = format!("chat {i}");
        let cwd = format!("/Users/me/Projects/cmux-{}", i % 40);
        b.tabs.push(CTab {
            title: add(&mut b.strings, &title),
            list_title: add(&mut b.strings, &title),
            cwd: add(&mut b.strings, &cwd),
            flags: 0,
            kind: 0,
            agent: 0,
            progress_state: 0,
            reserved: 0,
            progress_value: NO_VALUE,
            reserved2: 0,
            notification: 0,
            attention_at_ms: 0,
            agent_updated_ms: 0,
            notification_created_ms: 0,
        });
        b.panes.push(CPane { focused_at: i as u64, default_tab: 0, tab_count: 1, selected: NONE });
        b.workspaces.push(CWorkspace {
            pane_start: i as u32,
            pane_count: 1,
            tab_start: i as u32,
            tab_count: 1,
            entry_start: 0,
            entry_count: 0,
            flags: WORKSPACE_LOCAL,
            reserved: 0,
            unread_count: 0,
            reported_progress: 0.0,
            status: CRange::ABSENT,
        });
    }
    (b, home)
}

/// Bytes across the bridge for `rows` rows in one call: the typed arrays and string buffer in, the reply's arrays
/// and strings out. Also the number of rows answered.
fn bridge_bytes(rows: usize) -> (usize, usize) {
    let (b, home) = batch(rows);
    let request = CRequest {
        workspaces: b.workspaces.as_ptr(),
        panes: b.panes.as_ptr(),
        tabs: b.tabs.as_ptr(),
        entries: std::ptr::null(),
        workspace_count: b.workspaces.len() as u32,
        pane_count: b.panes.len() as u32,
        tab_count: b.tabs.len() as u32,
        entry_count: 0,
        home,
        shows_unread: 1,
        new_tab_titled: 1,
        reserved: [0; 6],
    };
    let sent = b.workspaces.len() * size_of::<CWorkspace>()
        + b.panes.len() * size_of::<CPane>()
        + b.tabs.len() * size_of::<CTab>()
        + size_of::<CRequest>()
        + b.strings.len();
    let faces = cmux_sidebar_face_new();
    // SAFETY: a live handle and a request whose arrays hold their counts.
    let reply = unsafe { &*cmux_sidebar_face_rows(faces, &request, b.strings.as_ptr(), b.strings.len()) };
    assert_eq!(reply.ok, 1);
    let got = reply.face_count as usize
        * size_of::<CFace>()
        + reply.listed_count as usize * size_of::<CListedTab>()
        + reply.kept_entry_count as usize * size_of::<u32>()
        + reply.strings_len as usize
        + size_of::<CReply>();
    let answered = reply.face_count as usize;
    // SAFETY: freed once.
    unsafe { cmux_sidebar_face_free(faces) };
    assert_eq!(answered, rows, "one call answers every row");
    (sent + got, answered)
}

#[test]
fn sidebar_face_work_bytes_per_row_are_flat_and_counted() {
    let (small, small_rows) = bridge_bytes(100);
    let (full, full_rows) = bridge_bytes(ROWS);
    let per_small = small as f64 / small_rows as f64;
    let per_row = full as f64 / full_rows as f64;
    println!("sidebar face: {small_rows} rows {small} B, {full_rows} rows {full} B, {per_row:.1} B per row");
    assert!(
        (per_row - per_small).abs() / per_small < 0.05,
        "bytes per row grew with the batch: {per_small:.1} at {small_rows} rows, {per_row:.1} at {full_rows}"
    );
    println!("bench_work={:.0} bytes_per_row", per_row.ceil());
}
