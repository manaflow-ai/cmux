#![cfg(unix)]
//! `git.status` over a real session socket. A person waits for this read each time a view
//! shows a branch, so it must not grow with the checkout:
//!
//! - its reply is what the status child of git says of HEAD, in each form of a repository that
//!   a caller can be in. Each test here builds that reply from `git status --porcelain=v2
//!   --branch` itself ([`reference`]) and the daemon's reply must be equal to it, field for
//!   field;
//! - the daemon reads no file of the work tree for it. A `git status` child reads the index
//!   and looks at each tracked file, which is the part that grows with the checkout.
//!
//! The git on `PATH` is a stand-in that writes its arguments to a log named as its working
//! directory, and then is the real git.

use cmux_git::{Repository, parse};
use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::ffi::OsStr;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

struct Fixture {
    dir: PathBuf,
    real: PathBuf,
}

/// The real git, as an absolute path, before the stand-in goes on `PATH`.
fn real_git() -> PathBuf {
    let path = std::env::var_os("PATH").expect("PATH is set");
    std::env::split_paths(&path)
        .map(|dir| dir.join("git"))
        .find(|candidate| candidate.is_file())
        .expect("git is on PATH")
}

/// One directory for this test process, with a stand-in `git` first on `PATH`.
fn fixture() -> &'static Fixture {
    static FIXTURE: OnceLock<Fixture> = OnceLock::new();
    FIXTURE.get_or_init(|| {
        let dir = std::env::temp_dir().join(format!("gstatus-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        std::fs::create_dir_all(dir.join("log")).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        let real = real_git();
        let script = format!(
            "#!/bin/sh\n\
             echo \"$*\" >> \"{log}/$(basename \"$PWD\")\"\n\
             exec \"{real}\" \"$@\"\n",
            log = dir.join("log").display(),
            real = real.display(),
        );
        let shim = dir.join("bin").join("git");
        std::fs::write(&shim, script).unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut path = dir.join("bin").into_os_string();
        if let Some(old) = std::env::var_os("PATH") {
            path.push(":");
            path.push(old);
        }
        // Every test takes the fixture before it starts a daemon or a child,
        // and this runs once, under the cell's lock.
        unsafe { std::env::set_var("PATH", path) };
        Fixture { dir, real }
    })
}

fn unique(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}{}", NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Runs the real git in `directory`, apart from the host's git config. Returns whether it
/// ended with success.
fn git_ended<S: AsRef<OsStr>>(directory: &Path, arguments: &[S]) -> bool {
    Command::new(&fixture().real)
        .arg("-C")
        .arg(directory)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(["-c", "protocol.file.allow=always", "-c", "advice.detachedHead=false"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success()
}

fn git(directory: &Path, arguments: &[&str]) {
    assert!(git_ended(directory, arguments), "git {arguments:?} failed in {directory:?}");
}

/// A commit that writes `text` to `file`.
fn commit(repo: &Path, file: &str, text: &str) {
    std::fs::write(repo.join(file), text).unwrap();
    git(repo, &["add", file]);
    git(repo, &["commit", "--quiet", "-m", file]);
}

/// Makes HEAD of `repo` a symbolic ref to `refs/remotes/origin/main`. A git that refuses
/// that still has a HEAD file that can say it.
fn point_head_outside_the_branches(repo: &Path) {
    if !git_ended(repo, &["symbolic-ref", "HEAD", "refs/remotes/origin/main"]) {
        std::fs::write(repo.join(".git/HEAD"), "ref: refs/remotes/origin/main\n").unwrap();
    }
}

/// A folder of repositories: an `origin` with 2 commits on `main`.
struct World {
    dir: PathBuf,
}

impl World {
    fn new() -> Self {
        let dir = fixture().dir.join(unique("w"));
        std::fs::create_dir_all(&dir).unwrap();
        let world = Self { dir };
        let origin = world.dir.join("origin");
        std::fs::create_dir_all(&origin).unwrap();
        git(&origin, &["init", "--quiet", "--initial-branch=main"]);
        commit(&origin, "a.txt", "one\n");
        commit(&origin, "b.txt", "two\n");
        world
    }

    fn origin(&self) -> PathBuf {
        self.dir.join("origin")
    }

    /// A new clone of `source`, on `main` with the upstream `origin/main`. Each has a name
    /// of its own, which is the name of its log of git children.
    fn clone_of(&self, source: &Path) -> PathBuf {
        let name = unique("c");
        git(&self.dir, &["clone", "--quiet", &source.to_string_lossy(), &name]);
        self.dir.join(name)
    }

    /// A new clone of the origin.
    fn fresh_clone(&self) -> PathBuf {
        self.clone_of(&self.origin())
    }
}

/// The git children that ran in the directory `name` since [`forget_children`].
fn children(directory: &Path) -> Vec<String> {
    let name = directory.file_name().unwrap();
    let log = std::fs::read_to_string(fixture().dir.join("log").join(name)).unwrap_or_default();
    log.lines().map(str::to_owned).collect()
}

fn forget_children(directory: &Path) {
    let name = directory.file_name().unwrap();
    let _ = std::fs::remove_file(fixture().dir.join("log").join(name));
}

/// The children whose arguments have the word `word`.
fn with_word<'a>(children: &'a [String], word: &str) -> Vec<&'a String> {
    children.iter().filter(|line| line.split(' ').any(|argument| argument == word)).collect()
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    /// A client of a new daemon on a socket of its own.
    fn of_a_new_daemon() -> Self {
        let name = unique("d");
        let socket = fixture().dir.join(format!("{name}.sock"));
        let mux = Mux::new(
            format!("git-status-{}-{name}", std::process::id()),
            SurfaceOptions::default(),
        );
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        // The daemon lives as long as the test process.
        std::mem::forget(mux);
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// The whole reply to one `git.status` of `directory`.
    fn status(&mut self, directory: &Path) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": "git.status",
            "params": {"path": directory, "machine": "current", "session": "current"},
        });
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                return reply;
            }
        }
    }
}

/// What `git.status` must answer for `directory`: the branch headers of the status child of
/// git, the base branch and the main checkout, each read here with the handle that a
/// `git.diff` uses. This is the reply that the daemon gave when it ran that child itself.
fn reference(directory: &Path) -> Value {
    let repository = Repository::open(directory).expect("open the repository");
    let arguments = [
        "status",
        "--porcelain=v2",
        "--branch",
        "-z",
        "--untracked-files=no",
        "--ignore-submodules=all",
    ];
    let output = repository.run(&arguments, 256 * 1024).expect("the status child of git");
    let headers = parse::branch_headers(&output.stdout);
    let mut value = json!({
        "root": repository.root.to_string_lossy(),
        "detached": headers.branch.is_none(),
        "ahead": headers.ahead,
        "behind": headers.behind,
    });
    if let Some(branch) = headers.branch {
        value["branch"] = json!(branch);
    }
    if let Some(head) = headers.head {
        value["head"] = json!(head);
    }
    if let Some(upstream) = headers.upstream {
        value["upstream"] = json!(upstream);
    }
    if let Some((_, base)) = repository.base_branch() {
        value["base"] = json!(base);
    }
    if let Some(main) = repository.main_checkout() {
        value["worktree"] = json!({"main_root": main.to_string_lossy()});
    }
    value
}

/// The forms of one test: each is asked of the daemon and compared with [`reference`].
struct Forms {
    client: Client,
    different: Vec<String>,
    count: usize,
}

impl Forms {
    fn new() -> Self {
        Self { client: Client::of_a_new_daemon(), different: Vec::new(), count: 0 }
    }

    /// Asks the daemon for the status of `directory` and keeps the form when the reply is
    /// not the reference. Returns the daemon's result.
    fn check(&mut self, form: &str, directory: &Path) -> Value {
        let reply = self.client.status(directory);
        let expected = reference(directory);
        let result = reply["result"].clone();
        let equal = reply["ok"] == true && result == expected;
        eprintln!("git-status: {form}: {}: {reply}", if equal { "equal" } else { "DIFFERENT" });
        if !equal {
            self.different.push(format!("{form}:\n  daemon:    {reply}\n  reference: {expected}"));
        }
        self.count += 1;
        result
    }

    fn end(self) {
        eprintln!("git-status: {} forms, {} different", self.count, self.different.len());
        assert!(
            self.different.is_empty(),
            "git.status is not what the status child of git says:\n{}",
            self.different.join("\n")
        );
    }
}

/// A branch and its upstream: ahead, behind, both, equal, none, gone, and the names that the
/// short form of an upstream can be taken for.
#[test]
fn git_status_reply_is_what_the_status_child_says_of_a_branch_and_its_upstream() {
    let world = World::new();
    let mut forms = Forms::new();

    let repo = world.fresh_clone();
    let equal = forms.check("an upstream, equal", &repo);
    assert_eq!(
        (&equal["branch"], &equal["upstream"], &equal["ahead"], &equal["behind"]),
        (&json!("main"), &json!("origin/main"), &json!(0), &json!(0)),
        "{equal}"
    );
    assert_eq!((&equal["detached"], &equal["base"]), (&json!(false), &json!("origin/main")));
    assert_eq!(equal["root"], json!(repo.to_string_lossy()), "{equal}");
    assert!(equal.get("worktree").is_none(), "a main checkout has no main checkout: {equal}");

    commit(&repo, "c.txt", "mine\n");
    let ahead = forms.check("an upstream, ahead 1", &repo);
    assert_eq!((&ahead["ahead"], &ahead["behind"]), (&json!(1), &json!(0)), "{ahead}");

    let repo = world.fresh_clone();
    git(&repo, &["reset", "--quiet", "--hard", "HEAD~1"]);
    let behind = forms.check("an upstream, behind 1", &repo);
    assert_eq!((&behind["ahead"], &behind["behind"]), (&json!(0), &json!(1)), "{behind}");
    commit(&repo, "c.txt", "mine\n");
    commit(&repo, "d.txt", "mine\n");
    let both = forms.check("an upstream, ahead 2 and behind 1", &repo);
    assert_eq!((&both["ahead"], &both["behind"]), (&json!(2), &json!(1)), "{both}");
    git(&repo, &["config", "status.aheadBehind", "false"]);
    forms.check("ahead 2 and behind 1, status.aheadBehind = false", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["switch", "--quiet", "-c", "topic"]);
    let alone = forms.check("no upstream", &repo);
    assert!(alone.get("upstream").is_none(), "{alone}");

    let repo = world.fresh_clone();
    git(&repo, &["update-ref", "-d", "refs/remotes/origin/main"]);
    let gone = forms.check("an upstream whose ref is gone", &repo);
    assert_eq!(gone["upstream"], json!("origin/main"), "{gone}");

    let repo = world.fresh_clone();
    git(&repo, &["config", "branch.main.merge", "refs/heads/nosuch"]);
    forms.check("an upstream that the remote never had", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["config", "branch.main.remote", "nosuch"]);
    forms.check("an upstream of a remote that is not there", &repo);

    // The short name of an upstream that another ref can be taken for.
    let repo = world.fresh_clone();
    git(&repo, &["branch", "origin", "main"]);
    git(&repo, &["switch", "--quiet", "-c", "local"]);
    git(&repo, &["config", "branch.local.remote", "."]);
    git(&repo, &["config", "branch.local.merge", "refs/heads/origin"]);
    forms.check("an upstream that is a local branch with the name of a remote", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["branch", "origin/main", "main"]);
    forms.check("a local branch with the name of the upstream", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["tag", "main"]);
    forms.check("a tag with the name of the branch", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["switch", "--quiet", "-c", "feat/a-b_c.d"]);
    git(&repo, &["push", "--quiet", "--set-upstream", "origin", "feat/a-b_c.d"]);
    let slash = forms.check("a branch with a slash in its name and its upstream", &repo);
    assert_eq!(slash["upstream"], json!("origin/feat/a-b_c.d"), "{slash}");

    let repo = world.fresh_clone();
    git(&repo, &["switch", "--quiet", "-c", "chat"]);
    git(&repo, &["branch", "topic", "main"]);
    git(&repo, &["config", "branch.chat.cmuxBase", "topic"]);
    let recorded = forms.check("a branch with a recorded base", &repo);
    assert_eq!(recorded["base"], json!("topic"), "{recorded}");

    forms.end();
}

/// A HEAD that is on no branch, a branch with no commit, a HEAD that names no branch, a
/// linked worktree, a folder below the root, and a work tree with changes.
#[test]
fn git_status_reply_is_what_the_status_child_says_of_each_form_of_head() {
    let world = World::new();
    let mut forms = Forms::new();

    let repo = world.fresh_clone();
    git(&repo, &["checkout", "--quiet", "--detach"]);
    let detached = forms.check("a detached HEAD", &repo);
    assert_eq!(detached["detached"], json!(true), "{detached}");
    assert!(detached.get("branch").is_none() && detached.get("head").is_some(), "{detached}");

    let repo = world.fresh_clone();
    git(&repo, &["tag", "-a", "-m", "v1", "v1"]);
    git(&repo, &["checkout", "--quiet", "v1"]);
    forms.check("a detached HEAD at a tag", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["checkout", "--quiet", "origin/main"]);
    forms.check("a detached HEAD at a remote branch", &repo);

    // For a detached HEAD the status child of git prints the upstream of the branch that
    // has the name of the place that HEAD was detached at, when there is one.
    let repo = world.fresh_clone();
    git(&repo, &["tag", "v1", "HEAD~1"]);
    git(&repo, &["branch", "v1", "main"]);
    git(&repo, &["config", "branch.v1.remote", "origin"]);
    git(&repo, &["config", "branch.v1.merge", "refs/heads/main"]);
    git(&repo, &["checkout", "--quiet", "refs/tags/v1"]);
    forms.check("a detached HEAD at a tag, a branch of that name has an upstream", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["branch", "origin/main", "HEAD~1"]);
    git(&repo, &["config", "branch.origin/main.remote", "origin"]);
    git(&repo, &["config", "branch.origin/main.merge", "refs/heads/main"]);
    git(&repo, &["checkout", "--quiet", "refs/remotes/origin/main"]);
    forms.check("a detached HEAD at a remote branch, a local branch of that name", &repo);

    let repo = world.fresh_clone();
    commit(&repo, "a.txt", "main\n");
    git(&repo, &["switch", "--quiet", "-c", "moved", "HEAD~1"]);
    commit(&repo, "a.txt", "moved\n");
    assert!(!git_ended(&repo, &["rebase", "main"]), "the rebase did not stop");
    let rebase = forms.check("a rebase that stopped", &repo);
    assert_eq!(rebase["detached"], json!(true), "{rebase}");

    let repo = world.dir.join(unique("c"));
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet", "--initial-branch=main"]);
    let unborn = forms.check("no commit yet", &repo);
    assert_eq!(unborn["branch"], json!("main"), "{unborn}");
    assert!(unborn.get("head").is_none(), "{unborn}");

    let empty = world.dir.join(unique("empty"));
    std::fs::create_dir_all(&empty).unwrap();
    git(&empty, &["init", "--quiet", "--initial-branch=main"]);
    let repo = world.clone_of(&empty);
    forms.check("no commit yet, the clone of an empty repository", &repo);

    let repo = world.fresh_clone();
    git(&repo, &["switch", "--quiet", "--orphan", "orphan"]);
    forms.check("an orphan branch", &repo);
    git(&repo, &["config", "branch.orphan.remote", "origin"]);
    git(&repo, &["config", "branch.orphan.merge", "refs/heads/main"]);
    let orphan = forms.check("an orphan branch with an upstream", &repo);
    assert_eq!(orphan["upstream"], json!("origin/main"), "{orphan}");

    let repo = world.fresh_clone();
    point_head_outside_the_branches(&repo);
    forms.check("a HEAD that names a ref outside refs/heads", &repo);

    let repo = world.fresh_clone();
    let linked = world.dir.join(unique("c"));
    git(&repo, &["worktree", "add", "--quiet", "-b", "linked", &linked.to_string_lossy(), "main"]);
    let worktree = forms.check("a linked worktree", &linked);
    assert_eq!(worktree["worktree"]["main_root"], json!(repo.to_string_lossy()), "{worktree}");
    assert_eq!(worktree["branch"], json!("linked"), "{worktree}");
    git(&linked, &["checkout", "--quiet", "--detach"]);
    forms.check("a linked worktree with a detached HEAD", &linked);

    let bare = world.dir.join(unique("bare"));
    git(&world.dir, &["clone", "--quiet", "--bare", "origin", &bare.to_string_lossy()]);
    let of_bare = world.dir.join(unique("c"));
    git(&bare, &["worktree", "add", "--quiet", "-b", "of-bare", &of_bare.to_string_lossy()]);
    let no_main = forms.check("a linked worktree of a bare repository", &of_bare);
    assert!(no_main.get("worktree").is_none(), "{no_main}");

    let repo = world.fresh_clone();
    std::fs::create_dir_all(repo.join("deep/er")).unwrap();
    let below = forms.check("a folder below the root", &repo.join("deep/er"));
    assert_eq!(below["root"], json!(repo.to_string_lossy()), "{below}");

    let repo = world.fresh_clone();
    std::fs::write(repo.join("a.txt"), "changed\n").unwrap();
    std::fs::write(repo.join("b.txt"), "staged\n").unwrap();
    git(&repo, &["add", "b.txt"]);
    std::fs::write(repo.join("new.txt"), "untracked\n").unwrap();
    forms.check("a changed file, a staged file and an untracked file", &repo);

    forms.end();
}

/// A branch whose name ends in a Unicode space, and one whose name is not UTF-8, each beside
/// a second branch that has the name that a loose read of the first gives. The reply is of
/// the branch that HEAD is on, never of the second one.
#[test]
fn git_status_reply_is_of_the_branch_that_head_is_on_when_a_second_name_is_near() {
    let world = World::new();
    let mut forms = Forms::new();

    // U+00A0 is white space for Rust, and 2 bytes of a name for git.
    let repo = world.fresh_clone();
    git(&repo, &["branch", "foo", "HEAD~1"]);
    git(&repo, &["switch", "--quiet", "-c", "foo\u{a0}"]);
    let spaced = forms.check("a name that ends in U+00A0, beside the name with no such end", &repo);

    // On a file system that ignores case, git resolves HEAD through the file of `FOO`, and
    // the list of the refs has `foo` from the packed refs, at another commit.
    let repo = world.fresh_clone();
    git(&repo, &["branch", "foo", "HEAD~1"]);
    git(&repo, &["pack-refs", "--all"]);
    git(&repo, &["branch", "FOO"]);
    git(&repo, &["symbolic-ref", "HEAD", "refs/heads/foo"]);
    forms.check("a packed branch beside a loose one whose name differs in case only", &repo);

    // Only a file system that takes each byte can hold a ref that is not UTF-8.
    #[cfg(target_os = "linux")]
    let lossy = {
        use std::os::unix::ffi::OsStrExt;
        let repo = world.fresh_clone();
        git(&repo, &["branch", "b\u{fffd}d", "HEAD~1"]);
        let name = OsStr::from_bytes(b"b\xffd");
        assert!(git_ended(&repo, &[OsStr::new("branch"), name]), "no branch with a byte 0xff");
        let target = OsStr::from_bytes(b"refs/heads/b\xffd");
        let arguments = [OsStr::new("symbolic-ref"), OsStr::new("HEAD"), target];
        assert!(git_ended(&repo, &arguments), "HEAD does not go to the branch with a byte 0xff");
        forms.check("a branch name that is not UTF-8, beside its lossy name", &repo)
    };

    forms.end();
    assert_eq!(spaced["branch"], json!("foo\u{a0}"), "{spaced}");
    #[cfg(target_os = "linux")]
    assert_eq!(lossy["branch"], json!("b\u{fffd}d"), "{lossy}");
}

/// A clone with HEAD on a branch whose name is not UTF-8. Only a file system that takes
/// each byte can hold such a ref, so there is none on the others.
fn clone_on_a_name_that_is_not_utf8(world: &World) -> Option<PathBuf> {
    #[cfg(target_os = "linux")]
    {
        use std::os::unix::ffi::OsStrExt;
        let repo = world.fresh_clone();
        let name = OsStr::from_bytes(b"b\xffd");
        assert!(git_ended(&repo, &[OsStr::new("branch"), name]), "no branch with a byte 0xff");
        let target = OsStr::from_bytes(b"refs/heads/b\xffd");
        let arguments = [OsStr::new("symbolic-ref"), OsStr::new("HEAD"), target];
        assert!(git_ended(&repo, &arguments), "HEAD does not go to the branch with a byte 0xff");
        Some(repo)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = world;
        None
    }
}

/// A folder that is in no repository, and a bare repository: the error is the one that the
/// first git child gives, as before.
#[test]
fn git_status_refuses_a_folder_with_no_work_tree() {
    let world = World::new();
    let mut client = Client::of_a_new_daemon();

    let plain = world.dir.join(unique("plain"));
    std::fs::create_dir_all(&plain).unwrap();
    // The fixture's folder is in no repository when the temporary folder is in none.
    let reply = client.status(&plain);
    eprintln!("git-status: a folder in no repository: {reply}");
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "operation.failed", "{reply}");
    assert_eq!(reply["error"]["details"]["extra"]["code"], "not_a_repository", "{reply}");

    let bare = world.dir.join(unique("bare"));
    git(&world.dir, &["clone", "--quiet", "--bare", "origin", &bare.to_string_lossy()]);
    let reply = client.status(&bare);
    eprintln!("git-status: a bare repository: {reply}");
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["details"]["extra"]["code"], "git_failed", "{reply}");
}

/// The read of a branch that has a commit starts no `git status` child and looks for no
/// filter driver. A `git status` child reads the index and looks at each tracked file: in a
/// checkout of 50 000 files that is the largest part of the request, and it grows when
/// files have a new time. The filter drivers are looked for only before a child that can
/// read the content of a file.
#[test]
fn git_status_of_a_branch_runs_no_child_that_reads_the_work_tree() {
    let world = World::new();
    let mut client = Client::of_a_new_daemon();
    let repo = world.fresh_clone();
    std::fs::write(repo.join("a.txt"), "changed\n").unwrap();

    forget_children(&repo);
    let reply = client.status(&repo);
    let ran = children(&repo);
    eprintln!(
        "git-status: the {} git children of one git.status of a branch:\n  {}",
        ran.len(),
        ran.join("\n  ")
    );
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(!ran.is_empty(), "the stand-in git saw no child of the daemon");
    let status = with_word(&ran, "status");
    assert!(status.is_empty(), "a `git status` child read the work tree: {status:?}");
    let filters = with_word(&ran, "--get-regexp");
    assert!(filters.is_empty(), "the filter drivers were looked for: {filters:?}");
}

/// The forms that the refs do not answer keep the status child of git, limited to the path
/// `.git`, which is never a tracked file: git then looks at no tracked file. They are a
/// branch with no commit (only that child prints its upstream), a HEAD that names no branch,
/// and a detached HEAD (that child prints the upstream of the branch with the name of the
/// place that HEAD was detached at). A branch name that is not UTF-8 is one more, where a
/// file system can hold it. It is a child that can read content, so the filter drivers are
/// looked for before it.
#[test]
fn git_status_of_a_head_that_is_no_branch_with_a_commit_limits_the_status_child_to_no_file() {
    let world = World::new();
    let mut client = Client::of_a_new_daemon();
    let orphan = world.fresh_clone();
    git(&orphan, &["switch", "--quiet", "--orphan", "orphan"]);
    git(&orphan, &["checkout", "--quiet", "main", "--", "a.txt", "b.txt"]);
    std::fs::write(orphan.join("a.txt"), "changed\n").unwrap();
    let outside = world.fresh_clone();
    point_head_outside_the_branches(&outside);
    std::fs::write(outside.join("a.txt"), "changed\n").unwrap();
    let detached = world.fresh_clone();
    git(&detached, &["checkout", "--quiet", "--detach"]);
    std::fs::write(detached.join("a.txt"), "changed\n").unwrap();

    let forms = [
        Some(("a branch with no commit", orphan)),
        Some(("a HEAD outside refs/heads", outside)),
        Some(("a detached HEAD", detached)),
        clone_on_a_name_that_is_not_utf8(&world).map(|named| {
            std::fs::write(named.join("a.txt"), "changed\n").unwrap();
            ("a branch name that is not UTF-8", named)
        }),
    ];
    for (form, directory) in forms.iter().flatten() {
        forget_children(directory);
        let reply = client.status(directory);
        let ran = children(directory);
        eprintln!(
            "git-status: the {} git children of one git.status of {form}:\n  {}",
            ran.len(),
            ran.join("\n  ")
        );
        assert_eq!(reply["ok"], true, "{reply}");
        let status = with_word(&ran, "status");
        assert_eq!(status.len(), 1, "{form}: one `git status` child: {ran:?}");
        assert!(
            status[0].ends_with(" -- .git"),
            "{form}: the `git status` child is not limited to the path .git: {}",
            status[0]
        );
        let filters = ran.iter().position(|line| line.contains("--get-regexp"));
        let read = ran.iter().position(|line| line == status[0]);
        assert!(
            filters.is_some() && filters < read,
            "{form}: the filter drivers were not looked for before the status child: {ran:?}"
        );
    }
}
