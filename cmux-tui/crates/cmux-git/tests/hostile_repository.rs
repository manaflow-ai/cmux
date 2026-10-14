//! A repository's own config must not make a read run a program. Each test
//! builds a repository whose config would run `touch <marker>`, reads it the
//! way the changes view does, and checks the marker was never made.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_git::Repository;
use cmux_git::diff::{comparison, diff_args};

/// A fresh folder for one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let unique = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-git-hostile-{}-{name}-{unique}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).expect("create scratch folder");
        Self(std::fs::canonicalize(&path).expect("canonical scratch folder"))
    }

    fn marker(&self) -> PathBuf {
        self.0.join("marker")
    }

    /// A shell command that makes the marker.
    fn touch_marker(&self) -> String {
        format!("touch '{}'", self.marker().display())
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Runs setup git in `directory`, isolated from the machine's git config,
/// and returns its trimmed output.
fn git(directory: &Path, arguments: &[&str]) -> String {
    let mut command = Command::new("git");
    for (name, _) in std::env::vars_os() {
        if name.as_encoded_bytes().starts_with(b"GIT_") {
            command.env_remove(name);
        }
    }
    let output = command
        .args(arguments)
        .current_dir(directory)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_AUTHOR_NAME", "cmux tests")
        .env("GIT_AUTHOR_EMAIL", "cmux@example.invalid")
        .env("GIT_COMMITTER_NAME", "cmux tests")
        .env("GIT_COMMITTER_EMAIL", "cmux@example.invalid")
        .output()
        .expect("run git");
    assert!(
        output.status.success(),
        "git {arguments:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn new_repository(path: &Path) {
    std::fs::create_dir_all(path).expect("create repository folder");
    git(path, &["init", "--quiet", "--initial-branch=main"]);
}

/// Reads `scope` the way `git.diff` does: names, counts and patches.
fn read_changes(root: &Path, scope: &str) {
    let repository = Repository::open(root).expect("open repository");
    let comparison = comparison(&repository, scope).expect("comparison");
    for mode in [&["--name-status", "-z"][..], &["--numstat", "-z"], &["--patch"]] {
        let _ = repository.run(&diff_args(&comparison, mode, &[]), 1024 * 1024);
    }
    let _ = repository.run(&["status", "--porcelain=v2", "-z"], 1024 * 1024);
}

fn assert_no_marker(scratch: &Scratch) {
    assert!(
        !scratch.marker().exists(),
        "reading the repository ran a program from its config ({} exists)",
        scratch.marker().display()
    );
}

/// `-c filter.a=b.clean=` splits at the first `=`, so passing the blanking
/// on the command line never blanks a driver whose name has one.
#[test]
fn hostile_repository_filter_driver_name_with_equals_sign_runs_no_clean_command() {
    let scratch = Scratch::new("filter");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join(".gitattributes"), "* filter=a=b\n").expect("write attributes");
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    let clean = format!("{}; cat", scratch.touch_marker());
    git(&root, &["config", "filter.a=b.clean", clean.as_str()]);
    // Stat-dirty: git must hash the file again, through its clean filter.
    let file = root.join("file.txt");
    let old = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(978_307_200);
    std::fs::File::options()
        .write(true)
        .open(&file)
        .and_then(|handle| handle.set_modified(old))
        .expect("age the file");

    read_changes(&root, "uncommitted");

    assert_no_marker(&scratch);
}

/// A partial clone fetches a missing object on demand, through the
/// repository's own `core.sshCommand`.
#[test]
fn hostile_repository_partial_clone_lazy_fetch_runs_no_ssh_command() {
    let scratch = Scratch::new("lazy-fetch");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    std::fs::write(root.join("file.txt"), "two\n").expect("write file");
    git(&root, &["commit", "--quiet", "-a", "-m", "two"]);
    // Drop the committed blob, as a blobless clone would never have had it.
    let blob = git(&root, &["rev-parse", "HEAD:file.txt"]);
    let object = root.join(".git/objects").join(&blob[..2]).join(&blob[2..]);
    std::fs::remove_file(&object).expect("remove the blob");
    git(&root, &["config", "core.repositoryformatversion", "1"]);
    git(&root, &["config", "extensions.partialClone", "origin"]);
    git(&root, &["config", "remote.origin.url", "ssh://example.invalid/repository"]);
    git(&root, &["config", "remote.origin.promisor", "true"]);
    let ssh = format!("{}; false", scratch.touch_marker());
    git(&root, &["config", "core.sshCommand", ssh.as_str()]);

    read_changes(&root, "committed");

    assert_no_marker(&scratch);
}

/// `diff.submodule=diff` makes git run `git diff` inside the submodule,
/// which uses the submodule's own external diff driver.
#[test]
fn hostile_repository_submodule_inline_diff_runs_no_external_diff() {
    let scratch = Scratch::new("submodule");
    let submodule = scratch.0.join("submodule");
    new_repository(&submodule);
    std::fs::write(submodule.join(".gitattributes"), "* diff=x\n").expect("write attributes");
    std::fs::write(submodule.join("file.txt"), "one\n").expect("write file");
    git(&submodule, &["add", "."]);
    git(&submodule, &["commit", "--quiet", "-m", "one"]);
    let root = scratch.0.join("repository");
    new_repository(&root);
    let source = submodule.to_string_lossy().into_owned();
    git(
        &root,
        &["-c", "protocol.file.allow=always", "submodule", "add", "--quiet", &source, "sub"],
    );
    git(&root, &["commit", "--quiet", "-m", "add the submodule"]);
    // A new submodule commit is a change the superproject's diff shows.
    let checkout = root.join("sub");
    std::fs::write(checkout.join("file.txt"), "two\n").expect("write file");
    git(&checkout, &["commit", "--quiet", "-a", "-m", "two"]);
    let command = format!("{}; true", scratch.touch_marker());
    git(&checkout, &["config", "diff.x.command", command.as_str()]);
    git(&root, &["config", "diff.submodule", "diff"]);

    read_changes(&root, "uncommitted");

    assert_no_marker(&scratch);
}
