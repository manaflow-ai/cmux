//! `cmux repo from-archive --url URL --at DIR [--branch B] [--store STORE] [--archive-only]`: a
//! new checkout from our own store instead of GitHub (hq RFD 0065, piece 2). It downloads the
//! repo's `.git`-only zstd-3 archive in 8 ranged streams, unpacks it, applies the increment
//! bundle of the commits since and checks the branch out with `checkout.workers=16`
//! (`cmux_projection::repo_archive::fetch`). A repo or branch the store does not hold, a URL
//! the store cannot name, no store configured (the default: `CMUX_REPO_ARCHIVE_STORE` or
//! `/etc/cmux/repo-archive.json`), or an archive that fails half way is cloned as the RFD's
//! fallback, `git clone --depth 1 --filter=blob:none --sparse`, unless `--archive-only`, which
//! exits 3 and leaves DIR as it was so the caller clones its own way (the repo step's
//! credential paths, `machine_repo/step.sh`).
//!
//! One JSON line on stdout: `{"source":"archive",...}` (the archive's [`Fetched`] fields),
//! `{"source":"clone","why":...}` or, with `--archive-only`, `{"source":"none","why":...}`.

use std::path::{Path, PathBuf};

use cmux_process::{Command, Stdio};
use cmux_projection::repo_archive::{self as archive, Fetched, Store};

const USAGE: &str = "usage: cmux repo from-archive --url URL --at DIR [--branch B] [--store STORE] \
                     [--archive-only]";

/// Exit code when the store has no archive and `--archive-only` was asked for.
pub(crate) const NO_ARCHIVE: i32 = 3;

#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct Opts {
    pub url: String,
    pub at: PathBuf,
    pub branch: Option<String>,
    pub store: Option<String>,
    pub archive_only: bool,
}

pub(crate) fn parse(args: &[String]) -> Result<Opts, String> {
    let mut opts = Opts::default();
    let (mut url, mut at) = (None, None);
    let mut words = args.iter();
    while let Some(flag) = words.next() {
        if flag == "--archive-only" {
            opts.archive_only = true;
            continue;
        }
        let mut value = || words.next().cloned().ok_or_else(|| format!("{flag} takes a value"));
        match flag.as_str() {
            "--url" => url = Some(value()?),
            "--at" => at = Some(PathBuf::from(value()?)),
            "--branch" => opts.branch = Some(value()?).filter(|b| !b.is_empty()),
            "--store" => opts.store = Some(value()?).filter(|s| !s.trim().is_empty()),
            other => return Err(format!("unknown flag {other}")),
        }
    }
    opts.url = url.ok_or("--url is required")?;
    opts.at = at.ok_or("--at is required")?;
    Ok(opts)
}

pub(crate) fn run(args: &[String]) -> i32 {
    if args.first().is_some_and(|a| a == "--help" || a == "help") {
        println!("{USAGE}");
        return 0;
    }
    let opts = match parse(args) {
        Ok(opts) => opts,
        Err(error) => {
            eprintln!("cmux repo from-archive: {error}\n{USAGE}");
            return 2;
        }
    };
    let store = match &opts.store {
        Some(spec) => archive::open(spec, &|name: &str| std::env::var(name).ok()).map(Some),
        None => archive::store_from_env(),
    };
    // A store that cannot even be opened (a bad setting, a missing key file) is no archive.
    let store = store.unwrap_or_else(|error| {
        eprintln!("cmux repo from-archive: the repo archive store: {error:#}");
        None
    });
    let (code, line) = from_archive(&opts, store.as_deref());
    println!("{line}");
    code
}

/// The checkout from the archive, else the fallback; the exit code and the JSON line.
pub(crate) fn from_archive(opts: &Opts, store: Option<&dyn Store>) -> (i32, serde_json::Value) {
    let why = match take(opts, store) {
        Ok(fetched @ Fetched::Checkout { .. }) => {
            let mut line = serde_json::to_value(&fetched).unwrap_or_default();
            if let Some(fields) = line.as_object_mut() {
                fields.insert("source".into(), "archive".into());
            }
            return (0, line);
        }
        Ok(Fetched::Unknown { why }) => why,
        Err(error) => {
            eprintln!("cmux repo from-archive: {}: {error:#}", opts.url);
            format!("archive failed: {error:#}")
        }
    };
    if opts.archive_only {
        return (NO_ARCHIVE, serde_json::json!({"source": "none", "why": why}));
    }
    match shallow_clone(&opts.url, opts.branch.as_deref(), &opts.at) {
        Ok(()) => (0, serde_json::json!({"source": "clone", "why": why})),
        Err(error) => {
            eprintln!("cmux repo from-archive: {error}");
            (1, serde_json::json!({"source": "failed", "why": why, "error": error}))
        }
    }
}

fn take(opts: &Opts, store: Option<&dyn Store>) -> anyhow::Result<Fetched> {
    let Some(store) = store else {
        return Ok(Fetched::Unknown { why: "no repo archive store is configured".to_owned() });
    };
    if archive::repo_path(&opts.url).is_none() {
        return Ok(Fetched::Unknown { why: format!("the store names no repo {}", opts.url) });
    }
    if !empty_or_absent(&opts.at) {
        anyhow::bail!("{} exists and is not empty", opts.at.display());
    }
    archive::fetch(store, &opts.url, opts.branch.as_deref(), &opts.at, archive::STREAMS)
}

fn empty_or_absent(dir: &Path) -> bool {
    match std::fs::read_dir(dir) {
        Ok(mut entries) => entries.next().is_none(),
        Err(error) => error.kind() == std::io::ErrorKind::NotFound,
    }
}

/// RFD 0065's clone of a repo the store has never seen: one commit's trees and the root files
/// (1.0 s and 2.7 MB for cmux); a sparse folder's blobs come on demand.
pub(crate) fn shallow_clone(url: &str, branch: Option<&str>, at: &Path) -> Result<(), String> {
    if !empty_or_absent(at) {
        return Err(format!("{} exists and is not empty", at.display()));
    }
    let mut git = Command::new("git");
    git.env("GIT_TERMINAL_PROMPT", "0");
    git.args(["clone", "--quiet", "--depth", "1", "--filter=blob:none", "--sparse"]);
    if let Some(branch) = branch {
        git.args(["--branch", branch]);
    }
    git.arg("--").arg(url).arg(at);
    let out = git
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|error| format!("git clone {url}: {error}"))?;
    if out.status.success() {
        Ok(())
    } else {
        Err(format!("git clone {url}: {}", String::from_utf8_lossy(&out.stderr).trim()))
    }
}

#[cfg(test)]
#[path = "repo_archive_tests.rs"]
mod tests;
