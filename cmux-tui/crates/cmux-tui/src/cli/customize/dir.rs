//! `cmux customize use dir:PATH [--watch]`: a working copy on this computer
//! as a library entry, with no push, no pull request and no CI (cmuxterm-hq
//! `docs/design/experiments-shelf.md`).
//!
//! The folder's own `scripts/cmux-next/build-web-bundles.sh --out-root`
//! builds its web bundles; the three overlay surfaces become a layer folder
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
/// The builders of the three overlay surfaces, with their extra arguments; a
/// watch rebuild runs them side by side, each into its surface's folder.
const BUILDERS: [(&str, &[&str]); 3] = [
    ("scripts/cmux-next/build-agent-pane-web.sh", &[]),
    ("scripts/cmux-next/build-pages-web.sh", &[]),
    ("scripts/build-webviews-app.sh", &["--skip-checks"]),
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
fn run(dir: &Path, program: &str, args: &[&str]) -> Result<(), Failure> {
    let output = cmux_process::Command::new(dir.join(program))
        .args(args)
        .current_dir(dir)
        .stdin(cmux_process::Stdio::null())
        .output()
        .map_err(|error| failure(format!("{program}: {error}")))?;
    if output.status.success() {
        return Ok(());
    }
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let lines: Vec<&str> = text.lines().collect();
    let tail = lines.iter().skip(lines.len().saturating_sub(25)).copied().collect::<Vec<_>>();
    Err(failure(format!("{program} failed:\n{}", tail.join("\n"))))
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

/// Builds the three overlay surfaces of `dir` into `out`, side by side: the
/// three builders run at once, each writing its output to a log in `out`
/// (a pipe each would stall a builder while another is waited on).
fn build_surfaces(dir: &Path, out: &Path) -> Result<(), Failure> {
    std::fs::create_dir_all(out).map_err(|error| failure(format!("{}: {error}", out.display())))?;
    let mut started = Vec::new();
    for ((builder, extra), (prefix, _)) in BUILDERS.iter().zip(SURFACES.iter()) {
        let name = prefix.trim_end_matches('/');
        let log = out.join(format!(".{name}.log"));
        let file = std::fs::File::create(&log)
            .map_err(|error| failure(format!("{}: {error}", log.display())))?;
        let copy =
            file.try_clone().map_err(|error| failure(format!("{}: {error}", log.display())))?;
        let target = out.join(name);
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
            let lines: Vec<&str> = text.lines().collect();
            let tail =
                lines.iter().skip(lines.len().saturating_sub(25)).copied().collect::<Vec<_>>();
            Err(failure(format!("{builder} failed:\n{}", tail.join("\n"))))
        });
        let _ = std::fs::remove_file(&log);
        if first.is_ok() {
            first = result;
        }
    }
    first
}

/// Every file under the three surfaces of `out`, sorted, as paths relative
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
    watch_folder(customize, &dir, &app, layer, origin)
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
    loop {
        let Ok(first) = receive.recv() else {
            return Err(failure("the folder watch stopped".into()));
        };
        let mut paths: Vec<PathBuf> = first.map(|event| event.paths).unwrap_or_default();
        // A save is often several events: take what comes in the next moment too.
        while let Ok(more) = receive.recv_timeout(Duration::from_millis(300)) {
            paths.extend(more.map(|event| event.paths).unwrap_or_default());
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
            Ok((next, seconds)) => {
                if next.web == layer.web {
                    println!("  built in {seconds:.0} s: the same bundles, nothing to apply");
                    continue;
                }
                let old = std::mem::replace(&mut layer, next.clone());
                match customize.library_use_code(next.clone(), Vec::new(), origin, now_ms()) {
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
                if !old.web.is_empty() && old.web != next.web {
                    prune(customize, &old.web);
                }
            }
            Err(error) => {
                println!("  the build failed; the last layer stays on:\n{}", error.message);
            }
        }
        // What the build itself changed (generated files git does not ignore,
        // if any) is not a save.
        while receive.try_recv().is_ok() {}
    }
}

/// `library refresh` for a folder entry: built again, swapped in place when
/// the bundles differ.
pub(super) fn refresh_entry(
    customize: &Customize,
    code: &CodeLayer,
    on: bool,
    origin: &str,
    now: u64,
) -> Result<String, Failure> {
    let Ok(dir) = checkout(Path::new(&code.source)) else {
        return Ok(format!("{} is gone or no longer a cmux working copy", code.source));
    };
    let (layer, seconds) = build_layer(customize, &dir, &App::find(), true)?;
    if layer.web == code.web && layer.head == code.head {
        return Ok(format!("built again in {seconds:.0} s: up to date"));
    }
    let name = layer.name();
    let old = code.web.clone();
    customize.library_use_code(layer.clone(), Vec::new(), origin, now)?;
    if !on {
        customize.library_settle_code(&name, "", Some(false), origin, now)?;
    }
    if !old.is_empty() && old != layer.web {
        prune(customize, &old);
    }
    Ok(format!("built again in {seconds:.0} s: now {}", layer.label()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tree(root: &Path, files: &[(&str, &str)]) {
        for (path, body) in files {
            let path = root.join(path);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, body).unwrap();
        }
    }

    #[test]
    fn the_same_build_is_the_same_layer_and_a_change_is_another() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("out");
        tree(
            &out,
            &[
                (
                    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/app.js",
                    "a",
                ),
                ("Resources/markdown-viewer/webviews-app/index.html", "b"),
                (
                    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentActivity/Resources/agent-activity/x",
                    "c",
                ),
            ],
        );
        let found = files(&out).unwrap();
        // Agent Activity is no overlay surface.
        assert_eq!(found.len(), 2);
        let one = digest(&out, &found).unwrap();
        assert_eq!(one, digest(&out, &files(&out).unwrap()).unwrap());
        tree(&out, &[("Resources/markdown-viewer/webviews-app/index.html", "c")]);
        assert_ne!(one, digest(&out, &files(&out).unwrap()).unwrap());
    }

    #[test]
    fn place_maps_the_surfaces_and_writes_the_manifest() {
        let tmp = tempfile::tempdir().unwrap();
        let out = tmp.path().join("out");
        tree(
            &out,
            &[
                (
                    "Packages/macOS/CmuxNext/Sources/CmuxNextPages/Resources/pages/settings/app.js",
                    "a",
                ),
                (
                    "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
                    "p",
                ),
            ],
        );
        let found = files(&out).unwrap();
        let key = digest(&out, &found).unwrap();
        let layer = layer_for(tmp.path(), &App::default(), key.clone());
        let dir = tmp.path().join("layers").join(&key);
        place(&out, &found, &dir, &layer).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join("pages/settings/app.js")).unwrap(), "a");
        assert!(dir.join("agent-pane/index.html").is_file());
        let manifest: Value =
            serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
        assert_eq!(manifest["kind"], "dir");
    }

    #[test]
    fn a_folder_with_another_web_abi_stays_out() {
        let tmp = tempfile::tempdir().unwrap();
        tree(tmp.path(), &[(ABI_SOURCE, r#"{"abi": 8}"#)]);
        let app = App { path: None, commit: None, abi: Some(7) };
        let layer = layer_for(tmp.path(), &app, "e".repeat(64));
        assert!(!layer.has_web());
        assert!(layer.needs_build[0].contains("web ABI 8; this app has 7"));
        let same = App { abi: Some(8), ..app };
        assert!(layer_for(tmp.path(), &same, "e".repeat(64)).has_web());
    }

    #[test]
    fn a_folder_is_named_by_its_last_part() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("My Cmux");
        std::fs::create_dir_all(&path).unwrap();
        let layer = layer_for(&path, &App::default(), "e".repeat(64));
        assert_eq!(layer.name(), "dir-my-cmux");
        assert_eq!(layer.kind, CodeKind::Dir);
    }

    #[test]
    fn output_and_installs_are_not_saves() {
        let tmp = tempfile::tempdir().unwrap();
        let kept = worth_a_build(
            tmp.path(),
            vec![
                tmp.path().join("webviews/node_modules/x/index.js"),
                tmp.path().join("webviews/dist/a.js"),
            ],
        );
        assert!(kept.is_empty());
    }
}
