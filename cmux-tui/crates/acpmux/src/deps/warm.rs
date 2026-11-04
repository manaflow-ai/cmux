//! One warm: for each project in a folder, restore its archive (when the
//! cache has one and nothing is installed yet), run its normal install, and
//! after a cold install upload an archive for the next machine.

use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::Serialize;

use super::archive::{self, Codec};
use super::detect::{self, Plan, Project};
use super::remote::{Fetched, Remote, Stored};

#[derive(Debug, Clone, Copy)]
pub struct Options {
    pub install: bool,
    pub upload: bool,
    /// Skip a project whose dependencies are already installed.
    pub if_missing: bool,
}

/// One project's result. Times are milliseconds; names and sizes only.
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub ecosystem: &'static str,
    pub key: String,
    /// `restored`, `miss`, `present` (already installed here), `installed`
    /// (skipped under `--if-missing`), `off` (the hub
    /// has no dependency caches), `not_joined`, `skipped` (the tool is not
    /// installed) or `error`.
    pub restore: &'static str,
    /// `created`, `exists`, `skipped` or `error`, when an upload was tried.
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

async fn install(plan: &Plan, dir: &Path) -> bool {
    let Some((program, args)) = plan.install.split_first() else { return true };
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
    let mut cold = false;
    // A project's own node_modules that is already there is kept. A package
    // manager's shared cache is always merged into: one earlier install must
    // not stop every later project from restoring or publishing its key.
    if plan.replaces && present(&plan) {
        report.restore = "present";
    } else if let Some(remote) = remote {
        let started = Instant::now();
        let fetched = remote.fetch(&report.key, &archive_path).await;
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
                        cold = true;
                        report.restore = "error";
                        report.error = Some(format!("restore: {error:#}"));
                    }
                }
                report.unpack_ms = ms(started);
            }
            Ok(Fetched::Miss) => {
                report.restore = "miss";
                cold = true;
            }
            Ok(Fetched::Off) => report.restore = "off",
            Err(error) => {
                report.restore = "error";
                report.error = Some(format!("{error:#}"));
                cold = true;
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
    let placed_tree = plan.replaces && report.restore == "restored";
    if options.if_missing && !placed_tree && detect::installed(project) {
        report.restore = "installed";
        return Ok(());
    }
    let started = Instant::now();
    let ok = install(&plan, &project.dir).await;
    report.install_ms = ms(started);
    report.install_ok = Some(ok);
    let Some(remote) = remote.filter(|_| cold && ok && options.upload) else {
        return Ok(());
    };
    let started = Instant::now();
    let (root, include, path) = (plan.root.clone(), plan.include.clone(), archive_path.clone());
    let packed = blocking(move || archive::pack(&root, &include, codec, &path)).await?;
    report.pack_ms = ms(started);
    report.denied = packed.denied;
    report.archive_bytes = std::fs::metadata(&archive_path)?.len();
    let started = Instant::now();
    let stored = remote.store(&report.key, &archive_path).await;
    report.upload_ms = ms(started);
    report.upload = Some(match stored {
        Ok(Stored::Created) => "created",
        Ok(Stored::Exists) => "exists",
        Ok(Stored::Off) => "skipped",
        Err(error) => {
            report.error = Some(format!("{error:#}"));
            "error"
        }
    });
    Ok(())
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
