//! The JSONL layout (`main/YYYY-MM-DD.jsonl`, `tree/YYYY-MM-DD.jsonl`): the
//! store before 2026-10-06, and the text export since. `import_legacy`
//! reads either into an empty database in one transaction and checks the
//! result against what it read; `migrate_legacy` does that once for a home
//! that still has only the old files, after copying them aside.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::{Path, PathBuf};

use optchat_core::{Kind, NodeId};
use rusqlite::{params, Connection};
use serde_json::json;

use super::{sql, write_state, Db};
use crate::fault::fault;
use crate::lines::{self, MainLine, TreeIn};
use crate::report::Report;

/// The state key that records a finished migration (JSON: source, backup,
/// counts, hash). Its presence makes the migration run at most once.
pub const MIGRATION_KEY: &str = "memory/migration";

/// Built nodes with their text sizes, for `Memory::load`.
pub type Built = Vec<(NodeId, usize)>;

/// The state write an import commits with its rows (key, JSON value).
pub type Marker<'a> = &'a dyn Fn(&Imported) -> (String, String);

/// What an import read and stored.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Imported {
    pub messages: u64,
    pub nodes: u64,
    /// Hash of every stored line (order-independent), equal on both sides.
    pub hash: String,
    /// Lines skipped (torn, invalid, duplicate or past the end).
    pub skipped: usize,
}

fn jsonl_files(dir: &Path) -> io::Result<Vec<PathBuf>> {
    let mut files: Vec<PathBuf> = match fs::read_dir(dir) {
        Ok(entries) => entries
            .filter_map(|e| e.ok())
            .map(|e| e.path())
            .filter(|p| p.extension().is_some_and(|x| x == "jsonl"))
            .collect(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(e),
    };
    files.sort();
    Ok(files)
}

/// Whether `dir` holds a JSONL layout with at least one non-empty day file.
pub fn has_legacy(dir: &Path) -> bool {
    ["main", "tree"].iter().any(|stream| {
        jsonl_files(&dir.join(stream)).is_ok_and(|files| {
            files
                .iter()
                .any(|f| fs::metadata(f).is_ok_and(|m| m.len() > 0))
        })
    })
}

/// The non-empty lines of one file with their 1-based numbers. A last line
/// without its newline (a crash mid-write) is still read, and reported; the
/// file is never changed.
fn file_lines(path: &Path, reports: &mut Vec<Report>) -> io::Result<Vec<(usize, Vec<u8>)>> {
    let bytes = fs::read(path)?;
    if !bytes.is_empty() && bytes.last() != Some(&b'\n') {
        reports.push(Report::MissingNewline {
            file: path.to_path_buf(),
        });
    }
    Ok(bytes
        .split(|b| *b == b'\n')
        .enumerate()
        .filter(|(_, l)| !l.is_empty())
        .map(|(n, l)| (n + 1, l.to_vec()))
        .collect())
}

fn day_of_file(path: &Path) -> String {
    path.file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("0000-00-00")
        .to_owned()
}

/// FNV-1a 64 of one line.
fn fnv(bytes: &[u8]) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= u64::from(*b);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// The stored side of the check: the same lines rendered from the rows.
fn stored_hash(conn: &Connection) -> io::Result<(u64, u64)> {
    let mut messages = 0u64;
    let mut stmt = conn
        .prepare("SELECT id, kind, text, date FROM messages")
        .map_err(sql)?;
    let mut rows = stmt.query([]).map_err(sql)?;
    while let Some(r) = rows.next().map_err(sql)? {
        let (i, kind, text, date): (i64, String, String, String) = (
            r.get(0).map_err(sql)?,
            r.get(1).map_err(sql)?,
            r.get(2).map_err(sql)?,
            r.get(3).map_err(sql)?,
        );
        let kind = Kind::parse(&kind).ok_or_else(|| io::Error::other("unknown kind stored"))?;
        messages = messages.wrapping_add(fnv(
            lines::main_line(i as u64, kind, &text, &date).as_bytes()
        ));
    }
    let mut nodes = 0u64;
    let mut stmt = conn
        .prepare("SELECT level, idx, text FROM nodes")
        .map_err(sql)?;
    let mut rows = stmt.query([]).map_err(sql)?;
    while let Some(r) = rows.next().map_err(sql)? {
        let (l, i, text): (i64, i64, String) = (
            r.get(0).map_err(sql)?,
            r.get(1).map_err(sql)?,
            r.get(2).map_err(sql)?,
        );
        let node = NodeId::new(l as u32, i as u64);
        nodes = nodes.wrapping_add(fnv(lines::tree_line(node, &text).as_bytes()));
    }
    Ok((messages, nodes))
}

fn invalid(what: String) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, what)
}

/// Imports the JSONL layout under `dir` into the EMPTY database `db`, in
/// one transaction, with `marker`'s state write (if any) in the same one.
/// Invalid lines (a crash mid-write) are reported and skipped, as the line
/// store's load did; message ids must be exactly 0..T. Before it commits it
/// renders every stored row again and checks counts and hash against what
/// it read, so a bad import leaves the database empty.
pub fn import_legacy(
    db: &mut Db,
    dir: &Path,
    reports: &mut Vec<Report>,
    marker: Option<Marker<'_>>,
) -> io::Result<(Imported, Built)> {
    if !db.is_empty() || db.node_count() > 0 {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "the memory is not empty; import needs an empty memory",
        ));
    }
    let tx = db.conn_mut().transaction().map_err(sql)?;
    let mut skipped = 0usize;
    let (mut read_m, mut read_n) = (0u64, 0u64);
    let mut t = 0u64;
    {
        let mut insert = tx
            .prepare("INSERT INTO messages (id, kind, date, day, text) VALUES (?1, ?2, ?3, ?4, ?5)")
            .map_err(sql)?;
        for path in jsonl_files(&dir.join("main"))? {
            let day = day_of_file(&path);
            for (n, line) in file_lines(&path, reports)? {
                let parsed = serde_json::from_slice::<MainLine>(&line)
                    .map_err(|e| e.to_string())
                    .and_then(|m| match Kind::parse(&m.kind) {
                        Some(kind) => Ok((m, kind)),
                        None => Err(format!("unknown kind {:?}", m.kind)),
                    });
                let (m, kind) = match parsed {
                    Ok(p) => p,
                    Err(error) => {
                        skipped += 1;
                        reports.push(Report::InvalidLine {
                            file: path.clone(),
                            line: n,
                            error,
                        });
                        continue;
                    }
                };
                if m.i > i64::MAX as u64 {
                    return Err(invalid(format!("message id {} is out of range", m.i)));
                }
                match insert.execute(params![m.i as i64, kind.as_str(), m.date, day, m.text]) {
                    Ok(_) => {}
                    Err(rusqlite::Error::SqliteFailure(e, _))
                        if e.code == rusqlite::ErrorCode::ConstraintViolation =>
                    {
                        return Err(invalid(format!("message id {} appears twice", m.i)));
                    }
                    Err(e) => return Err(sql(e)),
                }
                read_m = read_m
                    .wrapping_add(fnv(lines::main_line(m.i, kind, &m.text, &m.date).as_bytes()));
                t += 1;
            }
        }
        // Ids are global and files split by local day; a clock moved back can
        // put a later id in an earlier file, so only the set must be 0..T.
        let top: i64 = tx
            .query_row("SELECT COALESCE(MAX(id) + 1, 0) FROM messages", [], |r| {
                r.get(0)
            })
            .map_err(sql)?;
        if top as u64 != t {
            return Err(invalid(format!(
                "message ids are not contiguous: {t} messages, the largest id is {}",
                top - 1
            )));
        }
        let mut insert = tx
            .prepare(
                "INSERT INTO nodes (level, idx, bytes, day, text) VALUES (?1, ?2, ?3, ?4, ?5) \
                 ON CONFLICT (level, idx) DO NOTHING",
            )
            .map_err(sql)?;
        for path in jsonl_files(&dir.join("tree"))? {
            let day = day_of_file(&path);
            for (n, line) in file_lines(&path, reports)? {
                let node = match serde_json::from_slice::<TreeIn>(&line) {
                    Ok(node) if node.l < 64 => node,
                    Ok(_) => {
                        skipped += 1;
                        reports.push(Report::InvalidLine {
                            file: path.clone(),
                            line: n,
                            error: "level out of range".to_owned(),
                        });
                        continue;
                    }
                    Err(e) => {
                        skipped += 1;
                        reports.push(Report::InvalidLine {
                            file: path.clone(),
                            line: n,
                            error: e.to_string(),
                        });
                        continue;
                    }
                };
                let id = NodeId::new(node.l, node.i);
                let ignore = |why| Report::IgnoredNode {
                    file: path.clone(),
                    line: n,
                    node: id,
                    why,
                };
                if id.checked_end().is_none_or(|end| end > t) || node.i > i64::MAX as u64 {
                    skipped += 1;
                    reports.push(ignore("past the end of the log"));
                    continue;
                }
                let added = insert
                    .execute(params![
                        node.l as i64,
                        node.i as i64,
                        node.text.len() as i64,
                        day,
                        node.text
                    ])
                    .map_err(sql)?;
                if added == 0 {
                    skipped += 1;
                    reports.push(ignore("already loaded"));
                    continue;
                }
                read_n = read_n.wrapping_add(fnv(lines::tree_line(id, &node.text).as_bytes()));
            }
        }
    }
    let stored_nodes: i64 = tx
        .query_row("SELECT COUNT(*) FROM nodes", [], |r| r.get(0))
        .map_err(sql)?;
    let (stored_m, stored_n) = stored_hash(&tx)?;
    if (stored_m, stored_n) != (read_m, read_n) {
        return Err(invalid(format!(
            "the imported memory does not read back as written (hash {stored_m:016x}{stored_n:016x}, read {read_m:016x}{read_n:016x})"
        )));
    }
    let imported = Imported {
        messages: t,
        nodes: stored_nodes as u64,
        hash: format!("{read_m:016x}{read_n:016x}"),
        skipped,
    };
    if let Some(marker) = marker {
        let (key, value) = marker(&imported);
        write_state(&tx, &[(key, Some(value))])?;
    }
    fault("migrate:before-commit");
    tx.commit().map_err(sql)?;
    let built = db.reload_counts()?;
    Ok((imported, built))
}

fn copy_private(from: &Path, to: &Path) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(to)?;
    for path in jsonl_files(from)? {
        if let Some(name) = path.file_name() {
            let dest = to.join(name);
            fs::copy(&path, &dest)?;
            fs::set_permissions(&dest, fs::Permissions::from_mode(0o600))?;
        }
    }
    Ok(())
}

/// Migrates a home that has only the old JSONL files: copies them into a
/// backup folder next to the database, imports them in one transaction
/// (verified, see `import_legacy`) and records the migration in the same
/// transaction. Runs at most once: a recorded migration, a non-empty
/// database or a directory without day files does nothing (None). A crash
/// before the commit leaves the database empty, so the next start does it
/// again (with a fresh backup folder).
pub fn migrate_legacy(
    db: &mut Db,
    dir: &Path,
    reports: &mut Vec<Report>,
) -> io::Result<Option<(Imported, Built)>> {
    if db.state(MIGRATION_KEY)?.is_some()
        || !db.is_empty()
        || db.node_count() > 0
        || !has_legacy(dir)
    {
        return Ok(None);
    }
    let parent = db
        .path()
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let stamp = chrono::Local::now().format("%Y%m%d-%H%M%S-%3f");
    let backup = parent.join(format!("memory-jsonl-backup-{stamp}"));
    copy_private(&dir.join("main"), &backup.join("main"))?;
    copy_private(&dir.join("tree"), &backup.join("tree"))?;
    fault("migrate:after-backup");
    let source = dir.to_path_buf();
    let kept = backup.clone();
    let marker = move |i: &Imported| {
        let value = json!({
            "from": source.display().to_string(),
            "backup": kept.display().to_string(),
            "messages": i.messages,
            "nodes": i.nodes,
            "hash": i.hash,
            "skipped": i.skipped,
            "schema": super::SCHEMA_VERSION,
            "at": lines::now_iso(),
        });
        (MIGRATION_KEY.to_owned(), value.to_string())
    };
    let (imported, built) = import_legacy(db, dir, reports, Some(&marker))?;
    reports.push(Report::Migrated {
        messages: imported.messages,
        nodes: imported.nodes,
        hash: imported.hash.clone(),
        backup,
    });
    Ok(Some((imported, built)))
}
