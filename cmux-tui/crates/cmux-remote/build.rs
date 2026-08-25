use std::collections::{BTreeSet, HashSet};
use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BUILD_COMMIT_ENV: &str = "CMUX_TUI_BUILD_COMMIT";
const BUILD_IDENTITY_ENV: &str = "CMUX_TUI_BUILD_IDENTITY";
const DIRTY_SEPARATOR: &[u8] = b"\0cmux-tui-untracked\0";

const _: () = cmux_tui_source_watch::ACTIVE;

fn main() {
    println!("cargo:rerun-if-env-changed={BUILD_COMMIT_ENV}");

    let manifest_dir =
        PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR is unset"));
    let identity = env::var(BUILD_COMMIT_ENV)
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| source_revision(&manifest_dir));
    if identity.bytes().any(|byte| byte.is_ascii_control()) {
        panic!("{BUILD_COMMIT_ENV} contains a control character");
    }
    println!("cargo:rustc-env={BUILD_IDENTITY_ENV}={identity}");
}

fn source_revision(manifest_dir: &Path) -> String {
    track_git_revision(manifest_dir);
    let revision =
        git(manifest_dir, &["rev-parse", "--verify", "HEAD^{commit}"]).unwrap_or_else(|| {
            panic!(
                "could not determine the cmux-tui source revision; set {BUILD_COMMIT_ENV} when building outside a Git checkout"
            )
        });
    let git_root = git(manifest_dir, &["rev-parse", "--show-toplevel"])
        .map(PathBuf::from)
        .and_then(|path| path.canonicalize().ok())
        .unwrap_or_else(|| {
            panic!(
                "could not determine the cmux-tui Git worktree; set {BUILD_COMMIT_ENV} when building outside a Git checkout"
            )
        });
    let source_root = manifest_dir
        .parent()
        .and_then(Path::parent)
        .unwrap_or_else(|| panic!("cmux-remote is not inside the cmux-tui workspace"));
    let source_root = source_root.canonicalize().unwrap_or_else(|error| {
        panic!("could not resolve cmux-tui source root {}: {error}", source_root.display())
    });
    let source_relative = source_root.strip_prefix(&git_root).unwrap_or_else(|_| {
        panic!(
            "cmux-tui source root {} is outside Git worktree {}",
            source_root.display(),
            git_root.display()
        )
    });
    let source_relative = source_relative.to_string_lossy().replace('\\', "/");
    let source_pathspec = format!(":(top){source_relative}");
    let target_pathspec = format!(":(top,exclude){source_relative}/target");
    let pathspecs = [source_pathspec.as_str(), target_pathspec.as_str()];

    let source_files = git_bytes(
        &git_root,
        &[
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "--full-name",
            "-z",
            "--",
            pathspecs[0],
            pathspecs[1],
        ],
    )
    .unwrap_or_else(|| panic!("could not enumerate cmux-tui source files"));
    track_source_files(&git_root, &source_files);
    let ignored_entries = git_bytes(
        &git_root,
        &[
            "ls-files",
            "--others",
            "--ignored",
            "--exclude-standard",
            "--directory",
            "--full-name",
            "-z",
            "--",
            pathspecs[0],
        ],
    )
    .unwrap_or_else(|| panic!("could not enumerate ignored cmux-tui paths"));
    track_source_directories(&git_root, &source_root, &source_files, &ignored_entries);

    let tracked_diff = git_bytes(
        &git_root,
        &[
            "diff",
            "--binary",
            "--full-index",
            "--no-ext-diff",
            "--no-textconv",
            "--no-renames",
            "HEAD",
            "--",
            pathspecs[0],
            pathspecs[1],
        ],
    )
    .unwrap_or_else(|| panic!("could not inspect tracked cmux-tui source changes"));
    let untracked_files = git_bytes(
        &git_root,
        &[
            "ls-files",
            "--others",
            "--exclude-standard",
            "--full-name",
            "-z",
            "--",
            pathspecs[0],
            pathspecs[1],
        ],
    )
    .unwrap_or_else(|| panic!("could not inspect untracked cmux-tui source files"));
    if tracked_diff.is_empty() && untracked_files.is_empty() {
        return revision;
    }

    let mut dirty_state = tracked_diff;
    dirty_state.extend_from_slice(DIRTY_SEPARATOR);
    for path in nul_separated(&untracked_files) {
        let path = std::str::from_utf8(path)
            .unwrap_or_else(|_| panic!("cmux-tui has a non-UTF-8 untracked source path"));
        let object = git(&git_root, &["hash-object", "--no-filters", "--", path])
            .unwrap_or_else(|| panic!("could not hash untracked cmux-tui source {path}"));
        dirty_state.extend_from_slice(path.as_bytes());
        dirty_state.push(0);
        dirty_state.extend_from_slice(object.as_bytes());
        dirty_state.push(0);
    }
    let dirty_hash = git_with_input(&git_root, &["hash-object", "--stdin"], &dirty_state)
        .unwrap_or_else(|| panic!("could not hash the dirty cmux-tui source state"));
    format!("{revision}-dirty.{dirty_hash}")
}

fn track_git_revision(manifest_dir: &Path) {
    track_git_path(manifest_dir, "HEAD");
    track_git_path(manifest_dir, "index");
    track_git_path(manifest_dir, "packed-refs");
    if let Some(reference) = git(manifest_dir, &["symbolic-ref", "-q", "HEAD"]) {
        track_git_path(manifest_dir, &reference);
    }
}

fn track_git_path(manifest_dir: &Path, path: &str) {
    if let Some(path) = git(manifest_dir, &["rev-parse", "--git-path", path])
        && Path::new(&path).exists()
    {
        emit_cargo_path_directive("rerun-if-changed", Path::new(&path));
    }
}

fn track_source_files(git_root: &Path, source_files: &[u8]) {
    for path in nul_separated(source_files) {
        let path =
            std::str::from_utf8(path).unwrap_or_else(|_| panic!("cmux-tui has a non-UTF-8 path"));
        emit_cargo_path_directive("rerun-if-changed", &git_root.join(path));
    }
}

fn track_source_directories(
    git_root: &Path,
    source_root: &Path,
    source_files: &[u8],
    ignored_entries: &[u8],
) {
    let mut unsafe_directories = HashSet::new();
    for path in nul_separated(ignored_entries) {
        let path = std::str::from_utf8(path)
            .unwrap_or_else(|_| panic!("cmux-tui has a non-UTF-8 ignored path"));
        let absolute = git_root.join(path.trim_end_matches('/'));
        let mut directory = if path.ends_with('/') {
            absolute.as_path()
        } else {
            absolute.parent().unwrap_or(&absolute)
        };
        while directory.starts_with(source_root) {
            unsafe_directories.insert(directory.to_owned());
            if directory == source_root {
                break;
            }
            let Some(parent) = directory.parent() else {
                break;
            };
            directory = parent;
        }
    }

    let mut watched = BTreeSet::new();
    for path in nul_separated(source_files) {
        let path =
            std::str::from_utf8(path).unwrap_or_else(|_| panic!("cmux-tui has a non-UTF-8 path"));
        let absolute = git_root.join(path);
        let Some(mut directory) = absolute.parent() else {
            continue;
        };
        let mut candidate = None;
        while directory.starts_with(source_root) {
            if unsafe_directories.contains(directory) {
                break;
            }
            candidate = Some(directory.to_owned());
            if directory == source_root {
                break;
            }
            let Some(parent) = directory.parent() else {
                break;
            };
            directory = parent;
        }
        if let Some(candidate) = candidate {
            watched.insert(candidate);
        }
    }
    for directory in watched {
        emit_cargo_path_directive("rerun-if-changed", &directory);
    }
}

fn emit_cargo_path_directive(directive: &str, path: &Path) {
    let value = path.to_string_lossy();
    if value.chars().any(char::is_control) {
        panic!("Cargo directive path contains a control character");
    }
    println!("cargo:{directive}={value}");
}

fn nul_separated(values: &[u8]) -> impl Iterator<Item = &[u8]> {
    values.split(|byte| *byte == 0).filter(|value| !value.is_empty())
}

fn git(manifest_dir: &Path, arguments: &[&str]) -> Option<String> {
    let output = git_bytes(manifest_dir, arguments)?;
    let value = String::from_utf8(output).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}

fn git_bytes(manifest_dir: &Path, arguments: &[&str]) -> Option<Vec<u8>> {
    let output = Command::new("git").current_dir(manifest_dir).args(arguments).output().ok()?;
    if !output.status.success() {
        return None;
    }
    Some(output.stdout)
}

fn git_with_input(manifest_dir: &Path, arguments: &[&str], input: &[u8]) -> Option<String> {
    let mut child = Command::new("git")
        .current_dir(manifest_dir)
        .args(arguments)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .ok()?;
    child.stdin.take()?.write_all(input).ok()?;
    let output = child.wait_with_output().ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_owned())
}
