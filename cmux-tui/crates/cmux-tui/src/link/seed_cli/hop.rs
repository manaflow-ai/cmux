//! Move to another Cloud machine as git, VM to VM: the second machine clones the history from
//! GitHub on its own network and gets only the folder's own changes as one bundle, and this
//! Mac's working copy is never read for content nor written. The bundles pass through a private
//! temp file on this Mac (never a working copy), so only those changes cross its links:
//! `link_relay_bench` has the numbers. `cmux link agent move --sync relay` runs [`hop_bulk`]
//! before the chat freezes, then [`hop_frozen`] once it is frozen. The bulk is one of:
//!
//! 1. A folder a Move to Cloud seeded from this Mac (`--sync-seed-local LOCAL`): the second
//!    machine is seeded with the seed this Mac recorded for the first ([`super::record`], R:
//!    the HEAD, INDEX, WORK and stash commits the first machine started from). That bundle comes
//!    from this Mac's object store alone (`plan::plan_recorded`), so it is the seed's own small
//!    diff over GitHub. The frozen pass: the first machine exports what changed since R
//!    (`git.seed.export`), the bundle's refs are renamed from `refs/cmux-back/` to
//!    `refs/cmux-seed/` (the same length, so only the header changes), and the second machine
//!    applies it as a delta seed since R.
//! 2. A folder no folder of this Mac's is in (a chat that started on a Cloud machine): the first
//!    machine exports its state since the tip its branch tracks, which GitHub has (a move's
//!    export, `move: upstream`: its own `refs/cmux-move/*`, the folder's seed records left as
//!    they are), and the second machine is seeded from that tip with it.
//! 3. A chat moving back to a machine that still has its folder (one, two, one): the first
//!    machine exports what changed since its own seed (`move: seed`), and the second applies it
//!    as a delta on the record it kept when the chat left (`refs/cmux-move`, or `refs/cmux-back`
//!    after (1)). The second machine checks that nothing changed there since; a folder that did
//!    is never written over (`relay.target_exists`).
//!
//! After (2) and (3) the frozen pass exports what changed since the bulk's own export (`move:
//! since`) and the second machine applies it as a delta on the bulk. Before Leo asked ("isn't
//! this like yet another sync problem?"), (2) and (3) copied the folder file by file (`cmux link
//! sync relay`): the whole folder with `.git`, through both links.
//!
//! The conflict model: a move is not a merge. The second machine's folder must not be there,
//! except as (3) left it, so nothing of its own is ever overwritten; it ends exactly as the
//! first machine's folder was when the chat froze. This Mac's folder may have changed since R
//! too, and it is left as it is. Bring Back Local from the second machine is then the same
//! three-way merge it is from the first: base R, the machine's state, this Mac's folder now;
//! a path both changed differently stops it with that path named (`sync_conflict`) and
//! nothing written, everything else merges.
//!
//! The second machine's record waits under its own key ([`side_key`]) until the move commits
//! ([`land`]), since both machines may hold the folder at one path. With a folder of this Mac's
//! it is R (Bring Back Local's base), with the bulk's state beside it for (3)
//! ([`record::HopState`]); without one it is kept under [`NO_MAC_FOLDER`]. The key names the
//! move that made it (`owner`: the source daemon and the chat's surface), so only that move's
//! retry deletes what an earlier try of it left (never a folder that was there before it);
//! another chat's move to the same path finds the folder there and is refused.
//!
//! A seed carries `refs/stash` alone, not its older entries, so a folder whose stash holds more
//! than one goes by the relay instead (`hop.stashes`): the bulk falls back before anything is
//! seeded, and a frozen pass that finds more since asks the caller ([`many_stashes`]) to delete
//! what the bulk seeded and relay the folder whole.

use std::io::{Read as _, Seek as _, Write as _};
use std::path::{Path, PathBuf};

use super::super::seed::plan::{self, Planned, PreviousSeed, SeedParams};
use super::record::{self, HopState, Kept, Record};
use super::sync_cli::{self, Exported, SeedBase};
use super::{LocalBundle, Machine, SeedError, run_seed};

/// Where the second machine's record waits for the commit: the move's own (module docs).
fn side_key(to_root: &str, owner: &str) -> String {
    format!("hop-target:{to_root}#{owner}")
}

/// The records' key when no folder of this Mac's is in the move (module docs, 2): never a
/// folder's, which is absolute.
const NO_MAC_FOLDER: &str = "cloud-machine:";

const MANY_STASHES: &str = "hop.stashes";
/// A folder the second machine has that the move may not write into.
const TARGET_EXISTS: &str = "relay.target_exists";

/// Whether `error` is a hop refused for a stash with older entries (module docs).
pub(in crate::link) fn many_stashes(error: &anyhow::Error) -> bool {
    error.downcast_ref::<SeedError>().is_some_and(|error| error.code == MANY_STASHES)
}

/// The key of the move's records: this Mac's folder, else [`NO_MAC_FOLDER`].
fn store(local: Option<&Path>) -> anyhow::Result<PathBuf> {
    match local {
        Some(local) => Ok(std::fs::canonicalize(local)?),
        None => Ok(PathBuf::from(NO_MAC_FOLDER)),
    }
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

/// The bulk (module docs). `local` is this Mac's folder a seed put on the first machine, if
/// any. A waiting record of this move (`owner`) on the same machine is a cut or failed try's:
/// a folder it made there is this move's to seed again, so a retry goes on.
pub(in crate::link) fn hop_bulk(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    local: Option<&Path>,
    owner: &str,
) -> anyhow::Result<()> {
    let key = store(local)?;
    bulk(from, from_root, to, to_root, local.map(|_| key.as_path()), &key, owner)
}

/// The frozen pass (module docs), once [`hop_bulk`]'s record waits.
pub(in crate::link) fn hop_frozen(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    local: Option<&Path>,
    owner: &str,
) -> anyhow::Result<()> {
    let key = store(local)?;
    let Some(waiting) = record::load(&key, &side_key(to_root, owner))? else {
        return Err(no_previous("no bulk pass ran for this move"));
    };
    frozen(from, from_root, to, to_root, &waiting)
}

/// Undoes a bulk pass whose frozen pass can't follow it as git ([`many_stashes`]): the folder it
/// seeded on the second machine and its waiting record go, so a relay can copy the folder whole.
/// A folder that was there before the move (module docs, 3) is never deleted: the move stops.
pub(in crate::link) fn abandon(
    to: &Path,
    to_root: &str,
    local: Option<&Path>,
    owner: &str,
) -> anyhow::Result<()> {
    let key = store(local)?;
    let side = side_key(to_root, owner);
    let waiting = record::load(&key, &side)?;
    record::forget(&key, &side)?;
    if waiting.and_then(|waiting| waiting.hop).is_some_and(|hop| hop.into_existing) {
        return Err(SeedError::new(
            TARGET_EXISTS,
            format!(
                "{to_root} is already on the machine, and the folder's stash now has older \
                 entries than a move as git carries"
            ),
        )
        .into());
    }
    sync_cli::delete_remote(to, to_root)
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

/// The bulk (module docs): `mac` is this Mac's folder (canonical), `key` the records' key.
fn bulk(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    mac: Option<&Path>,
    key: &Path,
    owner: &str,
) -> anyhow::Result<()> {
    let kept = mac.map(|mac| recorded(mac, from_root, from)).transpose()?;
    one_stash_at_most(from, from_root)?;
    let machine = Machine::read(to)?;
    if !machine.seeds {
        return Err(Machine::outdated().into());
    }
    let side = side_key(to_root, owner);
    match record::load(key, &side)? {
        // This move's own earlier try moved the chat's folder back there already: the frozen
        // pass sends what changed since.
        Some(waiting)
            if waiting.machine.is_some()
                && waiting.machine == machine.id
                && waiting.hop.as_ref().is_some_and(|hop| hop.into_existing) =>
        {
            return Ok(());
        }
        // This move's own earlier try left the folder: it goes, and the seed starts again.
        Some(waiting) if waiting.machine.is_some() && waiting.machine == machine.id => {
            sync_cli::delete_remote(to, to_root)?;
            record::forget(key, &side)?;
        }
        // This move's try on another machine, which never committed: not this machine's folder.
        Some(_) => record::forget(key, &side)?,
        None => {}
    }
    // The chat moving back to a machine that still has its folder (module docs, 3).
    if sync_cli::remote_kind(to, to_root)?.is_some() {
        let (url, hop) = back(from, from_root, to, to_root)?;
        let waiting = match kept {
            Some((kept, _)) => {
                Record { machine: machine.id, filling: None, hop: Some(hop), ..kept }
            }
            None => moved(machine.id, url, hop),
        };
        return record::save(key, &side, &waiting);
    }
    let Some((kept, previous)) = kept else {
        // No seed of this Mac's: from the first machine's upstream (module docs, 2).
        let (url, hop) = upstream(from, from_root, &machine, to_root)?;
        return record::save(key, &side, &moved(machine.id, url, hop));
    };
    let bundle = LocalBundle::new()?;
    let planned = plan::plan_recorded(key, &bundle.file, &previous).map_err(|fallback| {
        SeedError::new(format!("seed.{}", fallback.code.as_str()), fallback.why)
    })?;
    if kept.url.as_deref().is_some_and(|url| url != planned.params.url) {
        return Err(no_previous("the folder's GitHub remote changed since the seed"));
    }
    if let Err(error) = run_seed(machine.socket, to_root, &planned, &bundle, None) {
        // The folder was not there: what the seed left is not anyone's.
        let _ = sync_cli::delete_remote(to, to_root);
        return Err(error.into());
    }
    let waiting = Record { machine: machine.id, filling: None, hop: None, ..kept };
    record::save(key, &side, &waiting)
}

/// The waiting record of a move with no seed of this Mac's: the bulk's state, by URL.
fn moved(machine: Option<String>, url: String, hop: HopState) -> Record {
    Record {
        mode: Kept::Seed,
        machine,
        url: Some(url),
        head: Some(hop.head.clone()),
        index: Some(hop.index.clone()),
        work: Some(hop.work.clone()),
        stash: hop.stash.clone(),
        stash_known: true,
        filling: None,
        hop: Some(hop),
    }
}

/// What a move's export left on the second machine.
fn hop_state(exported: &Exported, into_existing: bool) -> HopState {
    HopState {
        head: exported.head.clone(),
        index: exported.index.clone(),
        work: exported.work.clone(),
        stash: exported.stash.clone(),
        into_existing,
    }
}

/// `https://github.com/OWNER/NAME.git` and `OWNER/NAME` of the first machine's remote.
fn github(url: &str) -> Result<(String, String), SeedError> {
    super::super::seed::github_url(url).ok_or_else(|| {
        SeedError::new("seed.no_github", "the folder's remote is not a GitHub repository")
    })
}

/// The bulk from the first machine's upstream (module docs, 2): a whole seed on the second
/// machine, from the tip its branch tracks, with the first machine's work on top.
fn upstream(
    from: &Path,
    from_root: &str,
    machine: &Machine<'_>,
    to_root: &str,
) -> anyhow::Result<(String, HopState)> {
    let bundle = LocalBundle::new()?;
    let (exported, base) =
        sync_cli::export_move_to(from, from_root, "upstream", None, &bundle.file)?;
    let (url, repo) = github(&base.url)?;
    let planned = planned(&url, repo, &base.work, None, &exported);
    as_seed(&bundle.file)?;
    if let Err(error) = run_seed(machine.socket, to_root, &planned, &bundle, None) {
        // The folder was not there: what the seed left is not anyone's.
        let _ = sync_cli::delete_remote(machine.socket, to_root);
        return Err(error.into());
    }
    Ok((url, hop_state(&exported, false)))
}

/// The bulk of a chat moving back (module docs, 3): what changed on the first machine since
/// its seed, as a delta on the record the second machine kept when the chat left it. Anything
/// else there is someone's: refused, and nothing is written.
fn back(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
) -> anyhow::Result<(String, HopState)> {
    let theirs = |why: String| -> anyhow::Error {
        SeedError::new(TARGET_EXISTS, format!("{to_root} is already on the machine ({why})")).into()
    };
    let bundle = LocalBundle::new()?;
    let (exported, base) = sync_cli::export_move_to(from, from_root, "seed", None, &bundle.file)
        .map_err(|error| theirs(format!("the chat's folder did not come from it: {error:#}")))?;
    let (url, repo) = github(&base.url)?;
    if exported.unchanged {
        // Nothing to send: the folder there must still be exactly as the chat left it (its
        // record, and HEAD, the index, the files and the stash as that record has them).
        // Nothing is written either way.
        let as_left =
            sync_cli::still_as_recorded(to, to_root, &base.head, &base.work).map_err(|error| {
                theirs(format!("the chat's folder did not come from it: {error:#}"))
            })?;
        if !as_left {
            return Err(theirs("it changed since the chat left it".to_owned()));
        }
        return Ok((url, hop_state(&exported, true)));
    }
    let planned = planned(&url, repo, &base.work, Some(&base.work), &exported);
    as_seed(&bundle.file)?;
    // Never deleted on a failure: the folder was there before the move.
    run_seed(to, to_root, &planned, &bundle, None).map_err(|error| match error.code.as_str() {
        "seed.since_mismatch" | "seed.machine_changed" => theirs(format!(
            "it changed since the chat left it, or the chat's folder did not come from it: {}",
            error.message
        )),
        _ => error.into(),
    })?;
    Ok((url, hop_state(&exported, true)))
}

/// A seed of `exported` on the second machine: whole from `base`, or a delta on `since`.
fn planned(
    url: &str,
    repo: String,
    base: &str,
    since: Option<&str>,
    exported: &Exported,
) -> Planned {
    Planned {
        params: SeedParams {
            url: url.to_owned(),
            repo,
            base: base.to_owned(),
            head_ref: exported.head_ref.clone(),
            head: exported.head.clone(),
            index: exported.index.clone(),
            work: exported.work.clone(),
            stash: exported.stash.clone(),
            sparse: None,
            lfs: false,
            since: since.map(str::to_owned),
        },
        skipped: Vec::new(),
        submodules: Vec::new(),
        bases: Vec::new(),
        bundle_bytes: exported.bundle_bytes,
        unchanged: false,
    }
}

/// The frozen pass (module docs): the first machine's changes since the waiting record's
/// state, machine to machine as one bundle.
fn frozen(
    from: &Path,
    from_root: &str,
    to: &Path,
    to_root: &str,
    waiting: &Record,
) -> anyhow::Result<()> {
    let Some(url) = &waiting.url else {
        return Err(no_previous("the waiting record is incomplete"));
    };
    one_stash_at_most(from, from_root)?;
    let bundle = LocalBundle::new()?;
    // After a move's own export (module docs, 2 and 3): since that export.
    if let Some(hop) = &waiting.hop {
        let since = Some((hop.head.as_str(), hop.work.as_str()));
        let (exported, _) =
            sync_cli::export_move_to(from, from_root, "since", since, &bundle.file)?;
        if exported.unchanged {
            // A folder that was there before the move must still be as the bulk left it.
            if hop.into_existing && !sync_cli::still_as_recorded(to, to_root, &hop.head, &hop.work)?
            {
                return Err(SeedError::new(
                    TARGET_EXISTS,
                    format!("{to_root} changed on the machine since the move began"),
                )
                .into());
            }
            return Ok(());
        }
        as_seed(&bundle.file)?;
        let planned = planned(url, slug(url), &hop.work, Some(&hop.work), &exported);
        return run_seed(to, to_root, &planned, &bundle, None).map(|_| ()).map_err(Into::into);
    }
    let (Some(head), Some(index), Some(work)) = (&waiting.head, &waiting.index, &waiting.work)
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
    let Some(exported) = sync_cli::export_to(from, from_root, &base, &bundle.file)? else {
        return Ok(());
    };
    as_seed(&bundle.file)?;
    // The waiting record stays R: the base Bring Back Local from the second machine merges against.
    let planned = planned(url, slug(url), work, Some(work), &exported);
    run_seed(to, to_root, &planned, &bundle, None).map(|_| ()).map_err(Into::into)
}

/// `OWNER/NAME` of `https://github.com/OWNER/NAME.git`.
fn slug(url: &str) -> String {
    let path = url.strip_prefix("https://github.com/").unwrap_or(url);
    path.strip_suffix(".git").unwrap_or(path).to_string()
}

/// Renames an export bundle's `refs/cmux-back/*` or a move's `refs/cmux-move/*` to the
/// `refs/cmux-seed/*` a seed applies, in the header only (the pack after it names no refs).
fn as_seed(bundle: &Path) -> anyhow::Result<()> {
    const FROM: [&[u8]; 2] = [b" refs/cmux-back/", b" refs/cmux-move/"];
    const TO: &[u8] = b" refs/cmux-seed/";
    let mut file = std::fs::OpenOptions::new().read(true).write(true).open(bundle)?;
    let mut head = vec![0; 64 * 1024];
    let read = file.read(&mut head)?;
    head.truncate(read);
    let Some(end) = head.windows(2).position(|pair| pair == b"\n\n") else {
        anyhow::bail!("the first machine's bundle has no header");
    };
    let mut header = head.get(..end).unwrap_or_default().to_vec();
    for from in FROM {
        let mut at = 0;
        while let Some(found) =
            header.get(at..).and_then(|rest| rest.windows(from.len()).position(|w| w == from))
        {
            // Offsets into the header: an overflow is an error, never a wrapped or clamped index.
            let Some(start) = at.checked_add(found) else {
                anyhow::bail!("the first machine's bundle header is too long to rename its refs");
            };
            let Some(end) = start.checked_add(TO.len()) else {
                anyhow::bail!("the first machine's bundle header is too long to rename its refs");
            };
            if let Some(slot) = header.get_mut(start..end) {
                slot.copy_from_slice(TO);
            }
            at = end;
        }
    }
    file.rewind()?;
    file.write_all(&header)?;
    file.sync_all()?;
    Ok(())
}

/// Whether a hop's bulk pass already ran for `to_root`: its frozen pass hops too.
pub(in crate::link) fn started(local: Option<&Path>, to_root: &str, owner: &str) -> bool {
    store(local)
        .ok()
        .and_then(|key| record::load(&key, &side_key(to_root, owner)).ok().flatten())
        .is_some()
}

/// The move committed. With a folder of this Mac's, the second machine's record is this Mac's
/// record of `to_root` now (R: Bring Back Local's base); without one there is nothing to keep.
pub(in crate::link) fn land(
    local: Option<&Path>,
    to_root: &str,
    owner: &str,
) -> anyhow::Result<bool> {
    let key = store(local)?;
    let side = side_key(to_root, owner);
    let Some(kept) = record::load(&key, &side)? else { return Ok(false) };
    if local.is_some() {
        record::save(&key, to_root, &Record { hop: None, ..kept })?;
    }
    record::forget(&key, &side)?;
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::as_seed;

    #[test]
    fn a_bundle_header_names_seed_refs_and_its_pack_is_kept() {
        let dir = tempfile::tempdir().unwrap();
        let bundle = dir.path().join("x.bundle");
        let header = "# v2 git bundle\n\
                      1111111111111111111111111111111111111111 refs/cmux-back/main\n\
                      2222222222222222222222222222222222222222 refs/cmux-move/a\n\
                      3333333333333333333333333333333333333333 refs/cmux-back/b\n\n";
        std::fs::write(&bundle, format!("{header}PACK refs/cmux-back/not-a-ref")).unwrap();

        as_seed(&bundle).unwrap();

        let text = std::fs::read_to_string(&bundle).unwrap();
        assert_eq!(
            text,
            "# v2 git bundle\n\
             1111111111111111111111111111111111111111 refs/cmux-seed/main\n\
             2222222222222222222222222222222222222222 refs/cmux-seed/a\n\
             3333333333333333333333333333333333333333 refs/cmux-seed/b\n\n\
             PACK refs/cmux-back/not-a-ref"
        );
    }
}
