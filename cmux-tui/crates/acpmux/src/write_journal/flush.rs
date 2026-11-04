//! Applying a journal on the machine, in sequence order, with conflict detection.
//!
//! For each entry, oldest first:
//! 1. The machine's file already has the entry's result, or the result of later edits made on
//!    top of it: it was applied (a flush that stopped half way and runs again), so it counts as
//!    applied and nothing is written twice.
//! 2. The machine's file is still the entry's base: apply it (an atomic replace, or a remove).
//! 3. Otherwise a process on the machine changed the file since the agent's edit: the entry
//!    fails with the machine's copy, and so does every later entry for that file, so no edit is
//!    stacked on a version the agent never saw.
//!
//! The check in step 2 is repeated by the mutation itself ([`MachineFs::write`] and
//! [`MachineFs::remove`] take the expected version), so a process that resumes and saves the
//! file between the flush's read and its write is a conflict, not an overwrite.
//!
//! The flush is not a lock on the machine's files. The swap that applies an entry is the
//! moment the agent's write happens: a save the machine makes before it is a conflict, and a
//! save made after it is a later write that replaces the agent's, as it would if the agent
//! had written the file directly on a running machine. Only an earlier save is protected.
//!
//! An I/O error stops the flush at that entry; it and everything after it stay in the journal
//! for the next try. Everything before it is cleared.

use super::{Entry, Op, Version, WriteJournal};
use std::collections::BTreeMap;
use std::io;
use std::path::PathBuf;

/// The machine's files, as the flush sees them. Paths are journal paths.
pub trait MachineFs {
    fn read(&self, path: &str) -> io::Result<Option<Vec<u8>>>;
    /// Replace the whole file atomically (readers see the old or the new bytes, never a mix),
    /// only while it is still `expected`; [`Mutation::Changed`] (nothing written) otherwise.
    /// `seq` names any staging state, so [`MachineFs::recover`] finds it after a crash.
    fn write(&self, seq: u64, path: &str, bytes: &[u8], expected: &Version)
    -> io::Result<Mutation>;
    /// Remove the file, only while it is still `expected`; an absent file is not an error.
    fn remove(&self, seq: u64, path: &str, expected: &Version) -> io::Result<Mutation>;
    /// Finish or undo a mutation for `entry` that an earlier flush started and never finished
    /// (it died part way), so the machine's own copy is never left aside. The flush calls this
    /// before it looks at the file.
    fn recover(&self, entry: &Entry) -> io::Result<()> {
        let _ = entry;
        Ok(())
    }
    /// Make the file's current state (its bytes, or its absence) survive a power loss, with every
    /// folder on the way to it. `write` and `remove` already do this; the flush calls it for an
    /// entry an earlier flush applied, whose own sync may not have finished.
    fn make_durable(&self, path: &str) -> io::Result<()>;
}

/// What a conditional [`MachineFs`] mutation did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mutation {
    Applied,
    /// The file was no longer the expected version; it was left as it is.
    Changed,
}

/// [`MachineFs`] over a local folder: what runs on the machine itself, and the test double.
///
/// No call follows a link anywhere on a path, the folder itself included, so a journal path
/// can never name a file outside the folder. The machine's own processes are not an adversary
/// here: they run as the same user and can write anywhere that user can. A process that moves a
/// folder while the flush holds it open moves the agent's file along with it, as it would
/// move a file the agent had written there directly.
/// A replace is an
/// atomic swap and a remove an atomic rename aside, each checked afterwards and undone when
/// what came out was not the expected version, so a save made at any moment before the swap is
/// kept. Only a process writing in place through a handle it opened before the swap can still
/// lose that write, as with any editor that saves by replacing the file. Unix only.
///
/// Staging files are named after the entry (`.cmux-journal-<seq>.tmp` and `.aside`) next to
/// the file, so a flush that dies part way leaves state the next one resolves
/// ([`MachineFs::recover`]). Nothing this does ever deletes a version saved on the machine: a
/// copy it cannot put back is kept as `<name>.journal-conflict-<seq>`.
pub struct DirMachineFs {
    root: PathBuf,
    /// Called at named points of a mutation, so tests can act between its steps.
    #[cfg(test)]
    hook: Option<Box<dyn Fn(&str) + Send + Sync>>,
}

impl DirMachineFs {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            #[cfg(test)]
            hook: None,
        }
    }

    #[cfg(test)]
    pub(crate) fn with_hook(mut self, hook: impl Fn(&str) + Send + Sync + 'static) -> Self {
        self.hook = Some(Box::new(hook));
        self
    }

    #[cfg(test)]
    fn at(&self, stage: &str) {
        if let Some(h) = &self.hook {
            h(stage);
        }
    }

    #[cfg(not(test))]
    fn at(&self, _: &str) {}
}

#[cfg(unix)]
mod dir_impl {
    use super::super::nofollow::Dir;
    use super::super::{Entry, Op};
    use super::{DirMachineFs, MachineFs, Mutation, Version};
    use std::io::{self, Write};

    use super::super::STAGING_PREFIX;

    fn staging(seq: u64) -> String {
        format!("{STAGING_PREFIX}{seq}.tmp")
    }

    fn aside(seq: u64) -> String {
        format!("{STAGING_PREFIX}{seq}.aside")
    }

    impl DirMachineFs {
        /// The open folders from the root to `path`'s folder (the root first), and the file's
        /// name; `None` when a folder on the way is missing and `create` is off.
        fn walk(&self, path: &str, create: bool) -> io::Result<Option<(Vec<Dir>, String)>> {
            let mut parts: Vec<&str> = path.split('/').collect();
            let Some(name) = parts.pop() else {
                return Err(io::Error::new(io::ErrorKind::InvalidInput, "an empty path"));
            };
            // `rel_path` refuses these, and `WriteJournal::open` re-checks stored paths; refused
            // here too, so a staging name can never be the file itself.
            if path.split('/').any(|p| p.starts_with(STAGING_PREFIX)) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("{path}: a name the write journal keeps for itself"),
                ));
            }
            let mut chain = vec![Dir::open_root(&self.root)?];
            for part in parts {
                let Some(at) = chain.last() else { break };
                match at.child(part, create)? {
                    Some(d) => chain.push(d),
                    None => return Ok(None),
                }
            }
            Ok(Some((chain, name.to_owned())))
        }

        fn folder(&self, path: &str, create: bool) -> io::Result<Option<(Dir, String)>> {
            Ok(self.walk(path, create)?.and_then(|(mut c, n)| c.pop().map(|d| (d, n))))
        }
    }

    /// Syncs every folder from the file's up to the root. An applied entry is cleared from the
    /// journal next, so the folders on its way must survive a power loss too: a retry after a
    /// flush that died between making a folder and syncing its parent opens that folder without
    /// making it.
    fn durable(chain: &[Dir]) -> io::Result<()> {
        chain.iter().rev().try_for_each(Dir::sync)
    }

    fn is(dir: &Dir, name: &str, expected: &Version) -> bool {
        // A link, a folder or an unreadable file there is never the expected version.
        matches!(dir.read(name), Ok(b) if Version::of(b.as_deref()) == *expected)
    }

    fn exists(dir: &Dir, name: &str) -> io::Result<bool> {
        Ok(dir.mode(name)?.is_some())
    }

    /// Moves a machine version that could not be put back to a name of its own beside the file.
    fn keep(dir: &Dir, from: &str, name: &str, seq: u64, path: &str) -> io::Result<()> {
        let to = format!("{name}.journal-conflict-{seq}");
        dir.rename_noreplace(from, &to).map_err(|e| {
            io::Error::new(
                e.kind(),
                format!("{path} changed during the flush; its copy is kept as {from}: {e}"),
            )
        })?;
        dir.sync()
    }

    /// After a swap back, `tmp` holds what was at the file just before it: our own staged bytes,
    /// or a save made on the machine in that moment, which is kept, never deleted.
    fn settle(
        dir: &Dir,
        tmp: &str,
        ours: &Version,
        name: &str,
        seq: u64,
        path: &str,
    ) -> io::Result<()> {
        if is(dir, tmp, ours) {
            dir.unlink(tmp)?;
            dir.sync()
        } else {
            keep(dir, tmp, name, seq, path)
        }
    }

    impl MachineFs for DirMachineFs {
        fn read(&self, path: &str) -> io::Result<Option<Vec<u8>>> {
            match self.folder(path, false)? {
                None => Ok(None),
                Some((dir, name)) => dir.read(&name),
            }
        }

        fn write(
            &self,
            seq: u64,
            path: &str,
            bytes: &[u8],
            expected: &Version,
        ) -> io::Result<Mutation> {
            let Some((chain, name)) = self.walk(path, true)? else {
                return Err(io::Error::other(format!("{path}: its folder could not be made")));
            };
            let Some(dir) = chain.last() else {
                return Err(io::Error::other(format!("{path}: no folder")));
            };
            let tmp = staging(seq);
            let new = *expected == Version::Absent;
            // A new file gets the default mode, the one it ends up with anyway. A replacement is
            // staged owner-only and given the old file's mode (an executable script stays
            // executable) before any bytes go in, so the staged copy is never readable by more
            // people than the file it replaces.
            let mut file = dir.create(&tmp, if new { 0o666 } else { 0o600 })?;
            let staged = (|| {
                if !new && let Some(mode) = dir.mode(&name)? {
                    use std::os::unix::fs::PermissionsExt;
                    file.set_permissions(std::fs::Permissions::from_mode(mode))?;
                }
                file.write_all(bytes)?;
                file.sync_all()
            })();
            if let Err(e) = staged {
                let _ = dir.unlink(&tmp);
                return Err(e);
            }
            self.at("staged");
            let ours = Version::of(Some(bytes));
            if new {
                // A second name for the new file, never over one created in the meantime.
                let linked = dir.link_noclobber(&tmp, &name);
                dir.unlink(&tmp)?;
                return match linked {
                    Ok(()) => durable(&chain).map(|()| Mutation::Applied),
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Ok(Mutation::Changed),
                    Err(e) => Err(e),
                };
            }
            if let Err(e) = dir.exchange(&tmp, &name) {
                dir.unlink(&tmp)?;
                return if e.kind() == io::ErrorKind::NotFound {
                    Ok(Mutation::Changed)
                } else {
                    Err(e)
                };
            }
            self.at("swapped");
            // `tmp` now names what was there. Anything but the expected version goes back.
            if !is(dir, &tmp, expected) {
                dir.exchange(&tmp, &name)?;
                settle(dir, &tmp, &ours, &name, seq, path)?;
                return Ok(Mutation::Changed);
            }
            dir.unlink(&tmp)?;
            // The entry is cleared from the journal after this returns: the swap must survive a
            // power loss first.
            durable(&chain)?;
            Ok(Mutation::Applied)
        }

        fn remove(&self, seq: u64, path: &str, expected: &Version) -> io::Result<Mutation> {
            let absent =
                if *expected == Version::Absent { Mutation::Applied } else { Mutation::Changed };
            let Some((chain, name)) = self.walk(path, false)? else { return Ok(absent) };
            let Some(dir) = chain.last() else { return Ok(absent) };
            let aside = aside(seq);
            match dir.rename_noreplace(&name, &aside) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(absent),
                Err(e) => return Err(e),
            }
            self.at("aside");
            if !is(dir, &aside, expected) {
                match dir.rename_noreplace(&aside, &name) {
                    Ok(()) => dir.sync()?,
                    // Saved again in the meantime: both versions stay.
                    Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                        keep(dir, &aside, &name, seq, path)?;
                    }
                    Err(e) => return Err(e),
                }
                return Ok(Mutation::Changed);
            }
            dir.unlink(&aside)?;
            durable(&chain)?;
            Ok(Mutation::Applied)
        }

        fn recover(&self, entry: &Entry) -> io::Result<()> {
            let Some((dir, name)) = self.folder(&entry.path, false)? else { return Ok(()) };
            let (seq, path) = (entry.seq, entry.path.as_str());
            match &entry.op {
                Op::Write { .. } => {
                    let tmp = staging(seq);
                    if !exists(&dir, &tmp)? {
                        return Ok(());
                    }
                    let result = entry.result();
                    // Our staged bytes, or the base the edit legitimately replaced.
                    if is(&dir, &tmp, &result) || is(&dir, &tmp, &entry.base) {
                        dir.unlink(&tmp)?;
                        return dir.sync();
                    }
                    // A machine save swapped out before the check could undo it: put it back.
                    if is(&dir, &name, &result) {
                        dir.exchange(&tmp, &name)?;
                        return settle(&dir, &tmp, &result, &name, seq, path);
                    }
                    keep(&dir, &tmp, &name, seq, path)
                }
                Op::Delete => {
                    let aside = aside(seq);
                    if !exists(&dir, &aside)? {
                        return Ok(());
                    }
                    if is(&dir, &aside, &entry.base) {
                        dir.unlink(&aside)?;
                        return dir.sync();
                    }
                    match dir.rename_noreplace(&aside, &name) {
                        Ok(()) => dir.sync(),
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                            keep(&dir, &aside, &name, seq, path)
                        }
                        Err(e) => Err(e),
                    }
                }
            }
        }

        fn make_durable(&self, path: &str) -> io::Result<()> {
            // Every folder on the way: an earlier flush may have died before syncing one it made.
            let Some((chain, name)) = self.walk(path, false)? else { return Ok(()) };
            if let Some(dir) = chain.last()
                && let Some(f) = dir.open_file(&name)?
            {
                f.sync_all()?;
            }
            durable(&chain)
        }
    }
}

#[cfg(not(unix))]
impl MachineFs for DirMachineFs {
    fn read(&self, _: &str) -> io::Result<Option<Vec<u8>>> {
        Err(unsupported())
    }
    fn write(&self, _: u64, _: &str, _: &[u8], _: &Version) -> io::Result<Mutation> {
        Err(unsupported())
    }
    fn remove(&self, _: u64, _: &str, _: &Version) -> io::Result<Mutation> {
        Err(unsupported())
    }
    fn make_durable(&self, _: &str) -> io::Result<()> {
        Err(unsupported())
    }
}

#[cfg(not(unix))]
fn unsupported() -> io::Error {
    io::Error::new(io::ErrorKind::Unsupported, "the write journal's folder access is unix only")
}

/// Why one entry did not apply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictReason {
    /// The machine's file is neither the version the edit was made against nor its result.
    ChangedOnMachine { expected: Version, found: Version },
    /// An earlier entry for the same file (this seq) did not apply.
    EarlierEditFailed { seq: u64 },
}

/// One entry that did not apply, with what the agent needs to redo it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Conflict {
    pub seq: u64,
    pub path: String,
    pub reason: ConflictReason,
    /// The machine's copy now: `None` if absent or not text.
    pub machine_copy: Option<String>,
}

impl Conflict {
    /// The text the agent's next tool result carries.
    pub fn message(&self) -> String {
        match &self.reason {
            ConflictReason::ChangedOnMachine { .. } => {
                let copy = match &self.machine_copy {
                    Some(text) => format!("The machine's copy now:\n{text}"),
                    None => "The file is not there on the machine now.".to_owned(),
                };
                format!(
                    "{} changed on the machine since your edit, so the edit was not applied. {copy}",
                    self.path
                )
            }
            ConflictReason::EarlierEditFailed { seq } => format!(
                "{}: an earlier edit to this file (journal entry {seq}) did not apply, so this one was not applied either.",
                self.path
            ),
        }
    }
}

/// What a flush did.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct FlushReport {
    /// Written or removed by this flush.
    pub applied: Vec<u64>,
    /// Already on the machine (an earlier flush got this far).
    pub already: Vec<u64>,
    pub conflicts: Vec<Conflict>,
    /// The flush stopped at this entry on an I/O error; it and later entries stay journaled.
    pub stopped: Option<(u64, String)>,
}

impl FlushReport {
    pub fn is_clean(&self) -> bool {
        self.conflicts.is_empty() && self.stopped.is_none()
    }
}

/// Whether `found` is where the chain of edits to this file from `entries[0]` onward already
/// leads: `entries[0]`'s result, or a later entry's for the same file that was written on top of
/// it. A flush that stopped after applying several edits to one file sees the last one there.
fn already_applied(entries: &[Entry], found: &Version) -> bool {
    let Some(first) = entries.first() else { return false };
    let mut at = first.result();
    if &at == found {
        return true;
    }
    for e in entries.iter().skip(1).filter(|e| e.path == first.path) {
        if e.base != at {
            return false;
        }
        at = e.result();
        if &at == found {
            return true;
        }
    }
    false
}

/// Applies `entries[0]`; `Ok(None)` when it applied (or was there already, `already` set).
fn apply(
    entries: &[Entry],
    machine: &dyn MachineFs,
    already: &mut bool,
) -> io::Result<Option<(Version, Option<Vec<u8>>)>> {
    let Some(entry) = entries.first() else { return Ok(None) };
    machine.recover(entry)?;
    let now = machine.read(&entry.path)?;
    let found = Version::of(now.as_deref());
    if already_applied(entries, &found) {
        // An earlier flush got this far but may have died before its sync: sync now, before the
        // entry is cleared.
        machine.make_durable(&entry.path)?;
        *already = true;
        return Ok(None);
    }
    if found != entry.base {
        return Ok(Some((found, now)));
    }
    let done = match &entry.op {
        Op::Write { content } => {
            machine.write(entry.seq, &entry.path, content.as_bytes(), &entry.base)?
        }
        Op::Delete => machine.remove(entry.seq, &entry.path, &entry.base)?,
    };
    match done {
        Mutation::Applied => Ok(None),
        // Saved on the machine between the read above and the mutation: report what is there.
        Mutation::Changed => {
            let now = machine.read(&entry.path)?;
            Ok(Some((Version::of(now.as_deref()), now)))
        }
    }
}

/// Applies `journal` on `machine` (module docs) and clears what it settled, durably, before
/// returning. The caller surfaces each conflict's [`Conflict::message`] to the agent.
pub fn flush(journal: &mut WriteJournal, machine: &dyn MachineFs) -> io::Result<FlushReport> {
    let mut report = FlushReport::default();
    let mut failed: BTreeMap<String, u64> = BTreeMap::new();
    let mut settled = None;
    let entries = journal.entries();
    for (i, entry) in entries.iter().enumerate() {
        if let Some(&seq) = failed.get(&entry.path) {
            report.conflicts.push(Conflict {
                seq: entry.seq,
                path: entry.path.clone(),
                reason: ConflictReason::EarlierEditFailed { seq },
                machine_copy: None,
            });
            settled = Some(entry.seq);
            continue;
        }
        let mut already = false;
        match apply(entries.get(i..).unwrap_or_default(), machine, &mut already) {
            Ok(None) if already => report.already.push(entry.seq),
            Ok(None) => report.applied.push(entry.seq),
            Ok(Some((found, now))) => {
                failed.insert(entry.path.clone(), entry.seq);
                report.conflicts.push(Conflict {
                    seq: entry.seq,
                    path: entry.path.clone(),
                    reason: ConflictReason::ChangedOnMachine {
                        expected: entry.base.clone(),
                        found,
                    },
                    machine_copy: now.and_then(|b| String::from_utf8(b).ok()),
                });
            }
            Err(e) => {
                report.stopped = Some((entry.seq, e.to_string()));
                break;
            }
        }
        settled = Some(entry.seq);
    }
    if let Some(seq) = settled {
        journal.clear_through(seq)?;
    }
    Ok(report)
}
