//! Move to another Cloud machine for a folder a Move to Cloud seeded from this Mac: the second
//! machine gets the folder as git, VM to VM, and this Mac's working copy is never read for
//! content nor written. `cmux link agent move --sync relay --sync-seed-local LOCAL` runs [`hop`]
//! twice:
//!
//! 1. Bulk, before the chat freezes: the second machine is seeded with the seed this Mac
//!    recorded for the first ([`super::record`], R: the HEAD, INDEX, WORK and stash commits
//!    the first machine started from). The bundle comes from this Mac's object store alone
//!    (`plan::plan_recorded`), so it is the seed's own small diff over GitHub; the second
//!    machine clones the history from GitHub on its own network.
//! 2. Frozen: the first machine exports what changed since R (`git.seed.export`, a bundle of
//!    its commits and of an INDEX and a WORK commit of its working tree, untracked files
//!    included), the bundle passes through a private file on this Mac with its refs renamed
//!    from `refs/cmux-back/` to `refs/cmux-seed/` (the same length, so only the header
//!    changes), and the second machine applies it as a delta seed since R.
//!
//! So only R's diff and the first machine's changes since R cross this Mac's links:
//! `link_relay_bench` has the numbers.
//!
//! The conflict model: a move is not a merge. The second machine's folder must not be there
//! (`relay.target_exists`), so nothing of its own is ever overwritten; it ends exactly as the
//! first machine's folder was when the chat froze. This Mac's folder may have changed since R
//! too, and it is left as it is. Bring Back Local from the second machine is then the same
//! three-way merge it is from the first: base R, the machine's state, this Mac's folder now;
//! a path both changed differently stops it with that path named (`sync_conflict`) and
//! nothing written, everything else merges.
//!
//! The second machine's record (R, with that machine) waits under its own key ([`side_key`])
//! until the move commits ([`land`]), since both machines may hold the folder at one path. The
//! key names the move that made it (`owner`: the source daemon and the chat's surface), so only
//! that move's retry deletes what an earlier try of it left; another chat's move to the same path
//! finds the folder there and is refused (`relay.target_exists`).
//!
//! A seed carries `refs/stash` alone, not its older entries, so a folder whose stash holds more
//! than one goes by the relay instead (`hop.stashes`): the bulk falls back before anything is
//! seeded, and a frozen pass that finds more since asks the caller ([`many_stashes`]) to delete
//! what the bulk seeded and relay the folder whole.

use std::io::{Read as _, Seek as _, Write as _};
use std::path::Path;

use super::super::seed::plan::{self, Planned, PreviousSeed, SeedParams};
use super::record::{self, Kept, Record};
use super::sync_cli::{self, SeedBase};
use super::{LocalBundle, Machine, SeedError, run_seed};

/// Where the second machine's record waits for the commit: the move's own (module docs).
fn side_key(to_root: &str, owner: &str) -> String {
    format!("hop-target:{to_root}#{owner}")
}

const MANY_STASHES: &str = "hop.stashes";

/// Whether `error` is a hop refused for a stash with older entries (module docs).
pub(in crate::link) fn many_stashes(error: &anyhow::Error) -> bool {
    error.downcast_ref::<SeedError>().is_some_and(|error| error.code == MANY_STASHES)
}

/// Refuses a source folder whose stash has older entries than its tip: one line of
/// `.git/logs/refs/stash` per entry.
fn one_stash_at_most(from: &Path, from_root: &str) -> anyhow::Result<()> {
    let log = sync_cli::remote_read(from, &format!("{from_root}/.git/logs/refs/stash"))?;
    let entries = log
        .map_or(0, |log| log.split(|byte| *byte == b'\n').filter(|line| !line.is_empty()).count());
    if entries > 1 {
        return Err(SeedError::new(
            MANY_STASHES,
            format!("the folder's stash has {entries} entries and a seed carries only the newest"),
        )
        .into());
    }
    Ok(())
}

fn no_previous(why: &str) -> anyhow::Error {
    SeedError::new("seed.no_previous", why).into()
}

/// The bulk (module docs, 1). A waiting record of this move (`owner`) on the same machine is a
/// cut or failed try's: its folder there is this move's to seed again, so a retry goes on.
pub(in crate::link) fn hop_bulk(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    local: &Path,
    owner: &str,
) -> anyhow::Result<()> {
    let local = std::fs::canonicalize(local)?;
    bulk(from, from_root, to, to_root, &local, owner)
}

/// The frozen pass (module docs, 2), once [`hop_bulk`]'s record waits.
pub(in crate::link) fn hop_frozen(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    local: &Path,
    owner: &str,
) -> anyhow::Result<()> {
    let local = std::fs::canonicalize(local)?;
    let Some(waiting) = record::load(&local, &side_key(to_root, owner))? else {
        return Err(no_previous("no bulk pass ran for this move"));
    };
    frozen(from, from_root, to, to_root, &waiting)
}

/// Undoes a bulk pass whose frozen pass can't follow it as git ([`many_stashes`]): the folder it
/// seeded on the second machine and its waiting record go, so a relay can copy the folder whole.
pub(in crate::link) fn abandon(
    to: &Path,
    to_root: &str,
    local: &Path,
    owner: &str,
) -> anyhow::Result<()> {
    let local = std::fs::canonicalize(local)?;
    sync_cli::delete_remote(to, to_root)?;
    record::forget(&local, &side_key(to_root, owner))
}

/// The seed this Mac recorded for the first machine's folder, which that machine started from.
fn recorded(local: &Path, from_root: &str, from: &Path) -> anyhow::Result<(Record, PreviousSeed)> {
    let Some(kept) = record::load(local, from_root)? else {
        return Err(no_previous("this Mac never seeded the folder on the first machine"));
    };
    if kept.mode != Kept::Seed || !kept.stash_known {
        return Err(no_previous("the first machine's folder was copied, not seeded"));
    }
    if let Some(was) = &kept.machine {
        let source = Machine::read(from)?;
        if source.id.as_deref() != Some(was.as_str()) {
            return Err(no_previous("this Mac's seed record is of another machine"));
        }
    }
    let (Some(head), Some(index), Some(work)) =
        (kept.head.clone(), kept.index.clone(), kept.work.clone())
    else {
        return Err(no_previous("the seed's record is incomplete"));
    };
    let previous = PreviousSeed { head, index, work, stash: kept.stash.clone() };
    Ok((kept, previous))
}

/// The bulk (module docs, 1).
fn bulk(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    local: &Path,
    owner: &str,
) -> anyhow::Result<()> {
    let (kept, previous) = recorded(local, from_root, from)?;
    one_stash_at_most(from, from_root)?;
    let machine = Machine::read(to)?;
    if !machine.seeds {
        return Err(Machine::outdated().into());
    }
    let side = side_key(to_root, owner);
    match record::load(local, &side)? {
        // This move's own earlier try left the folder: it goes, and the seed starts again.
        Some(waiting) if waiting.machine.is_some() && waiting.machine == machine.id => {
            sync_cli::delete_remote(to, to_root)?;
            record::forget(local, &side)?;
        }
        // This move's try on another machine, which never committed: not this machine's folder.
        Some(_) => record::forget(local, &side)?,
        None => {}
    }
    refuse_theirs(to, to_root)?;
    let bundle = LocalBundle::new()?;
    let planned = plan::plan_recorded(local, &bundle.file, &previous).map_err(|fallback| {
        SeedError::new(format!("seed.{}", fallback.code.as_str()), fallback.why)
    })?;
    if kept.url.as_deref().is_some_and(|url| url != planned.params.url) {
        return Err(no_previous("the folder's GitHub remote changed since the seed"));
    }
    if let Err(error) = run_seed(machine.socket, to_root, &planned, &bundle, None) {
        // The folder was not there (refuse_theirs): what the seed left is not anyone's.
        let _ = sync_cli::delete_remote(to, to_root);
        return Err(error.into());
    }
    let waiting = Record { machine: machine.id, filling: None, ..kept };
    record::save(local, &side, &waiting)
}

/// The frozen pass (module docs, 2): the first machine's changes since the waiting record's
/// seed, machine to machine as one bundle.
fn frozen(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    waiting: &Record,
) -> anyhow::Result<()> {
    let (Some(head), Some(index), Some(work), Some(url)) =
        (&waiting.head, &waiting.index, &waiting.work, &waiting.url)
    else {
        return Err(no_previous("the waiting record is incomplete"));
    };
    let base = SeedBase {
        head: head.clone(),
        index: index.clone(),
        work: work.clone(),
        stash: waiting.stash.clone(),
        stash_known: true,
    };
    one_stash_at_most(from, from_root)?;
    let bundle = LocalBundle::new()?;
    let Some(exported) = sync_cli::export_to(from, from_root, &base, &bundle.file)? else {
        return Ok(());
    };
    as_seed(&bundle.file)?;
    let planned = Planned {
        params: SeedParams {
            url: url.clone(),
            repo: slug(url),
            base: work.clone(),
            head_ref: exported.head_ref.clone(),
            head: exported.head.clone(),
            index: exported.index.clone(),
            work: exported.work.clone(),
            stash: exported.stash.clone(),
            sparse: None,
            lfs: false,
            since: Some(work.clone()),
        },
        skipped: Vec::new(),
        submodules: Vec::new(),
        bases: Vec::new(),
        bundle_bytes: exported.bundle_bytes,
        unchanged: false,
    };
    // The waiting record stays R: the base Bring Back Local from the second machine merges against.
    run_seed(to, to_root, &planned, &bundle, None).map(|_| ()).map_err(Into::into)
}

/// `OWNER/NAME` of `https://github.com/OWNER/NAME.git`.
fn slug(url: &str) -> String {
    let path = url.strip_prefix("https://github.com/").unwrap_or(url);
    path.strip_suffix(".git").unwrap_or(path).to_string()
}

/// Renames an export bundle's `refs/cmux-back/*` to the `refs/cmux-seed/*` a seed applies, in
/// the header only (the pack after it names no refs).
fn as_seed(bundle: &Path) -> anyhow::Result<()> {
    const FROM: &[u8] = b" refs/cmux-back/";
    const TO: &[u8] = b" refs/cmux-seed/";
    let mut file = std::fs::OpenOptions::new().read(true).write(true).open(bundle)?;
    let mut head = vec![0; 64 * 1024];
    let read = file.read(&mut head)?;
    head.truncate(read);
    let Some(end) = head.windows(2).position(|pair| pair == b"\n\n") else {
        anyhow::bail!("the first machine's bundle has no header");
    };
    let mut header = head.get(..end).unwrap_or_default().to_vec();
    let mut at = 0;
    while let Some(found) =
        header.get(at..).and_then(|rest| rest.windows(FROM.len()).position(|w| w == FROM))
    {
        let start = at + found;
        if let Some(slot) = header.get_mut(start..start + TO.len()) {
            slot.copy_from_slice(TO);
        }
        at = start + TO.len();
    }
    file.rewind()?;
    file.write_all(&header)?;
    file.sync_all()?;
    Ok(())
}

/// A seed into a checkout the second machine has would reset its work (a forced checkout
/// and a clean), so one that is there is refused as a relay refuses it (`relay.target_exists`).
fn refuse_theirs(to: &Path, to_root: &str) -> anyhow::Result<()> {
    if sync_cli::remote_kind(to, to_root)?.is_some() {
        return Err(SeedError::new(
            "relay.target_exists",
            format!("{to_root} is already on the machine"),
        )
        .into());
    }
    Ok(())
}

/// Whether a hop's bulk pass already ran for `to_root`: its frozen pass hops too.
pub(in crate::link) fn started(local: &Path, to_root: &str, owner: &str) -> bool {
    std::fs::canonicalize(local)
        .ok()
        .and_then(|local| record::load(&local, &side_key(to_root, owner)).ok().flatten())
        .is_some()
}

/// The move committed: the second machine's record is this Mac's record of `to_root` now.
pub(in crate::link) fn land(local: &Path, to_root: &str, owner: &str) -> anyhow::Result<bool> {
    let local = std::fs::canonicalize(local)?;
    let side = side_key(to_root, owner);
    let Some(kept) = record::load(&local, &side)? else { return Ok(false) };
    record::save(&local, to_root, &kept)?;
    record::forget(&local, &side)?;
    Ok(true)
}
