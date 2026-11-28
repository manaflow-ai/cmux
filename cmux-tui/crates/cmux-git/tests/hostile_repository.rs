//! A repository's own config must not make a read run a program. Each test
//! builds a repository whose config would run `touch <marker>`, reads it the
//! way the changes view does, and checks the marker was never made.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Once;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_git::Repository;
use cmux_git::diff::{comparison, diff_args};

/// A fresh folder for one test, removed when dropped.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Self {
        isolate_home();
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

/// The test home's global config, the user's own: the `upper` filter
/// upper-cases what it cleans and makes `global-marker` beside the
/// repository, and `lfs` runs the home's fake `git-lfs`. Values are quoted:
/// `;` starts a comment in a config file.
fn global_config(home: &Path) -> String {
    format!(
        "[filter \"upper\"]\n\tclean = \"touch ../global-marker; tr a-z A-Z\"\n\tsmudge = cat\n\
         [filter \"lfs\"]\n\tclean = \"'{lfs}' clean -- %f\"\n\tsmudge = \"'{lfs}' smudge -- %f\"\n",
        lfs = home.join("git-lfs").display()
    )
}

/// Like git-lfs, the fake cleans by running the repository's
/// `lfs.extension.<name>.clean` programs, then passes the content through.
const FAKE_GIT_LFS: &str = "#!/bin/sh\n\
    git config --get-regexp '^lfs\\.extension\\..*\\.clean$' | while read -r _ program; do\n\
    sh -c \"$program\" </dev/null\n\
    done\n\
    exec cat\n";

/// Points HOME and XDG_CONFIG_HOME at an empty folder for the whole test
/// process, so the developer's own git config never changes what the reads
/// under test do.
fn isolate_home() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let home =
            std::env::temp_dir().join(format!("cmux-git-hostile-home-{}", std::process::id()));
        std::fs::create_dir_all(&home).expect("create the test home");
        // Drivers only the user's own config defines, as `git lfs install`
        // does. git runs filters at the top level, so the marker lands next
        // to a test's repository.
        std::fs::write(home.join(".gitconfig"), global_config(&home))
            .expect("write the global config");
        let lfs = home.join("git-lfs");
        std::fs::write(&lfs, FAKE_GIT_LFS).expect("write the fake git-lfs");
        std::fs::set_permissions(&lfs, std::os::unix::fs::PermissionsExt::from_mode(0o755))
            .expect("make the fake git-lfs executable");
        // SAFETY: every test calls this before it spawns anything or reads
        // the environment, and `Once` blocks them until it has run.
        unsafe {
            std::env::set_var("HOME", &home);
            std::env::set_var("XDG_CONFIG_HOME", home.join(".config"));
        }
    });
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

/// Backdates `file`, so git must hash it again (through its clean filter)
/// to learn whether it changed.
fn make_stat_dirty(file: &Path) {
    // 2001-01-01, long before the checkout.
    let old = std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_hours(271_752);
    std::fs::File::options()
        .write(true)
        .open(file)
        .and_then(|handle| handle.set_modified(old))
        .expect("age the file");
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
    let repository = Repository::open(&root).expect("open repository");
    let comparison = comparison(&repository, "committed").expect("comparison");
    let failure = repository
        .run(&diff_args(&comparison, &["--patch"], &[]), 1024 * 1024)
        .err()
        .expect("the diff needs the missing blob");
    let reason = failure.reason();
    assert!(reason.contains("not available locally in this partial clone"), "{reason}");
}

/// `core.attributesFile` and `diff.orderFile` name files every diff reads,
/// to the end: `/dev/zero` would be read until the deadline. An unreadable
/// order file (git stops) and attributes that mark text binary show whether
/// git read them, without risking the memory.
#[test]
fn hostile_repository_attributes_and_order_files_are_never_read() {
    let scratch = Scratch::new("config-files");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    std::fs::write(root.join("file.txt"), "two\n").expect("write file");
    let attributes = scratch.0.join("attributes");
    std::fs::write(&attributes, "*.txt -diff\n").expect("write attributes");
    git(&root, &["config", "core.attributesFile", &attributes.to_string_lossy()]);
    let order = scratch.0.join("missing-order-file");
    git(&root, &["config", "diff.orderFile", &order.to_string_lossy()]);

    let repository = Repository::open(&root).expect("open repository");
    let comparison = comparison(&repository, "uncommitted").expect("comparison");
    let output = repository
        .run(&diff_args(&comparison, &["--patch"], &[]), 1024 * 1024)
        .expect("the diff runs without reading the order file");
    let patch = String::from_utf8_lossy(&output.stdout);
    assert!(patch.contains("+two"), "the attributes file made the diff binary: {patch}");
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

/// The submodule search keeps gitlinks only, so a large index with no
/// submodule is never refused for its size.
#[test]
fn submodule_filter_search_is_bounded_by_gitlinks_not_files() {
    let scratch = Scratch::new("large-index");
    let root = scratch.0.join("repository");
    new_repository(&root);
    for index in 0..200 {
        std::fs::write(root.join(format!("file-{index:04}.txt")), "x\n").expect("write file");
    }
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "many files"]);

    let repository = Repository::open(&root).expect("open repository");
    // 200 entries list about 14 KiB; none is a gitlink.
    let searched = repository.with_submodule_filters_limited(1024);

    assert!(searched.is_ok(), "{:?}", searched.err());
}

/// A repository with `file.txt` committed through no filter, marked for the
/// global `upper` filter and changed to `two` in the work tree.
fn upper_filtered_repository(scratch: &Scratch) -> PathBuf {
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join(".gitattributes"), "*.txt filter=upper\n").expect("write attributes");
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    std::fs::write(root.join("file.txt"), "two\n").expect("write file");
    root
}

fn uncommitted_patch(root: &Path) -> String {
    let repository = Repository::open(root).expect("open repository");
    let repository = repository.with_submodule_filters().expect("blank submodule filters");
    let comparison = comparison(&repository, "uncommitted").expect("comparison");
    let output = repository
        .run(&diff_args(&comparison, &["--patch"], &[]), 1024 * 1024)
        .expect("diff the work tree");
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// A driver the user's global config defines is blanked too: a global
/// driver such as git-lfs reads the repository's config, which can name a
/// program for it to run, so a read runs no filter at all and the diff
/// shows the raw content.
#[test]
fn hostile_repository_global_filter_driver_never_runs() {
    let scratch = Scratch::new("global-filter");
    let root = upper_filtered_repository(&scratch);

    let patch = uncommitted_patch(&root);

    assert!(!scratch.0.join("global-marker").exists(), "the global clean filter ran");
    assert!(patch.contains("+two"), "{patch}");
}

/// git-lfs runs the programs the repository's `lfs.extension.<name>.clean`
/// names, so a global lfs driver would run a program from repository
/// config.
#[test]
fn hostile_repository_lfs_extension_never_runs() {
    let scratch = Scratch::new("lfs-extension");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join(".gitattributes"), "*.bin filter=lfs\n").expect("write attributes");
    std::fs::write(root.join("file.bin"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    git(&root, &["config", "lfs.extension.x.clean", &scratch.touch_marker()]);
    std::fs::write(root.join("file.bin"), "two\n").expect("write file");

    read_changes(&root, "uncommitted");

    assert_no_marker(&scratch);
}

/// `GIT_CONFIG_KEY_<n>` must name the driver byte for byte: a name that is
/// not UTF-8 could never be blanked through a lossy copy, so the read is
/// refused instead.
#[test]
fn hostile_repository_filter_driver_name_not_utf8_never_runs() {
    let scratch = Scratch::new("filter-not-utf8");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join(".gitattributes"), b"* filter=\xff\n").expect("write attributes");
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    let mut config = std::fs::read(root.join(".git/config")).expect("read config");
    config.extend_from_slice(b"[filter \"\xff\"]\n\tclean = \"");
    config.extend_from_slice(scratch.touch_marker().as_bytes());
    config.extend_from_slice(b"; cat\"\n");
    std::fs::write(root.join(".git/config"), config).expect("write config");
    make_stat_dirty(&root.join("file.txt"));

    let opened = Repository::open(&root);
    if let Ok(repository) = &opened {
        let comparison = comparison(repository, "uncommitted").expect("comparison");
        let _ = repository.run(&diff_args(&comparison, &["--patch"], &[]), 1024 * 1024);
        let _ = repository.run(&["status", "--porcelain=v2", "-z"], 1024 * 1024);
    }

    assert_no_marker(&scratch);
    let reason = opened.err().map(|error| error.to_string()).unwrap_or_default();
    assert!(reason.contains("not UTF-8"), "the read was not refused: {reason}");
}

/// A submodule whose `.git` file points nowhere is no repository, for git
/// as much as for the filter search: it is skipped, not a failed read.
#[test]
fn submodule_with_missing_git_folder_is_skipped() {
    let scratch = Scratch::new("broken-submodule");
    let submodule = scratch.0.join("submodule");
    new_repository(&submodule);
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
    let missing = scratch.0.join("missing-git-folder");
    std::fs::write(root.join("sub/.git"), format!("gitdir: {}\n", missing.display()))
        .expect("point the submodule nowhere");

    let repository = Repository::open(&root).expect("open repository");
    let searched = repository.with_submodule_filters();

    assert!(searched.is_ok(), "{:?}", searched.err());
}

/// Repository config that redefines a global driver's command never gets
/// it run.
#[test]
fn hostile_repository_local_override_of_global_filter_never_runs() {
    let scratch = Scratch::new("global-filter-override");
    let root = upper_filtered_repository(&scratch);
    let clean = format!("{}; cat", scratch.touch_marker());
    git(&root, &["config", "filter.upper.clean", clean.as_str()]);

    let patch = uncommitted_patch(&root);

    assert_no_marker(&scratch);
    assert!(!scratch.0.join("global-marker").exists(), "the overridden global filter ran");
    assert!(patch.contains("+two"), "{patch}");
}

/// A file the repository's config includes is repository config too.
#[test]
fn hostile_repository_included_filter_driver_never_runs() {
    let scratch = Scratch::new("included-filter");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join(".gitattributes"), "* filter=inc\n").expect("write attributes");
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    let included = scratch.0.join("included.config");
    let clean = format!("{}; cat", scratch.touch_marker());
    std::fs::write(&included, format!("[filter \"inc\"]\n\tclean = \"{clean}\"\n"))
        .expect("write the included config");
    git(&root, &["config", "include.path", &included.to_string_lossy()]);
    std::fs::write(root.join("file.txt"), "two\n").expect("write file");

    read_changes(&root, "uncommitted");

    assert_no_marker(&scratch);
}

/// Writes an executable `post-index-change` hook in `hooks` that makes the
/// marker.
fn write_index_hook(scratch: &Scratch, hooks: &Path) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::create_dir_all(hooks).expect("create the hooks folder");
    let hook = hooks.join("post-index-change");
    std::fs::write(&hook, format!("#!/bin/sh\n{}\n", scratch.touch_marker()))
        .expect("write the hook");
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755))
        .expect("make the hook executable");
}

/// A working-tree diff refreshes a stale index and writes it, which runs
/// the repository's `post-index-change` hook; `.git/hooks` needs no config.
#[test]
fn hostile_repository_index_hook_never_runs() {
    let scratch = Scratch::new("index-hook");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    write_index_hook(&scratch, &root.join(".git/hooks"));
    make_stat_dirty(&root.join("file.txt"));

    read_changes(&root, "uncommitted");

    assert_no_marker(&scratch);
}

/// The same hook from a folder the repository's `core.hooksPath` names.
#[test]
fn hostile_repository_hooks_path_index_hook_never_runs() {
    let scratch = Scratch::new("hooks-path");
    let root = scratch.0.join("repository");
    new_repository(&root);
    std::fs::write(root.join("file.txt"), "one\n").expect("write file");
    git(&root, &["add", "."]);
    git(&root, &["commit", "--quiet", "-m", "one"]);
    let hooks = scratch.0.join("hooks");
    write_index_hook(&scratch, &hooks);
    git(&root, &["config", "core.hooksPath", &hooks.to_string_lossy()]);
    make_stat_dirty(&root.join("file.txt"));

    read_changes(&root, "uncommitted");

    assert_no_marker(&scratch);
}
