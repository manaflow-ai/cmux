//! The daemon stores a rollback must check (plans/cmux-next/updates-and-announcements.md,
//! Rollback): the newest schema of each store this build reads, and the
//! newest schema each store holds on disk. An older build refuses to open a
//! store whose schema is newer than its own, so the app compares the two
//! before it swaps in a kept build.

use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use rusqlite::{Connection, OpenFlags, OptionalExtension};

/// Every store a rollback checks: its name, its file in a session directory,
/// and the newest schema this build reads.
const STORES: &[(&str, &str, i64)] = &[
    (
        "workspace_registry",
        crate::workspace_registry::WORKSPACE_REGISTRY_FILE,
        crate::workspace_registry::SCHEMA_VERSION,
    ),
    (
        "conversation_store",
        crate::conversation_store::CONVERSATIONS_FILE,
        crate::conversation_store::SCHEMA_VERSION,
    ),
];

/// The newest schema of every store this build reads.
pub fn readable() -> BTreeMap<String, i64> {
    STORES.iter().map(|(name, _, version)| ((*name).to_string(), *version)).collect()
}

/// What a check of the stored schemas found.
#[derive(Debug, PartialEq, Eq)]
pub enum Stored {
    /// Each session was read: the newest schema each store holds.
    Schemas(BTreeMap<String, i64>),
    /// The check's time ended first. `sessions` session folders of the state
    /// root hold a store, and this call read `sessions_read` of them.
    NotReady { sessions: usize, sessions_read: usize },
}

/// The newest schema each store holds in any session under `state_root`.
/// A store that no session has written yet is absent. A store that cannot be
/// read is an error: the caller must not guess.
///
/// `end` is the check's end time. The caller of the check ends its process
/// after a fixed time, and a check that is ended gives no answer. So before
/// each session after the first, the check reads the clock; at or after
/// `end` it stops and says how far it is ([`Stored::NotReady`]). The first
/// session of a call is always read, so each call reads 1 session or more.
/// The check keeps nothing between 2 calls: a call after it starts at the
/// first session again, in the same order (the session folders sorted by
/// path), and is faster only because the files are in the file cache. With
/// no `end` it reads each session. A caller that carries a place from one
/// call to the next uses [`stored_from`].
pub fn stored_until(state_root: &Path, end: Option<Instant>) -> anyhow::Result<Stored> {
    stored_from(state_root, end, None, 0).map(|(stored, _)| stored)
}

/// How far the calls of one check are: what a call that stops before its end
/// gives to its caller, and what the caller gives back to the next call.
///
/// `after` is the name of a session folder, and a session folder's name is a
/// session's id: a place goes from the check to its caller and back only.
/// The check writes it to no log and prints it in no error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Place {
    /// The name of the last session folder that the calls so far read. The
    /// next call goes on at the first name that sorts after it, so a folder
    /// of this name that is no longer there is no error.
    pub after: String,
    /// The newest schema of each store in the sessions read so far.
    pub found: BTreeMap<String, i64>,
    /// The start of the first call, in milliseconds since 1970 by the wall
    /// clock: a file time is compared with it.
    pub since_ms: u64,
}

impl Place {
    /// The place that `text` is: one JSON object with `after`, `found` and
    /// `since_ms` and no other part. Nil for each other text; the caller of
    /// this function must not print `text`.
    pub fn of(text: &str) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_str(text).ok()?;
        let parts = value.as_object()?;
        if parts.len() != 3 {
            return None;
        }
        let after = parts.get("after")?.as_str()?.to_string();
        let since_ms = parts.get("since_ms")?.as_u64()?;
        let mut found = BTreeMap::new();
        for (name, number) in parts.get("found")?.as_object()? {
            if !STORES.iter().any(|(store, _, _)| *store == name.as_str()) {
                return None;
            }
            found.insert(name.clone(), number.as_i64()?);
        }
        Some(Self { after, found, since_ms })
    }

    /// The text of this place, which [`Place::of`] reads.
    pub fn text(&self) -> String {
        serde_json::json!({
            "after": self.after,
            "found": self.found,
            "since_ms": self.since_ms,
        })
        .to_string()
    }
}

/// A file time this near before the start of the first call counts as after
/// it: a file system can keep a time in steps of up to 2 seconds.
const FILE_TIME_MARGIN_MS: u64 = 2_000;

/// `time` in milliseconds since 1970; nil for a time before 1970.
fn millis_of(time: SystemTime) -> Option<u64> {
    let since_1970 = time.duration_since(UNIX_EPOCH).ok()?;
    u64::try_from(since_1970.as_millis()).ok()
}

/// False only when the file at `path` is not there, or when its times say
/// that nothing wrote it, made it or put it in its place at or after
/// `limit_ms`. A file whose times cannot be read counts as written.
fn written_since(path: &Path, limit_ms: u64) -> bool {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => return error.kind() != std::io::ErrorKind::NotFound,
    };
    let Ok(modified) = metadata.modified() else {
        return true;
    };
    if millis_of(modified).is_none_or(|modified| modified >= limit_ms) {
        return true;
    }
    // A store file that is swapped in by a rename keeps the time of its last
    // write. The time of its last status change is the time of the rename.
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        let changed = u64::try_from(metadata.ctime()).ok().map(|seconds| {
            let millis = u64::try_from(metadata.ctime_nsec()).unwrap_or(0) / 1_000_000;
            seconds.saturating_mul(1_000).saturating_add(millis)
        });
        if changed.is_none_or(|changed| changed >= limit_ms) {
            return true;
        }
    }
    false
}

/// True when a store of the session folder `session` can hold a schema that
/// was written at or after `since_ms`: by the times of the folder, of each
/// store file and of each store's `-wal` file (each store is in WAL mode: a
/// write goes to the `-wal` file first, to the store file at a later time).
/// This reads no store.
fn changed_since(session: &Path, since_ms: u64) -> bool {
    let limit_ms = since_ms.saturating_sub(FILE_TIME_MARGIN_MS);
    written_since(session, limit_ms)
        || STORES.iter().any(|(_, file, _)| {
            let store = session.join(file);
            let mut wal = store.clone().into_os_string();
            wal.push("-wal");
            written_since(&store, limit_ms) || written_since(Path::new(&wal), limit_ms)
        })
}

/// Reads each store of the session folder `session`, and keeps in `found`
/// the newest schema of each.
fn read_session(session: &Path, found: &mut BTreeMap<String, i64>) -> anyhow::Result<()> {
    for (name, file, _) in STORES {
        let path = session.join(file);
        // A store can go away after the listing (a session that is
        // reset is renamed, then deleted): then it is no store.
        if !path.is_file() {
            continue;
        }
        if let Some(version) = schema_version(&path)? {
            let newest = found.entry((*name).to_string()).or_insert(version);
            *newest = (*newest).max(version);
        }
    }
    Ok(())
}

/// The place after the session folder `last`; nil when its name is not
/// UTF-8, which a text cannot carry.
fn place_after(last: &Path, found: BTreeMap<String, i64>, since_ms: u64) -> Option<Place> {
    let after = last.file_name()?.to_str()?.to_string();
    Some(Place { after, found, since_ms })
}

/// [`stored_until`] for a caller that carries a place from one call to the
/// next. `place` is the place that the call before gave, nil for a first
/// call. `now_ms` is the start of this call, in milliseconds since 1970 by
/// the wall clock. With [`Stored::NotReady`] comes the place for the next
/// call (nil when the last session folder read has a name that is not
/// UTF-8).
///
/// A call with a place reads first each session whose folder name sorts
/// after `place.after`, in order; `sessions_read` then counts the sessions
/// of all calls. The calls of one check take longer together than one call,
/// so a store that an earlier call read can get a newer schema before the
/// last call ends, and a session can start with a name at or before the
/// place. So a call that read each session after the place looks at the
/// times of each folder at or before the place ([`changed_since`], against
/// `place.since_ms`), and reads again each one that was written since the
/// first call started. It gives the numbers only after that. The folders
/// that were not written are not read again.
///
/// The end-time check is the same in both parts: before each session after
/// the first one that this call reads. A call that stops in the second part
/// says that it read each session, and the place that it gives makes the
/// next call do the second part again.
///
/// A place whose `since_ms` is after `now_ms` is no place: the call starts
/// at the first session, with `now_ms` as its start. The number that an
/// earlier call found in a folder that is gone stays in the numbers.
pub fn stored_from(
    state_root: &Path,
    end: Option<Instant>,
    place: Option<&Place>,
    now_ms: u64,
) -> anyhow::Result<(Stored, Option<Place>)> {
    let place = place.filter(|place| place.since_ms <= now_ms);
    let since_ms = place.map_or(now_ms, |place| place.since_ms);
    let mut found = place.map(|place| place.found.clone()).unwrap_or_default();
    let entries = match std::fs::read_dir(state_root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Stored::Schemas(found), None));
        }
        Err(error) => {
            return Err(error).with_context(|| format!("read {}", state_root.display()));
        }
    };
    // The session folders that hold a store, before the first read: an
    // answer before the end names how many there are.
    let mut sessions: Vec<PathBuf> = Vec::new();
    for entry in entries {
        let session = entry.with_context(|| format!("read {}", state_root.display()))?.path();
        if session.is_dir() && STORES.iter().any(|(_, file, _)| session.join(file).is_file()) {
            sessions.push(session);
        }
    }
    // The same order in each call.
    sessions.sort();
    // The sessions at or before the place, which the calls before read, and
    // the sessions after it. With no place each session is after it.
    let after = place.map(|place| OsStr::new(&place.after));
    let (before, rest): (Vec<&PathBuf>, Vec<&PathBuf>) = sessions.iter().partition(|session| {
        after.is_some_and(|after| session.file_name().is_some_and(|name| name <= after))
    });
    let past_the_end = || end.is_some_and(|end| Instant::now() >= end);
    for (index, session) in rest.iter().enumerate() {
        if index > 0 && past_the_end() {
            let next = place_after(rest[index - 1], found, since_ms);
            let sessions_read = before.len() + index;
            return Ok((Stored::NotReady { sessions: sessions.len(), sessions_read }, next));
        }
        read_session(session, &mut found)?;
    }
    let mut read_one = !rest.is_empty();
    for session in &before {
        if !changed_since(session, since_ms) {
            continue;
        }
        if read_one && past_the_end() {
            let next = match rest.last() {
                Some(last) => place_after(last, found, since_ms),
                None => place.map(|place| Place { after: place.after.clone(), found, since_ms }),
            };
            let all = sessions.len();
            return Ok((Stored::NotReady { sessions: all, sessions_read: all }, next));
        }
        read_session(session, &mut found)?;
        read_one = true;
    }
    Ok((Stored::Schemas(found), None))
}

/// `meta.schema_version` of the SQLite store at `path`, read-only; nil when
/// the store has no schema yet.
fn schema_version(path: &Path) -> anyhow::Result<Option<i64>> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .with_context(|| format!("open {}", path.display()))?;
    connection.busy_timeout(Duration::from_millis(500))?;
    let has_meta: bool = connection.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta')",
        [],
        |row| row.get(0),
    )?;
    if !has_meta {
        return Ok(None);
    }
    let value: Option<String> = connection
        .query_row("SELECT value FROM meta WHERE key = 'schema_version'", [], |row| row.get(0))
        .optional()?;
    value
        .map(|value| {
            value.parse::<i64>().with_context(|| format!("{} schema is invalid", path.display()))
        })
        .transpose()
}

const USAGE: &str = "usage: cmux-tui __store-schemas [--stored [--within-ms N] [--place PLACE]]";

/// The time of `--within-ms N`: `text` as a count of milliseconds, nil when
/// it is not one.
pub fn within_of(text: &str) -> Option<Duration> {
    text.parse::<u64>().ok().map(Duration::from_millis)
}

/// What `--place TEXT` asks for: no place yet for the empty text (a first
/// call), else the place that the text is. A text that is not a place is the
/// usage error, which does not hold the text.
fn asked_place(text: &str) -> Result<Option<Place>, String> {
    if text.is_empty() {
        return Ok(None);
    }
    Place::of(text).map(Some).ok_or_else(|| USAGE.to_string())
}

/// `cmux-tui __store-schemas [--stored [--within-ms N] [--place PLACE]]`:
/// one JSON object of store name to schema, what this build reads or
/// (`--stored`) what the state directory holds. Internal plumbing for the
/// app's build stamp and rollback check.
///
/// `--within-ms N` is the check's own end time, N milliseconds after its
/// start, below the time at which its caller ends the process. A check that
/// is not at its end then stops before the next session, prints
/// `{"not_ready":{"sessions":M,"sessions_read":R}}` and still exits 0
/// ([`stored_until`]). A caller that knows only the object of numbers reads
/// that as no answer, as it reads a process that was ended.
///
/// `--place PLACE` is for a caller that makes more than one call: the
/// `not_ready` object then has one more part, `place`, a text. The caller
/// gives that text back as PLACE at its next call, which goes on after the
/// sessions read so far ([`stored_from`]). The first call sends the empty
/// text. A caller that does not send `--place` gets the answer with no
/// `place`, and each of its calls starts at the first session.
pub fn run(args: &[String]) -> Result<String, String> {
    let began = Instant::now();
    let usage = || USAGE.to_string();
    // Nil = the caller sent no `--place`.
    let (within, asked) = match args {
        [] => return serde_json::to_string(&readable()).map_err(|error| error.to_string()),
        [flag] if flag == "--stored" => (None, None),
        [flag, within, millis] if flag == "--stored" && within == "--within-ms" => {
            (Some(within_of(millis).ok_or_else(usage)?), None)
        }
        [flag, place, text] if flag == "--stored" && place == "--place" => {
            (None, Some(asked_place(text)?))
        }
        [flag, within, millis, place, text]
            if flag == "--stored" && within == "--within-ms" && place == "--place" =>
        {
            (Some(within_of(millis).ok_or_else(usage)?), Some(asked_place(text)?))
        }
        _ => return Err(usage()),
    };
    let root = crate::platform::workspace_state_dir()
        .ok_or_else(|| "no workspace state directory".to_string())?;
    // A time that the clock cannot hold is no end time.
    let end = within.and_then(|within| began.checked_add(within));
    // A wall clock before 1970 gives 0: each place is then after this call,
    // and a place with a start of 0 makes the last call read each session.
    let now_ms = millis_of(SystemTime::now()).unwrap_or(0);
    let place = asked.as_ref().and_then(Option::as_ref);
    let (stored, next) =
        stored_from(&root, end, place, now_ms).map_err(|error| format!("{error:#}"))?;
    let answer = match stored {
        Stored::Schemas(schemas) => serde_json::to_string(&schemas),
        Stored::NotReady { sessions, sessions_read } => {
            let mut not_ready =
                serde_json::json!({ "sessions": sessions, "sessions_read": sessions_read });
            if let Some(next) = next.filter(|_| asked.is_some()) {
                not_ready["place"] = serde_json::Value::String(next.text());
            }
            serde_json::to_string(&serde_json::json!({ "not_ready": not_ready }))
        }
    };
    answer.map_err(|error| error.to_string())
}
