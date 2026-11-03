//! A Codex state database write costs the threads it changed, not the table.
//!
//! Every Codex process writes `state_<n>.sqlite` (its WAL) about once a second, and each write is
//! a store change for the chat index. Reading the whole `threads` table again for each one kept
//! acpmux's chat watcher reading ~40 MB/s on a lane VM (2026-10-31): 3,268 threads, each
//! row holding its first prompt three times (`title`, `preview`, `first_user_message`, ~29 KB
//! each), so one read was 391 MB and ~200 ms while about two rows had changed.

use cmux_chat_index::{
    AdapterKind, ChatIndex, ChatRoot, IndexedChat, RootSource, forget_codex_reads,
};
use rusqlite::Connection;
use std::path::{Path, PathBuf};

const THREADS: usize = 400;

fn id(i: usize) -> String {
    format!("019a0000-0000-7000-8000-{i:012}")
}

/// A prompt as long as the ones Codex keeps, its first line unique to the thread.
fn prompt(i: usize) -> String {
    format!("prompt for thread {i}\n{}", "context line\n".repeat(1_200))
}

/// A Codex state database with the column order Codex uses (the prompt columns before the
/// millisecond times, the source and the name). Kept open in WAL mode, as a running Codex keeps
/// it.
fn codex_db(codex: &Path) -> Connection {
    std::fs::create_dir_all(codex).unwrap();
    let conn = Connection::open(codex.join("state_5.sqlite")).unwrap();
    // As Codex makes it (`PRAGMA auto_vacuum` = 2): its pointer map lets SQLite pass a row's
    // overflow pages without reading them, to the small columns stored after the prompts.
    conn.execute_batch("pragma auto_vacuum = incremental").unwrap();
    let _: String = conn.query_row("pragma journal_mode=wal", [], |row| row.get(0)).unwrap();
    conn.execute_batch(
        "create table threads (
            id text primary key, rollout_path text not null, created_at integer not null,
            updated_at integer not null, source text, cwd text not null, title text not null,
            has_user_event integer not null default 0, archived integer not null default 0,
            first_user_message text not null default '', agent_nickname text, agent_role text,
            created_at_ms integer, updated_at_ms integer, thread_source text,
            preview text not null default '', name text, originator text);
         create index idx_threads_updated_at_ms on threads(updated_at_ms desc, id desc);
         create table thread_spawn_edges (
            parent_thread_id text not null, child_thread_id text not null primary key,
            status text not null);",
    )
    .unwrap();
    let tx = conn.unchecked_transaction().unwrap();
    for i in 0..THREADS {
        insert(&conn, i, &prompt(i));
    }
    tx.commit().unwrap();
    conn
}

fn insert(conn: &Connection, i: usize, text: &str) {
    let ms = 1_759_312_800_000 + i as i64 * 1_000;
    conn.execute(
        "insert into threads (id, rollout_path, created_at, updated_at, source, cwd, title,
            has_user_event, first_user_message, created_at_ms, updated_at_ms, preview, originator)
         values (?1, '', ?2, ?2, 'cli', '/work/app', ?3, 1, ?3, ?4, ?4, ?3, 'codex_cli_rs')",
        (id(i), ms / 1_000, text, ms),
    )
    .unwrap();
}

fn root(codex: &Path) -> ChatRoot {
    ChatRoot {
        harness: AdapterKind::Codex,
        path: codex.to_path_buf(),
        real_path: codex.canonicalize().unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    }
}

fn wal(codex: &Path) -> Vec<PathBuf> {
    vec![codex.join("state_5.sqlite-wal")]
}

/// Bytes this thread has read so far (rusqlite reads on the calling thread).
#[cfg(target_os = "linux")]
fn thread_read_bytes() -> u64 {
    let io = std::fs::read_to_string("/proc/thread-self/io").unwrap();
    io.lines().find_map(|line| line.strip_prefix("rchar: ")).unwrap().trim().parse().unwrap()
}

fn chats(index: &ChatIndex) -> Vec<IndexedChat> {
    index.chats().into_iter().cloned().collect()
}

/// What a new index reads from the whole table now: the result every incremental read must
/// equal. The last read is forgotten first, so this read shares nothing with the one it checks.
fn fresh(codex: &Path) -> Vec<IndexedChat> {
    forget_codex_reads(codex);
    let mut index = ChatIndex::new(vec![root(codex)]);
    index.rescan_all();
    chats(&index)
}

#[cfg(target_os = "linux")]
#[test]
fn a_thread_update_reads_that_thread_not_the_table() {
    let home = tempfile::tempdir().unwrap();
    let codex = home.path().join(".codex");
    let writer = codex_db(&codex);
    let mut index = ChatIndex::new(vec![root(&codex)]);
    index.rescan_all();
    assert_eq!(index.chats().len(), THREADS);
    let table = std::fs::metadata(codex.join("state_5.sqlite")).unwrap().len()
        + std::fs::metadata(codex.join("state_5.sqlite-wal")).unwrap().len();

    // Codex bumps one thread's time, as it does on every turn.
    writer
        .execute(
            "update threads set updated_at = updated_at + 60, updated_at_ms = updated_at_ms + 60000
             where id = ?1",
            [id(7)],
        )
        .unwrap();
    let before = thread_read_bytes();
    let changes = index.paths_changed(&wal(&codex));
    let read = thread_read_bytes() - before;

    assert_eq!(changes.len(), 1, "one thread changed: {changes:?}");
    // Every row's key costs its header and small columns (~10% of this database); the prompts
    // are what a whole read pays for (~70%).
    assert!(
        read < table / 4,
        "one changed thread read {read} bytes of a {table}-byte database (a whole-table read)"
    );
    assert_eq!(chats(&index), fresh(&codex));
}

/// Codex writes some columns without bumping `updated_at_ms` (`UPDATE threads SET name = ?`,
/// `SET title = ?`): those changes, removals and spawn edges still reach the index.
#[test]
fn every_store_change_matches_a_fresh_read() {
    let home = tempfile::tempdir().unwrap();
    let codex = home.path().join(".codex");
    let writer = codex_db(&codex);
    let mut index = ChatIndex::new(vec![root(&codex)]);
    index.rescan_all();
    let steps: &[(&str, &str)] = &[
        ("a title, no time bump", "update threads set title = 'Fix the login page' where id = ?1"),
        ("a name, no time bump", "update threads set name = 'Login work' where id = ?1"),
        ("the same name's length, no bump", "update threads set name = 'Login wore' where id = ?1"),
        ("the created time only", "update threads set created_at_ms = 5 where id = ?1"),
        ("a cwd, no time bump", "update threads set cwd = '/work/api' where id = ?1"),
        ("archived, no time bump", "update threads set archived = 1 where id = ?1"),
        ("a subagent", "update threads set thread_source = 'subagent' where id = ?1"),
        (
            "spawned",
            "insert into thread_spawn_edges values ('019a0000-0000-7000-8000-000000000001', ?1, 'open')",
        ),
        ("deleted", "delete from threads where id = ?1"),
    ];
    for (i, (what, sql)) in steps.iter().enumerate() {
        let target = if sql.contains("Login wore") { id(20 + i - 1) } else { id(20 + i) };
        writer.execute(sql, [target]).unwrap();
        index.paths_changed(&wal(&codex));
        assert_eq!(chats(&index), fresh(&codex), "after {what}");
    }
    // A thread Codex adds, and a spawn edge it removes.
    insert(&writer, THREADS, "a new chat");
    writer.execute("delete from thread_spawn_edges where child_thread_id = ?1", [id(27)]).unwrap();
    index.paths_changed(&wal(&codex));
    assert_eq!(chats(&index), fresh(&codex), "after a new thread and a removed edge");
    assert_eq!(
        index.chats().len(),
        THREADS - 1,
        "a subagent and a deleted thread go; the unspawned and a new one stay"
    );
}

/// Changes the row keys do not see: a filter that comes with a column, and a spawn edge that names
/// a thread through SQLite's type affinity.
#[test]
fn a_schema_or_affinity_change_matches_a_fresh_read() {
    let home = tempfile::tempdir().unwrap();
    let codex = home.path().join(".codex");
    let writer = codex_db(&codex);
    let mut index = ChatIndex::new(vec![root(&codex)]);
    index.rescan_all();
    // The table named in another case, which SQLite still resolves as `threads`.
    writer
        .execute_batch("alter table threads rename to t; alter table t rename to Threads")
        .unwrap();
    index.paths_changed(&wal(&codex));
    assert_eq!(chats(&index), fresh(&codex), "after the table is renamed");
    // A thread with no user text, in a database with no `has_user_event` column: it is listed.
    writer.execute_batch("alter table threads drop column has_user_event").unwrap();
    writer
        .execute(
            "insert into threads (id, rollout_path, created_at, updated_at, cwd, title)
             values (?1, '', 1759312800, 1759312800, '/work/app', '')",
            [id(THREADS)],
        )
        .unwrap();
    index.paths_changed(&wal(&codex));
    assert_eq!(chats(&index), fresh(&codex), "after the column is dropped");
    // The column comes back, empty: its filter leaves that thread out though no row changed.
    writer.execute_batch("alter table threads add column has_user_event integer").unwrap();
    index.paths_changed(&wal(&codex));
    assert_eq!(chats(&index), fresh(&codex), "after the column is added");

    // Spawn edges whose child column is declared `integer`, so it compares by number.
    writer
        .execute_batch(
            "create table edges (parent_thread_id text, child_thread_id integer, status text);
             insert into edges select * from thread_spawn_edges;
             drop table thread_spawn_edges;
             alter table edges rename to thread_spawn_edges;",
        )
        .unwrap();
    writer
        .execute(
            "insert into threads (id, rollout_path, created_at, updated_at, cwd, title)
             values ('123', '', 1759312800, 1759312800, '/work/app', 'A numbered thread')",
            [],
        )
        .unwrap();
    index.paths_changed(&wal(&codex));
    assert_eq!(chats(&index), fresh(&codex), "after a thread with a numeric id");
    // An edge naming it as the integer 123: `id NOT IN (...)` compares '123' as a number and
    // drops it.
    writer.execute("insert into thread_spawn_edges values (?1, 123, 'open')", [id(1)]).unwrap();
    index.paths_changed(&wal(&codex));
    assert_eq!(chats(&index), fresh(&codex), "after an integer spawn edge");
}
