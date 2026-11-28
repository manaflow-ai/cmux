//! acpmux-build-id's build.rs: the Git files it watches must have the same
//! bytes in a fresh clone of the same commit (so a restored target/ does not
//! relink acpmux), and a commit on a packed branch must still change something
//! watched. It lives here, beside the cmux-build-identity script's own checks
//! and the lint over every build script, so acpmux's test job (which runs every
//! acpmux-build-id test file) is unchanged.

use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

/// A repository holding `crates/acpmux` (where build.rs runs git) and
/// `crates/acpmux-build-id` (its manifest directory), with build.rs compiled.
struct Fixture {
    root: PathBuf,
    executable: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let unique = NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed);
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let root = env::temp_dir()
            .join(format!("acpmux-build-id-{}-{nanos}-{unique}", std::process::id()));
        fs::create_dir_all(root.join("crates/acpmux")).unwrap();
        fs::create_dir_all(root.join("crates/acpmux-build-id")).unwrap();
        fs::write(root.join("crates/acpmux/Cargo.toml"), "[package]\nname = \"acpmux\"\n").unwrap();
        git(&root, &["init", "--quiet"]);
        git(&root, &["add", "."]);
        commit(&root, "fixture");

        let executable = root.join(format!("build-script{}", env::consts::EXE_SUFFIX));
        let output = Command::new(env::var_os("RUSTC").unwrap_or_else(|| "rustc".into()))
            .arg("--edition=2024")
            .arg(Path::new(env!("CARGO_MANIFEST_DIR")).join("../acpmux-build-id/build.rs"))
            .arg("-o")
            .arg(&executable)
            .output()
            .unwrap();
        assert_success("compile build.rs", &output);
        Self { root, executable }
    }

    /// The watched paths under the Git directory, relative to it.
    fn watched_git_paths(&self) -> Vec<PathBuf> {
        let output = Command::new(&self.executable)
            .env("CARGO_MANIFEST_DIR", self.root.join("crates/acpmux-build-id"))
            .env_remove("CMUX_GIT_SHORT_SHA")
            .env("SOURCE_DATE_EPOCH", "0")
            .output()
            .unwrap();
        assert_success("run build.rs", &output);
        let git_dir = self.root.join(".git").canonicalize().unwrap();
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .filter_map(|line| line.strip_prefix("cargo:rerun-if-changed="))
            .filter_map(|path| Path::new(path).canonicalize().ok())
            .filter_map(|path| path.strip_prefix(&git_dir).ok().map(Path::to_owned))
            .collect()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn git(root: &Path, arguments: &[&str]) -> String {
    let output = Command::new("git").current_dir(root).args(arguments).output().unwrap();
    assert_success("run git", &output);
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn commit(root: &Path, message: &str) {
    git(
        root,
        &[
            "-c",
            "user.name=cmux test",
            "-c",
            "user.email=cmux@example.test",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--quiet",
            "--allow-empty",
            "-m",
            message,
        ],
    );
}

fn assert_success(action: &str, output: &Output) {
    assert!(
        output.status.success(),
        "{action} failed with {}\nstdout:\n{}\nstderr:\n{}",
        output.status,
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn watched_git_files_have_the_same_bytes_in_a_fresh_clone_of_the_commit() {
    let fixture = Fixture::new();
    let watched = fixture.watched_git_paths();
    let branch = git(&fixture.root, &["symbolic-ref", "-q", "HEAD"]);
    for expected in ["HEAD", branch.as_str()] {
        assert!(
            watched.iter().any(|path| path == Path::new(expected)),
            "build.rs does not watch {expected}: {watched:?}"
        );
    }

    let clone = fixture.root.join("fresh-clone");
    let output = Command::new("git")
        .args(["clone", "--quiet", "--no-local"])
        .arg(&fixture.root)
        .arg(&clone)
        .output()
        .unwrap();
    assert_success("clone the fixture", &output);
    for path in &watched {
        assert_eq!(
            fs::read(fixture.root.join(".git").join(path)).unwrap(),
            fs::read(clone.join(".git").join(path)).unwrap_or_default(),
            "watched Git file {} differs in a fresh clone of the same commit: {watched:?}",
            path.display()
        );
    }
}

#[test]
fn a_packed_branch_watches_the_directory_its_first_commit_writes_into() {
    let fixture = Fixture::new();
    let branch = git(&fixture.root, &["symbolic-ref", "-q", "HEAD"]);
    git(&fixture.root, &["pack-refs", "--all", "--prune"]);
    assert!(!fixture.root.join(".git").join(&branch).exists(), "pack-refs left a loose ref");

    let watched = fixture.watched_git_paths();
    let directory = Path::new(&branch).parent().unwrap();
    assert!(
        watched.iter().any(|path| path == directory),
        "a packed branch's ref directory {} is not watched: {watched:?}",
        directory.display()
    );

    // The first commit creates the loose ref inside the watched directory,
    // and from then on the loose ref itself is watched.
    commit(&fixture.root, "on a packed branch");
    assert!(fixture.root.join(".git").join(&branch).is_file());
    let watched = fixture.watched_git_paths();
    assert!(
        watched.iter().any(|path| path == Path::new(&branch)),
        "the loose ref is not watched after a commit: {watched:?}"
    );
}
