//! `cmux customize use dir:PATH [--watch]`: a working copy on this computer
//! as a library entry, with no push, no pull request and no CI (cmuxterm-hq
//! `docs/design/experiments-shelf.md`).
//!
//! The folder's own `scripts/cmux-next/build-web-bundles.sh --out-root`
//! builds its web bundles; the overlay surfaces become a layer folder
//! named by their digest, with the same manifest (`abi`, `commit`) the app
//! checks, and the entry `dir-NAME` goes on top of the library like any other
//! code. A folder whose web ABI is not the app's is kept off with that line.
//!
//! `--watch` stays: on a save under `webviews/` or `schemas/` (what git
//! ignores, such as generated strings, is not a change), the three overlay
//! builders run side by side, and the new layer replaces the old one in
//! place; open pages reload. Stopping the watch leaves the entry on:
//! `library off dir-NAME` puts back what was under it.

use std::path::{Component, Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_customize::Customize;
use cmux_customize::library::{CodeKind, CodeLayer};
use serde_json::Value;
use sha2::{Digest, Sha256};

use super::Failure;
use super::pr::{self, App, SURFACES, failure, hex, put_on};
use super::render::Answer;

const BUILD: &str = "scripts/cmux-next/build-web-bundles.sh";
const ABI_SOURCE: &str = "webviews/src/web-abi.json";
/// The builders of the overlay surfaces, with their extra arguments; a
/// watch rebuild runs them side by side, each into its surface's folder.
const BUILDERS: [(&str, &[&str]); 4] = [
    ("scripts/cmux-next/build-agent-pane-web.sh", &[]),
    ("scripts/cmux-next/build-pages-web.sh", &[]),
    ("scripts/build-webviews-app.sh", &["--skip-checks"]),
    ("scripts/cmux-next/build-agent-activity-web.sh", &[]),
];
/// What a watch follows inside the folder.
const WATCHED: [&str; 2] = ["webviews", "schemas"];
/// Folder names a watch never reacts to (installs, build output, caches).
const NOISE: [&str; 5] = ["node_modules", "dist", ".vite", ".git", ".turbo"];

/// The working copy `path` names, checked.
fn checkout(path: &Path) -> Result<PathBuf, Failure> {
    let dir =
        path.canonicalize().map_err(|error| failure(format!("{}: {error}", path.display())))?;
    if !dir.join(BUILD).is_file() {
        return Err(failure(format!(
            "{} is not a cmux working copy (it has no {BUILD})",
            dir.display()
        )));
    }
    Ok(dir)
}

fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let output = cmux_process::Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .output()
        .ok()?;
    output.status.success().then(|| String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

/// Runs `program` in `dir`; on a failure, its last lines.
/// Runs `program` with its stdout and stderr in one log, in the order it wrote
/// them. Read as two pipes joined end to end, stderr's warnings came last and
/// filled the tail: the Nightly walk of 2026-11-24 (hq run 45341531578) saw
/// only esbuild's `No matching export` warning, never the error that stopped
/// the build.
fn run(dir: &Path, program: &str, args: &[&str]) -> Result<(), Failure> {
    let log =
        tempfile::NamedTempFile::new().map_err(|error| failure(format!("{program}: {error}")))?;
    let file = log.reopen().map_err(|error| failure(format!("{program}: {error}")))?;
    let copy = file.try_clone().map_err(|error| failure(format!("{program}: {error}")))?;
    let status = cmux_process::Command::new(dir.join(program))
        .args(args)
        .current_dir(dir)
        .stdin(cmux_process::Stdio::null())
        .stdout(file)
        .stderr(copy)
        .status()
        .map_err(|error| failure(format!("{program}: {error}")))?;
    if status.success() {
        return Ok(());
    }
    let text = std::fs::read_to_string(log.path()).unwrap_or_default();
    Err(failure(why_failed(program, &text)))
}

/// How many of a failed build's last lines the message keeps.
const TAIL_LINES: usize = 25;

/// A failed build's message: the lines that name an error, when the tail
/// lacks them, then the tail. A warning (`▲ [WARNING]`, `warning:`) names no
/// error, however it is worded.
pub(super) fn why_failed(program: &str, text: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(TAIL_LINES);
    let (head, tail) = lines.split_at_checked(start).unwrap_or((&[], lines.as_slice()));
    let names_error = |line: &str| {
        let lower = line.to_ascii_lowercase();
        !lower.contains("warning")
            && (lower.contains("error") || line.contains('✘') || lower.contains("failed"))
    };
    let causes: Vec<&str> = if tail.iter().any(|line| names_error(line)) {
        Vec::new()
    } else {
        head.iter().copied().filter(|line| names_error(line)).take(5).collect()
    };
    if causes.is_empty() {
        return format!("{program} failed:\n{}", tail.join("\n"));
    }
    format!("{program} failed: {}\n…\n{}", causes.join("\n"), tail.join("\n"))
}

/// A scratch build folder next to the layers.
fn out_root(customize: &Customize) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis());
    customize.layer_dir("build").with_file_name(format!(".build-{}-{stamp}", std::process::id()))
}

/// Builds every web bundle of `dir` into `out` (the first build: it also
/// installs packages and makes the generated strings).
fn build_all(dir: &Path, out: &Path) -> Result<(), Failure> {
    let out = out.to_string_lossy().into_owned();
    run(dir, BUILD, &["--out-root", &out])
}

/// Builds the overlay surfaces of `dir` into `out`, side by side: the
/// builders run at once, each writing its output to a log in `out`
/// (a pipe each would stall a builder while another is waited on).
fn build_surfaces(dir: &Path, out: &Path) -> Result<(), Failure> {
    std::fs::create_dir_all(out).map_err(|error| failure(format!("{}: {error}", out.display())))?;
    let mut started = Vec::new();
    for ((builder, extra), (prefix, bundle)) in BUILDERS.iter().zip(SURFACES.iter()) {
        // A surface is a nested path (…/Resources/agent-pane/): its log sits in
        // `out` itself, and its folder's parents are made first.
        let target = out.join(prefix.trim_end_matches('/'));
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| failure(format!("{}: {error}", parent.display())))?;
        }
        let log = out.join(format!(".{bundle}.log"));
        let file = std::fs::File::create(&log)
            .map_err(|error| failure(format!("{}: {error}", log.display())))?;
        let copy =
            file.try_clone().map_err(|error| failure(format!("{}: {error}", log.display())))?;
        let child = cmux_process::Command::new(dir.join(builder))
            .args(extra.iter().copied())
            .arg("--out")
            .arg(&target)
            .current_dir(dir)
            .stdin(cmux_process::Stdio::null())
            .stdout(file)
            .stderr(copy)
            .spawn()
            .map_err(|error| failure(format!("{builder}: {error}")));
        started.push((*builder, log, child));
    }
    let mut first = Ok(());
    for (builder, log, child) in started {
        let result = child.and_then(|mut child| {
            let status = child.wait().map_err(|error| failure(format!("{builder}: {error}")))?;
            if status.success() {
                return Ok(());
            }
            let text = std::fs::read_to_string(&log).unwrap_or_default();
            Err(failure(why_failed(builder, &text)))
        });
        let _ = std::fs::remove_file(&log);
        if first.is_ok() {
            first = result;
        }
    }
    first
}

/// Every file under the surfaces of `out`, sorted, as paths relative
/// to `out`.
fn files(out: &Path) -> std::io::Result<Vec<PathBuf>> {
    let mut found = Vec::new();
    let mut stack: Vec<PathBuf> =
        SURFACES.iter().map(|(prefix, _)| out.join(prefix.trim_end_matches('/'))).collect();
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries {
            let entry = entry?;
            let kind = entry.file_type()?;
            if kind.is_dir() {
                stack.push(entry.path());
            } else if kind.is_file()
                && let Ok(relative) = entry.path().strip_prefix(out)
            {
                found.push(relative.to_path_buf());
            }
        }
    }
    found.sort();
    Ok(found)
}

/// The surfaces' digest: the layer folder's name, so the same build is the
/// same layer.
fn digest(out: &Path, found: &[PathBuf]) -> std::io::Result<String> {
    let mut hash = Sha256::new();
    for path in found {
        hash.update(path.to_string_lossy().as_bytes());
        hash.update([0]);
        hash.update(std::fs::read(out.join(path))?);
        hash.update([0]);
    }
    Ok(hex(&hash.finalize()))
}

/// Copies the surfaces of `out` into layer folder `dir` through a sibling
/// folder renamed into place, manifest.json last.
fn place(out: &Path, found: &[PathBuf], dir: &Path, layer: &CodeLayer) -> std::io::Result<()> {
    if dir.join(cmux_customize::library::code::LAYER_MANIFEST).is_file() {
        return Ok(());
    }
    let parent = dir.parent().ok_or_else(|| std::io::Error::other("no layers folder"))?;
    let part = parent.join(format!(
        ".{}.part-{}",
        dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&part);
    let result = (|| {
        let mut surfaces: Vec<&str> = Vec::new();
        for path in found {
            let text = path.to_string_lossy().replace('\\', "/");
            let Some((prefix, surface)) =
                SURFACES.iter().find(|(prefix, _)| text.starts_with(prefix))
            else {
                continue;
            };
            let Some(rest) = text.strip_prefix(prefix) else { continue };
            let target = part.join(surface).join(rest);
            if let Some(folder) = target.parent() {
                std::fs::create_dir_all(folder)?;
            }
            std::fs::copy(out.join(path), &target)?;
            if !surfaces.contains(surface) {
                surfaces.push(surface);
            }
        }
        if surfaces.is_empty() {
            return Err(std::io::Error::other("the build made no web bundles"));
        }
        pr::write_manifest(&part, layer, &surfaces)?;
        std::fs::rename(&part, dir)
    })();
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&part);
    }
    result
}

/// The entry for folder `dir` built as `key`, for an app with `app`.
fn layer_for(dir: &Path, app: &App, key: String) -> CodeLayer {
    let head = git(dir, &["rev-parse", "HEAD"]).filter(|head| pr::is_sha(head)).unwrap_or_default();
    let subject = git(dir, &["log", "-1", "--format=%s"]).unwrap_or_default();
    let dirty = git(dir, &["status", "--porcelain", "--untracked-files=no"])
        .is_some_and(|status| !status.is_empty());
    let title = match (subject.is_empty(), dirty) {
        (true, true) => "uncommitted changes".to_owned(),
        (false, true) => format!("{subject}, with uncommitted changes"),
        _ => subject,
    };
    let abi = std::fs::read(dir.join(ABI_SOURCE))
        .ok()
        .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
        .and_then(|value| value.get("abi").and_then(Value::as_u64))
        .and_then(|abi| u32::try_from(abi).ok());
    let mut needs_build = Vec::new();
    let mut web = key;
    if let (Some(want), Some(have)) = (abi, app.abi)
        && want != have
    {
        needs_build.push(format!(
            "its web part needs web ABI {want}; this app has {have}: build the folder at a commit near the app's, or a new app"
        ));
        web.clear();
    }
    CodeLayer {
        kind: CodeKind::Dir,
        source: dir.to_string_lossy().into_owned(),
        repo: "local".to_owned(),
        pr: 0,
        title,
        head: head.clone(),
        base: head,
        web,
        abi,
        needs_build,
        note: String::new(),
    }
}

/// Builds `dir` (all of it, or the three surfaces) and places the result as
/// a layer; the entry it makes and the seconds the build took.
fn build_layer(
    customize: &Customize,
    dir: &Path,
    app: &App,
    all: bool,
) -> Result<(CodeLayer, f64), Failure> {
    let out = out_root(customize);
    let started = Instant::now();
    let result = (|| {
        if all { build_all(dir, &out) } else { build_surfaces(dir, &out) }?;
        let seconds = started.elapsed().as_secs_f64();
        let found = files(&out).map_err(|error| failure(format!("the build output: {error}")))?;
        let key =
            digest(&out, &found).map_err(|error| failure(format!("the build output: {error}")))?;
        let layer = layer_for(dir, app, key);
        if layer.has_web() {
            place(&out, &found, &customize.layer_dir(&layer.web), &layer)
                .map_err(|error| failure(format!("the layer folder: {error}")))?;
        }
        Ok((layer, seconds))
    })();
    let _ = std::fs::remove_dir_all(&out);
    result
}

/// Removes layer folder `key` when no entry names it any more.
fn prune(customize: &Customize, key: &str) {
    let used = customize.library().is_ok_and(|listing| {
        listing.entries.iter().any(|entry| entry.code.as_ref().is_some_and(|code| code.web == key))
    });
    if !used && cmux_customize::library::code::valid_key(key) {
        let _ = std::fs::remove_dir_all(customize.layer_dir(key));
    }
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// `cmux customize use dir:PATH [--watch]`.
pub(super) fn use_dir(
    customize: &Customize,
    path: &Path,
    watch: bool,
    origin: &str,
    now: u64,
) -> Result<Answer, Failure> {
    let dir = checkout(path)?;
    let app = App::find();
    clear_stale_builds(customize);
    let (layer, seconds) = build_layer(customize, &dir, &app, true)?;
    let name = layer.name();
    let lines = vec![format!("built here in {seconds:.0} s; nothing was pushed")];
    let answer = put_on(customize, layer.clone(), lines, origin, now)?;
    if !watch {
        return Ok(answer);
    }
    if let Answer::Library { human, .. } = &answer {
        print!("{human}");
    }
    println!("watching {} for saves (ctrl-c stops; {name} stays on)", dir.display());
    // main's handlers only note a signal for loops that look; this one waits
    // on the folder, so ctrl-c and SIGTERM end it the plain way.
    #[cfg(unix)]
    if crate::restore_default_termination_signals().is_err() {
        return Ok(answer);
    }
    watch_folder(customize, &dir, &app, layer, origin)
}

/// Scratch build folders (`.build-<pid>-<ms>`) of a CLI that is gone: a watch
/// stopped mid-build leaves one, and nothing else would remove it.
fn clear_stale_builds(customize: &Customize) {
    let Some(layers) = customize.layer_dir("build").parent().map(Path::to_path_buf) else {
        return;
    };
    let Ok(entries) = std::fs::read_dir(&layers) else { return };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(pid) = name
            .strip_prefix(".build-")
            .and_then(|rest| rest.split('-').next())
            .and_then(|pid| pid.parse::<i32>().ok())
        else {
            continue;
        };
        if pid != i32::try_from(std::process::id()).unwrap_or(0) && !alive(pid) {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

#[cfg(unix)]
fn alive(pid: i32) -> bool {
    if pid <= 0 {
        return false;
    }
    // SAFETY: signal 0 only asks whether `pid` exists; nothing is sent.
    let asked = unsafe { libc::kill(pid, 0) };
    asked == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
}

#[cfg(not(unix))]
fn alive(_pid: i32) -> bool {
    true
}

/// The changed paths in `paths` that are worth a build: not install or build
/// output, and not ignored by git (generated files).
fn worth_a_build(dir: &Path, paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let candidates: Vec<PathBuf> = paths
        .into_iter()
        .filter(|path| {
            !path.components().any(|part| match part {
                Component::Normal(name) => NOISE.iter().any(|noise| name == *noise),
                _ => false,
            })
        })
        .collect();
    if candidates.is_empty() {
        return candidates;
    }
    let mut command = cmux_process::Command::new("git");
    command.arg("-C").arg(dir).args(["check-ignore", "--no-index"]);
    for path in &candidates {
        command.arg(path);
    }
    let ignored: Vec<PathBuf> = command
        .stdin(cmux_process::Stdio::null())
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).lines().map(PathBuf::from).collect())
        .unwrap_or_default();
    candidates
        .into_iter()
        .filter(|path| !ignored.iter().any(|ignored| path.ends_with(ignored) || ignored == path))
        .collect()
}

fn watch_folder(
    customize: &Customize,
    dir: &Path,
    app: &App,
    mut layer: CodeLayer,
    origin: &str,
) -> Result<Answer, Failure> {
    use notify::Watcher;
    let (send, receive) = mpsc::channel::<notify::Result<notify::Event>>();
    let mut watcher = notify::recommended_watcher(send)
        .map_err(|error| failure(format!("could not watch {}: {error}", dir.display())))?;
    for part in WATCHED {
        let path = dir.join(part);
        if path.is_dir() {
            watcher
                .watch(&path, notify::RecursiveMode::Recursive)
                .map_err(|error| failure(format!("could not watch {}: {error}", path.display())))?;
        }
    }
    // Saves seen while a build ran: the next round builds them.
    let mut pending: Vec<PathBuf> = Vec::new();
    loop {
        let mut paths = std::mem::take(&mut pending);
        if paths.is_empty() {
            let Ok(first) = receive.recv() else {
                return Err(failure("the folder watch stopped".into()));
            };
            paths = saved_paths(first);
        }
        // A save is often several events: take what comes in the next moment too.
        while let Ok(more) = receive.recv_timeout(Duration::from_millis(300)) {
            paths.extend(saved_paths(more));
        }
        paths.sort();
        paths.dedup();
        let changed = worth_a_build(dir, paths);
        let Some(first) = changed.first() else { continue };
        let shown = first.strip_prefix(dir).unwrap_or(first).display().to_string();
        println!(
            "{shown}{}: building",
            if changed.len() > 1 {
                format!(" and {} more", changed.len().saturating_sub(1))
            } else {
                String::new()
            }
        );
        match build_layer(customize, dir, app, false) {
            Ok((next, seconds)) if next.web == layer.web => {
                println!("  built in {seconds:.0} s: the same bundles, nothing to apply");
            }
            Ok((next, seconds)) => {
                let old = std::mem::replace(&mut layer, next.clone());
                let applied = customize.library_update_code(next.clone(), origin, now_ms());
                // The replaced layer goes before the line that says so: a watch
                // stopped right after it keeps no stale layer.
                if applied.is_ok() && !old.web.is_empty() && old.web != next.web {
                    prune(customize, &old.web);
                }
                match applied {
                    Ok(_) if next.has_web() => println!(
                        "  built in {seconds:.0} s and applied ({}); open pages reload",
                        pr::short(&next.web)
                    ),
                    Ok(_) => println!(
                        "  built in {seconds:.0} s; not applied: {}",
                        next.needs_build.join("; ")
                    ),
                    Err(error) => println!("  built in {seconds:.0} s; not applied: {error}"),
                }
            }
            Err(error) => {
                println!("  the build failed; the last layer stays on:\n{}", error.message);
            }
        }
        // A save made while the build ran is built next. The build's own
        // reads are no save (`saved_paths`), and what it writes under the
        // folder is git-ignored (`worth_a_build`).
        while let Ok(event) = receive.try_recv() {
            pending.extend(saved_paths(event));
        }
        if !pending.is_empty() {
            pending = worth_a_build(dir, pending);
        }
    }
}

/// The paths an event changed. Linux reports a file opened or read too
/// (`Access`): every build reads the whole folder, so counting those made a
/// watch build again forever with nothing saved.
fn saved_paths(event: notify::Result<notify::Event>) -> Vec<PathBuf> {
    match event {
        Ok(event) if saves(&event.kind) => event.paths,
        _ => Vec::new(),
    }
}

fn saves(kind: &notify::EventKind) -> bool {
    use notify::EventKind;
    use notify::event::{AccessKind, AccessMode, MetadataKind, ModifyKind};
    match kind {
        EventKind::Access(AccessKind::Close(AccessMode::Write)) => true,
        EventKind::Access(_) | EventKind::Other => false,
        EventKind::Modify(ModifyKind::Metadata(MetadataKind::AccessTime)) => false,
        _ => true,
    }
}

/// `library refresh` for a folder entry: built again, swapped in place when
/// the bundles differ.
pub(super) fn refresh_entry(
    customize: &Customize,
    code: &CodeLayer,
    origin: &str,
    now: u64,
) -> Result<String, Failure> {
    let Ok(dir) = checkout(Path::new(&code.source)) else {
        return Ok(format!("{} is gone or no longer a cmux working copy", code.source));
    };
    // A folder that does not build is this entry's note, not the end of the
    // refresh: the other entries are still checked.
    let (layer, seconds) = match build_layer(customize, &dir, &App::find(), true) {
        Ok(built) => built,
        Err(error) => {
            let first = error.message.lines().next().unwrap_or_default().to_owned();
            return Ok(format!("did not build, the last layer stays: {first}"));
        }
    };
    if layer.web == code.web && layer.head == code.head {
        return Ok(format!("built again in {seconds:.0} s: up to date"));
    }
    let old = code.web.clone();
    customize.library_update_code(layer.clone(), origin, now)?;
    if !old.is_empty() && old != layer.web {
        prune(customize, &old);
    }
    Ok(format!("built again in {seconds:.0} s: now {}", layer.label()))
}

#[cfg(test)]
#[path = "dir_tests.rs"]
mod tests;
