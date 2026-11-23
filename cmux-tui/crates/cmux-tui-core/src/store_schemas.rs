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
    /// The state root that the calls read, as [`root_part`] names it: a
    /// place is a place of that root only. The empty text names no root.
    pub root: String,
    /// The name of the last session folder that the calls so far read. The
    /// next call goes on at the first name that sorts after it, so a folder
    /// of this name that is no longer there is no error.
    pub after: String,
    /// The newest schema of each store in the sessions read so far.
    pub found: BTreeMap<String, i64>,
    /// The time that a pass over the sessions read before compares a file
    /// time with, in milliseconds since 1970 by the wall clock: the start
    /// of the first call, and after a pass that came to its end, the start
    /// of that pass.
    pub since_ms: u64,
    /// The pass that the call stopped in. Nil when the next pass starts at
    /// its first folder.
    pub pass: Option<Pass>,
}

/// A pass over the sessions read before ([`stored_from`]) that a call
/// stopped in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pass {
    /// The name of the last session folder that the pass looked at. The
    /// next call goes on at the first name that sorts after it.
    pub after: String,
    /// The start of the call in which the pass started, in milliseconds
    /// since 1970 by the wall clock.
    pub began_ms: u64,
}

impl Pass {
    /// The pass that `value` is: one object with `after` and `began_ms` and
    /// no other part.
    fn of(value: &serde_json::Value) -> Option<Self> {
        let parts = value.as_object()?;
        if parts.len() != 2 {
            return None;
        }
        let after = parts.get("after")?.as_str()?.to_string();
        let began_ms = parts.get("began_ms")?.as_u64()?;
        Some(Self { after, began_ms })
    }
}

/// Each part that the text of a place can have.
const PLACE_PARTS: [&str; 5] = ["after", "found", "pass", "root", "since_ms"];

impl Place {
    /// The place that `text` is: one JSON object with `after`, `found` and
    /// `since_ms`, with or without `root` and `pass`, and no other part. A
    /// text with no `root` is a place of no root, so each call reads it as
    /// no place. Nil for each other text; the caller of this function must
    /// not print `text`.
    pub fn of(text: &str) -> Option<Self> {
        let value: serde_json::Value = serde_json::from_str(text).ok()?;
        let parts = value.as_object()?;
        if parts.keys().any(|part| !PLACE_PARTS.contains(&part.as_str())) {
            return None;
        }
        let root = match parts.get("root") {
            Some(root) => root.as_str()?.to_string(),
            None => String::new(),
        };
        let after = parts.get("after")?.as_str()?.to_string();
        let since_ms = parts.get("since_ms")?.as_u64()?;
        let mut found = BTreeMap::new();
        for (name, number) in parts.get("found")?.as_object()? {
            if !STORES.iter().any(|(store, _, _)| *store == name.as_str()) {
                return None;
            }
            found.insert(name.clone(), number.as_i64()?);
        }
        let pass = match parts.get("pass") {
            Some(pass) => Some(Pass::of(pass)?),
            None => None,
        };
        Some(Self { root, after, found, since_ms, pass })
    }

    /// The text of this place, which [`Place::of`] reads.
    pub fn text(&self) -> String {
        let mut text = serde_json::json!({
            "root": self.root,
            "after": self.after,
            "found": self.found,
            "since_ms": self.since_ms,
        });
        if let (Some(pass), Some(parts)) = (&self.pass, text.as_object_mut()) {
            let pass = serde_json::json!({ "after": pass.after, "began_ms": pass.began_ms });
            parts.insert("pass".to_string(), pass);
        }
        text.to_string()
    }
}

/// The part of a place that names the state root: 16 hex digits, the 64-bit
/// FNV-1a hash of the bytes of the root's canonical path. The path itself is
/// not in it. The hash is fixed: nothing in it is made new for a process, a
/// build or a system. Nil when the root has no canonical path (it is not
/// there, or a folder above it cannot be read).
pub fn root_part(state_root: &Path) -> Option<String> {
    let canonical = std::fs::canonicalize(state_root).ok()?;
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in canonical.as_os_str().as_encoded_bytes() {
        hash = (hash ^ u64::from(*byte)).wrapping_mul(0x0000_0100_0000_01b3);
    }
    Some(format!("{hash:016x}"))
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
/// `limit_ms`. A file whose times cannot be read counts as written: each
/// error but "not there" does. With `only_with_bytes`, a file of 0 bytes
/// counts as a file that is not there.
fn written_since(path: &Path, limit_ms: u64, only_with_bytes: bool) -> bool {
    let metadata = match std::fs::metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => return error.kind() != std::io::ErrorKind::NotFound,
    };
    if only_with_bytes && metadata.len() == 0 {
        return false;
    }
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
/// was written at or after `since_ms`: by the times of each store file, and
/// of each store's `-wal` file that holds bytes (each store is in WAL mode:
/// a write goes to the `-wal` file first, to the store file at a later
/// time). This reads no store.
///
/// The time of the folder and a `-wal` file of 0 bytes say nothing here. The
/// check's own read of a store that was closed makes a `-wal` file of 0
/// bytes in the folder, which changes the folder's time; a read writes no
/// byte to a `-wal` file and none to a store file. So this does not see a
/// folder that a rename moves to a name at or before the place, when
/// nothing wrote its stores since. The reset command makes such a rename:
/// [`in_reset`] is for it.
fn changed_since(session: &Path, since_ms: u64) -> bool {
    let limit_ms = since_ms.saturating_sub(FILE_TIME_MARGIN_MS);
    STORES.iter().any(|(_, file, _)| {
        let store = session.join(file);
        let mut wal = store.clone().into_os_string();
        wal.push("-wal");
        written_since(&store, limit_ms, false) || written_since(Path::new(&wal), limit_ms, true)
    })
}

/// True when the name of the session folder `session` has the form that the
/// reset command gives a session folder before it deletes it. That rename
/// can put a session that no call read yet at or before the place, and it
/// changes no time of a store file. So each pass that starts at the first
/// folder reads each folder of this form, with no look at a time.
fn in_reset(session: &Path) -> bool {
    use crate::workspace_registry::{RESET_DIR_HEAD, RESET_DIR_TAIL};
    session
        .file_name()
        .and_then(OsStr::to_str)
        .is_some_and(|name| name.starts_with(RESET_DIR_HEAD) && name.ends_with(RESET_DIR_TAIL))
}

/// Reads each store of the session folder `session`, and keeps in `found`
/// the newest schema of each. `in_delete` is for a folder that the reset
/// deletes while the check runs: a store that cannot be read and whose file
/// is then gone is no store and no error.
fn read_session(
    session: &Path,
    in_delete: bool,
    found: &mut BTreeMap<String, i64>,
) -> anyhow::Result<()> {
    for (name, file, _) in STORES {
        let path = session.join(file);
        // A store can go away after the listing (a session that is
        // reset is renamed, then deleted): then it is no store.
        if !path.is_file() {
            continue;
        }
        let version = match schema_version(&path) {
            Ok(version) => version,
            Err(_) if in_delete && !path.is_file() => continue,
            Err(error) => return Err(error),
        };
        if let Some(version) = version {
            let newest = found.entry((*name).to_string()).or_insert(version);
            *newest = (*newest).max(version);
        }
    }
    Ok(())
}

/// The name of the session folder `session`; nil when it is not UTF-8,
/// which a text cannot carry.
fn name_of(session: &Path) -> Option<String> {
    Some(session.file_name()?.to_str()?.to_string())
}

/// The place of a call that stops in the pass over the sessions read
/// before: `after` is the last session folder that the calls read, `cursor`
/// the last one that this pass looked at (nil: none yet). Nil when one of
/// the 2 names is not UTF-8.
fn place_in_pass(
    root: String,
    after: Option<String>,
    found: BTreeMap<String, i64>,
    since_ms: u64,
    cursor: Option<&OsStr>,
    began_ms: u64,
) -> Option<Place> {
    let pass = match cursor {
        Some(cursor) => Some(Pass { after: cursor.to_str()?.to_string(), began_ms }),
        None => None,
    };
    Some(Place { root, after: after?, found, since_ms, pass })
}

/// A pass reads the clock again after it looked at this many session
/// folders. A look at a folder is 4 `stat` calls at most and no read of a
/// store, so this is 256 `stat` calls at most between 2 reads of the clock.
/// With 1 here, a pass over 2 folders or more that nothing changed could
/// not come to its end in one call with an end time that is past.
const LOOKS_FOR_EACH_CLOCK_READ: usize = 64;

/// [`stored_until`] for a caller that carries a place from one call to the
/// next. `place` is the place that the call before gave, nil for a first
/// call. `now_ms` is the start of this call, in milliseconds since 1970 by
/// the wall clock. With [`Stored::NotReady`] comes the place for the next
/// call (nil when a session folder's name that the place needs is not
/// UTF-8).
///
/// A call with a place reads first each session whose folder name sorts
/// after `place.after`, in order, with the end-time check of
/// [`stored_until`]. `sessions_read` is then the count of the session
/// folders that are now at or before the place, plus the sessions that
/// this call read: it is the count of all calls only when no folder came
/// or went.
///
/// The calls of one check take longer together than one call, so a store
/// that an earlier call read can get a newer schema before the last call
/// ends, and a session can start with a name at or before the place. So a
/// call that read each session after the place makes a pass over the
/// folders at or before it: it looks at the file times of each
/// ([`changed_since`], against `place.since_ms`) and reads again each one
/// that was written since. Each pass that starts at the first folder reads
/// each folder that the reset command renamed ([`in_reset`]), with no look
/// at a time. The call gives the numbers only after such a pass that ran
/// from its first folder to its last in this one call. A store that is read
/// again keeps the larger of its 2 numbers.
///
/// A pass that stops keeps its place: `place.pass` names the last folder
/// that it looked at, and the next call goes on after that folder. A pass
/// that comes to its end in a later call than the call it started in is not
/// the last pass. The same call then starts a new pass at the first folder,
/// and that pass compares the file times with the start of the call in
/// which the pass before it started: it reads again what was written since
/// that start, and each folder that the reset command renamed.
///
/// In a pass the check reads the clock before each read of a store after
/// the first read of this call, and after each
/// [`LOOKS_FOR_EACH_CLOCK_READ`] folders that it looked at. At or after
/// `end` it stops. A call that stops in a pass says that it read each
/// session.
///
/// These are no place, and the call is then a first call with `now_ms` as
/// its start: a place of another state root ([`root_part`]), each place
/// when this root has no canonical path, and a place with a time after
/// `now_ms`. The number that an earlier call found in a folder that is gone
/// stays in the numbers.
pub fn stored_from(
    state_root: &Path,
    end: Option<Instant>,
    place: Option<&Place>,
    now_ms: u64,
) -> anyhow::Result<(Stored, Option<Place>)> {
    // The empty text when the root cannot be named: no place is of it.
    let root = root_part(state_root).unwrap_or_default();
    let place = place.filter(|place| {
        !root.is_empty()
            && place.root == root
            && place.since_ms <= now_ms
            && place.pass.as_ref().is_none_or(|pass| pass.began_ms <= now_ms)
    });
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
    // The pass that the call before stopped in.
    let carried = place.and_then(|place| place.pass.as_ref());
    let mut last_read: Option<&PathBuf> = None;
    for (index, session) in rest.iter().copied().enumerate() {
        if let Some(last) = last_read
            && past_the_end()
        {
            let sessions_read = before.len().saturating_add(index);
            let pass = carried.cloned();
            let next = name_of(last).map(|after| Place { root, after, found, since_ms, pass });
            return Ok((Stored::NotReady { sessions: sessions.len(), sessions_read }, next));
        }
        read_session(session, false, &mut found)?;
        last_read = Some(session);
    }
    // The last session folder that the calls read: nil only for a name that
    // is not UTF-8, or with no place and no session (then no pass stops).
    let after_now = match last_read {
        Some(last) => name_of(last),
        None => place.map(|place| place.after.clone()),
    };
    // The pass in work: the time that it compares with, the start of the
    // call in which it started, the last folder that it looked at, and
    // whether it started at its first folder in this call.
    let mut compare_ms = since_ms;
    let mut began_ms = carried.map_or(now_ms, |pass| pass.began_ms);
    let mut cursor: Option<&OsStr> = carried.map(|pass| OsStr::new(&pass.after));
    let mut whole = carried.is_none();
    let mut read_one = last_read.is_some();
    let mut looks_left = LOOKS_FOR_EACH_CLOCK_READ;
    loop {
        for session in before.iter().copied() {
            let name = session.file_name();
            if cursor.is_some_and(|cursor| name.is_some_and(|name| name <= cursor)) {
                continue;
            }
            let reset = in_reset(session);
            let changed = reset || changed_since(session, compare_ms);
            if (changed && read_one) || looks_left == 0 {
                if past_the_end() {
                    let all = sessions.len();
                    let next = place_in_pass(root, after_now, found, compare_ms, cursor, began_ms);
                    return Ok((Stored::NotReady { sessions: all, sessions_read: all }, next));
                }
                looks_left = LOOKS_FOR_EACH_CLOCK_READ;
            }
            if changed {
                read_session(session, reset, &mut found)?;
                read_one = true;
            }
            looks_left = looks_left.saturating_sub(1);
            cursor = name;
        }
        if whole {
            return Ok((Stored::Schemas(found), None));
        }
        // The pass that an earlier call started is at its end. The pass
        // that follows starts here, at the first folder.
        compare_ms = began_ms;
        began_ms = now_ms;
        cursor = None;
        whole = true;
    }
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
/// text. A place is a place of one state root: for another root it is the
/// empty text. A caller that does not send `--place` gets the answer with
/// no `place`, and each of its calls starts at the first session.
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
            let mut not_ready = serde_json::Map::new();
            not_ready.insert("sessions".to_string(), sessions.into());
            not_ready.insert("sessions_read".to_string(), sessions_read.into());
            if let Some(next) = next.filter(|_| asked.is_some()) {
                not_ready.insert("place".to_string(), next.text().into());
            }
            serde_json::to_string(&serde_json::json!({ "not_ready": not_ready }))
        }
    };
    answer.map_err(|error| error.to_string())
}
