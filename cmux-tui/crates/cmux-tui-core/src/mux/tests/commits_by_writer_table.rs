//! MEASURE, NOT FOR A MERGE. The commits of the registry's file and their WAL
//! frames by the name of their writer (`server-stats`
//! `write_path.commits_by_writer`), for a flow of agents and of a person on a
//! small store.
//!
//! COUNT form (no clock): the registry is a file in a temporary directory and
//! its commits go through the journal writer thread, as in a daemon. The row
//! reads the section as a client does (its JSON) after each step of the flow
//! and prints the writers whose row moved, with the journal rows that the
//! step added by kind. Under each step: one line for each commit that the
//! step put in the WAL file, in the WAL's order, with its frames by the
//! b-tree of their page (`dbstat`, read after the step).
//!
//! The flow: 2 agents with hooks (a session's start, a turn's start, 2 tools,
//! one of them with a permission request, the turn's end, the session's end);
//! 2 agents that a screen plugin reports; 1 agent that reports through the
//! socket; a person's creates and closes (a workspace with a terminal, 2
//! splits, a tab, an empty workspace); 2 hooks on a real terminal; a
//! notification with one read mark; a frontend's projection document.
//!
//! What the table leaves out:
//! - Each step ends with a settle of the roster's owner, which saves the
//!   roster's snapshot row at once. A daemon saves it each 512 journal rows
//!   or at its tick: the commits of `agent_roster_save` here are more than a
//!   daemon's for the same flow.
//! - The journal maintenance worker is stopped: it has no commit here.
//! - A small store's frames a commit are not a large store's: fuller pages
//!   split and rewrite more.
//! - A step that fails says so in its line and the flow goes on.
//!
//! After the flow, 3 measures of the journal's subject rows (the table
//! `journal_subject_index` and its index by subject):
//! - M1: under each step, one line for each journal row of the step with its
//!   subject rows by the subject's kind.
//! - THE BULK: sessions of `BULK_AGENTS` agents at the same time, each hook
//!   of one agent after the same hook of the agent before, until the journal
//!   has `BULK_ROWS` rows more. One line, no commit lines.
//! - M3: a second connection makes 2 pairs of a copy table and a copy index
//!   with the keys of the subject table and of its index, and fills each
//!   with the subject rows of the journal rows before the last 1,110. Then
//!   for 3 periods (the next 10, 100 and 1,000 journal rows): the frames of
//!   ONE commit that puts the period's subject rows in the first pair, and
//!   the frames of one commit for each journal row of the period in the
//!   second pair. The first is a write of the subject rows one time a
//!   period, the second is the write of today.
//! - M2: the 8 hooks of one new agent session with the index, then the test
//!   drops the index by subject with a second connection, then the 8 hooks
//!   of one more new agent session. Both sessions come after M4's seals.
//!
//! Between M3 and M2, M4: the seal of journal rows into a segment. The
//! maintenance worker stays stopped; the test makes the worker's 2 calls (a
//! checkpoint at the journal's head, then one seal after the other to that
//! checkpoint) with the worker's origin and under its writer name. First for
//! the rows so far (one seal takes 1,024 rows at most), then after about 100
//! rows more, then after about 940 rows more. Each seal has a line: its
//! rows, its frames by the b-tree of their page after the seal, the frames
//! on a page that has no b-tree after the seal by the page's b-tree before
//! it, and the b-trees whose count of pages changed. Then 2 ticks of the
//! worker with no seal due.
//!
//! What M4 leaves out:
//! - The worker makes a checkpoint when the journal has 4,096 rows more than
//!   at its last one: it does not seal 100 rows or 1,000 rows on its own.
//! - The rows are those of hooks and reports: no row here has a payload of
//!   many pages.
//! - The store has fewer free pages than the worker keeps: no tick here
//!   gives pages back to the file system.
//!
//! What M1, M2 and M3 leave out:
//! - The copies are filled in one commit and the product's index grew row by
//!   row: their pages are not as full as the product's.
//! - How many subjects a period has is a property of this flow (the agents
//!   of the bulk and their new session ids), not of a real session.
//! - A WAL that started again in the bulk loses the frames before its start:
//!   the bulk's line has the writers' counts and no frames by b-tree.
//! - After the drop, a read of the journal by subject fails. No step here
//!   makes one; a step that fails says so.
//!
//! It fails by design: its words are the result.

use std::collections::{BTreeMap, BTreeSet};

use serde_json::{Value, json};

use super::agent_reports_at_rest::{Agent, kinds_after, session_with_terminals, tick};
use super::*;
use crate::mux::resource_content::without_crosscheck;

const PLUGIN: &str = "screen_table_test";
const WORKSPACES: usize = 60;
const FREE_PAGE: &str = "(no b-tree now: a free page)";
const WAL_HEADER: usize = 32;
const WAL_FRAME_HEADER: usize = 24;
/// The first agent of the bulk and how many agents it has.
const BULK_FIRST: usize = 50;
const BULK_AGENTS: usize = 20;
/// The journal rows that the bulk adds at least, and its most rounds.
const BULK_ROWS: u64 = 1200;
const BULK_ROUNDS: usize = 12;
/// The agents of M2: the control with the index, and the one after the drop.
const WITH_INDEX: usize = 100;
const NO_INDEX: usize = 101;
/// The journal rows of M3's 3 periods.
const PERIODS: [i64; 3] = [10, 100, 1000];
const SUBJECT_INDEX: &str = "journal_subject_index_by_subject_sequence";
const COPY_ROWS: &str = "SELECT sequence, kind, id FROM journal_subject_index \
                         WHERE sequence > ?1 AND sequence <= ?2";
/// M4: the journal rows that the flow adds at least before each of its 2
/// last seals, and how many agents' sessions add them.
const SEAL_ROWS: [(u64, usize); 2] = [(100, 2), (940, 10)];
/// The most seals after one checkpoint: the worker's most in one tick.
const SEALS_A_CHECKPOINT: usize = 8;
/// The origin of the worker's checkpoints and seals.
const WORKER: &str = "journal-maintenance";
const NO_TREE_BEFORE: &str = "(no b-tree before the seal)";

/// The frames that the registry's WAL file holds now.
#[derive(Default)]
struct Wal {
    /// The 2 salts of the WAL's header. They change when the WAL starts
    /// again from its first frame.
    salts: Vec<u8>,
    /// Each frame of this WAL: its page number, and if it ends a commit.
    frames: Vec<(u32, bool)>,
}

/// Reads the WAL file: each frame after the header is 24 bytes and one page;
/// its first 4 bytes are the page's number, the next 4 are not zero in the
/// last frame of a commit, and bytes 8 to 16 are the salts of the header.
fn read_wal(mux: &Mux) -> Wal {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry");
    let mut path = database.as_os_str().to_owned();
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

/// The b-tree of each page of the registry, by `dbstat`.
fn page_trees(mux: &Mux) -> BTreeMap<u32, String> {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry");
    let reader = crate::workspace_registry::open_registry_database_read_only(database).unwrap();
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

/// One line for each commit of `frames`, in the WAL's order: its frames by
/// the b-tree of their page.
fn commit_lines(frames: &[(u32, bool)], trees: &BTreeMap<u32, String>) -> Vec<String> {
    let mut lines = Vec::new();
    let mut by_tree = BTreeMap::<&str, usize>::new();
    let mut count = 0;
    for (page, ends_a_commit) in frames {
        *by_tree.entry(trees.get(page).map_or(FREE_PAGE, String::as_str)).or_default() += 1;
        count += 1;
        if *ends_a_commit {
            lines.push(format!("    COMMIT {}: {count} frames: {by_tree:?}", lines.len() + 1));
            by_tree.clear();
            count = 0;
        }
    }
    if count > 0 {
        lines.push(format!("    {count} frames with no commit mark: {by_tree:?}"));
    }
    lines
}

/// The frames of `frames` and their commits, by the b-tree of their page.
fn by_tree(frames: &[(u32, bool)], trees: &BTreeMap<u32, String>) -> String {
    let mut by_tree = BTreeMap::<&str, usize>::new();
    for (page, _) in frames {
        *by_tree.entry(trees.get(page).map_or(FREE_PAGE, String::as_str)).or_default() += 1;
    }
    let commits = frames.iter().filter(|frame| frame.1).count();
    let pages = frames.iter().map(|frame| frame.0).collect::<BTreeSet<_>>().len();
    format!("{} frames of {pages} pages in {commits} commits: {by_tree:?}", frames.len())
}

/// The pages that each b-tree has now.
fn tree_sizes(trees: &BTreeMap<u32, String>) -> BTreeMap<&str, usize> {
    let mut sizes = BTreeMap::<&str, usize>::new();
    for tree in trees.values() {
        *sizes.entry(tree.as_str()).or_default() += 1;
    }
    sizes
}

/// The b-trees whose count of pages is not the same in `before` and `after`.
fn size_changes(before: &BTreeMap<u32, String>, after: &BTreeMap<u32, String>) -> Vec<String> {
    let (before, after) = (tree_sizes(before), tree_sizes(after));
    let names = before.keys().chain(after.keys()).copied().collect::<BTreeSet<_>>();
    names
        .into_iter()
        .filter_map(|name| {
            let pages = |sizes: &BTreeMap<&str, usize>| sizes.get(name).copied().unwrap_or(0);
            let (was, is) = (pages(&before), pages(&after));
            (was != is).then(|| format!("{name} {was} -> {is}"))
        })
        .collect()
}

/// One line for each journal row after `after`: its kind, and its rows of
/// the subject table by the subject's kind.
fn subject_lines(mux: &Mux, after: u64) -> Vec<String> {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry");
    let reader = crate::workspace_registry::open_registry_database_read_only(database).unwrap();
    let mut statement = reader
        .prepare(
            "SELECT j.sequence, j.kind, s.kind, COUNT(s.kind)
               FROM session_journal j
               LEFT JOIN journal_subject_index s ON s.sequence = j.sequence
              WHERE j.sequence > ?1
              GROUP BY j.sequence, j.kind, s.kind
              ORDER BY j.sequence, s.kind",
        )
        .unwrap();
    let found = statement
        .query_map([i64::try_from(after).unwrap()], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, String>(1)?,
                row.get::<_, Option<String>>(2)?,
                row.get::<_, i64>(3)?,
            ))
        })
        .unwrap();
    let mut rows = BTreeMap::<i64, (String, i64, Vec<String>)>::new();
    for row in found {
        let (sequence, kind, subject, count) = row.unwrap();
        let entry = rows.entry(sequence).or_insert_with(|| (kind, 0, Vec::new()));
        if let Some(subject) = subject {
            entry.1 += count;
            entry.2.push(format!("{subject} {count}"));
        }
    }
    rows.into_iter()
        .map(|(sequence, (kind, total, subjects))| {
            format!("    ROW {sequence} {kind}: {total} subject rows: {}", subjects.join(", "))
        })
        .collect()
}

/// The section's rows: writer -> (commits, WAL frames).
type Rows = BTreeMap<String, (u64, u64)>;

/// The `write_path` section as a client reads it.
fn section(mux: &Mux) -> Value {
    serde_json::to_value(mux.write_path_stats()).unwrap()
}

fn rows_of(section: &Value) -> Rows {
    section["commits_by_writer"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| {
            (
                row["writer"].as_str().unwrap_or_default().to_owned(),
                (row["commits"].as_u64().unwrap_or(0), row["wal_frames"].as_u64().unwrap_or(0)),
            )
        })
        .collect()
}

/// Commits, frames and the frames of one commit (cut to 1 decimal).
fn cost(commits: u64, frames: u64) -> String {
    if commits == 0 {
        return format!("0 commits, {frames} frames");
    }
    let tenths = frames * 10 / commits;
    format!("{commits} commits, {frames} frames, {}.{} frames a commit", tenths / 10, tenths % 10)
}

/// The writers whose row moved from `before` to `after`.
fn moved(before: &Rows, after: &Rows) -> String {
    let words = after
        .iter()
        .filter_map(|(writer, &(commits, frames))| {
            let (commits_before, frames_before) = before.get(writer).copied().unwrap_or((0, 0));
            let (commits, frames) = (commits - commits_before, frames - frames_before);
            (commits > 0 || frames > 0).then(|| format!("{writer} {}", cost(commits, frames)))
        })
        .collect::<Vec<_>>();
    if words.is_empty() { "no commit".to_owned() } else { words.join("; ") }
}

/// Nothing for a step that did its work, the error's words for one that did
/// not.
fn note<T, E: std::fmt::Debug>(result: Result<T, E>) -> String {
    match result {
        Ok(_) => String::new(),
        Err(error) => format!(" (FAILED: {error:?})"),
    }
}

/// Keeps a terminal that a create made.
fn keep(made: &mut Vec<Arc<Surface>>, result: anyhow::Result<Arc<Surface>>) -> String {
    match result {
        Ok(surface) => {
            made.push(surface);
            String::new()
        }
        Err(error) => format!(" (FAILED: {error:?})"),
    }
}

/// The flow's lines: the section's rows and the journal's head after the
/// step before.
struct Table<'a> {
    mux: &'a Arc<Mux>,
    rows: Rows,
    head: u64,
    /// The WAL after the step before: its salts and the count of its frames.
    wal: (Vec<u8>, usize),
    lines: Vec<String>,
    /// How many of the lines a print showed.
    printed: usize,
}

impl<'a> Table<'a> {
    fn new(mux: &'a Arc<Mux>) -> Self {
        settled(mux);
        let wal = read_wal(mux);
        Table {
            mux,
            rows: rows_of(&section(mux)),
            head: mux.session_journal_head().unwrap(),
            wal: (wal.salts, wal.frames.len()),
            lines: Vec::new(),
            printed: 0,
        }
    }

    /// Prints the lines that no print showed: a row that the runner stops at
    /// its time limit has its lines so far. The table at the end has them
    /// again.
    fn print_new(&mut self) {
        eprintln!("LINES SO FAR (again in the table):\n{}", self.lines[self.printed..].join("\n"));
        self.printed = self.lines.len();
    }

    /// Takes the section's rows, the journal's head and the WAL as they are
    /// now for the start of the next step.
    fn from_now(&mut self) {
        settled(self.mux);
        self.new_frames();
        self.rows = rows_of(&section(self.mux));
        self.head = self.mux.session_journal_head().unwrap();
    }

    /// The frames that the WAL got after the read before, and the words for
    /// a WAL that started again from its first frame.
    fn new_frames(&mut self) -> (Vec<(u32, bool)>, &'static str) {
        let wal = read_wal(self.mux);
        let same_wal = wal.salts == self.wal.0 && wal.frames.len() >= self.wal.1;
        let frames = if same_wal { wal.frames[self.wal.1..].to_vec() } else { wal.frames.clone() };
        let again = if same_wal { "" } else { " | THE WAL STARTED AGAIN: its frames from there" };
        self.wal = (wal.salts, wal.frames.len());
        (frames, again)
    }

    /// Runs one step of the flow, lets the roster's owner settle, and writes
    /// the step's line, its commits and its journal rows. Gives the step's
    /// frames.
    fn step(&mut self, name: &str, act: impl FnOnce() -> String) -> Vec<(u32, bool)> {
        self.run(name, true, act)
    }

    /// A step with its line only.
    fn quiet(&mut self, name: &str, act: impl FnOnce() -> String) {
        self.run(name, false, act);
    }

    fn run(&mut self, name: &str, loud: bool, act: impl FnOnce() -> String) -> Vec<(u32, bool)> {
        let failure = act();
        settled(self.mux);
        let now = rows_of(&section(self.mux));
        let head = self.mux.session_journal_head().unwrap();
        let kinds = kinds_after(self.mux, self.head);
        let (frames, again) = self.new_frames();
        self.lines.push(format!(
            "STEP {name}{failure}: {} | journal rows: {kinds:?}{again}",
            moved(&self.rows, &now)
        ));
        if loud {
            self.lines.extend(commit_lines(&frames, &page_trees(self.mux)));
            self.lines.extend(subject_lines(self.mux, self.head));
        }
        self.rows = now;
        self.head = head;
        frames
    }
}

/// The 8 hooks of one new session on `agent`, each one a step, then one line
/// with their sum.
fn session_steps(table: &mut Table<'_>, agent: &Agent, session: &str, name: &str) {
    let mux = table.mux;
    let before = table.rows.clone();
    let mut frames = Vec::new();
    for (event, native) in hooks_of_a_session() {
        let tool = native["tool_name"].as_str().map(|tool| format!(" of {tool}"));
        tick();
        frames.extend(table.step(&format!("{name}: {event}{}", tool.unwrap_or_default()), || {
            hook(mux, &agent.terminal, session, event, native)
        }));
    }
    let sum = by_tree(&frames, &page_trees(mux));
    table.lines.push(format!("SUM {name}: {} | {sum}", moved(&before, &table.rows)));
}

/// A second connection to the registry's file, as a tool beside the daemon.
/// Its commits are not in the section: the daemon's hook does not see them.
fn second_connection(mux: &Mux) -> rusqlite::Connection {
    let database = mux.journal_kernel.database_path().expect("an on-disk registry");
    let connection = rusqlite::Connection::open(database).unwrap();
    connection.busy_timeout(std::time::Duration::from_secs(10)).unwrap();
    // No sync at each commit of the copies: the frames are the same.
    connection.pragma_update(None, "synchronous", "NORMAL").unwrap();
    connection
}

/// Rounds of sessions of `agents` at the same time, each hook of one agent
/// after the same hook of the agent before, until the journal's head is at
/// `wanted` (read after each hook of all agents) or `BULK_ROUNDS` rounds
/// ran.
fn grow(mux: &Arc<Mux>, agents: &[Agent], tag: &str, wanted: u64) -> String {
    let (mut rounds, mut sent, mut failed) = (0, 0, 0);
    'rounds: while rounds < BULK_ROUNDS {
        for (event, native) in hooks_of_a_session() {
            if mux.session_journal_head().unwrap() >= wanted {
                break 'rounds;
            }
            for (index, agent) in agents.iter().enumerate() {
                let session = format!("writer-table-{tag}-{rounds}-{index}");
                tick();
                let failure = hook(mux, &agent.terminal, &session, event, native.clone());
                sent += 1;
                failed += usize::from(!failure.is_empty());
            }
            settled(mux);
        }
        rounds += 1;
    }
    format!(
        " ({rounds} whole rounds of the sessions of {} agents, {sent} hooks sent, {failed} failed)",
        agents.len()
    )
}

/// Sessions of `agents` (see `grow`) until the journal has `rows` rows more:
/// one line, no commit lines.
fn more_rows(table: &mut Table<'_>, name: &str, tag: &str, agents: &[Agent], rows: u64) {
    let mux = table.mux;
    let wanted = table.head + rows;
    table.quiet(name, || grow(mux, agents, tag, wanted));
}

/// M4: a checkpoint at the journal's head, then one seal after the other to
/// that checkpoint, with the worker's origin and under its writer name.
fn seals(table: &mut Table<'_>, round: usize, name: &str) {
    let mux = table.mux;
    table.from_now();
    let writer = crate::diagnostics::CommitWriter::JournalMaintenance.scope();
    let mut rows = table.rows.clone();
    let checkpoint =
        mux.create_journal_checkpoint(WORKER, &format!("writer_table_checkpoint_{round}"));
    let (frames, again) = table.new_frames();
    let now = rows_of(&section(mux));
    let target = match checkpoint {
        Ok(commit) => commit.checkpoint.source_sequence,
        Err(error) => {
            table.lines.push(format!("M4 {name}: NO CHECKPOINT: {error:?}"));
            drop(writer);
            table.from_now();
            return;
        }
    };
    table.lines.push(format!(
        "M4 {name}: THE CHECKPOINT at the journal's row {target}: {} | {}{again}",
        moved(&rows, &now),
        by_tree(&frames, &page_trees(mux))
    ));
    rows = now;
    for batch in 1..=SEALS_A_CHECKPOINT {
        let sealed =
            mux.workspace_registry.lock().unwrap().journal_segments_end().unwrap_or(target);
        if sealed >= target {
            break;
        }
        let before = page_trees(mux);
        let key = format!("writer_table_seal_{round}_{batch}");
        let result = mux.seal_journal_segments(target, WORKER, &key);
        let (frames, again) = table.new_frames();
        let trees = page_trees(mux);
        let now = rows_of(&section(mux));
        let commit = match result {
            Ok(commit) => commit,
            Err(error) => {
                table.lines.push(format!("    SEAL {batch}: FAILED: {error:?}"));
                break;
            }
        };
        let sealed_rows = commit.through_sequence.saturating_sub(sealed);
        let records: u64 = commit.segments.iter().map(|segment| segment.record_count).sum();
        let bytes: u64 = commit.segments.iter().map(|segment| segment.uncompressed_bytes).sum();
        let mut freed = BTreeMap::<&str, usize>::new();
        for (page, _) in &frames {
            if !trees.contains_key(page) {
                let tree = before.get(page).map_or(NO_TREE_BEFORE, String::as_str);
                *freed.entry(tree).or_default() += 1;
            }
        }
        let tenths = u64::try_from(frames.len()).unwrap() * 10 / sealed_rows.max(1);
        table.lines.push(format!(
            "    SEAL {batch}: {sealed_rows} journal rows (after {sealed}, to {}) in {} segments \
             of {records} records, {bytes} bytes before the codec: {}.{} frames a sealed row: {} \
             | {}{again} | the frames on a page with no b-tree after the seal, by the page's \
             b-tree before it: {freed:?} | the b-trees whose count of pages changed: {:?}",
            commit.through_sequence,
            commit.segments.len(),
            tenths / 10,
            tenths % 10,
            moved(&rows, &now),
            by_tree(&frames, &trees),
            size_changes(&before, &trees)
        ));
        rows = now;
    }
    drop(writer);
    table.from_now();
}

/// M4's last part: 2 ticks of the maintenance worker when no seal is due.
fn worker_ticks(table: &mut Table<'_>) {
    let mux = table.mux;
    table.from_now();
    for round in 1..=2 {
        let before = rows_of(&section(mux));
        let done = mux.run_journal_maintenance_tick_for_test();
        let (frames, again) = table.new_frames();
        table.lines.push(format!(
            "M4 THE WORKER's TICK {round} with no seal due (the tick says that it settled: \
             {done}): {} | {}{again}",
            moved(&before, &rows_of(&section(mux))),
            by_tree(&frames, &page_trees(mux))
        ));
    }
    table.from_now();
}

/// M3: the subject rows of 3 periods in ONE commit a period, beside one
/// commit for each journal row, in 2 pairs of a copy table and a copy index.
fn late_write(table: &mut Table<'_>) {
    let mux = table.mux;
    let writer = second_connection(mux);
    let head = i64::try_from(table.head).unwrap();
    let base = (head - PERIODS.iter().sum::<i64>()).max(0);
    let count = |sql: &str, from: i64, to: i64| -> i64 {
        writer.query_row(sql, [from, to], |row| row.get(0)).unwrap()
    };
    table.new_frames();
    for copy in ["subject_copy_period", "subject_copy_each"] {
        writer
            .execute_batch(&format!(
                "CREATE TABLE {copy} (
                   sequence INTEGER NOT NULL, kind TEXT NOT NULL, id TEXT NOT NULL,
                   PRIMARY KEY(sequence, kind, id)
                 ) WITHOUT ROWID;
                 CREATE INDEX {copy}_by_subject ON {copy}(kind, id, sequence);"
            ))
            .unwrap();
        writer.execute(&format!("INSERT INTO {copy} {COPY_ROWS}"), [0, base]).unwrap();
    }
    let (frames, again) = table.new_frames();
    let trees = page_trees(mux);
    table.lines.push(format!(
        "M3 THE COPIES: 2 pairs of a copy table and a copy index, each filled with the subject \
         rows of the journal rows to {base} of {head}: {}{again} | the pages of each b-tree \
         now: {:?}",
        by_tree(&frames, &trees),
        tree_sizes(&trees)
    ));
    let mut from = base;
    for size in PERIODS {
        let to = (from + size).min(head);
        let journal_rows = count(
            "SELECT COUNT(*) FROM session_journal WHERE sequence > ?1 AND sequence <= ?2",
            from,
            to,
        );
        let subject_rows = count(&format!("SELECT COUNT(*) FROM ({COPY_ROWS})"), from, to);
        let subjects = count(
            "SELECT COUNT(*) FROM (SELECT DISTINCT kind, id FROM journal_subject_index \
             WHERE sequence > ?1 AND sequence <= ?2)",
            from,
            to,
        );
        table.lines.push(format!(
            "M3 A PERIOD of {journal_rows} journal rows (after {from}, to {to}): {subject_rows} \
             subject rows of {subjects} subjects (a kind with an id)"
        ));
        writer
            .execute(&format!("INSERT INTO subject_copy_period {COPY_ROWS}"), [from, to])
            .unwrap();
        let (frames, again) = table.new_frames();
        table.lines.push(format!(
            "    ONE COMMIT A PERIOD: {}{again}",
            by_tree(&frames, &page_trees(mux))
        ));
        let mut frames = Vec::new();
        let mut restarts = 0;
        for sequence in from..to {
            writer
                .execute(
                    &format!("INSERT INTO subject_copy_each {COPY_ROWS}"),
                    [sequence, sequence + 1],
                )
                .unwrap();
            let (more, again) = table.new_frames();
            frames.extend(more);
            restarts += usize::from(!again.is_empty());
        }
        table.lines.push(format!(
            "    ONE COMMIT A JOURNAL ROW: {} | the WAL started again {restarts} times",
            by_tree(&frames, &page_trees(mux))
        ));
        from = to;
    }
}

/// M2's drop: the index by subject goes, by a second connection.
fn drop_the_subject_index(table: &mut Table<'_>) {
    let mux = table.mux;
    let writer = second_connection(mux);
    table.new_frames();
    let dropped = writer.execute_batch(&format!("DROP INDEX {SUBJECT_INDEX}"));
    let (frames, again) = table.new_frames();
    table.lines.push(format!(
        "M2 THE DROP of the index `{SUBJECT_INDEX}`{}: {}{again}",
        note(dropped),
        by_tree(&frames, &page_trees(mux))
    ));
}

/// One hook of the agent session `session` on `terminal`, through the journal
/// ingress path, as its hook helper sends it.
fn hook(
    mux: &Arc<Mux>,
    terminal: &TerminalPublicId,
    session: &str,
    event: &str,
    mut native: Value,
) -> String {
    native["session_id"] = json!(session);
    native["cwd"] = json!("/srv/project");
    let ingress = match crate::agent_hooks::agent_hook_journal_ingress(
        "claude",
        event,
        Some(terminal.as_str()),
        native,
    ) {
        Ok(ingress) => ingress,
        Err(error) => return format!(" (NOT SENT: {error:?})"),
    };
    let key = format!("writer-table-{}", crate::workspace_registry::new_uuid_v4());
    note(mux.append_journal_ingress(&ingress, "test", &key))
}

fn put_plugin_manifest(mux: &Mux) {
    let event = |name: &str| crate::JournalEventSchema {
        kind: format!("plugin.{PLUGIN}.agent.{name}"),
        schema_version: 1,
        class: crate::JournalClass::State,
        replay: crate::JournalReplayPolicy::Advisory,
        sensitivity: crate::JournalSensitivity::Metadata,
        payload_schema: json!({"type":"object"}),
    };
    let manifest = crate::JournalProducerManifest {
        producer_id: PLUGIN.into(),
        namespace: format!("plugin.{PLUGIN}"),
        manifest_version: 1,
        max_sensitivity: crate::JournalSensitivity::Metadata,
        permissions: vec![format!("journal.append.plugin.{PLUGIN}")],
        events: vec![event("state.changed"), event("session.ended")],
    };
    mux.put_journal_producer(&manifest, "test", "screen-table-manifest").unwrap();
}

/// One report of the screen plugin about the agent process `pid` on `agent`'s
/// terminal, observed now, through the journal ingress the plugin's
/// `session.journal.append` reaches.
fn screen(mux: &Arc<Mux>, agent: &Agent, state: &str, pid: usize) -> String {
    let ingress = crate::JournalIngress {
        producer_id: PLUGIN.into(),
        manifest_version: 1,
        kind: format!("plugin.{PLUGIN}.agent.state.changed"),
        schema_version: 1,
        occurred_at_ms: None,
        subjects: vec![crate::JournalSubject {
            kind: "terminal".into(),
            id: agent.terminal.to_string(),
        }],
        sensitivity: None,
        payload: json!({
            "format": crate::journal_reducers::AGENT_PLUGIN_FORMAT,
            "plugin": {"id": PLUGIN, "version": 1},
            "adapter": {"id": "claude", "version": 1},
            "event": "state.changed",
            "normalized": {
                "state": state,
                "source_session": format!("pid:{pid}"),
                "observed_at_ms": crate::workspace_registry::unix_epoch_ms().unwrap().to_string(),
                "plugin_generation": "1",
            },
            "native": {"visible": {"blocker": state == "blocked"}},
        }),
        causation_id: None,
        correlation_id: None,
    };
    let key = format!("writer-table-screen-{}", crate::workspace_registry::new_uuid_v4());
    note(mux.append_journal_ingress(&ingress, "screen", &key))
}

/// The hooks of one session of an agent: its start, one turn with 2 tools
/// (the second one asks for a permission), and its end.
fn hooks_of_a_session() -> Vec<(&'static str, Value)> {
    vec![
        ("SessionStart", json!({})),
        ("UserPromptSubmit", json!({ "prompt": "go on" })),
        ("PreToolUse", json!({ "tool_name": "Read" })),
        ("PostToolUse", json!({ "tool_name": "Read" })),
        ("PermissionRequest", json!({ "tool_name": "Bash" })),
        ("PostToolUse", json!({ "tool_name": "Bash" })),
        ("Stop", json!({})),
        ("SessionEnd", json!({})),
    ]
}

#[test]
fn the_commits_and_the_frames_of_each_writer_in_a_flow_of_agents() {
    let root = std::env::temp_dir()
        .join(format!("cmux-writer-table-{}", crate::workspace_registry::new_uuid_v4()));
    let (mux, agents) = session_with_terminals(WORKSPACES, &root);
    put_plugin_manifest(&mux);
    let fold = mux.workspace_registry.lock().unwrap().public_fold_complete_for_test();
    let mut table = Table::new(&mux);
    let setup = table.rows.clone();

    for (index, agent) in agents.iter().take(2).enumerate() {
        let session = format!("writer-table-session-{index}");
        for (event, native) in hooks_of_a_session() {
            let tool = native["tool_name"].as_str().map(|tool| format!(" of {tool}"));
            tick();
            table.step(&format!("hook agent {index}: {event}{}", tool.unwrap_or_default()), || {
                hook(&mux, &agent.terminal, &session, event, native)
            });
        }
    }

    for (index, agent) in agents.iter().skip(20).take(2).enumerate() {
        for state in ["working", "blocked", "working", "idle"] {
            tick();
            table.step(&format!("plugin agent {index}: {state}"), || {
                screen(&mux, agent, state, 4000 + index)
            });
        }
    }

    for (state, name) in [(AgentState::Working, "working"), (AgentState::Idle, "idle")] {
        let agent = &agents[40];
        tick();
        table.step(&format!("socket agent: {name}"), || {
            note(mux.report_agent(
                agent.surface,
                state,
                AgentSource::Socket,
                Some("writer-table-socket".into()),
            ))
        });
    }

    let mut made: Vec<Arc<Surface>> = Vec::new();
    table.step("create: a workspace with a terminal (the first create)", || {
        keep(
            &mut made,
            without_crosscheck(|| mux.new_workspace(Some("made".into()), Some((80, 24)))),
        )
    });
    let pane = made.first().and_then(|surface| mux.with_state(|state| state.pane_of(surface.id)));
    if let Some(pane) = pane {
        for round in 1..=2 {
            table.step(&format!("create: split {round} of that terminal's pane"), || {
                keep(&mut made, without_crosscheck(|| mux.split(pane, SplitDir::Down, None)))
            });
        }
        table.step("create: a tab in that pane", || {
            keep(&mut made, without_crosscheck(|| mux.new_tab(Some(pane), None, Some((80, 24)))))
        });
    }
    table.step("create: a second workspace with a terminal", || {
        keep(
            &mut made,
            without_crosscheck(|| mux.new_workspace(Some("more".into()), Some((80, 24)))),
        )
    });

    let mut empty = None;
    table.step("create: an empty workspace", || {
        match mux.create_empty_workspace(Some("empty".into()), None, None) {
            Ok(placement) => {
                empty = Some(placement.workspace);
                String::new()
            }
            Err(error) => format!(" (FAILED: {error:?})"),
        }
    });
    if let Some(empty) = empty {
        table.step("close: the empty workspace", || {
            if without_crosscheck(|| mux.close_workspace(empty)) {
                String::new()
            } else {
                " (FAILED: it did not close)".to_owned()
            }
        });
    }

    let real = made.first().and_then(|surface| surface.terminal_public_id().cloned());
    if let Some(real) = &real {
        for (event, native) in hooks_of_a_session().into_iter().take(2) {
            tick();
            table.step(&format!("hook on the first real terminal: {event}"), || {
                hook(&mux, real, "writer-table-real", event, native)
            });
        }
    }

    if let Some(surface) = made.first().map(|surface| surface.id) {
        table.step("notification: a post on the first real terminal", || {
            note(mux.post_notification(
                "one".into(),
                "".into(),
                NotificationLevel::Info,
                Some(surface),
            ))
        });
        let newest = mux.resource_notifications(16).first().map(|row| row.id.clone());
        if let Some(newest) = newest {
            table.step("notification: the read mark of one client", || {
                let mutation = WorkspaceMutation::daemon("writer-table-ack", "test").unwrap();
                note(mux.ack_notifications(&mutation, None, "mac-a", std::slice::from_ref(&newest)))
            });
        }
    }

    table.step("frontend projection: the put of a new document", || {
        let mutation = WorkspaceMutation::daemon("writer-table-projection", "test").unwrap();
        note(mux.put_frontend_projection(
            &mutation,
            "writer-table",
            "session",
            "catalog",
            1,
            Some(0),
            &json!({ "rows": [] }),
        ))
    });

    // The terminal made last closes; the others end with the session.
    let closed = made.pop();
    if let Some(surface) = &closed {
        table.step("close: the terminal made last", || {
            note(without_crosscheck(|| mux.close_surface(surface.id)))
        });
    }

    // The first flow ends here: the totals and the writers' lines are its.
    let end = table.rows.clone();
    let all = section(&mux);

    table.print_new();
    let bulk = &agents[BULK_FIRST..BULK_FIRST + BULK_AGENTS];
    more_rows(&mut table, "THE BULK", "bulk", bulk, BULK_ROWS);
    late_write(&mut table);
    table.print_new();
    seals(&mut table, 0, "THE ROWS SO FAR");
    for (round, (rows, sessions)) in SEAL_ROWS.into_iter().enumerate() {
        let name = format!("M4 at least {rows} journal rows more");
        more_rows(&mut table, &name, &format!("seal-{round}"), &bulk[..sessions], rows);
        seals(&mut table, round + 1, &format!("AFTER {rows} ROWS MORE"));
    }
    worker_ticks(&mut table);
    table.print_new();
    session_steps(&mut table, &agents[WITH_INDEX], "writer-table-with-index", "M2 with the index");
    // The lines so far, for a daemon that does not live through the drop.
    table.print_new();
    drop_the_subject_index(&mut table);
    session_steps(&mut table, &agents[NO_INDEX], "writer-table-no-index", "M2 after the drop");

    let Table { lines: steps, .. } = table;
    let commits: u64 = end.values().map(|row| row.0).sum();
    let frames: u64 = end.values().map(|row| row.1).sum();
    let mut lines = vec![
        format!(
            "THE STORE: {WORKSPACES} workspaces, {} seeded terminals, the public fold complete \
             before the flow: {fold}",
            agents.len()
        ),
        format!(
            "THE TOTALS from the daemon's start to the end of the first flow (before THE BULK): \
             wal_commits {} (the rows' sum {commits}), registry_wal_frame_bytes {} (the rows' \
             frames {frames})",
            all["wal_commits"], all["registry_wal_frame_bytes"]
        ),
    ];
    lines.extend(steps);
    for (writer, &(commits, frames)) in &end {
        let (commits_before, frames_before) = setup.get(writer).copied().unwrap_or((0, 0));
        lines.push(format!(
            "WRITER {writer}: in the first flow {} | from the daemon's start to its end {}",
            cost(commits - commits_before, frames - frames_before),
            cost(commits, frames)
        ));
    }
    let table = lines.join("\n");
    eprintln!("{table}");

    for surface in made {
        surface.kill();
    }
    drop(closed);
    drop(mux);
    let _ = std::fs::remove_dir_all(&root);
    panic!("MEASURE (it fails by design):\n{table}");
}
