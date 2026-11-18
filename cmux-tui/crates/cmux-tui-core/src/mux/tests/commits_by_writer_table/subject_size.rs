//! MEASURE, NOT FOR A MERGE. M5: the WAL frames of the subject rows of ONE
//! journal row, by how many journal rows' subject rows the store holds
//! before it.
//!
//! COUNT form (no clock, no daemon): a SQLite file of its own in a temporary
//! directory, with the registry's settings (incremental auto-vacuum, WAL,
//! `synchronous=NORMAL`, a checkpoint at 1,000 frames, `secure_delete=ON`)
//! and the 2 statements that make the subject table and its index by
//! subject in `workspace_registry/session_journal.rs`. A larger page cache
//! than the registry's, for the fill's speed.
//!
//! The fill, in the order of the journal's sequence, 7 subject rows for each
//! journal row: the one session; and a workspace, a screen, a pane, a tab, a
//! terminal and an agent. The model: 100 workspaces with 1 screen and 4
//! terminals each; each terminal has 1 pane, 1 tab and 1 agent: 1,801
//! subjects. 9 of 10 journal rows are of 40 terminals in turn (the terminals
//! of 10 workspaces); each tenth row is of the other 360 in turn. An id is
//! its kind's prefix and 32 hex digits, the first 8 from a product with a
//! constant, so that ids near in count are not near in the index.
//!
//! At each size: a checkpoint that empties the WAL, then 100 journal rows
//! more, each one a commit of its 7 subject rows, and the frames of each
//! commit by the b-tree of their page (`dbstat`, read after the 100).
//!
//! What it leaves out:
//! - A journal row's commit in the daemon writes other tables too, and a
//!   batch can hold more than one row: only the 2 b-trees of the subject
//!   rows are here.
//! - The spread of the rows over the subjects is this model's, not a real
//!   session's.
//!
//! It fails by design: its words are the result.

use std::collections::BTreeMap;
use std::path::Path;

/// The journal rows whose subject rows the store holds before a measure.
const SIZES: [i64; 3] = [10_000, 100_000, 1_000_000];
/// The journal rows measured at each size.
const ROWS: i64 = 100;
/// The journal rows of one commit of the fill.
const CHUNK: i64 = 100_000;
const NO_TREE: &str = "(no b-tree: a page of the pointer map or a free page)";

const SETTINGS: &str = "PRAGMA auto_vacuum=INCREMENTAL;
     PRAGMA journal_mode=WAL;
     PRAGMA synchronous=NORMAL;
     PRAGMA wal_autocheckpoint=1000;
     PRAGMA secure_delete=ON;
     PRAGMA temp_store=MEMORY;
     PRAGMA cache_size=-262144;
     CREATE TABLE journal_subject_index (
       sequence INTEGER NOT NULL CHECK(sequence > 0),
       kind TEXT NOT NULL,
       id TEXT NOT NULL,
       PRIMARY KEY(sequence, kind, id)
     ) WITHOUT ROWID;
     CREATE INDEX journal_subject_index_by_subject_sequence
       ON journal_subject_index(kind, id, sequence);";

/// The subject rows of the journal rows after `?1` to `?2`, in the order of
/// the table's key: the cross join keeps the journal rows in the outer loop
/// and the 7 kinds, in the order of their names, in the inner one.
const SUBJECT_ROWS: &str = "WITH RECURSIVE
     journal(n) AS (SELECT ?1 + 1 UNION ALL SELECT n + 1 FROM journal WHERE n < ?2),
     place(n, t) AS (
       SELECT n,
              CASE WHEN n % 10 = 9 THEN 40 + (n / 10) % 360 ELSE (n - (n + 1) / 10) % 40 END
         FROM journal
     ),
     kinds(k) AS (VALUES (0), (1), (2), (3), (4), (5), (6))
     INSERT INTO journal_subject_index(sequence, kind, id)
     SELECT n,
            CASE k WHEN 0 THEN 'agent' WHEN 1 THEN 'pane' WHEN 2 THEN 'screen'
                   WHEN 3 THEN 'session' WHEN 4 THEN 'tab' WHEN 5 THEN 'terminal'
                   ELSE 'workspace' END,
            CASE k WHEN 3 THEN 'session_000000000000400080000000000000a1'
                   ELSE printf(
                     '%s_%08x%024x',
                     CASE k WHEN 0 THEN 'agent' WHEN 1 THEN 'pane' WHEN 2 THEN 'screen'
                            WHEN 4 THEN 'tab' WHEN 5 THEN 'term' ELSE 'ws' END,
                     (CASE WHEN k IN (2, 6) THEN t / 4 ELSE t END * 2654435761) % 4294967296,
                     CASE WHEN k IN (2, 6) THEN t / 4 ELSE t END)
                   END
       FROM place CROSS JOIN kinds";

/// The frames that the WAL file got after the read before: the page number
/// of each. `seen` is the WAL's salts and the count of its frames at that
/// read; a WAL that started again gives all its frames.
fn new_frames(database: &Path, seen: &mut (Vec<u8>, usize)) -> Vec<u32> {
    let mut path = database.as_os_str().to_owned();
    path.push("-wal");
    let bytes = std::fs::read(&path).unwrap_or_default();
    let Some(header) = bytes.get(..32) else {
        *seen = (Vec::new(), 0);
        return Vec::new();
    };
    let page = u32::from_be_bytes(header[8..12].try_into().unwrap()) as usize;
    let salts = header[16..24].to_vec();
    let mut pages = Vec::new();
    if page > 0 {
        for frame in bytes[32..].chunks_exact(24 + page) {
            if frame[8..16] != salts[..] {
                break;
            }
            pages.push(u32::from_be_bytes(frame[..4].try_into().unwrap()));
        }
    }
    let from = if salts == seen.0 && pages.len() >= seen.1 { seen.1 } else { 0 };
    *seen = (salts, pages.len());
    pages[from..].to_vec()
}

/// The b-tree of each page, and the pages of each b-tree by their kind.
fn pages_of(store: &rusqlite::Connection) -> (BTreeMap<u32, String>, BTreeMap<String, usize>) {
    let mut statement = store.prepare("SELECT pageno, name, pagetype FROM dbstat").unwrap();
    let found = statement
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, String>(1)?, row.get::<_, String>(2)?))
        })
        .unwrap();
    let mut trees = BTreeMap::new();
    let mut counts = BTreeMap::<String, usize>::new();
    for row in found {
        let (page, name, kind) = row.unwrap();
        *counts.entry(format!("{name} {kind}")).or_default() += 1;
        trees.insert(u32::try_from(page).unwrap(), name);
    }
    (trees, counts)
}

/// A count of hundredths as a number with 2 decimals.
fn hundredths(value: usize) -> String {
    format!("{}.{:02}", value / 100, value % 100)
}

#[test]
fn the_frames_of_the_subject_rows_of_one_journal_row_by_the_size_of_the_store() {
    let root = std::env::temp_dir()
        .join(format!("cmux-subject-size-{}", crate::workspace_registry::new_uuid_v4()));
    std::fs::create_dir_all(&root).unwrap();
    let database = root.join("subjects.sqlite3");
    let store = rusqlite::Connection::open(&database).unwrap();
    store.execute_batch(SETTINGS).unwrap();

    let mut lines = Vec::new();
    let mut size = 0;
    for wanted in SIZES {
        while size < wanted {
            let to = (size + CHUNK).min(wanted);
            store.execute(SUBJECT_ROWS, [size, to]).unwrap();
            size = to;
        }
        let busy: i64 =
            store.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |row| row.get(0)).unwrap();
        let mut seen = (Vec::new(), 0);
        new_frames(&database, &mut seen);
        let mut commits = Vec::new();
        for _ in 0..ROWS {
            store.execute(SUBJECT_ROWS, [size, size + 1]).unwrap();
            size += 1;
            commits.push(new_frames(&database, &mut seen));
        }
        let (trees, counts) = pages_of(&store);
        // For each b-tree: the frames of the 100 commits, and the most of one.
        let mut by_tree = BTreeMap::<&str, (usize, usize)>::new();
        let (mut all, mut most) = (0, 0);
        for commit in &commits {
            let mut of_commit = BTreeMap::<&str, usize>::new();
            for page in commit {
                *of_commit.entry(trees.get(page).map_or(NO_TREE, String::as_str)).or_default() += 1;
            }
            for (tree, frames) in of_commit {
                let entry = by_tree.entry(tree).or_default();
                entry.0 += frames;
                entry.1 = entry.1.max(frames);
            }
            all += commit.len();
            most = most.max(commit.len());
        }
        let rows = usize::try_from(ROWS).unwrap();
        let by_tree = by_tree
            .into_iter()
            .map(|(tree, (frames, most))| {
                format!("{tree}: mean {}, max {most}", hundredths(frames * 100 / rows))
            })
            .collect::<Vec<_>>();
        let line = format!(
            "M5 AFTER THE SUBJECT ROWS OF {} JOURNAL ROWS (7 each): {ROWS} journal rows more, one \
             commit each: ALL FRAMES A ROW: mean {}, max {most} | BY B-TREE: {} | the pages of \
             each b-tree by their kind after the {ROWS}: {counts:?} | the checkpoint before \
             them said busy: {busy}",
            size - ROWS,
            hundredths(all * 100 / rows),
            by_tree.join("; ")
        );
        eprintln!("{line}");
        lines.push(line);
        if wanted == SIZES[0] {
            let subjects: i64 = store
                .query_row(
                    "SELECT COUNT(*) FROM (SELECT DISTINCT kind, id FROM journal_subject_index)",
                    [],
                    |row| row.get(0),
                )
                .unwrap();
            lines.push(format!("M5 THE SUBJECTS (a kind with an id) in the store: {subjects}"));
        }
    }
    drop(store);
    let _ = std::fs::remove_dir_all(&root);
    panic!("MEASURE (it fails by design):\n{}", lines.join("\n"));
}
