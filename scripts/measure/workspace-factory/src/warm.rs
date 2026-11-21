//! Warm build trees: N built checkouts kept per seat, keyed by commit; a job restores the one
//! nearest its ref into the seat and builds only the delta.
//!
//! A seat is a fixed path holding a standalone git checkout plus its build state inside it
//! (SwiftPM `.build`, cargo `target`, a DerivedData dir under the tree). Build tools key that state
//! by absolute path, so a tree is only ever restored at the seat it was saved from.
//!
//! Layout under the store S:
//!   S/trees/<commit>       a saved tree         S/trees/<commit>.json  its record (seat, time)
//!
//! `use` picks the saved tree with the fewest commits between it and the ref (`rev-list --count
//! A...B`, so a sibling branch counts too), clones it over the seat (clonefile on APFS: one call,
//! file times kept), then checks the ref out in place. With `core.checkStat=minimal` git compares
//! only mtime and size, so a cloned file whose bytes did not change is not rewritten and keeps its
//! mtime; only files that differ between the two commits get a new one, and the build redoes those.
//! One store belongs to one seat's owner: the caller holds the seat (the slot lock) around a call.

use crate::json::Obj;
use crate::{absolute, ctx, fsx, ms_since, now_unix, read_obj, utf8, write_atomic};
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Instant;

/// git settings that make a cloned tree's index usable without rehashing every file: a clone has new
/// inodes and ctimes, and these two are the only stat fields it changes.
const STAT_CONFIG: [(&str, &str); 2] =
    [("core.checkStat", "minimal"), ("core.trustctime", "false")];

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let mut c = Command::new("git");
    c.arg("-C").arg(dir);
    for (k, v) in STAT_CONFIG {
        c.arg("-c").arg(format!("{k}={v}"));
    }
    let out = c
        .args(args)
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("git {}: {e}", args.join(" ")))?;
    if !out.status.success() {
        return Err(format!(
            "git -C {} {}: {}",
            dir.display(),
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn is_sha(s: &str) -> bool {
    s.len() == 40
        && s.bytes()
            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())
}

/// The seat's real path even before it exists (its parent must), so `/tmp` and `/private/tmp`
/// name one seat.
pub(crate) fn seat_path(p: &Path) -> Result<PathBuf, String> {
    let p = absolute(p)?;
    if let Ok(c) = fs::canonicalize(&p) {
        return Ok(c);
    }
    let (Some(parent), Some(name)) = (p.parent(), p.file_name()) else {
        return Err(format!("bad seat {}", p.display()));
    };
    fs::create_dir_all(parent).map_err(ctx(parent.display()))?;
    Ok(fs::canonicalize(parent)
        .map_err(ctx(parent.display()))?
        .join(name))
}

/// A seat must own its git dir: a worktree's `.git` file points at a shared one, and a clone of it
/// would move the other checkout's HEAD.
fn check_standalone(seat: &Path) -> Result<(), String> {
    if seat.join(".git").is_dir() {
        Ok(())
    } else {
        Err(format!(
            "{} is not a standalone git checkout (.git must be a directory, not a worktree link)",
            seat.display()
        ))
    }
}

pub(crate) struct Saved {
    pub commit: String,
    pub seat: PathBuf,
    pub saved_at: i64,
    pub dir: PathBuf,
}

fn trees(store: &Path) -> PathBuf {
    store.join("trees")
}

pub(crate) fn list_saved(store: &Path) -> Result<Vec<Saved>, String> {
    let dir = trees(store);
    let entries = match fs::read_dir(&dir) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        r => r.map_err(ctx(dir.display()))?,
    };
    let mut out = Vec::new();
    for ent in entries {
        let name = ent.map_err(ctx(dir.display()))?.file_name();
        let name = name.to_string_lossy();
        let Some(commit) = name.strip_suffix(".json") else {
            continue;
        };
        // Skip temporaries; a record without its tree is an interrupted save or remove.
        if !is_sha(commit) || !dir.join(commit).is_dir() {
            continue;
        }
        let rec = read_obj(&dir.join(&*name))?;
        out.push(Saved {
            commit: commit.to_string(),
            seat: PathBuf::from(rec.str("seat").unwrap_or_default()),
            saved_at: rec.int("saved_at_unix").unwrap_or(0),
            dir: dir.join(commit),
        });
    }
    // Newest first.
    out.sort_by(|a, b| b.saved_at.cmp(&a.saved_at).then(a.commit.cmp(&b.commit)));
    Ok(out)
}

fn remove_saved(s: &Saved) -> Result<(), String> {
    // Record first: a tree without a record is never used.
    let rec = s.dir.with_file_name(format!("{}.json", s.commit));
    match fs::remove_file(&rec) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", rec.display()))
        }
        _ => {}
    }
    fsx::remove_tree(&s.dir).map_err(ctx(s.dir.display()))
}

/// Saves the seat's tree under its HEAD commit and keeps the `keep` newest trees of this seat.
pub(crate) fn save(store: &Path, seat: &Path, keep: usize) -> Result<Obj, String> {
    let t = Instant::now();
    let store = absolute(store)?;
    let seat = fs::canonicalize(seat).map_err(ctx(seat.display()))?;
    check_standalone(&seat)?;
    let commit = git(&seat, &["rev-parse", "--verify", "HEAD^{commit}"])?;
    let dir = trees(&store);
    fs::create_dir_all(&dir).map_err(ctx(dir.display()))?;
    let pid = std::process::id();
    let tmp = dir.join(format!(".{commit}.tmp-{pid}"));
    fsx::remove_tree(&tmp).map_err(ctx(tmp.display()))?;
    let tc = Instant::now();
    let how = fsx::clone_tree(&seat, &tmp).map_err(ctx(format!(
        "clone {} to {}",
        seat.display(),
        tmp.display()
    )))?;
    let clone_ms = ms_since(tc);
    let (dst, record) = (dir.join(&commit), dir.join(format!("{commit}.json")));
    let replaced = !fsx::gone(&dst).map_err(ctx(dst.display()))?;
    if replaced {
        remove_saved(&Saved {
            commit: commit.clone(),
            seat: seat.clone(),
            saved_at: 0,
            dir: dst.clone(),
        })?;
    }
    fs::rename(&tmp, &dst).map_err(ctx(dst.display()))?;
    let rec = Obj::new()
        .with("commit", commit.as_str())
        .with("seat", utf8(&seat)?)
        .with("saved_at_unix", now_unix());
    write_atomic(&record, &rec.to_string())?;

    let mut evicted = Vec::new();
    let mine: Vec<Saved> = list_saved(&store)?
        .into_iter()
        .filter(|s| s.seat == seat)
        .collect();
    for s in mine.iter().skip(keep.max(1)) {
        remove_saved(s)?;
        evicted.push(s.commit.clone());
    }
    Ok(rec
        .with("path", utf8(&dst)?)
        .with("clone", how)
        .with("clone_ms", clone_ms)
        .with("replaced", replaced)
        .with("evicted", evicted)
        .with("ms", ms_since(t)))
}

/// Commits between `a` and `b` in either direction, or None when `git_dir` lacks one of them.
fn distance(git_dir: &Path, a: &str, b: &str) -> Option<i64> {
    git(git_dir, &["rev-list", "--count", &format!("{a}...{b}")])
        .ok()?
        .parse()
        .ok()
}

pub(crate) struct Use<'a> {
    pub store: &'a Path,
    pub seat: &'a Path,
    pub rev: &'a str,
    /// A repository holding the ref and the saved commits; the seat itself when None.
    pub git_dir: Option<&'a Path>,
    /// Restore even when the seat already is at least as near the ref as the best saved tree.
    pub always: bool,
    /// Restore and stop: leave the checkout of the ref to the caller.
    pub no_checkout: bool,
}

pub(crate) fn use_tree(u: &Use) -> Result<Obj, String> {
    let t = Instant::now();
    let store = absolute(u.store)?;
    let seat = seat_path(u.seat)?;
    let seat_exists = !fsx::gone(&seat).map_err(ctx(seat.display()))?;
    let git_dir = match u.git_dir {
        Some(d) => absolute(d)?,
        None if seat_exists => seat.clone(),
        None => return Err(format!("{} does not exist; pass --git DIR", seat.display())),
    };
    let target = git(
        &git_dir,
        &["rev-parse", "--verify", &format!("{}^{{commit}}", u.rev)],
    )?;

    let seat_head = if seat_exists && seat.join(".git").is_dir() {
        git(&seat, &["rev-parse", "--verify", "HEAD^{commit}"]).ok()
    } else {
        None
    };
    let seat_distance = seat_head
        .as_deref()
        .and_then(|h| distance(&git_dir, h, &target));

    let mut best: Option<(i64, Saved)> = None;
    let mut considered = 0u64;
    for s in list_saved(&store)?.into_iter().filter(|s| s.seat == seat) {
        considered += 1;
        let Some(d) = distance(&git_dir, &s.commit, &target) else {
            continue;
        };
        // Newest first, so a tie keeps the newer tree.
        if best.as_ref().map_or(true, |(bd, _)| d < *bd) {
            best = Some((d, s));
        }
    }

    let mut out = Obj::new()
        .with("seat", utf8(&seat)?)
        .with("ref", target.as_str())
        .with("considered", considered);
    if let Some(h) = &seat_head {
        out.set("seat_head", h.as_str());
    }
    if let Some(d) = seat_distance {
        out.set("seat_distance", d);
    }
    let restore = match &best {
        None => false,
        Some((d, _)) => u.always || seat_distance.map_or(true, |sd| *d < sd),
    };
    if let Some((d, s)) = &best {
        out.set("nearest", s.commit.as_str());
        out.set("nearest_distance", *d);
    }
    out.set("restored", restore);

    if restore {
        let (_, s) = best.as_ref().expect("restore implies a saved tree");
        // The old seat is removed, timed apart from the clone (a big tree takes a while to delete).
        let td = Instant::now();
        if seat_exists {
            fsx::remove_tree(&seat).map_err(ctx(format!("remove {}", seat.display())))?;
        }
        out.set("discard_ms", ms_since(td));
        let tc = Instant::now();
        let how = fsx::clone_tree(&s.dir, &seat).map_err(ctx(format!(
            "clone {} to {}",
            s.dir.display(),
            seat.display()
        )))?;
        out.set("clone", how);
        out.set("restore_ms", ms_since(tc));
    }

    let ready = !fsx::gone(&seat).map_err(ctx(seat.display()))?;
    if u.no_checkout || !ready {
        return Ok(out.with("checked_out", false).with("ms", ms_since(t)));
    }
    check_standalone(&seat)?;
    let tc = Instant::now();
    // Persist the stat settings so the caller's own git calls in the seat (a checkout script, a
    // submodule update) also trust the cloned index instead of rehashing every file.
    for (k, v) in STAT_CONFIG {
        git(&seat, &["config", k, v])?;
    }
    if git(&seat, &["cat-file", "-e", &format!("{target}^{{commit}}")]).is_err() {
        let src = utf8(&git_dir)?.to_string();
        git(
            &seat,
            &[
                "fetch",
                "--quiet",
                "--no-tags",
                "--no-recurse-submodules",
                &src,
                &target,
            ],
        )?;
    }
    let head = git(&seat, &["rev-parse", "--verify", "HEAD^{commit}"]).ok();
    let changed = match &head {
        Some(h) if h != &target => {
            git(&seat, &["diff", "--name-only", "--no-renames", h, &target])?
                .lines()
                .count() as u64
        }
        _ => 0,
    };
    git(&seat, &["update-index", "-q", "--refresh"]).ok();
    // --force: a seat left dirty by an interrupted job is reset to the ref; untracked and ignored
    // files (the build state) are left alone.
    git(
        &seat,
        &["checkout", "--quiet", "--force", "--detach", &target],
    )?;
    Ok(out
        .with("checked_out", true)
        .with("from", head.unwrap_or_default())
        .with("changed_files", changed)
        .with("checkout_ms", ms_since(tc))
        .with("ms", ms_since(t)))
}

pub(crate) fn list(store: &Path) -> Result<Obj, String> {
    let store = absolute(store)?;
    let mut out = Vec::new();
    for s in list_saved(&store)? {
        out.push(
            Obj::new()
                .with("commit", s.commit.as_str())
                .with("seat", utf8(&s.seat)?)
                .with("saved_at_unix", s.saved_at)
                .with("path", utf8(&s.dir)?),
        );
    }
    Ok(Obj::new().with("trees", out))
}
