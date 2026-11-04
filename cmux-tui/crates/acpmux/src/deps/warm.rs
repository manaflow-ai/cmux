//! One warm: for each project in a folder, restore its archive (when the
//! cache has one, nothing is installed yet, and a restore is expected to beat
//! a cold install on this machine), run its normal install (offline after a
//! restore, where the tool has that), and after a cold install pack and upload
//! an archive for the next machine in the background.
//!
//! The choice is measured, per lockfile key, on this machine (`stats.rs`): the
//! last cold install against the last restore, or the archive's size at the
//! measured download and unpack speeds. A download whose pace shows it will be
//! slower than the last cold install is given up part way.

use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::Serialize;

use super::archive::{self, Codec};
use super::detect::{self, Plan, Project};
use super::remote::{Fetched, Meta, Remote, Stored};
use super::stats::{Choice, Stats};

#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub install: bool,
    pub upload: bool,
    /// Skip a project whose dependencies are already installed.
    pub if_missing: bool,
    /// Pack and upload after a cold install in this process, before returning
    /// (otherwise a detached `machine deps upload` does it).
    pub upload_now: bool,
}

/// One project's result. Times are milliseconds; names and sizes only.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub ecosystem: &'static str,
    pub key: String,
    /// `restored`, `miss`, `present` (already installed here), `installed`
    /// (skipped under `--if-missing`), `cold_faster` (the last cold install
    /// here beat a restore), `abandoned` (the download's pace showed it would
    /// be slower than a cold install), `off` (the hub has no dependency
    /// caches), `not_joined`, `skipped` (the tool is not installed) or `error`.
    pub restore: &'static str,
    /// What the choice expected a restore to take, and the cold install it beat.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub expected_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cold_ms: Option<u64>,
    /// `created`, `exists`, `skipped` or `error`, when an upload was tried here;
    /// `background` when a detached `machine deps upload` was started.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upload: Option<&'static str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub install_ok: Option<bool>,
    pub archive_bytes: u64,
    pub fetch_ms: u64,
    pub unpack_ms: u64,
    pub install_ms: u64,
    pub pack_ms: u64,
    pub upload_ms: u64,
    /// Credentials files left out of the uploaded archive (paths under its root).
    pub denied: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

fn ms(since: Instant) -> u64 {
    since.elapsed().as_millis() as u64
}

/// Whether the plan's folders are already there (a `node_modules`, a cache).
fn present(plan: &Plan) -> bool {
    plan.include.iter().any(|rel| {
        std::fs::read_dir(plan.root.join(rel)).is_ok_and(|mut entries| entries.next().is_some())
    })
}

async fn blocking<T: Send + 'static>(
    f: impl FnOnce() -> std::io::Result<T> + Send + 'static,
) -> anyhow::Result<T> {
    Ok(tokio::task::spawn_blocking(f).await??)
}

/// Unpack a project's own `node_modules` to the side, then move it in with
/// one rename, so an interrupted restore never leaves a half-filled one.
fn restore_into(plan: &Plan, archive_path: &Path, codec: Codec) -> std::io::Result<()> {
    if !plan.replaces {
        // A shared cache sits beside a tool's binaries and config: no links at all.
        archive::unpack(archive_path, codec, &plan.root, &plan.include, false)?;
        return Ok(());
    }
    let stage = tempfile::Builder::new().prefix(".acpmux-deps-").tempdir_in(&plan.root)?;
    archive::unpack(archive_path, codec, stage.path(), &plan.include, true)?;
    for rel in &plan.include {
        let from = stage.path().join(rel);
        let to = plan.root.join(rel);
        // An empty folder (left by a tool or a sync) is replaced; one with files is never touched.
        let _ = std::fs::remove_dir(&to);
        if from.exists() && !to.exists() {
            std::fs::rename(&from, &to)?;
        }
    }
    Ok(())
}

async fn install(argv: &[String], dir: &Path) -> bool {
    let Some((program, args)) = argv.split_first() else { return true };
    tokio::process::Command::new(program)
        .args(args)
        .current_dir(dir)
        .stdin(std::process::Stdio::null())
        // The installer's own output would break `--json`; its errors still go to stderr.
        .stdout(std::process::Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

pub async fn warm(dir: &Path, options: Options) -> Vec<Report> {
    // Restore only (what a seed runs) never runs repository code, so no tool
    // is asked from inside the project: a repo's yarnPath or plugins never
    // load, and its config never picks where caches unpack.
    detect::neutral_probes(!options.install);
    let remote = Remote::joined();
    let codec = Codec::here();
    let mut reports = Vec::new();
    for project in detect::detect(dir) {
        let mut report = Report { ecosystem: project.ecosystem.name(), ..Report::default() };
        if let Err(error) = one(&project, codec, &remote, options, &mut report).await {
            report.restore = if report.restore.is_empty() { "error" } else { report.restore };
            report.error = Some(format!("{error:#}"));
        }
        reports.push(report);
    }
    reports
}

async fn one(
    project: &Project,
    codec: Codec,
    remote: &anyhow::Result<Option<Remote>>,
    options: Options,
    report: &mut Report,
) -> anyhow::Result<()> {
    let Some(plan) = detect::plan(project) else {
        report.restore = "skipped";
        return Ok(());
    };
    if options.if_missing && detect::installed(project) {
        report.restore = "installed";
        return Ok(());
    }
    report.key = detect::key(project, codec.name())?;
    let remote = match remote {
        Ok(Some(remote)) => Some(remote),
        Ok(None) => None,
        Err(error) => anyhow::bail!("machine credential: {error:#}"),
    };
    let scratch = tempfile::tempdir()?;
    let archive_path: PathBuf = scratch.path().join("deps.tar");
    let stats = Stats::load();
    // What this key's last cold install here took: a restore must beat it.
    let mut cold_record =
        stats.keys.get(&report.key).and_then(|r| r.cold_ms).filter(|_| options.install);
    // Whether the cache lacks this key (an upload after the install fills it).
    let mut missing = false;
    // A project's own node_modules that is already there is kept. A package
    // manager's shared cache is always merged into: one earlier install must
    // not stop every later project from restoring or publishing its key.
    if plan.replaces && present(&plan) {
        report.restore = "present";
    } else if let Some(remote) = remote {
        // Restore only (a seed) always restores: no install follows to compare with.
        let mut choice = if options.install { stats.choose(&report.key) } else { Choice::Restore };
        // A machine with no cold install of its own goes by the uploader's
        // (one small request); without one either, it restores.
        if options.install
            && cold_record.is_none()
            && let Ok(Some(meta)) = remote.fetch_meta(&report.key).await
        {
            cold_record = Some(meta.cold_ms);
            choice = stats.choose_from(&report.key, meta.cold_ms, meta.archive_bytes);
        }
        if let Choice::Cold { cold_ms, expected_ms } = choice {
            report.restore = "cold_faster";
            report.cold_ms = Some(cold_ms);
            report.expected_ms = Some(expected_ms);
        } else {
            let started = Instant::now();
            let give_up = |got: u64, size: u64, elapsed: u64| {
                cold_record
                    .is_some_and(|cold| stats.too_slow(&report.key, cold, got, size, elapsed))
            };
            let fetched = remote.fetch(&report.key, &archive_path, give_up).await;
            report.fetch_ms = ms(started);
            match fetched {
                Ok(Fetched::Hit(size)) => {
                    report.archive_bytes = size;
                    let started = Instant::now();
                    let (plan2, path) = (plan.clone(), archive_path.clone());
                    match blocking(move || restore_into(&plan2, &path, codec)).await {
                        Ok(()) => report.restore = "restored",
                        // The install below still runs, cold, and its archive is uploaded.
                        Err(error) => {
                            missing = true;
                            report.restore = "error";
                            report.error = Some(format!("restore: {error:#}"));
                        }
                    }
                    report.unpack_ms = ms(started);
                }
                Ok(Fetched::Abandoned { size, got }) => {
                    report.restore = "abandoned";
                    report.archive_bytes = size;
                    report.cold_ms = cold_record;
                    let fetch_ms = report.fetch_ms.max(1);
                    Stats::update(|s| {
                        s.download_bps = Some(got as f64 * 1000.0 / fetch_ms as f64);
                        s.key_mut(&report.key).archive_bytes = Some(size);
                    });
                }
                Ok(Fetched::Miss) => {
                    report.restore = "miss";
                    missing = true;
                }
                Ok(Fetched::Off) => report.restore = "off",
                Err(error) => {
                    report.restore = "error";
                    report.error = Some(format!("{error:#}"));
                    missing = true;
                }
            }
        }
    } else {
        report.restore = "not_joined";
    }
    if !options.install {
        return Ok(());
    }
    // The download took a while: an install that someone started meanwhile is
    // left alone (`npm ci` would delete the tree it is using).
    // A restored download cache (npm's, pnpm's) leaves node_modules to the
    // install, so only a restored node_modules skips this check.
    let restored = report.restore == "restored";
    let placed_tree = plan.replaces && restored;
    if options.if_missing && !placed_tree && detect::installed(project) {
        report.restore = "installed";
        return Ok(());
    }
    let started = Instant::now();
    // After a restore the install needs no network where the tool can say so;
    // if the archive lacked something, the normal install runs after it.
    let offline =
        restored.then(|| detect::offline_install(project.ecosystem, &plan.install)).flatten();
    let mut ok = match &offline {
        Some(argv) => install(argv, &project.dir).await,
        None => false,
    };
    if !ok {
        ok = install(&plan.install, &project.dir).await;
    }
    report.install_ms = ms(started);
    report.install_ok = Some(ok);
    if ok {
        let (key, restored_bytes) = (report.key.clone(), report.archive_bytes);
        let (fetch_ms, unpack_ms, install_ms) =
            (report.fetch_ms, report.unpack_ms, report.install_ms);
        let cold = !restored && report.restore != "present";
        let cold_known = cold_record;
        Stats::update(|s| {
            if restored {
                if fetch_ms > 0 {
                    s.download_bps = Some(restored_bytes as f64 * 1000.0 / fetch_ms as f64);
                }
                if unpack_ms > 0 {
                    s.unpack_bps = Some(restored_bytes as f64 * 1000.0 / unpack_ms as f64);
                }
                if let Some(cold_ms) = cold_known {
                    s.learn_after_restore(&key, install_ms, cold_ms);
                }
                let k = s.key_mut(&key);
                k.warm_ms = Some(fetch_ms + unpack_ms + install_ms);
                k.archive_bytes = Some(restored_bytes);
            } else if cold {
                s.key_mut(&key).cold_ms = Some(install_ms);
            }
        });
    }
    let Some(remote) = remote.filter(|_| missing && ok && options.upload) else {
        return Ok(());
    };
    if !options.upload_now {
        // The person's wait ends with the install: packing and uploading run detached.
        report.upload = Some(match spawn_upload(&report.key, &plan, codec, report.install_ms) {
            Ok(()) => "background",
            Err(error) => {
                report.error = Some(format!("background upload: {error:#}"));
                "error"
            }
        });
        return Ok(());
    }
    let (pack_ms, packed) = timed_pack(&plan, codec, &archive_path).await?;
    report.pack_ms = pack_ms;
    report.denied = packed.denied;
    report.archive_bytes = std::fs::metadata(&archive_path)?.len();
    let started = Instant::now();
    let stored = remote.store(&report.key, &archive_path).await;
    report.upload_ms = ms(started);
    report.upload = Some(upload_outcome(stored, &mut report.error));
    record_upload(&report.key, report.archive_bytes);
    if report.upload == Some("created") {
        let meta = Meta { cold_ms: report.install_ms, archive_bytes: report.archive_bytes };
        if let Err(error) = remote.store_meta(&report.key, meta).await {
            report.error = Some(format!("timing record: {error:#}"));
        }
    }
    Ok(())
}

async fn timed_pack(
    plan: &Plan,
    codec: Codec,
    out: &Path,
) -> anyhow::Result<(u64, archive::Packed)> {
    let started = Instant::now();
    let (root, include, path) = (plan.root.clone(), plan.include.clone(), out.to_owned());
    let packed = blocking(move || archive::pack(&root, &include, codec, &path)).await?;
    Ok((ms(started), packed))
}

fn upload_outcome(stored: anyhow::Result<Stored>, error: &mut Option<String>) -> &'static str {
    match stored {
        Ok(Stored::Created) => "created",
        Ok(Stored::Exists) => "exists",
        Ok(Stored::Off) => "skipped",
        Err(e) => {
            *error = Some(format!("{e:#}"));
            "error"
        }
    }
}

fn record_upload(key: &str, bytes: u64) {
    if bytes > 0 {
        Stats::update(|s| s.key_mut(key).archive_bytes = Some(bytes));
    }
}

/// A cache key as a file name: `<ecosystem>-<hex>`, nothing else.
fn plain_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 128
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn uploads_dir() -> PathBuf {
    crate::config::home().join("deps-uploads")
}

/// Starts `machine deps upload` detached from this process (its own process
/// group, no terminal), and returns once it holds its key's lock, so a
/// `machine deps wait` that runs after this warm always waits for it.
fn spawn_upload(key: &str, plan: &Plan, codec: Codec, cold_ms: u64) -> anyhow::Result<()> {
    use std::io::Read;
    anyhow::ensure!(plain_key(key), "key is not plain");
    let exe = std::env::current_exe()?;
    let mut cmd = std::process::Command::new(exe);
    cmd.args(["machine", "deps", "upload", "--key", key, "--codec", codec.name()])
        .arg("--cold-ms")
        .arg(cold_ms.to_string())
        .arg("--root")
        .arg(&plan.root);
    for rel in &plan.include {
        cmd.arg("--include").arg(rel);
    }
    cmd.stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    #[cfg(unix)]
    std::os::unix::process::CommandExt::process_group(&mut cmd, 0);
    let mut child = cmd.spawn()?;
    let mut ready = [0u8; 1];
    let mut out = child.stdout.take().ok_or_else(|| anyhow::anyhow!("no pipe to the uploader"))?;
    // One byte once it holds the lock; an end of file means it stopped first.
    let n = out.read(&mut ready)?;
    anyhow::ensure!(n == 1, "the uploader stopped before it started");
    Ok(())
}

/// An exclusive `flock` on `file`, waiting for it when `wait`.
#[cfg(unix)]
fn lock(file: &std::fs::File, wait: bool) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    let op = libc::LOCK_EX | if wait { 0 } else { libc::LOCK_NB };
    if unsafe { libc::flock(file.as_raw_fd(), op) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

/// Without `flock` an upload holds no lock and `machine deps wait` waits for none.
#[cfg(not(unix))]
fn lock(_file: &std::fs::File, _wait: bool) -> std::io::Result<()> {
    Ok(())
}

/// `machine deps upload`: pack `include` under `root` and store it as `key`,
/// holding `~/.acpmux/deps-uploads/<key>.lock` while it runs.
pub async fn upload(
    key: &str,
    root: &Path,
    include: &[PathBuf],
    codec: Codec,
    cold_ms: u64,
) -> anyhow::Result<&'static str> {
    use std::io::Write as _;
    anyhow::ensure!(plain_key(key), "key is not plain");
    let dir = uploads_dir();
    std::fs::create_dir_all(&dir)?;
    let lock_path = dir.join(format!("{key}.lock"));
    let file =
        std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(&lock_path)?;
    if lock(&file, false).is_err() {
        // Another upload of this key is running.
        let _ = std::io::stdout().write_all(b"1");
        return Ok("exists");
    }
    let _ = std::io::stdout().write_all(b"1");
    let _ = std::io::stdout().flush();
    let result = async {
        let remote = Remote::joined()?.ok_or_else(|| anyhow::anyhow!("not joined"))?;
        let scratch = tempfile::tempdir()?;
        let path = scratch.path().join("deps.tar");
        let plan = Plan {
            root: root.to_owned(),
            include: include.to_vec(),
            replaces: false,
            install: Vec::new(),
        };
        timed_pack(&plan, codec, &path).await?;
        let bytes = std::fs::metadata(&path)?.len();
        let mut error = None;
        let outcome = upload_outcome(remote.store(key, &path).await, &mut error);
        record_upload(key, bytes);
        // Beside the archive: the cold install it saves, for machines that measured nothing yet.
        if outcome == "created" && cold_ms > 0 {
            remote.store_meta(key, Meta { cold_ms, archive_bytes: bytes }).await?;
        }
        match error {
            Some(e) => Err(anyhow::anyhow!(e)),
            None => Ok(outcome),
        }
    }
    .await;
    let _ = std::fs::remove_file(&lock_path);
    drop(file);
    result
}

/// `machine deps wait`: returns when no background upload is running.
pub fn wait_uploads() -> anyhow::Result<usize> {
    let Ok(entries) = std::fs::read_dir(uploads_dir()) else { return Ok(0) };
    let mut waited = 0;
    for entry in entries.filter_map(Result::ok) {
        let path = entry.path();
        if path.extension().is_none_or(|e| e != "lock") {
            continue;
        }
        let Ok(file) = std::fs::File::open(&path) else { continue };
        lock(&file, true)?;
        waited += 1;
    }
    Ok(waited)
}

/// The projects in `dir` and their keys, without asking the hub.
pub fn keys(dir: &Path) -> Vec<(Project, Option<Plan>, std::io::Result<String>)> {
    let codec = Codec::here();
    detect::detect(dir)
        .into_iter()
        .map(|project| {
            let plan = detect::plan(&project);
            let key = detect::key(&project, codec.name());
            (project, plan, key)
        })
        .collect()
}
