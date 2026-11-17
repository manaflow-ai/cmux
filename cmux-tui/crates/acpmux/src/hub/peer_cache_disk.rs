//! Part of `Hub`; see `hub/mod.rs`. The disk form of a peer's last-known sessions
//! (`peer_cache.rs`): a snapshot `peers/<name>.json` and an append-only `peers/<name>.journal`
//! of what changed since it, so a save costs the rows that changed, not all of them.
//!
//! A peer listing two thousand sessions kept a 9 MB snapshot, rewritten whole at each throttled
//! save and at each parked drop: about 300 KB/s while it was busy, and macOS flagged the daemon
//! for disk writes (hang-watch f1c81387ea and cc7d7b55a9, 2026-11-03 to 11-07). Now a save
//! appends one line naming the rows that changed (by `Arc` identity first, then by value, so a
//! row put back unchanged costs nothing), the rows that left (tombstones), and the link's outage
//! metadata, and syncs it. A drop that only parks the next retry appends the link alone.
//!
//! The journal is folded into a fresh snapshot (compaction) at the first save after a daemon
//! starts, after a failed write, when either file is not what this writer last left, and once
//! the journal reaches `max(COMPACT_MIN_BYTES, 2 x snapshot)`: a rewrite of S bytes follows at
//! least 2S bytes of changes, so the amortized cost of a change stays a constant multiple of
//! the change, however many rows the peer lists.
//!
//! The snapshot keeps the format older daemons read, plus a `journal` id. Each journal line
//! names the snapshot it follows (`base`); a line of another snapshot is ignored, and so is the
//! whole journal under a snapshot without an id (an older daemon rewrote it), so an old journal
//! never lands on a newer snapshot. A torn line (a crash mid-append) does not parse and is
//! skipped. An older daemon reading these files sees the snapshot as of the last compaction:
//! the same rows, possibly older, all marked stale until the peer lists them again.

use super::*;

/// The journal is folded into the snapshot once it reaches this size or twice the snapshot's.
pub(super) const COMPACT_MIN_BYTES: u64 = 64 * 1024;

/// The snapshot file: what older daemons read (`journal` is new and optional).
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Saved {
    pub(super) last_seen: Option<u64>,
    #[serde(default)]
    pub(super) down_since: Option<u64>,
    #[serde(default)]
    pub(super) next_retry_at: Option<u64>,
    pub(super) sessions: Vec<Value>,
    /// The id the journal's lines name; none from an older daemon.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(super) journal: Option<u64>,
}

/// The link's outage metadata, saved with each snapshot and each journal line.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct Link {
    #[serde(default)]
    pub(super) last_seen: Option<u64>,
    #[serde(default)]
    pub(super) down_since: Option<u64>,
    #[serde(default)]
    pub(super) next_retry_at: Option<u64>,
}

/// One journal line as written: rows by key, borrowed from the hub's.
#[derive(serde::Serialize)]
struct EntryOut<'a> {
    base: u64,
    link: Link,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    set: Vec<(&'a str, &'a Value)>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    drop: Vec<&'a str>,
}

/// One journal line as read.
#[derive(serde::Deserialize)]
struct EntryIn {
    base: u64,
    link: Link,
    #[serde(default)]
    set: Vec<(String, Value)>,
    #[serde(default)]
    drop: Vec<String>,
}

/// What this writer last left on disk for one peer: the rows, the link, and both files'
/// lengths. `None` until the first save of this daemon, and after a failed write: the next save
/// writes a snapshot.
#[derive(Default)]
pub(crate) struct OnDisk(Option<Written>);

type Rows = HashMap<String, Kept>;

/// One row: the version on disk, and the hub's `Arc` last found to load as it, so an unchanged
/// row is found by pointer at the next save.
struct Kept {
    disk: Arc<RemoteSession>,
    seen: Arc<RemoteSession>,
}

impl Kept {
    fn new(row: &Arc<RemoteSession>) -> Self {
        Kept { disk: row.clone(), seen: row.clone() }
    }
}

struct Written {
    base: u64,
    rows: Rows,
    link: Link,
    snapshot_len: u64,
    /// When the snapshot was written: a replacement of the same length is still found.
    snapshot_modified: Option<std::time::SystemTime>,
    journal_len: u64,
}

pub(super) fn snapshot_path(dir: &Path, peer: &str) -> Option<std::path::PathBuf> {
    crate::session_name::validate(peer).ok()?;
    Some(dir.join(format!("{peer}.json")))
}

pub(super) fn journal_path(dir: &Path, peer: &str) -> Option<std::path::PathBuf> {
    crate::session_name::validate(peer).ok()?;
    Some(dir.join(format!("{peer}.journal")))
}

/// A snapshot id no earlier snapshot of this home used.
fn fresh_base(after: Option<u64>) -> u64 {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_nanos() as u64);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    nanos.wrapping_add(n).max(after.map_or(0, |a| a.wrapping_add(1))).max(1)
}

/// What `kept` becomes for the hub's row `now`, if loading the disk gives `now` back: the same
/// row, or the same row marked stale (a load marks every row stale itself,
/// `peer_cache::mark_stale`), so a peer that goes down and comes back writes no row it did not
/// change. `None`: the row changed.
fn still_on_disk(kept: &Kept, now: &Arc<RemoteSession>, link: &Link) -> Option<Kept> {
    if Arc::ptr_eq(&kept.seen, now) {
        return Some(Kept { disk: kept.disk.clone(), seen: now.clone() });
    }
    if kept.disk.summary == now.summary {
        return Some(Kept::new(now));
    }
    if now.summary.get("stale").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let mut loaded = kept.disk.summary.clone();
    super::peer_cache::mark_stale(&mut loaded, link.last_seen);
    (loaded == now.summary).then(|| Kept { disk: kept.disk.clone(), seen: now.clone() })
}

/// The bytes one save wrote, by file.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(crate) struct Wrote {
    pub(crate) snapshot: u64,
    pub(crate) journal: u64,
}

impl Wrote {
    pub(crate) fn total(self) -> u64 {
        self.snapshot + self.journal
    }
}

impl OnDisk {
    /// Brings `peer`'s files in `dir` to `rows` and `link`: one journal line of what changed, or
    /// a snapshot when one is due. Nothing changed, nothing is written.
    pub(super) fn save(
        &mut self,
        dir: &Path,
        peer: &str,
        rows: Vec<(String, Arc<RemoteSession>)>,
        link: Link,
    ) -> anyhow::Result<Wrote> {
        let (Some(snap), Some(journal)) = (snapshot_path(dir, peer), journal_path(dir, peer))
        else {
            anyhow::bail!("{peer:?} is not a peer name");
        };
        crate::config::private_state_dir(dir)?;
        enum Plan {
            Same(Rows),
            Append(Vec<u8>, Rows),
            Compact,
        }
        let plan = match self.0.as_ref().filter(|w| files_are(w, &snap, &journal)) {
            None => Plan::Compact,
            Some(written) => match line_for(written, &rows, link)? {
                (None, kept) => Plan::Same(kept),
                (Some(line), kept) => {
                    let limit = COMPACT_MIN_BYTES.max(written.snapshot_len.saturating_mul(2));
                    if written.journal_len + line.len() as u64 > limit {
                        Plan::Compact
                    } else {
                        Plan::Append(line, kept)
                    }
                }
            },
        };
        let result = match plan {
            Plan::Same(kept) => {
                // Disk already says this; keep this save's `Arc`s so the next compares by
                // pointer again.
                if let Some(w) = self.0.as_mut() {
                    w.rows = kept;
                }
                return Ok(Wrote::default());
            }
            Plan::Append(line, kept) => match self.0.as_mut() {
                Some(written) => append(written, dir, &journal, &line, kept, link),
                None => self.compact(&snap, &journal, rows, link),
            },
            Plan::Compact => self.compact(&snap, &journal, rows, link),
        };
        if result.is_err() {
            // What is on disk is no longer known: the next save writes it whole.
            self.0 = None;
        }
        result
    }

    fn compact(
        &mut self,
        snap: &Path,
        journal: &Path,
        rows: Vec<(String, Arc<RemoteSession>)>,
        link: Link,
    ) -> anyhow::Result<Wrote> {
        let base = fresh_base(self.0.as_ref().map(|w| w.base));
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct SavedOut<'a> {
            last_seen: Option<u64>,
            down_since: Option<u64>,
            next_retry_at: Option<u64>,
            sessions: Vec<&'a Value>,
            journal: u64,
        }
        let bytes = serde_json::to_vec(&SavedOut {
            last_seen: link.last_seen,
            down_since: link.down_since,
            next_retry_at: link.next_retry_at,
            sessions: rows.iter().map(|(_, r)| &r.summary).collect(),
            journal: base,
        })?;
        // The snapshot first: a crash before the journal is emptied leaves lines of the old
        // base, which a load ignores.
        crate::config::write_atomic(snap, &bytes)?;
        match std::fs::remove_file(journal) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.into()),
        }
        let snapshot_modified = std::fs::metadata(snap).and_then(|m| m.modified()).ok();
        self.0 = Some(Written {
            base,
            rows: rows.into_iter().map(|(key, row)| (key, Kept::new(&row))).collect(),
            link,
            snapshot_len: bytes.len() as u64,
            snapshot_modified,
            journal_len: 0,
        });
        Ok(Wrote { snapshot: bytes.len() as u64, journal: 0 })
    }
}

/// Appends `line` to the journal and syncs it; a new journal's directory entry is synced too,
/// so a power loss does not lose the file the line went to.
fn append(
    written: &mut Written,
    dir: &Path,
    journal: &Path,
    line: &[u8],
    rows: Rows,
    link: Link,
) -> anyhow::Result<Wrote> {
    use std::io::Write;
    let mut file = crate::config::private_state_append(journal)?;
    file.write_all(line)?;
    file.sync_data()?;
    #[cfg(unix)]
    if written.journal_len == 0 {
        std::fs::File::open(dir)?.sync_all()?;
    }
    #[cfg(not(unix))]
    let _ = dir;
    written.journal_len += line.len() as u64;
    written.rows = rows;
    written.link = link;
    Ok(Wrote { snapshot: 0, journal: line.len() as u64 })
}

/// Whether both files are as `written` left them (no other writer, no removal since).
fn files_are(written: &Written, snap: &Path, journal: &Path) -> bool {
    let modified = std::fs::metadata(snap).and_then(|m| m.modified()).ok();
    if modified.is_none() || modified != written.snapshot_modified {
        return false;
    }
    let len = |p: &Path| match std::fs::symlink_metadata(p) {
        Ok(m) if m.is_file() => Some(m.len()),
        Ok(_) => None,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Some(0),
        Err(_) => None,
    };
    len(snap) == Some(written.snapshot_len) && len(journal) == Some(written.journal_len)
}

/// The journal line that brings `written` to `rows` and `link` (none when it says that
/// already), and the rows disk holds once it is written.
fn line_for(
    written: &Written,
    rows: &[(String, Arc<RemoteSession>)],
    link: Link,
) -> anyhow::Result<(Option<Vec<u8>>, Rows)> {
    let mut set = Vec::new();
    let mut kept = Rows::with_capacity(rows.len());
    let mut seen = 0usize;
    for (key, row) in rows {
        let still = written.rows.get(key).and_then(|old| {
            seen += 1;
            still_on_disk(old, row, &link)
        });
        let next = still.unwrap_or_else(|| {
            set.push((key.as_str(), &row.summary));
            Kept::new(row)
        });
        kept.insert(key.clone(), next);
    }
    let mut drop = Vec::new();
    if seen != written.rows.len() {
        let now: std::collections::HashSet<&str> = rows.iter().map(|(k, _)| k.as_str()).collect();
        drop.extend(written.rows.keys().map(String::as_str).filter(|k| !now.contains(k)));
    }
    if set.is_empty() && drop.is_empty() && link == written.link {
        return Ok((None, kept));
    }
    let mut line = serde_json::to_vec(&EntryOut { base: written.base, link, set, drop })?;
    line.push(b'\n');
    Ok((Some(line), kept))
}

/// `peer`'s saved state: the snapshot with its journal's lines applied, or none.
pub(super) fn load(dir: &Path, peer: &str) -> Option<Saved> {
    let bytes = std::fs::read(snapshot_path(dir, peer)?).ok()?;
    let mut saved = serde_json::from_slice::<Saved>(&bytes).ok()?;
    let Some(base) = saved.journal else { return Some(saved) };
    let Ok(journal) = std::fs::read(journal_path(dir, peer)?) else { return Some(saved) };
    let entries: Vec<EntryIn> = journal
        .split(|b| *b == b'\n')
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_slice::<EntryIn>(line).ok())
        .filter(|entry| entry.base == base)
        .collect();
    if entries.is_empty() {
        return Some(saved);
    }
    // Rows by key, in snapshot order, then in the order the journal added them.
    let mut order: Vec<String> = Vec::with_capacity(saved.sessions.len());
    let mut rows: HashMap<String, Value> = HashMap::with_capacity(saved.sessions.len());
    for summary in std::mem::take(&mut saved.sessions) {
        let Some(receipt) = super::peers::session_receipt(&summary) else { continue };
        let key = receipt.qualified_id();
        if rows.insert(key.clone(), summary).is_none() {
            order.push(key);
        }
    }
    for entry in entries {
        saved.last_seen = entry.link.last_seen;
        saved.down_since = entry.link.down_since;
        saved.next_retry_at = entry.link.next_retry_at;
        for key in entry.drop {
            rows.remove(&key);
        }
        for (key, summary) in entry.set {
            if rows.insert(key.clone(), summary).is_none() {
                order.push(key);
            }
        }
    }
    saved.sessions = order.into_iter().filter_map(|key| rows.remove(&key)).collect();
    Some(saved)
}

/// Removes both of `peer`'s files.
pub(super) fn remove(dir: &Path, peer: &str) {
    for path in [snapshot_path(dir, peer), journal_path(dir, peer)].into_iter().flatten() {
        let _ = std::fs::remove_file(path);
    }
}

/// `peer`'s saved state as JSON, journal applied: what a test reads instead of the snapshot.
#[cfg(test)]
pub(crate) fn saved_json(dir: &Path, peer: &str) -> Value {
    let Some(saved) = load(dir, peer) else { return Value::Null };
    json!({
        "lastSeen": saved.last_seen,
        "downSince": saved.down_since,
        "nextRetryAt": saved.next_retry_at,
        "sessions": saved.sessions,
    })
}
