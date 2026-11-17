//! wsfactory: a fresh throwaway workspace per CI job, destroyed after it.
//!
//! Warm build state comes only from a read-only seed a trusted build published, never from an
//! earlier job's leftovers. SwiftPM and cargo key their caches by absolute path, so a workspace is
//! created at the path the seed was built at; on APFS clonefile(2) makes that copy nearly free.
//!
//! Layout under the root R:
//!   R/seeds/N        the seed tree        R/seeds/N.json  its record
//!   R/jobs/ID/       a job's scratch      R/leases/ID.json which path a job holds, and for whom

mod fsx;
mod json;
#[cfg(test)]
mod tests;

use json::{Obj, Val};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};
use std::time::{Instant, SystemTime, UNIX_EPOCH};

const USAGE: &str = "usage:
  wsfactory seed publish --root R --name N --from DIR [--clone]
  wsfactory seed verify  --root R --name N
  wsfactory seed remove  --root R --name N
  wsfactory create   --root R --seed N --job ID [--at PATH] [--owner-pid PID]
  wsfactory destroy  --root R --job ID
  wsfactory reconcile --root R
  wsfactory usage PATH...
  wsfactory statfs PATH";

enum Error {
    Usage(String),
    Fail(String),
}

impl From<String> for Error {
    fn from(s: String) -> Self {
        Error::Fail(s)
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match run(&args) {
        Ok(obj) => {
            println!("{obj}");
            // A verify that found a changed seed, or a reconcile that could not remove something.
            if obj.bool("ok") == Some(false) {
                std::process::exit(1);
            }
        }
        Err(Error::Usage(m)) => {
            eprintln!("wsfactory: {m}\n{USAGE}");
            std::process::exit(2);
        }
        Err(Error::Fail(m)) => {
            eprintln!("wsfactory: {m}");
            std::process::exit(1);
        }
    }
}

struct Args {
    flags: HashMap<String, String>,
    switches: HashSet<String>,
    pos: Vec<String>,
}

impl Args {
    fn parse(args: &[String], valued: &[&str], switches: &[&str]) -> Result<Args, Error> {
        let mut a = Args {
            flags: HashMap::new(),
            switches: HashSet::new(),
            pos: Vec::new(),
        };
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            if let Some(name) = arg.strip_prefix("--") {
                if valued.contains(&name) {
                    let v = it
                        .next()
                        .ok_or_else(|| Error::Usage(format!("{arg} needs a value")))?;
                    a.flags.insert(name.to_string(), v.clone());
                } else if switches.contains(&name) {
                    a.switches.insert(name.to_string());
                } else {
                    return Err(Error::Usage(format!("unknown option {arg}")));
                }
            } else {
                a.pos.push(arg.clone());
            }
        }
        Ok(a)
    }

    fn req(&self, name: &str) -> Result<&str, Error> {
        self.flags
            .get(name)
            .map(String::as_str)
            .ok_or_else(|| Error::Usage(format!("--{name} is required")))
    }

    fn no_pos(&self) -> Result<(), Error> {
        match self.pos.first() {
            Some(p) => Err(Error::Usage(format!("unexpected argument {p}"))),
            None => Ok(()),
        }
    }
}

fn run(args: &[String]) -> Result<Obj, Error> {
    let (cmd, rest) = args
        .split_first()
        .ok_or_else(|| Error::Usage("no command".into()))?;
    match cmd.as_str() {
        "seed" => {
            let (sub, rest) = rest
                .split_first()
                .ok_or_else(|| Error::Usage("seed needs a subcommand".into()))?;
            let a = Args::parse(rest, &["root", "name", "from"], &["clone"])?;
            a.no_pos()?;
            let (root, name) = (PathBuf::from(a.req("root")?), a.req("name")?);
            match sub.as_str() {
                "publish" => Ok(seed_publish(
                    &root,
                    name,
                    Path::new(a.req("from")?),
                    a.switches.contains("clone"),
                )?),
                "verify" => Ok(seed_verify(&root, name)?),
                "remove" => Ok(seed_remove(&root, name)?),
                s => Err(Error::Usage(format!("unknown seed subcommand {s}"))),
            }
        }
        "create" => {
            let a = Args::parse(rest, &["root", "seed", "job", "at", "owner-pid"], &[])?;
            a.no_pos()?;
            let owner = match a.flags.get("owner-pid") {
                Some(p) => p
                    .parse()
                    .map_err(|_| Error::Usage(format!("bad --owner-pid {p}")))?,
                // The calling shell: the job's lifetime, not this short-lived process's.
                None => std::os::unix::process::parent_id() as i64,
            };
            let at = a.flags.get("at").map(PathBuf::from);
            Ok(create(
                Path::new(a.req("root")?),
                a.req("seed")?,
                a.req("job")?,
                at.as_deref(),
                owner,
            )?)
        }
        "destroy" => {
            let a = Args::parse(rest, &["root", "job"], &[])?;
            a.no_pos()?;
            Ok(destroy(Path::new(a.req("root")?), a.req("job")?)?)
        }
        "reconcile" => {
            let a = Args::parse(rest, &["root"], &[])?;
            a.no_pos()?;
            Ok(reconcile(Path::new(a.req("root")?))?)
        }
        "usage" => {
            let a = Args::parse(rest, &[], &[])?;
            if a.pos.is_empty() {
                return Err(Error::Usage("usage needs at least one PATH".into()));
            }
            let paths: Vec<PathBuf> = a.pos.iter().map(PathBuf::from).collect();
            Ok(usage(&paths)?)
        }
        "statfs" => {
            let a = Args::parse(rest, &[], &[])?;
            let [p] = a.pos.as_slice() else {
                return Err(Error::Usage("statfs takes one PATH".into()));
            };
            let (free, total) =
                fsx::statfs(Path::new(p)).map_err(|e| format!("statfs {p}: {e}"))?;
            Ok(Obj::new()
                .with("path", p.as_str())
                .with("free_bytes", free)
                .with("total_bytes", total))
        }
        "help" | "--help" | "-h" => {
            println!("{USAGE}");
            std::process::exit(0);
        }
        c => Err(Error::Usage(format!("unknown command {c}"))),
    }
}

// ---- helpers ----

fn ctx(what: impl std::fmt::Display) -> impl FnOnce(io::Error) -> String {
    move |e| format!("{what}: {e}")
}

fn ms_since(t: Instant) -> f64 {
    t.elapsed().as_secs_f64() * 1000.0
}

fn now_unix() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

/// Seed names and job IDs become file names, so no separators and no leading dot
/// (temporary files start with one).
fn check_name(kind: &str, s: &str) -> Result<(), String> {
    let ok = !s.is_empty()
        && !s.starts_with('.')
        && s.len() <= 200
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'));
    if ok {
        Ok(())
    } else {
        Err(format!(
            "bad {kind} {s:?}: use letters, digits, '.', '_', '-', not starting with '.'"
        ))
    }
}

/// Absolute without resolving symlinks, so leases record the path the caller named.
fn absolute(p: &Path) -> Result<PathBuf, String> {
    if p.is_absolute() {
        return Ok(p.to_path_buf());
    }
    let cwd = std::env::current_dir().map_err(ctx("current directory"))?;
    Ok(cwd.join(p))
}

fn utf8(p: &Path) -> Result<&str, String> {
    p.to_str()
        .ok_or_else(|| format!("path is not UTF-8: {}", p.display()))
}

/// write tmp, fsync, rename: a reader sees the old file or the whole new one, never half.
fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    use std::io::Write;
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.tmp-{}", std::process::id()));
    let mut f = fs::File::create(&tmp).map_err(ctx(tmp.display()))?;
    f.write_all(text.as_bytes())
        .and_then(|_| f.sync_all())
        .map_err(ctx(tmp.display()))?;
    fs::rename(&tmp, path).map_err(ctx(path.display()))
}

fn read_obj(path: &Path) -> Result<Obj, String> {
    let text = fs::read_to_string(path).map_err(ctx(path.display()))?;
    json::parse_obj(&text).map_err(|e| format!("{}: {e}", path.display()))
}

/// A destroy removes whatever a lease names, so refuse anything that looks like a slip:
/// relative paths, "..", and the filesystem root or a top-level directory.
fn check_removable(p: &Path) -> Result<(), String> {
    let normal = p
        .components()
        .filter(|c| matches!(c, Component::Normal(_)))
        .count();
    let parent = p.components().any(|c| matches!(c, Component::ParentDir));
    if !p.is_absolute() || parent || normal < 2 {
        return Err(format!(
            "refusing to remove {}: not a workspace path",
            p.display()
        ));
    }
    Ok(())
}

fn usage_obj(u: &fsx::Usage) -> Obj {
    Obj::new()
        .with("files", u.files)
        .with("bytes", u.bytes)
        .with("newest_mtime_ns", u.newest_mtime_ns)
}

// ---- seeds ----

fn seed_paths(root: &Path, name: &str) -> (PathBuf, PathBuf) {
    let seeds = root.join("seeds");
    (seeds.join(name), seeds.join(format!("{name}.json")))
}

pub(crate) fn seed_publish(
    root: &Path,
    name: &str,
    from: &Path,
    clone: bool,
) -> Result<Obj, String> {
    check_name("seed name", name)?;
    let t = Instant::now();
    let root = absolute(root)?;
    // The real path: what getcwd returned inside the build, so what its caches are keyed by.
    let src = fs::canonicalize(from).map_err(ctx(from.display()))?;
    if !src.is_dir() {
        return Err(format!("{} is not a directory", src.display()));
    }
    let (dst, record_path) = seed_paths(&root, name);
    let seeds = root.join("seeds");
    fs::create_dir_all(&seeds).map_err(ctx(seeds.display()))?;
    let pid = std::process::id();
    let tmp = seeds.join(format!(".{name}.tmp-{pid}"));
    // Left by a crashed publish whose pid was reused.
    fsx::remove_tree(&tmp).map_err(ctx(tmp.display()))?;
    let how = if clone {
        fsx::clone_tree(&src, &tmp).map_err(ctx(format!(
            "clone {} to {}",
            src.display(),
            tmp.display()
        )))?
    } else {
        fs::rename(&src, &tmp).map_err(ctx(format!(
            "move {} to {} (the build dir and the root must be on one volume)",
            src.display(),
            tmp.display()
        )))?;
        "rename"
    };
    // The old record must never describe the new tree, even for a moment.
    match fs::remove_file(&record_path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", record_path.display()))
        }
        _ => {}
    }
    let old = seeds.join(format!(".{name}.old-{pid}"));
    let had_old = !fsx::gone(&dst).map_err(ctx(dst.display()))?;
    if had_old {
        fs::rename(&dst, &old).map_err(ctx(dst.display()))?;
    }
    fs::rename(&tmp, &dst).map_err(ctx(dst.display()))?;
    if had_old {
        fsx::remove_tree(&old).map_err(ctx(old.display()))?;
    }
    // Measured in place, after the last rename, so verify compares like with like.
    let u = fsx::usage(&dst).map_err(ctx(dst.display()))?;
    let rec = Obj::new()
        .with("name", name)
        .with("source_path", utf8(&src)?)
        .with("files", u.files)
        .with("bytes", u.bytes)
        .with("newest_mtime_ns", u.newest_mtime_ns)
        .with("published_at_unix", now_unix());
    write_atomic(&record_path, &rec.to_string())?;
    Ok(rec
        .with("path", utf8(&dst)?)
        .with("clone", how)
        .with("replaced", had_old)
        .with("ms", ms_since(t)))
}

pub(crate) fn seed_verify(root: &Path, name: &str) -> Result<Obj, String> {
    check_name("seed name", name)?;
    let (dir, record_path) = seed_paths(&absolute(root)?, name);
    let rec = read_obj(&record_path)?;
    let u = fsx::usage(&dir).map_err(ctx(dir.display()))?;
    let actual = usage_obj(&u);
    let mut mismatch = Vec::new();
    if !u.exists {
        mismatch.push("exists".to_string());
    }
    for k in ["files", "bytes", "newest_mtime_ns"] {
        if rec.int(k) != actual.int(k) {
            mismatch.push(k.to_string());
        }
    }
    let recorded = Obj::new()
        .with("files", rec.get("files").cloned().unwrap_or(Val::Null))
        .with("bytes", rec.get("bytes").cloned().unwrap_or(Val::Null))
        .with(
            "newest_mtime_ns",
            rec.get("newest_mtime_ns").cloned().unwrap_or(Val::Null),
        );
    Ok(Obj::new()
        .with("ok", mismatch.is_empty())
        .with("name", name)
        .with("mismatch", mismatch)
        .with("recorded", recorded)
        .with("actual", actual))
}

pub(crate) fn seed_remove(root: &Path, name: &str) -> Result<Obj, String> {
    check_name("seed name", name)?;
    let (dir, record_path) = seed_paths(&absolute(root)?, name);
    let existed = !fsx::gone(&dir).map_err(ctx(dir.display()))?;
    // Record first: a seed without a record cannot be used, a record without its seed can.
    match fs::remove_file(&record_path) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => {
            return Err(format!("{}: {e}", record_path.display()))
        }
        _ => {}
    }
    fsx::remove_tree(&dir).map_err(ctx(dir.display()))?;
    // Workspaces are independent clones, so removing the seed leaves running jobs alone.
    Ok(Obj::new().with("name", name).with("removed", existed))
}

// ---- leases and jobs ----

pub(crate) struct Lease {
    pub job: String,
    pub path: PathBuf,
    pub scratch: PathBuf,
    pub pid: i64,
}

fn lease_path(root: &Path, job: &str) -> PathBuf {
    root.join("leases").join(format!("{job}.json"))
}

fn parse_lease(file: &Path) -> Result<Lease, String> {
    let o = read_obj(file)?;
    let field = |k: &str| {
        o.str(k)
            .map(str::to_string)
            .ok_or_else(|| format!("{}: no {k}", file.display()))
    };
    Ok(Lease {
        job: field("job")?,
        path: PathBuf::from(field("path")?),
        scratch: PathBuf::from(field("scratch")?),
        pid: o
            .int("pid")
            .ok_or_else(|| format!("{}: no pid", file.display()))?,
    })
}

fn read_lease(root: &Path, job: &str) -> Result<Option<Lease>, String> {
    let p = lease_path(root, job);
    if fsx::gone(&p).map_err(ctx(p.display()))? {
        return Ok(None);
    }
    parse_lease(&p).map(Some)
}

pub(crate) fn list_leases(root: &Path) -> Result<Vec<Lease>, String> {
    let dir = root.join("leases");
    let entries = match fs::read_dir(&dir) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        r => r.map_err(ctx(dir.display()))?,
    };
    let mut out = Vec::new();
    for ent in entries {
        let ent = ent.map_err(ctx(dir.display()))?;
        let name = ent.file_name().to_string_lossy().into_owned();
        // Skip half-written ".ID.json.tmp-PID" files.
        if name.starts_with('.') || !name.ends_with(".json") {
            continue;
        }
        out.push(parse_lease(&ent.path())?);
    }
    out.sort_by(|a, b| a.job.cmp(&b.job));
    Ok(out)
}

pub(crate) fn create(
    root: &Path,
    seed: &str,
    job: &str,
    at: Option<&Path>,
    owner_pid: i64,
) -> Result<Obj, String> {
    check_name("seed name", seed)?;
    check_name("job id", job)?;
    let root = absolute(root)?;
    let (seed_dir, record_path) = seed_paths(&root, seed);
    let rec = read_obj(&record_path)?;
    let path = match at {
        Some(p) => absolute(p)?,
        None => PathBuf::from(
            rec.str("source_path")
                .ok_or_else(|| format!("{}: no source_path", record_path.display()))?,
        ),
    };
    check_removable(&path)?;
    if path.starts_with(root.join("seeds")) {
        return Err(format!("{} is inside the seed store", path.display()));
    }
    if read_lease(&root, job)?.is_some() {
        return Err(format!("job {job} already has a lease; destroy it first"));
    }

    // A lease for this path whose owner died is a crashed job (maybe mid-clone): take it back.
    // One whose owner lives is a running job, and its workspace is not ours to touch.
    let mut reclaimed = Vec::new();
    for l in list_leases(&root)? {
        if l.path != path {
            continue;
        }
        if fsx::pid_alive(l.pid) {
            return Err(format!(
                "{} is in use by job {} (pid {} is alive)",
                path.display(),
                l.job,
                l.pid
            ));
        }
        destroy(&root, &l.job)?;
        reclaimed.push(l.job);
    }
    if !fsx::gone(&path).map_err(ctx(path.display()))? {
        return Err(format!(
            "{} exists and no lease names it; remove it or pass --at",
            path.display()
        ));
    }

    let scratch = root.join("jobs").join(job);
    let (home, tmp, cache) = (
        scratch.join("home"),
        scratch.join("tmp"),
        scratch.join("cache"),
    );
    // The lease goes down before anything it names exists, so a crash at any later point is reclaimable.
    let leases = root.join("leases");
    fs::create_dir_all(&leases).map_err(ctx(leases.display()))?;
    let lease = Obj::new()
        .with("job", job)
        .with("path", utf8(&path)?)
        .with("seed", seed)
        .with("scratch", utf8(&scratch)?)
        .with("pid", owner_pid)
        .with("created_at_unix", now_unix());
    write_atomic(&lease_path(&root, job), &lease.to_string())?;

    // Err(None): another job won a race for this path after our check; it is theirs, so leave it.
    let made = (|| -> Result<(&'static str, f64), Option<String>> {
        for d in [&home, &tmp, &cache] {
            fs::create_dir_all(d).map_err(|e| Some(format!("{}: {e}", d.display())))?;
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(|e| Some(format!("{}: {e}", parent.display())))?;
        }
        let t = Instant::now();
        match fsx::clone_tree(&seed_dir, &path) {
            Ok(how) => Ok((how, ms_since(t))),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => Err(None),
            Err(e) => Err(Some(format!(
                "clone {} to {}: {e}",
                seed_dir.display(),
                path.display()
            ))),
        }
    })();
    let (how, clone_ms) = match made {
        Ok(m) => m,
        Err(None) => {
            let _ = fsx::remove_tree(&scratch);
            let _ = fs::remove_file(lease_path(&root, job));
            return Err(format!(
                "{} appeared while creating job {job}; another job holds it",
                path.display()
            ));
        }
        Err(Some(e)) => {
            let _ = destroy(&root, job);
            return Err(e);
        }
    };
    Ok(Obj::new()
        .with("job", job)
        .with("path", utf8(&path)?)
        .with("scratch", utf8(&scratch)?)
        .with("home", utf8(&home)?)
        .with("tmp", utf8(&tmp)?)
        .with("cache", utf8(&cache)?)
        .with("clone_ms", clone_ms)
        .with("clone", how)
        // The clone is exact, so the seed's count is the workspace's without walking it.
        .with("files", rec.get("files").cloned().unwrap_or(Val::Null))
        .with("seed", seed)
        .with("reclaimed", reclaimed))
}

pub(crate) fn destroy(root: &Path, job: &str) -> Result<Obj, String> {
    check_name("job id", job)?;
    let root = absolute(root)?;
    let t = Instant::now();
    let Some(lease) = read_lease(&root, job)? else {
        return Ok(Obj::new().with("job", job).with("already", true));
    };
    let mut removed = 0u64;
    for p in [&lease.path, &lease.scratch] {
        check_removable(p)?;
        removed += fsx::usage(p).map_err(ctx(p.display()))?.bytes;
        fsx::remove_tree(p).map_err(ctx(format!("remove {}", p.display())))?;
        // Keep the lease while anything is left, so the next reconcile tries again.
        if !fsx::gone(p).map_err(ctx(p.display()))? {
            return Err(format!("{} still exists after removal", p.display()));
        }
    }
    let lp = lease_path(&root, job);
    fs::remove_file(&lp).map_err(ctx(lp.display()))?;
    Ok(Obj::new()
        .with("job", job)
        .with("removed_bytes", removed)
        .with("ms", ms_since(t)))
}

pub(crate) fn reconcile(root: &Path) -> Result<Obj, String> {
    let root = absolute(root)?;
    let mut reclaimed = Vec::new();
    let mut failed = Vec::new();
    for l in list_leases(&root)? {
        if fsx::pid_alive(l.pid) {
            continue;
        }
        // One stuck job must not keep the others from being cleaned up.
        match destroy(&root, &l.job) {
            Ok(_) => reclaimed.push(l.job),
            Err(e) => failed.push(Obj::new().with("job", l.job).with("error", e)),
        }
    }
    Ok(Obj::new()
        .with("ok", failed.is_empty())
        .with("reclaimed", reclaimed)
        .with("failed", failed))
}

pub(crate) fn usage(paths: &[PathBuf]) -> Result<Obj, String> {
    let mut out = Vec::new();
    for p in paths {
        let u = fsx::usage(p).map_err(ctx(p.display()))?;
        out.push(
            Obj::new()
                .with("path", p.to_string_lossy().into_owned())
                .with("exists", u.exists)
                .with("files", u.files)
                .with("bytes", u.bytes),
        );
    }
    Ok(Obj::new().with("paths", out))
}
