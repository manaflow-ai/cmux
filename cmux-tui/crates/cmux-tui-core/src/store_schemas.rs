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

/// False only when the name at `path` is not there, or when it is a plain
/// file whose times say that nothing wrote it, made it or put it in its
/// place at or after `limit_ms`. A file whose times cannot be read counts as
/// written: each error but "not there" does. With `only_with_bytes`, a plain
/// file of 0 bytes counts as a file that is not there.
///
/// This follows no link. A name that is there and is no plain file by
/// itself counts as written, and a link is such a name. SQLite follows a
/// link that is a store's name and keeps the `-wal` file next to the file
/// that the link names. A write through the link goes to that `-wal` file
/// and changes no time of the file that the link names before a checkpoint:
/// the times at the 2 names that [`changed_since`] looks at say nothing of
/// such a write.
fn written_since(path: &Path, limit_ms: u64, only_with_bytes: bool) -> bool {
    let metadata = match std::fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) => return error.kind() != std::io::ErrorKind::NotFound,
    };
    if !metadata.is_file() {
        return true;
    }
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
/// time). This reads no store. A session with a store name or a `-wal` name
/// that is a link counts as written in each pass ([`written_since`]), so
/// each pass reads it again.
///
/// The time of the folder and a `-wal` file of 0 bytes say nothing here. A
/// plain read of a store that was closed makes a `-wal` file of 0 bytes and
/// a `-shm` file in the folder, which changes the folder's time, and a
/// second plain read writes the `-shm` file again; a read writes no byte to
/// a `-wal` file and none to a store file. The check does not make the
/// plain read for each store ([`schema_version`]): it makes it for a store
/// whose file is not at rest, for a store with bytes in its `-wal` file or
/// with a `-journal` file, for a store file that is a link, and for a store
/// that the read that makes no file gives an error for or is not sure of.
/// So this does not see a folder that a rename moves to a name at or before
/// the place, when nothing wrote its stores since. The reset command makes
/// such a rename: [`in_reset`] is for it.
///
/// 2 limits. Some sessions are read in each pass: one that counts as written
/// here in each pass (a link at a name that this looks at; a store that a
/// daemon writes all the time), and a folder of the reset's form, which the
/// pass reads by [`in_reset`] with no call of this. A check that needs more
/// than 1 call comes to its numbers only when one call can read each such
/// session in its pass. That gives a rule for the caller: its last call has
/// no end time. With an end time in each call, the check can answer
/// `not_ready` in each call. A last call that the caller ends after its own
/// fixed time for the process gives no answer, not the numbers: the safe
/// side. And a second name of a store file in another folder (a hard link)
/// is not seen before a checkpoint through that name: a write through that
/// name goes to the `-wal` file next to that name, the 2 names that this
/// looks at say nothing of it, and a read by the session's name does not
/// read that `-wal` file. A checkpoint writes the store file, which is one
/// file under the 2 names, and a later pass sees its new time.
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
///
/// The check must leave the folder of a closed store as it found it: the
/// reset command holds a confirmation text for each file of a session's
/// folder between its 2 calls, and refuses when one of them changed. The
/// plain read ([`plain_schema_version`]) of a closed store in WAL mode makes
/// a `-wal` file and a `-shm` file in the folder and leaves them, and a
/// second plain read writes the `-shm` file again. So a store that is at
/// rest is read with no lock and no side file ([`version_at_rest`]). Each
/// other store, and each store for which that read gives an error or is not
/// sure, gets the plain read, and the plain read's number or error is the
/// answer. On a system that is not unix each store gets the plain read.
fn schema_version(path: &Path) -> anyhow::Result<Option<i64>> {
    #[cfg(unix)]
    {
        if let Some(version) = version_at_rest(path) {
            return Ok(version);
        }
    }
    plain_schema_version(path)
}

/// The read of a store that takes the store's locks and reads its `-wal`
/// file: right for each store, also one that a process writes now.
fn plain_schema_version(path: &Path) -> anyhow::Result<Option<i64>> {
    stored_version(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX, path)
}

/// What a look sees of a store: the length of the store file, its time of
/// the last write (seconds, then nanoseconds), which file it is (the device
/// and the file number), the length of its `-wal` file (0 when it has none)
/// and if it has a `-journal` file.
#[cfg(unix)]
#[derive(PartialEq, Eq)]
struct StoreLook {
    length: u64,
    written: (i64, i64),
    device: u64,
    file: u64,
    wal_bytes: u64,
    journal: bool,
}

/// `path` with `tail` after its last letter: the name of a side file.
#[cfg(unix)]
fn side_file(path: &Path, tail: &str) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(tail);
    PathBuf::from(name)
}

/// A look at the store at `path`. It opens no file and follows no link. Nil
/// when the look cannot be sure: the store's name is not there, or is there
/// and is no plain file by itself; the name of its `-wal` file is there and
/// is no plain file by itself; or a name of the look gives an error (for the
/// 2 side files: an error other than "not there"). A `-journal` name that
/// is there counts as a `-journal` file, plain file or not. A link is no
/// plain file by itself.
/// SQLite follows a link that is a store's name and keeps the `-wal` file
/// and the `-journal` file next to the file that the link names, and this
/// look does not look there: so a store file that is a link gets no look.
#[cfg(unix)]
fn look_at(path: &Path) -> Option<StoreLook> {
    use std::os::unix::fs::MetadataExt;
    let wal_bytes = match std::fs::symlink_metadata(side_file(path, "-wal")) {
        Ok(wal) if wal.is_file() => wal.len(),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
        _ => return None,
    };
    let journal = match std::fs::symlink_metadata(side_file(path, "-journal")) {
        Ok(_) => true,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
        Err(_) => return None,
    };
    let store = std::fs::symlink_metadata(path).ok()?;
    store.is_file().then(|| StoreLook {
        length: store.len(),
        written: (store.mtime(), store.mtime_nsec()),
        device: store.dev(),
        file: store.ino(),
        wal_bytes,
        journal,
    })
}

/// The rule of the look before the read: true when the read that makes no
/// file can be tried for the store that `look` saw at the wall clock
/// `now_ms`. The store has no `-wal` file with bytes and no `-journal` file
/// (its newest content can be in such a file, and that read does not look
/// at one), and its file is at rest ([`at_rest`]).
#[cfg(unix)]
fn can_read_at_rest(look: &StoreLook, now_ms: Option<u64>) -> bool {
    look.wal_bytes == 0 && !look.journal && at_rest(look.written, now_ms)
}

/// The rule of the look after the read: true when the answer of the read
/// that makes no file counts. The look `after` saw the same store file as
/// the look `before` (the device and the file number), with the same length
/// and the same time of the last write, and again no `-wal` file with bytes
/// and no `-journal` file.
#[cfg(unix)]
fn stayed_at_rest(before: &StoreLook, after: &StoreLook) -> bool {
    after.wal_bytes == 0 && !after.journal && after == before
}

/// True when the time of the last write `written` (seconds, then
/// nanoseconds) is older than [`FILE_TIME_MARGIN_MS`] at the wall clock
/// `now_ms`. Then a write after the look gives the file a new time, which
/// the look after the read sees with each step that a file system keeps its
/// times in. A time before 1970, a time ahead of the clock and a clock that
/// cannot be read are not at rest.
#[cfg(unix)]
fn at_rest(written: (i64, i64), now_ms: Option<u64>) -> bool {
    let (Ok(seconds), Ok(nanos), Some(now_ms)) =
        (u64::try_from(written.0), u64::try_from(written.1), now_ms)
    else {
        return false;
    };
    let written_ms = seconds.saturating_mul(1_000).saturating_add(nanos / 1_000_000);
    written_ms.saturating_add(FILE_TIME_MARGIN_MS) < now_ms
}

/// The name of the store at `path` for a read that takes no lock and makes
/// no file: a file URI of the absolute path with `immutable=1`. Each byte of
/// the path that is not a letter, a digit, `/`, `-`, `.`, `_` or `~` is in
/// it as `%` and 2 hex digits, so a `?`, a `#`, a `%` and a byte that is not
/// ASCII in a name are bytes of the name. Nil when the path cannot be made
/// absolute.
#[cfg(unix)]
fn immutable_uri(path: &Path) -> Option<String> {
    use std::os::unix::ffi::OsStrExt;
    let absolute = std::path::absolute(path).ok()?;
    if !absolute.is_absolute() {
        return None;
    }
    let mut uri = String::from("file://");
    for &byte in absolute.as_os_str().as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'/' | b'-' | b'.' | b'_' | b'~') {
            uri.push(char::from(byte));
        } else {
            uri.push('%');
            uri.push(char::from_digit(u32::from(byte >> 4), 16)?);
            uri.push(char::from_digit(u32::from(byte & 0x0f), 16)?);
        }
    }
    uri.push_str("?immutable=1");
    Some(uri)
}

/// The stored schema of the store at `path` by a read that takes no lock,
/// makes no `-wal` file, no `-shm` file and no other file, and writes no
/// byte. That read does not look at a `-wal` file and does not see a write
/// that comes while it runs, so its answer counts only for a store at rest:
/// a look before the read ([`look_at`]) must pass [`can_read_at_rest`], and
/// a second look after the read must pass [`stayed_at_rest`]. Nil in each
/// other case, and when the read gives an error: the caller then makes the
/// plain read, and the plain read's number or error is the answer. A file
/// that goes away under the check (the reset deletes a folder) is such a
/// case: a look or the read does not find it.
///
/// The limits. A store whose file was written less than
/// [`FILE_TIME_MARGIN_MS`] before the check, a store whose `-wal` file holds
/// bytes, a store with a `-journal` file and a store file that is a link get
/// the plain read, which can make or write the side files. A wall clock that
/// was set back after the last write of a store makes that store "not at
/// rest" until the clock is past that write again.
///
/// 3 more limits, each against a check that makes the plain read for each
/// store:
/// - An error where the plain read gave a number. When the reset renames a
///   session folder after this read has its number, the look after finds no
///   store, the plain read then fails at its open, and the check ends with
///   that error ([`read_session`] drops it only for a folder that had the
///   reset's name when the check listed it). An error is the safe side: the
///   check gives no number that it is not sure of.
/// - A number where the plain read gave an error. This read takes no lock
///   and makes no `-shm` file. So it gives the number of a store that the
///   plain read cannot read: a store that a process holds a lock on with no
///   `-journal` file, and a store in WAL mode in a folder where no `-shm`
///   file can be made. With no bytes in a `-wal` file and no `-journal`
///   file, that number is the store file's own number.
/// - The looks are `stat` calls. A file system that answers a `stat` call
///   from a cache (a network file system) can give a look an old length of
///   a `-wal` file or an old time, and then the answer can be an old number.
#[cfg(unix)]
fn version_at_rest(path: &Path) -> Option<Option<i64>> {
    let before = look_at(path)?;
    if !can_read_at_rest(&before, millis_of(SystemTime::now())) {
        return None;
    }
    let uri = immutable_uri(path)?;
    let flags = OpenFlags::SQLITE_OPEN_READ_ONLY
        | OpenFlags::SQLITE_OPEN_NO_MUTEX
        | OpenFlags::SQLITE_OPEN_URI;
    let version = stored_version(Path::new(&uri), flags, path).ok()?;
    stayed_at_rest(&before, &look_at(path)?).then_some(version)
}

/// `meta.schema_version` of the SQLite store that `name` opens with `flags`;
/// nil when the store has no schema yet. `path` is the store's file, for the
/// text of an error.
fn stored_version(name: &Path, flags: OpenFlags, path: &Path) -> anyhow::Result<Option<i64>> {
    let connection = Connection::open_with_flags(name, flags)
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

#[cfg(all(test, unix))]
#[path = "store_schemas_tests.rs"]
mod tests;
