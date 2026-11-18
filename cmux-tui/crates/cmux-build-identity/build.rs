use std::collections::{BTreeSet, HashSet};
use std::env;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

const BUILD_COMMIT_ENV: &str = "CMUX_TUI_BUILD_COMMIT";
const BUILD_IDENTITY_ENV: &str = "CMUX_TUI_BUILD_IDENTITY";
/// Unix seconds of the source commit's committer time (cx-3r9mt): set by a
/// build outside Git, else read from Git; 0 when unknown.
const BUILD_TIME_ENV: &str = "CMUX_TUI_BUILD_TIME";
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
    println!("cargo:rerun-if-env-changed={BUILD_TIME_ENV}");
    println!("cargo:rustc-env={BUILD_TIME_ENV}={}", build_time(&manifest_dir, &identity));
}

/// The committer time of the build's commit (the stamped commit when it is
/// one, else HEAD, whose tree a dirty identity extends); 0 when Git cannot
/// tell. A dirty build keeps its commit's time: the remote update rule
/// (`update_need`) never orders two builds of one commit by time.
fn build_time(manifest_dir: &Path, identity: &str) -> u64 {
    if let Some(time) = env::var(BUILD_TIME_ENV).ok().and_then(|value| value.trim().parse().ok()) {
        return time;
    }
    let commit = if identity.len() == 40 && identity.bytes().all(|b| b.is_ascii_hexdigit()) {
        identity
    } else {
        "HEAD"
    };
    git(manifest_dir, &["log", "-1", "--format=%ct", commit])
        .and_then(|value| value.parse().ok())
        .unwrap_or(0)
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
        .unwrap_or_else(|| panic!("cmux-build-identity is not inside the cmux-tui workspace"));
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
    // Not .git/index: `git diff HEAD` and `git ls-files` rewrite it on a stat
    // refresh (this script's calls and acpmux's), so tracking it reran both
    // scripts on an unchanged tree. Cost: staging alone (`git add` of a new
    // file, `git rm --cached`) no longer refreshes the identity until the next
    // source change or commit; the binary is the same.
    //
    // Only files whose bytes are the ref state: HEAD (a checkout, or a commit
    // on a detached HEAD, rewrites it), packed-refs, and the branch ref HEAD
    // names (a commit, amend, reset or rebase rewrites its loose file). A
    // fresh clone of the same commit has the same bytes, so a cache that
    // serves mtimes by content (hq build-fleet/cache-bench) leaves this script
    // fresh. Not logs/HEAD, though every ref move appends to it: its lines
    // carry wall-clock times, so every clone differs and a target/ restored
    // under a fresh clone reran this script. The case it covered, a commit on
    // a branch whose ref is packed (no loose file to watch yet), is covered by
    // `branch_ref_watch_path`; a clone writes its branch loose, so that case
    // never meets a cache. tests/git_watch_lint.rs keeps every cmux-tui build
    // script off logs/, index, FETCH_HEAD and ORIG_HEAD.
    track_git_path(manifest_dir, "HEAD");
    track_git_path(manifest_dir, "packed-refs");
    // The ref store of a reftable repository (no loose refs).
    track_git_path(manifest_dir, "reftable/tables.list");
    if let Some(reference) = git(manifest_dir, &["symbolic-ref", "-q", "HEAD"])
        && let Some(path) = branch_ref_watch_path(manifest_dir, &reference)
    {
        emit_cargo_path_directive("rerun-if-changed", &path);
    }
}

fn git_path(manifest_dir: &Path, path: &str) -> Option<PathBuf> {
    git(manifest_dir, &["rev-parse", "--path-format=absolute", "--git-path", path])
        .map(PathBuf::from)
}

fn track_git_path(manifest_dir: &Path, path: &str) {
    if let Some(path) = git_path(manifest_dir, path)
        && path.exists()
    {
        emit_cargo_path_directive("rerun-if-changed", &path);
    }
}

/// What to watch for the branch `reference` (`refs/heads/...`): its loose ref
/// file, or, when the ref is packed and has no loose file, the nearest
/// existing directory under refs/ that the file will be created in, so the
/// first commit on a packed branch (which writes the loose file) still reruns
/// this script.
fn branch_ref_watch_path(manifest_dir: &Path, reference: &str) -> Option<PathBuf> {
    let loose = git_path(manifest_dir, reference)?;
    if loose.exists() {
        return Some(loose);
    }
    let refs = git_path(manifest_dir, "refs")?;
    loose
        .ancestors()
        .skip(1)
        .take_while(|dir| dir.starts_with(&refs))
        .find(|dir| dir.is_dir())
        .map(Path::to_owned)
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
