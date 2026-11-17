//! The bytes that ONE agent event puts on the disk, by their writer.
//!
//! An agent event that changes durable state (here: the end of a turn) is one
//! journal row. Two reducers also keep their whole state in one `meta` row
//! each: the agent history (`journal_reducer.history.agent_sessions`) and the
//! agent roster (`journal_reducer.agent_roster`). The history saves its row
//! after each page of the journal that held an agent record, so with its feed
//! on, each agent event writes the whole history again. The roster saves its
//! row each 512 journal rows, and at once for a caller that waits for it.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory and
//! its commits go through the journal writer thread, as in a daemon. The row
//! counts the WAL frame bytes and the commits of `write_path` for two events
//! of the same kind in one session:
//!
//! - the control event comes before the first history read of the session, so
//!   the session has no history feed;
//! - the measured event comes after a history read, so the feed is on.
//!
//! Each count ends after the roster's owner settled. That settle makes the
//! roster save its row one time in each count (a daemon does it each 512 rows),
//! so the difference of the two counts is the save of the history alone.
//!
//! One WAL frame is a page of 4,096 bytes with a header of 24, so no commit
//! writes less than one frame. The row asserts the target of one event (less
//! than 4,096 bytes) and its words give each number.
//!
//! WHICH TABLE: `write_path` counts the frames of another connection at the
//! next commit of the registry's own, and it does not say which b-tree a
//! frame is of. So the row also reads the WAL file itself before and after
//! each event: each frame after the header is 24 bytes and one page; its
//! first 4 bytes are the page's number, the next 4 are not zero in the last
//! frame of a commit, and bytes 8 to 16 are the salts of the WAL's header (a
//! frame with other salts is of an older WAL). `dbstat` gives the b-tree of
//! each page. The row's words give, for each commit of the event, its frames
//! by table and index, then the `meta` rows that changed with their sizes
//! and the tables whose row count changed.
//!
//! What this row leaves out: `fullfsync` (off in a test build), the copy of
//! each frame into the main file by a checkpoint, agents that report while the
//! event commits, and clients.

use std::collections::BTreeMap;

use serde_json::json;

use super::*;

/// The target for the bytes of one agent event.
const TARGET_BYTES: u64 = 4096;
const CWD: &str = "/work/project";
const HISTORY_ROW: &str = "journal_reducer.history.agent_sessions";
const ROSTER_ROW: &str = "journal_reducer.agent_roster";

/// One hook of the agent session `session` on `terminal`, through the journal
/// ingress path, as its hook helper sends it.
fn send(
    mux: &Arc<Mux>,
    terminal: &TerminalPublicId,
    session: &str,
    event: &str,
    mut native: Value,
) {
    native["session_id"] = json!(session);
    native["cwd"] = json!(CWD);
    let ingress = crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    )
    .unwrap();
    let key = format!("event-bytes-{}", crate::workspace_registry::new_uuid_v4());
    mux.append_journal_ingress(&ingress, "test", &key).unwrap();
}

/// `history.entries.list` of the agent kind: it folds the journal to its head
/// before it answers, and the first one starts the history feed.
fn read_agent_history(mux: &Arc<Mux>) {
    let mut fields = Map::new();
    fields.insert("kinds".into(), json!(["agent"]));
    let listed = crate::history_ops::list_for_test(mux, &fields).expect("history list answers");
    assert!(
        listed.get("pending_kinds").is_none(),
        "setup: the history read answered before its fold reached the journal head: {listed}"
    );
}

/// Journal rows after `sequence`, counted by kind.
fn kinds_after(mux: &Mux, mut sequence: u64) -> BTreeMap<String, usize> {
    let mut kinds = BTreeMap::new();
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { return kinds };
        sequence = last.sequence;
        for record in &page.records {
            *kinds.entry(record.kind.clone()).or_default() += 1;
        }
    }
}

/// The bytes of the `meta` row `key`; 0 when the registry has no such row.
fn meta_row_bytes(mux: &Mux, key: &str) -> u64 {
    let reader = reader(mux);
    let bytes: i64 = reader
        .query_row(
            "SELECT COALESCE(SUM(length(CAST(value AS BLOB))), 0) FROM meta WHERE key = ?1",
            [key],
            |row| row.get(0),
        )
        .unwrap();
    u64::try_from(bytes).unwrap()
}

/// The registry's database file.
fn database(mux: &Mux) -> &Path {
    mux.journal_kernel.database_path().expect("an on-disk registry")
}

const WAL_HEADER: usize = 32;
const WAL_FRAME_HEADER: usize = 24;

/// The frames that the registry's WAL file holds now.
#[derive(Default)]
struct Wal {
    /// The 2 salts of the WAL's header. They change when the WAL starts
    /// again from its first frame.
    salts: Vec<u8>,
    /// Each frame of this WAL: its page number, and if it ends a commit.
    frames: Vec<(u32, bool)>,
}

fn read_wal(mux: &Mux) -> Wal {
    let mut path = database(mux).as_os_str().to_owned();
    path.push("-wal");
    let bytes = std::fs::read(&path).unwrap_or_default();
    let Some(header) = bytes.get(..WAL_HEADER) else { return Wal::default() };
    let page = u32::from_be_bytes(header[8..12].try_into().unwrap()) as usize;
    if page == 0 {
        return Wal::default();
    }
    let salts = header[16..24].to_vec();
    let mut frames = Vec::new();
    for frame in bytes[WAL_HEADER..].chunks_exact(WAL_FRAME_HEADER + page) {
        if frame[8..16] != salts[..] {
            break;
        }
        let number = u32::from_be_bytes(frame[..4].try_into().unwrap());
        frames.push((number, frame[4..8] != [0; 4]));
    }
    Wal { salts, frames }
}

/// A reader of the registry's file.
fn reader(mux: &Mux) -> rusqlite::Connection {
    crate::workspace_registry::open_registry_database_read_only(database(mux)).unwrap()
}

/// The b-tree of each page of the registry, by `dbstat`.
fn page_trees(mux: &Mux) -> BTreeMap<u32, String> {
    let reader = reader(mux);
    let mut statement = reader.prepare("SELECT pageno, name, pagetype FROM dbstat").unwrap();
    let pages = statement
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })
        .unwrap()
        .map(|row| {
            let (page, name, kind) = row.unwrap();
            let tree = if kind == "overflow" { format!("{name} (overflow)") } else { name };
            (u32::try_from(page).unwrap(), tree)
        })
        .collect::<BTreeMap<_, _>>();
    pages
}

/// Each row of `meta`.
fn meta_rows(mux: &Mux) -> BTreeMap<String, Vec<u8>> {
    let reader = reader(mux);
    let mut statement = reader.prepare("SELECT key, CAST(value AS BLOB) FROM meta").unwrap();
    let rows = statement
        .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<Vec<u8>>>(1)?)))
        .unwrap()
        .map(|row| {
            let (key, value) = row.unwrap();
            (key, value.unwrap_or_default())
        })
        .collect::<BTreeMap<_, _>>();
    rows
}

/// The row count of each table of the registry; -1 for a table that gives
/// no count.
fn table_rows(mux: &Mux) -> BTreeMap<String, i64> {
    let reader = reader(mux);
    let names = {
        let mut statement = reader
            .prepare(
                "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
            )
            .unwrap();
        let names = statement
            .query_map([], |row| row.get::<_, String>(0))
            .unwrap()
            .map(Result::unwrap)
            .collect::<Vec<_>>();
        names
    };
    names
        .into_iter()
        .map(|name| {
            let count = reader
                .query_row(&format!("SELECT count(*) FROM \"{name}\""), [], |row| row.get(0))
                .unwrap_or(-1);
            (name, count)
        })
        .collect()
}

/// The registry's disk state at one point of the row.
struct DiskState {
    wal: Wal,
    meta: BTreeMap<String, Vec<u8>>,
    rows: BTreeMap<String, i64>,
}

fn disk_state(mux: &Mux) -> DiskState {
    DiskState { wal: read_wal(mux), meta: meta_rows(mux), rows: table_rows(mux) }
}

/// What the WAL file says of one event: its commits, each with its frames by
/// b-tree, and what changed in the tables.
#[derive(Debug)]
#[allow(dead_code)]
struct WalCost {
    /// The WAL started again from its first frame between the 2 reads. Then
    /// the frames below are those since that start: frames of the event
    /// before it are not in the count.
    wal_started_again: bool,
    frames: usize,
    commits: Vec<String>,
    meta_rows_changed: Vec<String>,
    table_row_counts_changed: Vec<String>,
}

fn wal_cost(mux: &Mux, before: &DiskState, after: &DiskState) -> WalCost {
    let same_wal =
        after.wal.salts == before.wal.salts && after.wal.frames.len() >= before.wal.frames.len();
    let frames =
        if same_wal { &after.wal.frames[before.wal.frames.len()..] } else { &after.wal.frames[..] };
    let trees = page_trees(mux);
    let mut commits = Vec::new();
    let mut by_tree = BTreeMap::<&str, usize>::new();
    let mut count = 0;
    for (page, ends_a_commit) in frames {
        let tree = trees.get(page).map_or("(no b-tree now: a free page)", String::as_str);
        *by_tree.entry(tree).or_default() += 1;
        count += 1;
        if *ends_a_commit {
            commits.push(format!("{count} frames: {:?}", std::mem::take(&mut by_tree)));
            count = 0;
        }
    }
    if count > 0 {
        commits.push(format!("{count} frames with no commit mark: {by_tree:?}"));
    }
    let meta_rows_changed = after
        .meta
        .iter()
        .filter(|(key, value)| before.meta.get(*key) != Some(*value))
        .map(|(key, value)| format!("{key}: {} bytes", value.len()))
        .collect();
    let table_row_counts_changed = after
        .rows
        .iter()
        .filter(|(name, count)| before.rows.get(*name) != Some(*count))
        .map(|(name, count)| {
            format!("{name}: {} to {count}", before.rows.get(name).copied().unwrap_or(0))
        })
        .collect();
    WalCost {
        wal_started_again: !same_wal,
        frames: frames.len(),
        commits,
        meta_rows_changed,
        table_row_counts_changed,
    }
}

/// What one agent event wrote.
#[derive(Debug)]
struct EventCost {
    /// Journal rows of the event, by kind.
    rows: BTreeMap<String, usize>,
    /// WAL frame bytes when the event's caller had its answer. Frames of
    /// another connection count at the next commit of the registry's own, so
    /// this number can be low; `frame_bytes` has them.
    frame_bytes_at_answer: u64,
    /// WAL frame bytes after the roster's owner settled.
    frame_bytes: u64,
    commits: u64,
    roster_saves: usize,
    /// The same event, by a read of the WAL file.
    wal: WalCost,
}

/// Runs `event` and counts what it wrote until the roster's owner settled.
/// With `history_read`, a history read comes after the event: it returns when
/// the fold of the history has the event and its save is made (by the read or
/// by the feed, one of them).
fn event_cost(mux: &Arc<Mux>, event: impl FnOnce(), history_read: bool) -> EventCost {
    let head = mux.session_journal_head().unwrap();
    let saves = mux.agent_roster_snapshot_saves_for_test();
    let before = mux.write_path_stats();
    let disk_before = disk_state(mux);
    event();
    let at_answer = mux.write_path_stats();
    if history_read {
        read_agent_history(mux);
    }
    settled(mux);
    let after = mux.write_path_stats();
    let disk_after = disk_state(mux);
    EventCost {
        rows: kinds_after(mux, head),
        frame_bytes_at_answer: at_answer.registry_wal_frame_bytes - before.registry_wal_frame_bytes,
        frame_bytes: after.registry_wal_frame_bytes - before.registry_wal_frame_bytes,
        commits: after.wal_commits - before.wal_commits,
        roster_saves: mux.agent_roster_snapshot_saves_for_test() - saves,
        wal: wal_cost(mux, &disk_before, &disk_after),
    }
}

/// The end of one agent's turn in a session of `workspaces` workspaces whose
/// agent history holds `sessions` agent sessions (2 or more: the control event
/// and the measured event are of 2 agents).
fn one_agent_event(workspaces: usize, sessions: usize) {
    assert!(sessions >= 2, "setup: the row needs 2 agent sessions");
    let root = std::env::temp_dir().join(format!(
        "cmux-agent-event-bytes-{workspaces}-{sessions}-{}",
        crate::workspace_registry::new_uuid_v4()
    ));
    let mux = open_persistent_test_mux("agent-event-bytes", &root);
    // The maintenance worker checkpoints and seals on its own clock; the
    // counts below must see only what the events cause.
    mux.stop_journal_maintenance();
    let keys = (0..workspaces)
        .map(|_| mux.create_empty_workspace(None, None, None).unwrap().key)
        .collect::<Vec<_>>();
    let terminals = (0..3)
        .map(|index| {
            let raw = format!("00000000000040008000{:012x}", index + 1);
            let incarnation = format!("10000000000040008000{:012x}", index + 1);
            mux.seed_running_terminal_for_test(&raw, &incarnation, &keys[index % workspaces])
                .unwrap();
            mux.workspace_registry.lock().unwrap().terminal_resource_id(&raw).unwrap().unwrap()
        })
        .collect::<Vec<_>>();
    let (filler, control, measured) = (&terminals[0], &terminals[1], &terminals[2]);
    // The history keeps one entry for each agent session: these fill it.
    for index in 0..sessions - 2 {
        send(&mux, filler, &format!("filler-{index}"), "SessionStart", json!({}));
    }
    for (terminal, session) in [(control, "control"), (measured, "measured")] {
        send(&mux, terminal, session, "SessionStart", json!({}));
        send(&mux, terminal, session, "UserPromptSubmit", json!({ "prompt": "go on" }));
    }
    settled(&mux);

    // No history read came yet: the session has no history feed.
    let without_feed =
        event_cost(&mux, || send(&mux, control, "control", "Stop", json!({})), false);

    // The first history read folds the journal and starts the feed. Its saves
    // are not in a count.
    crate::history_ops::set_list_fold_budget_for_test(&mux, Some(Duration::from_secs(600)));
    read_agent_history(&mux);
    settled(&mux);
    let with_feed = event_cost(&mux, || send(&mux, measured, "measured", "Stop", json!({})), true);

    let history_row = meta_row_bytes(&mux, HISTORY_ROW);
    let roster_row = meta_row_bytes(&mux, ROSTER_ROW);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);

    let history_save = with_feed.frame_bytes.saturating_sub(without_feed.frame_bytes);
    assert!(
        with_feed.frame_bytes < TARGET_BYTES,
        "one agent event (the end of a turn) in a session of {workspaces} workspaces with \
         {sessions} agent sessions in its history put {} bytes of WAL frames on the disk in {} \
         commits with the history feed on (journal rows {:?}; roster saves {}; {} bytes at the \
         event's answer), and {} bytes in {} commits before the first history read (journal \
         rows {:?}; roster saves {}; {} bytes at the event's answer). The difference, \
         {history_save} bytes, is the save of the history. The history's row holds \
         {history_row} bytes and the roster's row {roster_row} bytes. The target is less than \
         {TARGET_BYTES} bytes for one event. BY A READ OF THE WAL FILE, with the feed on: {:#?} \
         BY A READ OF THE WAL FILE, before the first history read: {:#?}",
        with_feed.frame_bytes,
        with_feed.commits,
        with_feed.rows,
        with_feed.roster_saves,
        with_feed.frame_bytes_at_answer,
        without_feed.frame_bytes,
        without_feed.commits,
        without_feed.rows,
        without_feed.roster_saves,
        without_feed.frame_bytes_at_answer,
        with_feed.wal,
        without_feed.wal,
    );
}

#[test]
fn agent_event_commit_bytes_in_60_workspaces_with_2_sessions() {
    one_agent_event(60, 2);
}

#[test]
fn agent_event_commit_bytes_in_60_workspaces_with_100_sessions() {
    one_agent_event(60, 100);
}

#[test]
fn agent_event_commit_bytes_in_60_workspaces_with_500_sessions() {
    one_agent_event(60, 500);
}

#[test]
fn agent_event_commit_bytes_in_826_workspaces_with_2_sessions() {
    one_agent_event(826, 2);
}

#[test]
fn agent_event_commit_bytes_in_826_workspaces_with_100_sessions() {
    one_agent_event(826, 100);
}

#[test]
fn agent_event_commit_bytes_in_826_workspaces_with_500_sessions() {
    one_agent_event(826, 500);
}
