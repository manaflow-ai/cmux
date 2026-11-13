#![cfg(unix)]
//! The daemon's own reads of a work tree, over a real session socket: a file is read only
//! through real folders of the work tree, never through a link.
//!
//! - `git.worktree.setup` gives the recipe of `.worktreeinclude` and `.cmux/worktree.toml`. A
//!   link at any part of one of these paths is refused with one problem text, and no text of
//!   the file behind the link is in the reply.
//!   Its `run` gives the state and the output of a worktree's setup from two files of the
//!   worktree's git folder: a link in the place of one of them is not read. The same holds
//!   for the setup's lock there, and for the ports file and its lock in the repository's
//!   shared git folder: no port and no lock state come from a link, and no file is made
//!   through one. A named pipe in the place of one of these files is not read either.
//! - `git.diff` counts the lines of each untracked file that git lists. It counts no line of
//!   a file below a link, also when the link took a folder's place after git's listing.
//! - `git.files.search` and `git.files.list` say of a listed name if it is a folder (a
//!   submodule). A link is a file whatever its target is, also when git lists tracked paths
//!   below its name. A name below a link is no folder and no search result, also when the
//!   link took a folder's place after git's listing. git gives the names, and the daemon
//!   itself looks if a listed path is there, through real folders only. A path that it cannot
//!   reach so is no match in the search's count, no result, and gives no name in the list:
//!   a path below a link, with and without a file of its name behind the link, also when the
//!   folder that is searched or listed became the link; a path below a folder that cannot be
//!   read; a path with more than 128 folders above its name.
//!
//! The git on `PATH` is a stand-in that is the real git. After a child that lists the
//! untracked files (`ls-files --others`) it runs `.git/after-untracked-listing` of the work
//! tree that holds its working directory, and after the child that lists the paths of the two
//! file operations (`ls-files -z --cached --others`) it runs `.git/after-files-listing`, when
//! a test put a program there: a change of the work tree between git's listing and the
//! daemon's reads.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::fs::OpenOptions;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::JoinHandle;
use std::time::Duration;

/// What the daemon says of a recipe file that it did not read because of a link.
const LINK_PROBLEM: &str = "not read: the file or a folder above it is a symbolic link";

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
        let dir = std::env::temp_dir().join(format!("grealf-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let dir = std::fs::canonicalize(&dir).unwrap();
        let real = real_git();
        let script = format!(
            "#!/bin/sh\n\
             hook=\n\
             case \" $* \" in\n\
             *\" ls-files --others \"*) hook=after-untracked-listing ;;\n\
             *\" ls-files -z --cached --others \"*) hook=after-files-listing ;;\n\
             esac\n\
             if [ -n \"$hook\" ]; then\n\
             top=$PWD\n\
             while [ \"$top\" != / ] && [ ! -e \"$top/.git\" ]; do top=$(dirname \"$top\"); done\n\
             if [ -x \"$top/.git/$hook\" ]; then\n\
             \"{real}\" \"$@\"\n\
             code=$?\n\
             \"$top/.git/$hook\" >/dev/null 2>&1\n\
             exit $code\n\
             fi\n\
             fi\n\
             exec \"{real}\" \"$@\"\n",
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

/// Runs the real git in `directory`, apart from the host's git config.
fn git(directory: &Path, arguments: &[&str]) {
    let ended = Command::new(&fixture().real)
        .arg("-C")
        .arg(directory)
        .args(["-c", "maintenance.auto=false", "-c", "user.name=t", "-c", "user.email=t@e.test"])
        .args(arguments)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(ended, "git {arguments:?} failed in {directory:?}");
}

/// A new repository on `main` with one commit of `a.txt`.
fn fresh_repository() -> PathBuf {
    let repo = fixture().dir.join(unique("r"));
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(repo.join("a.txt"), "one\n").unwrap();
    git(&repo, &["add", "a.txt"]);
    git(&repo, &["commit", "--quiet", "-m", "a.txt"]);
    repo
}

/// A new folder that is not in a repository, with one file.
fn outside_folder(file: &str, text: &[u8]) -> PathBuf {
    let folder = fixture().dir.join(unique("o"));
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join(file), text).unwrap();
    folder
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
            format!("git-real-folders-{}-{name}", std::process::id()),
            SurfaceOptions::default(),
        );
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        // The daemon lives as long as the test process.
        std::mem::forget(mux);
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// The result of one read `operation` of `directory`.
    fn read(&mut self, operation: &str, directory: &Path) -> Value {
        self.read_with(operation, directory, &[])
    }

    /// The result of one read `operation` of `directory`, with each parameter of `more`.
    fn read_with(&mut self, operation: &str, directory: &Path, more: &[(&str, &str)]) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        let mut params = json!({"path": directory, "machine": "current", "session": "current"});
        for (name, value) in more {
            params[*name] = json!(value);
        }
        let request = json!({
            "protocol": "cmux.protocol/2",
            "type": "request",
            "id": id,
            "operation": operation,
            "params": params,
        });
        writeln!(self.stream.get_mut(), "{request}").unwrap();
        loop {
            let mut line = String::new();
            assert_ne!(self.stream.read_line(&mut line).unwrap(), 0, "closed before {id}");
            let reply: Value = serde_json::from_str(&line).unwrap();
            if reply["id"] == id {
                assert_eq!(reply["ok"], true, "{operation} failed: {reply}");
                return reply["result"].clone();
            }
        }
    }

    /// The recipe that `git.worktree.setup` gives for `repo`.
    fn recipe(&mut self, repo: &Path) -> Value {
        self.read("git.worktree.setup", repo)["recipe"].clone()
    }

    /// The state and the output of the setup that `git.worktree.setup` gives for `worktree`.
    fn setup_run(&mut self, worktree: &Path) -> Value {
        self.read("git.worktree.setup", worktree)["run"].clone()
    }

    /// What `git.diff` says of the file `path` of `repo`.
    fn changed_file(&mut self, repo: &Path, path: &str) -> Value {
        let result = self.read_with("git.diff", repo, &[("scope", "uncommitted")]);
        let files = result["files"].as_array().unwrap_or_else(|| panic!("no files in {result}"));
        files
            .iter()
            .find(|file| file["path"] == path)
            .unwrap_or_else(|| panic!("no {path} in {result}"))
            .clone()
    }

    /// The kind that `git.files.list` gives for `name` in `folder`.
    fn listed_kind(&mut self, folder: &Path, name: &str) -> Value {
        let result = self.read("git.files.list", folder);
        let entries =
            result["entries"].as_array().unwrap_or_else(|| panic!("no entries in {result}"));
        let entry = entries
            .iter()
            .find(|entry| entry["name"] == name)
            .unwrap_or_else(|| panic!("no {name} in {result}"));
        entry["kind"].clone()
    }

    /// What `git.files.search` says of `folder` for `query`.
    fn search(&mut self, folder: &Path, query: &str) -> Value {
        self.read_with("git.files.search", folder, &[("query", query)])
    }

    /// The names that `git.files.list` gives for `folder`, in its order.
    fn listed_names(&mut self, folder: &Path) -> Vec<String> {
        let result = self.read("git.files.list", folder);
        let entries =
            result["entries"].as_array().unwrap_or_else(|| panic!("no entries in {result}"));
        entries.iter().map(|entry| entry["name"].as_str().unwrap_or_default().to_owned()).collect()
    }

    /// The paths that `git.files.search` finds in `folder` for `query`, sorted.
    fn found(&mut self, folder: &Path, query: &str) -> Vec<String> {
        let result = self.search(folder, query);
        let results =
            result["results"].as_array().unwrap_or_else(|| panic!("no results in {result}"));
        let mut paths: Vec<String> = results
            .iter()
            .map(|entry| entry["path"].as_str().unwrap_or_default().to_owned())
            .collect();
        paths.sort();
        paths
    }
}

/// Puts a program at the hook `name` of `repo` that makes the folder `dir` of `repo` a link
/// to `outside`: the stand-in git runs it after the listing that the hook names.
fn swap_after(repo: &Path, name: &str, outside: &Path) -> PathBuf {
    let hook = repo.join(".git").join(name);
    let script = format!(
        "#!/bin/sh\nmv '{dir}' '{away}' && ln -s '{outside}' '{dir}'\n",
        dir = repo.join("dir").display(),
        away = repo.join(".git").join("dir-away").display(),
        outside = outside.display(),
    );
    std::fs::write(&hook, script).unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    hook
}

/// Takes the hook away, and fails when its program did not make `dir` of `repo` a link.
fn swapped(repo: &Path, hook: &Path) {
    std::fs::remove_file(hook).unwrap();
    let dir = std::fs::symlink_metadata(repo.join("dir")).unwrap();
    assert!(dir.file_type().is_symlink(), "the stand-in git did not put the link there");
}

/// The problem that names `file`, a recipe file that was not read because of a link.
fn link_problem(file: &str) -> String {
    format!("{file}: {LINK_PROBLEM}")
}

#[test]
fn git_worktree_setup_reads_the_recipe_files_of_real_folders() {
    let repo = fresh_repository();
    std::fs::create_dir_all(repo.join(".cmux")).unwrap();
    std::fs::write(repo.join(".worktreeinclude"), ".env\n").unwrap();
    std::fs::write(repo.join(".cmux/worktree.toml"), "run = \"inside-run\"\n").unwrap();
    let recipe = Client::of_a_new_daemon().recipe(&repo);
    assert_eq!(recipe["run"], "inside-run", "{recipe}");
    assert_eq!(recipe["include"], json!([".env"]), "{recipe}");
    assert_eq!(recipe["files"], json!([".worktreeinclude", ".cmux/worktree.toml"]), "{recipe}");
    assert_eq!(recipe["problems"], Value::Null, "{recipe}");
}

/// The recipe of a repository whose `.cmux` is a link to a folder outside it, where
/// `worktree.toml` has `outside_text`.
fn recipe_with_a_link_in_the_place_of_the_cmux_folder(outside_text: &[u8]) -> Value {
    let repo = fresh_repository();
    let outside = outside_folder("worktree.toml", outside_text);
    std::os::unix::fs::symlink(&outside, repo.join(".cmux")).unwrap();
    Client::of_a_new_daemon().recipe(&repo)
}

#[test]
fn git_worktree_setup_reads_no_recipe_file_below_a_link_in_the_place_of_the_cmux_folder() {
    let recipe = recipe_with_a_link_in_the_place_of_the_cmux_folder(
        b"run = \"outside-run\"\nteardown = \"outside-teardown\"\ninclude = [\"outside-include\"]\n",
    );
    assert!(!recipe.to_string().contains("outside"), "text of a file behind a link: {recipe}");
    assert_eq!(recipe["files"], json!([]), "{recipe}");
    assert_eq!(recipe["problems"], json!([link_problem(".cmux/worktree.toml")]), "{recipe}");
}

#[test]
fn git_worktree_setup_names_no_text_of_a_file_that_is_not_a_recipe_below_such_a_link() {
    // A file that is not TOML: what the parser says of it has the file's text.
    let recipe = recipe_with_a_link_in_the_place_of_the_cmux_folder(b"outside-word = = 1\n");
    assert!(!recipe.to_string().contains("outside"), "text of a file behind a link: {recipe}");
    assert_eq!(recipe["problems"], json!([link_problem(".cmux/worktree.toml")]), "{recipe}");
}

#[test]
fn git_worktree_setup_refuses_a_recipe_file_that_is_a_link_with_one_problem_text() {
    let repo = fresh_repository();
    let outside = outside_folder("worktree.toml", b"run = \"outside-run\"\n");
    std::fs::write(outside.join("include"), "outside-include\n").unwrap();
    std::fs::create_dir_all(repo.join(".cmux")).unwrap();
    std::os::unix::fs::symlink(outside.join("worktree.toml"), repo.join(".cmux/worktree.toml"))
        .unwrap();
    std::os::unix::fs::symlink(outside.join("include"), repo.join(".worktreeinclude")).unwrap();
    let recipe = Client::of_a_new_daemon().recipe(&repo);
    assert!(!recipe.to_string().contains("outside"), "text of a file behind a link: {recipe}");
    assert_eq!(recipe["files"], json!([]), "{recipe}");
    assert_eq!(
        recipe["problems"],
        json!([link_problem(".worktreeinclude"), link_problem(".cmux/worktree.toml")]),
        "{recipe}"
    );
}

#[test]
fn git_diff_counts_no_line_through_an_untracked_link() {
    let repo = fresh_repository();
    let outside = outside_folder("new.txt", b"outside one\noutside two\noutside three\n");
    std::os::unix::fs::symlink(outside.join("new.txt"), repo.join("link.txt")).unwrap();
    std::os::unix::fs::symlink(&outside, repo.join("dir")).unwrap();
    let mut client = Client::of_a_new_daemon();
    for path in ["link.txt", "dir"] {
        let file = client.changed_file(&repo, path);
        assert_eq!(file["status"], "untracked", "{file}");
        assert_eq!(file["additions"], 0, "{path}: lines of a file behind a link: {file}");
        assert_eq!(file["binary"], Value::Null, "{path}: {file}");
    }
}

/// What `git.diff` says of the untracked `dir/new.txt` when `dir` becomes a link to a folder
/// outside the repository, whose `new.txt` has `outside_text`, after git printed
/// `dir/new.txt` in its list and before the daemon looks at the file.
fn file_below_a_folder_that_became_a_link(outside_text: &[u8]) -> Value {
    let repo = fresh_repository();
    std::fs::create_dir_all(repo.join("dir")).unwrap();
    std::fs::write(repo.join("dir/new.txt"), "inside\n").unwrap();
    let outside = outside_folder("new.txt", outside_text);
    let mut client = Client::of_a_new_daemon();
    let before = client.changed_file(&repo, "dir/new.txt");
    assert_eq!(before["additions"], 1, "the untracked file of the work tree: {before}");

    let hook = swap_after(&repo, "after-untracked-listing", &outside);
    let during = client.changed_file(&repo, "dir/new.txt");
    swapped(&repo, &hook);
    during
}

#[test]
fn git_diff_counts_no_line_below_a_folder_that_became_a_link_after_the_listing() {
    let file = file_below_a_folder_that_became_a_link(b"outside one\noutside two\noutside three\n");
    assert_eq!(file["status"], "untracked", "{file}");
    assert_eq!(file["additions"], 0, "lines of a file that is not in the work tree: {file}");
}

#[test]
fn git_diff_names_no_binary_file_below_a_folder_that_became_a_link_after_the_listing() {
    let file = file_below_a_folder_that_became_a_link(b"outside\0one\n");
    assert_eq!(file["status"], "untracked", "{file}");
    assert_eq!(file["binary"], Value::Null, "a file that is not in the work tree: {file}");
}

/// A linked worktree of a new repository, and the worktree's own git folder.
fn linked_worktree() -> (PathBuf, PathBuf) {
    let repo = fresh_repository();
    let name = unique("t");
    let worktree = fixture().dir.join(&name);
    git(&repo, &["worktree", "add", "--quiet", "--detach", &worktree.to_string_lossy()]);
    let git_dir = repo.join(".git").join("worktrees").join(&name);
    assert!(git_dir.is_dir(), "no git folder of the worktree at {git_dir:?}");
    (worktree, git_dir)
}

/// The status file of a setup that ended.
const ENDED: &str = r#"{"state":"succeeded","started_ms":1,"finished_ms":2}"#;

#[test]
fn git_worktree_setup_gives_the_state_and_the_output_of_the_files_in_the_git_folder() {
    let (worktree, git_dir) = linked_worktree();
    std::fs::write(git_dir.join("cmux-setup.json"), ENDED).unwrap();
    std::fs::write(git_dir.join("cmux-setup.log"), "inside line\n").unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["state"], "succeeded", "{run}");
    assert_eq!(run["output"], "inside line\n", "{run}");
}

#[test]
fn git_worktree_setup_gives_no_output_of_a_link_in_the_place_of_the_setup_log() {
    let (worktree, git_dir) = linked_worktree();
    let outside = outside_folder("log", b"outside line\n");
    std::fs::write(git_dir.join("cmux-setup.json"), ENDED).unwrap();
    std::os::unix::fs::symlink(outside.join("log"), git_dir.join("cmux-setup.log")).unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["state"], "succeeded", "{run}");
    assert_eq!(run["output"], "", "text of a file behind a link: {run}");
    assert_eq!(run["output_end"], "0", "the size of a file behind a link: {run}");
}

#[test]
fn git_worktree_setup_gives_no_state_of_a_link_in_the_place_of_the_setup_status() {
    let (worktree, git_dir) = linked_worktree();
    let outside = outside_folder("status", ENDED.as_bytes());
    std::os::unix::fs::symlink(outside.join("status"), git_dir.join("cmux-setup.json")).unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["state"], "none", "the state of a file behind a link: {run}");
}

/// Makes a named pipe at `path`.
fn named_pipe(path: &Path) {
    let made = Command::new("mkfifo").arg(path).status().expect("mkfifo runs");
    assert!(made.success(), "mkfifo {}", path.display());
}

/// Gives `text` to the first reader that opens the named pipe `path`, then closes the pipe:
/// a reader that waits for the pipe's other end gets the text and its end.
fn writer_of(path: &Path, text: String) -> JoinHandle<()> {
    let path = path.to_path_buf();
    std::thread::spawn(move || {
        // The open waits for a reader. A reader that is gone before the write gets nothing.
        if let Ok(mut pipe) = OpenOptions::new().write(true).open(path) {
            let _ = pipe.write_all(text.as_bytes());
        }
    })
}

/// Lets the writer of the named pipe `path` come to its end, also when nobody read the pipe.
fn ended(writer: JoinHandle<()>, path: &Path) {
    // An open for a read that does not wait: the writer's open has its reader now.
    let reader = OpenOptions::new().read(true).custom_flags(libc::O_NONBLOCK).open(path).unwrap();
    writer.join().unwrap();
    drop(reader);
}

#[test]
fn git_worktree_setup_reads_no_recipe_file_that_is_a_named_pipe() {
    let repo = fresh_repository();
    std::fs::create_dir(repo.join(".cmux")).unwrap();
    named_pipe(&repo.join(".cmux/worktree.toml"));
    let recipe = Client::of_a_new_daemon().recipe(&repo);
    assert_eq!(recipe["problems"], json!([".cmux/worktree.toml: not a regular file"]), "{recipe}");
}

#[test]
fn git_worktree_setup_gives_no_state_of_a_named_pipe_in_the_place_of_the_setup_status() {
    let (worktree, git_dir) = linked_worktree();
    let status = git_dir.join("cmux-setup.json");
    named_pipe(&status);
    let writer = writer_of(&status, ENDED.to_string());
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    ended(writer, &status);
    assert_eq!(run["state"], "none", "the state of a file that is not a regular file: {run}");
}

/// The shared git folder of the repository that has the worktree's git folder `git_dir`.
fn shared_git_folder(git_dir: &Path) -> PathBuf {
    git_dir.parent().and_then(Path::parent).unwrap().to_path_buf()
}

/// The text of a ports file that gives `port` to `worktree`.
fn ports_text(worktree: &Path, port: u16) -> String {
    let mut ports = serde_json::Map::new();
    let folder = std::fs::canonicalize(worktree).unwrap();
    ports.insert(folder.to_string_lossy().into_owned(), json!(port));
    Value::Object(ports).to_string()
}

#[test]
fn git_worktree_setup_gives_the_port_of_the_ports_file_in_the_shared_git_folder() {
    let (worktree, git_dir) = linked_worktree();
    let ports = shared_git_folder(&git_dir).join("cmux-worktree-ports.json");
    std::fs::write(ports, ports_text(&worktree, 4310)).unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["port"], 4310, "{run}");
}

#[test]
fn git_worktree_setup_gives_no_port_of_a_link_in_the_place_of_the_ports_file() {
    let (worktree, git_dir) = linked_worktree();
    let outside = outside_folder("ports", ports_text(&worktree, 4310).as_bytes());
    let ports = shared_git_folder(&git_dir).join("cmux-worktree-ports.json");
    std::os::unix::fs::symlink(outside.join("ports"), ports).unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["port"], Value::Null, "a number of a file behind a link: {run}");
}

#[test]
fn git_worktree_setup_gives_no_port_of_a_named_pipe_in_the_place_of_the_ports_file() {
    let (worktree, git_dir) = linked_worktree();
    let ports = shared_git_folder(&git_dir).join("cmux-worktree-ports.json");
    named_pipe(&ports);
    let writer = writer_of(&ports, ports_text(&worktree, 4310));
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    ended(writer, &ports);
    assert_eq!(run["port"], Value::Null, "a number of a file that is not a regular file: {run}");
}

#[test]
fn git_worktree_setup_makes_no_file_through_a_link_in_the_place_of_the_ports_lock() {
    let (worktree, git_dir) = linked_worktree();
    let outside = outside_folder("other", b"outside\n");
    let lock = shared_git_folder(&git_dir).join("cmux-worktree-ports.lock");
    std::os::unix::fs::symlink(outside.join("made"), lock).unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["state"], "none", "{run}");
    let made = std::fs::symlink_metadata(outside.join("made")).is_ok();
    assert!(!made, "the read made a file where the link points");
}

#[test]
fn git_worktree_setup_waits_for_no_lock_of_a_named_pipe_in_the_place_of_the_ports_lock() {
    let (worktree, git_dir) = linked_worktree();
    let shared = shared_git_folder(&git_dir);
    std::fs::write(shared.join("cmux-worktree-ports.json"), ports_text(&worktree, 4310)).unwrap();
    let lock = shared.join("cmux-worktree-ports.lock");
    named_pipe(&lock);
    // The two ends of the pipe are open here, so no open of it waits. Where a pipe takes a
    // lock, this one is held to the end of the test: a read that asks for it does not end.
    let holder = OpenOptions::new().read(true).write(true).open(&lock).unwrap();
    let locked = holder.lock().is_ok();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["port"], 4310, "the port with a pipe as the lock (locked: {locked}): {run}");
}

/// The status file of a setup that runs.
const RUNS: &str = r#"{"state":"running","started_ms":1}"#;

#[test]
fn git_worktree_setup_says_running_while_the_setup_lock_in_the_git_folder_is_held() {
    let (worktree, git_dir) = linked_worktree();
    std::fs::write(git_dir.join("cmux-setup.json"), RUNS).unwrap();
    std::fs::write(git_dir.join("cmux-setup.lock"), "").unwrap();
    let mut client = Client::of_a_new_daemon();
    let free = client.setup_run(&worktree);
    assert_eq!(free["state"], "interrupted", "nobody holds the lock: {free}");

    let holder = std::fs::File::open(git_dir.join("cmux-setup.lock")).unwrap();
    holder.lock().unwrap();
    let held = client.setup_run(&worktree);
    assert_eq!(held["state"], "running", "a run holds the lock: {held}");
}

#[test]
fn git_worktree_setup_takes_no_lock_state_of_a_link_in_the_place_of_the_setup_lock() {
    let (worktree, git_dir) = linked_worktree();
    let outside = outside_folder("lock", b"");
    std::fs::write(git_dir.join("cmux-setup.json"), RUNS).unwrap();
    std::os::unix::fs::symlink(outside.join("lock"), git_dir.join("cmux-setup.lock")).unwrap();
    // The file behind the link is locked: its state is not the setup's.
    let holder = std::fs::File::open(outside.join("lock")).unwrap();
    holder.lock().unwrap();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["state"], "interrupted", "the lock state of a file behind a link: {run}");
}

#[test]
fn git_worktree_setup_takes_no_lock_state_of_a_named_pipe_in_the_place_of_the_setup_lock() {
    let (worktree, git_dir) = linked_worktree();
    let lock = git_dir.join("cmux-setup.lock");
    std::fs::write(git_dir.join("cmux-setup.json"), RUNS).unwrap();
    named_pipe(&lock);
    // The two ends of the pipe are open here, so no open of it waits. Where a pipe takes a
    // lock, this one is held; where it takes none, a look at its lock fails.
    let holder = OpenOptions::new().read(true).write(true).open(&lock).unwrap();
    let locked = holder.lock().is_ok();
    let run = Client::of_a_new_daemon().setup_run(&worktree);
    assert_eq!(run["state"], "interrupted", "the lock state of a pipe (locked: {locked}): {run}");
}

#[test]
fn git_files_search_gives_a_link_as_a_file_whatever_its_target_is() {
    let repo = fresh_repository();
    let outside = outside_folder("file", b"outside\n");
    std::os::unix::fs::symlink(&outside, repo.join("tolink-folder")).unwrap();
    std::os::unix::fs::symlink(outside.join("file"), repo.join("tolink-file")).unwrap();
    std::os::unix::fs::symlink(outside.join("nothing"), repo.join("tolink-nothing")).unwrap();
    let found = Client::of_a_new_daemon().found(&repo, "tolink");
    assert_eq!(
        found,
        ["tolink-file", "tolink-folder", "tolink-nothing"],
        "a result says what the target of a link is"
    );
}

#[test]
fn git_files_list_gives_no_name_of_a_folder_that_became_a_link_after_the_listing() {
    let repo = fresh_repository();
    std::fs::create_dir_all(repo.join("dir")).unwrap();
    std::fs::write(repo.join("dir/name"), "inside\n").unwrap();
    // `name` is a file in the work tree and a folder in the folder outside it.
    let outside = fixture().dir.join(unique("o"));
    std::fs::create_dir_all(outside.join("name")).unwrap();
    let mut client = Client::of_a_new_daemon();
    let folder = repo.join("dir");
    assert_eq!(client.listed_kind(&folder, "name"), "file", "the file of the work tree");

    let hook = swap_after(&repo, "after-files-listing", &outside);
    let during = client.listed_names(&folder);
    swapped(&repo, &hook);
    assert!(during.is_empty(), "a name that is not in the work tree: {during:?}");
}

#[test]
fn git_files_search_counts_no_match_in_a_folder_that_became_a_link_after_the_listing() {
    let repo = fresh_repository();
    std::fs::create_dir_all(repo.join("dir")).unwrap();
    std::fs::write(repo.join("dir/name.txt"), "inside\n").unwrap();
    let outside = outside_folder("name.txt", b"outside\n");
    let mut client = Client::of_a_new_daemon();
    let folder = repo.join("dir");
    let before = client.search(&folder, "name");
    assert_eq!(before["total_matches"], 1, "the file of the work tree: {before}");

    let hook = swap_after(&repo, "after-files-listing", &outside);
    let during = client.search(&folder, "name");
    swapped(&repo, &hook);
    assert_eq!(during["total_matches"], 0, "a path that is not in the work tree: {during}");
    assert_eq!(during["results"], json!([]), "{during}");
}

#[test]
fn git_files_search_gives_no_path_below_a_folder_that_became_a_link_after_the_listing() {
    let repo = fresh_repository();
    std::fs::create_dir_all(repo.join("dir")).unwrap();
    std::fs::write(repo.join("dir/name.txt"), "inside\n").unwrap();
    let outside = outside_folder("name.txt", b"outside\n");
    let mut client = Client::of_a_new_daemon();
    assert_eq!(client.found(&repo, "name"), ["dir/name.txt"], "the file of the work tree");

    let hook = swap_after(&repo, "after-files-listing", &outside);
    let during = client.found(&repo, "name");
    swapped(&repo, &hook);
    assert_eq!(during, NO_PATH, "a path that is not in the work tree");
}

/// No search result.
const NO_PATH: [&str; 0] = [];

/// Makes the tracked folder `dir` in `folder`, a folder of `repo`, with the tracked file
/// `dir/below.txt`, and then puts a link to a folder outside the repository in the place of
/// `dir`. That folder has one file, `outside_file`.
fn link_in_the_place_of_a_tracked_folder_in(repo: &Path, folder: &Path, outside_file: &str) {
    std::fs::create_dir_all(folder.join("dir")).unwrap();
    std::fs::write(folder.join("dir/below.txt"), "inside\n").unwrap();
    git(repo, &["add", "."]);
    git(repo, &["commit", "--quiet", "-m", "dir"]);
    let outside = outside_folder(outside_file, b"outside\n");
    std::fs::rename(folder.join("dir"), repo.join(".git").join("dir-away")).unwrap();
    std::os::unix::fs::symlink(&outside, folder.join("dir")).unwrap();
}

/// A new repository whose tracked folder `dir`, with the tracked file `dir/below.txt`, is now
/// a link to a folder outside it. That folder has one file, `outside_file`.
fn repository_with_a_link_to_a_folder_with(outside_file: &str) -> PathBuf {
    let repo = fresh_repository();
    link_in_the_place_of_a_tracked_folder_in(&repo, &repo, outside_file);
    repo
}

/// A new repository whose tracked folder `dir` is now a link to a folder outside it. That
/// folder has a `below.txt` of its own, the name of the tracked file `dir/below.txt`.
fn repository_with_a_link_in_the_place_of_a_tracked_folder() -> PathBuf {
    repository_with_a_link_to_a_folder_with("below.txt")
}

/// The folder behind the link has a file of the tracked name, or it has none.
const BEHIND_THE_LINK: [&str; 2] = ["below.txt", "other.txt"];

#[test]
fn git_files_search_counts_no_match_below_a_link_in_the_place_of_a_tracked_folder() {
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = repository_with_a_link_to_a_folder_with(outside_file);
        let result = client.search(&repo, "below");
        assert_eq!(result["total_matches"], 0, "{outside_file} behind the link: {result}");
        assert_eq!(result["truncated"], false, "{outside_file} behind the link: {result}");
        assert_eq!(result["results"], json!([]), "{outside_file} behind the link: {result}");
    }
}

#[test]
fn git_files_list_gives_no_name_for_an_ignored_link_in_the_place_of_a_tracked_folder() {
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = repository_with_a_link_to_a_folder_with(outside_file);
        // An ignore rule hides the link, as it hides each untracked name; it hides no tracked
        // path, and the tracked `dir/below.txt` is not in the work tree.
        std::fs::write(repo.join(".gitignore"), "/dir\n").unwrap();
        let names = client.listed_names(&repo);
        assert_eq!(names, [".gitignore", "a.txt"], "{outside_file} behind the link");
    }
}

#[test]
fn git_files_list_gives_no_folder_for_a_link_in_the_place_of_a_tracked_folder() {
    let repo = repository_with_a_link_in_the_place_of_a_tracked_folder();
    let kind = Client::of_a_new_daemon().listed_kind(&repo, "dir");
    assert_eq!(kind, "file", "a link with tracked paths below its name");
}

#[test]
fn git_files_search_gives_no_path_below_a_link_in_the_place_of_a_tracked_folder() {
    let repo = repository_with_a_link_in_the_place_of_a_tracked_folder();
    let found = Client::of_a_new_daemon().found(&repo, "below");
    assert_eq!(found, NO_PATH, "a path that is not in the work tree");
}

#[test]
fn git_files_list_gives_a_submodule_as_a_folder_and_the_search_gives_it_as_no_file() {
    let repo = fresh_repository();
    let inner = repo.join("inner-repo");
    std::fs::create_dir_all(&inner).unwrap();
    git(&inner, &["init", "--quiet", "--initial-branch=main"]);
    std::fs::write(inner.join("s.txt"), "one\n").unwrap();
    git(&inner, &["add", "s.txt"]);
    git(&inner, &["commit", "--quiet", "-m", "s.txt"]);
    // git records the folder as one path, a repository of its own.
    git(&repo, &["add", "inner-repo"]);
    let mut client = Client::of_a_new_daemon();
    assert_eq!(client.listed_kind(&repo, "inner-repo"), "directory", "a real folder");
    assert_eq!(client.found(&repo, "inner-repo"), NO_PATH, "a folder is no file");
}

#[test]
fn git_files_search_counts_no_match_below_a_link_in_a_folder_whose_name_ends_with_a_line_break() {
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = fresh_repository();
        let folder = repo.join("pkg\n");
        link_in_the_place_of_a_tracked_folder_in(&repo, &folder, outside_file);
        let result = client.search(&folder, "below");
        assert_eq!(result["total_matches"], 0, "{outside_file} behind the link: {result}");
        assert_eq!(result["results"], json!([]), "{outside_file} behind the link: {result}");
        let searched = result["search_root"].as_str().unwrap_or_default();
        assert!(searched.ends_with("/pkg\n"), "the folder that was searched: {result}");
        let kind = client.listed_kind(&folder, "dir");
        assert_eq!(kind, "file", "{outside_file} behind the link");
    }
}

/// A name that is not UTF-8 is a name of Linux only. The client names the folder by a link
/// to it, and git gives the folder's own name.
#[cfg(target_os = "linux")]
#[test]
fn git_files_search_counts_no_match_below_a_link_in_a_folder_whose_name_is_not_utf8() {
    use std::os::unix::ffi::OsStrExt as _;
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = fresh_repository();
        let name = std::ffi::OsStr::from_bytes(b"caf\xe9");
        link_in_the_place_of_a_tracked_folder_in(&repo, &repo.join(name), outside_file);
        let alias = repo.join("alias");
        std::os::unix::fs::symlink(name, &alias).unwrap();
        let result = client.search(&alias, "below");
        assert_eq!(result["total_matches"], 0, "{outside_file} behind the link: {result}");
        assert_eq!(result["results"], json!([]), "{outside_file} behind the link: {result}");
        let kind = client.listed_kind(&alias, "dir");
        assert_eq!(kind, "file", "{outside_file} behind the link");
    }
}

/// The daemon looks at a path with 128 folders above its name, and it does not look at a
/// path with more. A path with 129 is no candidate, as a path below a link is none.
#[test]
fn git_files_search_counts_no_match_below_a_link_with_more_than_128_folders_above_the_name() {
    let mut client = Client::of_a_new_daemon();
    for folders in [128, 129] {
        for outside_file in BEHIND_THE_LINK {
            let repo = fresh_repository();
            // The link `dir` is the last of the folders above the name.
            let real: PathBuf = (1..folders).map(|_| "d").collect();
            let folder = repo.join(real);
            link_in_the_place_of_a_tracked_folder_in(&repo, &folder, outside_file);
            let result = client.search(&repo, "below");
            let state = format!("{folders} folders, {outside_file} behind the link");
            assert_eq!(result["total_matches"], 0, "{state}: {result}");
            assert_eq!(result["results"], json!([]), "{state}: {result}");
            assert_eq!(client.listed_kind(&folder, "dir"), "file", "{state}");
        }
    }
}

/// Gives a folder its read permission back at the end of a test, also after a failed assert.
struct ReadAgain(PathBuf);

impl Drop for ReadAgain {
    fn drop(&mut self) {
        let _ = std::fs::set_permissions(&self.0, std::fs::Permissions::from_mode(0o755));
    }
}

/// Takes the read permission of `folder` away: a user can go through the folder to a name
/// below it, and cannot read the folder. A user that reads each folder (root) makes no such
/// state, so the test fails there with these words and does not pass with no run.
fn passed_and_not_read(folder: &Path) -> ReadAgain {
    std::fs::set_permissions(folder, std::fs::Permissions::from_mode(0o111)).unwrap();
    let read_again = ReadAgain(folder.to_path_buf());
    assert!(
        std::fs::read_dir(folder).is_err(),
        "NOT RUN: the user of this test reads a folder that has no read permission (root?)"
    );
    read_again
}

#[test]
fn git_files_search_counts_no_match_below_a_link_in_a_folder_that_cannot_be_read() {
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = fresh_repository();
        let closed = repo.join("closed");
        link_in_the_place_of_a_tracked_folder_in(&repo, &closed, outside_file);
        let read_again = passed_and_not_read(&closed);
        let result = client.search(&repo, "below");
        let names = client.listed_names(&repo);
        let names_in_the_folder = client.listed_names(&closed);
        drop(read_again);
        assert_eq!(result["total_matches"], 0, "{outside_file} behind the link: {result}");
        assert_eq!(result["results"], json!([]), "{outside_file} behind the link: {result}");
        assert_eq!(names, ["a.txt"], "{outside_file} behind the link");
        assert!(names_in_the_folder.is_empty(), "{outside_file}: {names_in_the_folder:?}");
    }
}

/// A work tree with no link. The daemon does not look below a folder that it cannot read, so
/// a tracked file below such a folder is no match, no result and gives no name.
#[test]
fn git_files_search_gives_no_file_below_a_folder_that_cannot_be_read() {
    let repo = fresh_repository();
    let closed = repo.join("closed");
    std::fs::create_dir_all(&closed).unwrap();
    std::fs::write(closed.join("inclosed.txt"), "inside\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "--quiet", "-m", "closed"]);
    let mut client = Client::of_a_new_daemon();
    assert_eq!(client.found(&repo, "inclosed"), ["closed/inclosed.txt"], "a folder with a read");
    let read_again = passed_and_not_read(&closed);
    let result = client.search(&repo, "inclosed");
    let names = client.listed_names(&repo);
    drop(read_again);
    assert_eq!(result["total_matches"], 0, "{result}");
    assert_eq!(result["results"], json!([]), "{result}");
    assert_eq!(names, ["a.txt"]);
}

/// A sparse checkout, a work tree with no link. git lists a tracked file that the checkout
/// left out, and the file is not on the disk: it is no match, no result and gives no name.
/// One such file has its folder on the disk, and one has not.
#[test]
fn git_files_search_gives_no_tracked_file_that_a_sparse_checkout_left_out() {
    let repo = fresh_repository();
    std::fs::create_dir_all(repo.join("out")).unwrap();
    std::fs::create_dir_all(repo.join("part")).unwrap();
    std::fs::write(repo.join("out/sparse-one.txt"), "one\n").unwrap();
    std::fs::write(repo.join("part/sparse-two.txt"), "two\n").unwrap();
    std::fs::write(repo.join("part/stays.txt"), "three\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "--quiet", "-m", "sparse"]);
    let mut client = Client::of_a_new_daemon();
    let all = client.found(&repo, "sparse");
    assert_eq!(all, ["out/sparse-one.txt", "part/sparse-two.txt"], "the whole checkout");

    git(&repo, &["sparse-checkout", "set", "--no-cone", "/*", "!/out/", "!/part/sparse-two.txt"]);
    assert!(!repo.join("out").exists(), "the sparse checkout did not take the folder `out` away");
    assert!(!repo.join("part/sparse-two.txt").exists(), "the sparse checkout left the file");
    let result = client.search(&repo, "sparse");
    assert_eq!(result["total_matches"], 0, "{result}");
    assert_eq!(result["results"], json!([]), "{result}");
    assert_eq!(client.listed_names(&repo), ["part", "a.txt"]);
    assert_eq!(client.listed_names(&repo.join("part")), ["stays.txt"]);
}

/// Puts a program at the hook `name` of `repo` that takes the link `dir` of `repo` away and
/// puts the folder back that was there before the link: the stand-in git runs it after the
/// listing that the hook names.
fn swap_back_after(repo: &Path, name: &str) -> PathBuf {
    let hook = repo.join(".git").join(name);
    let script = format!(
        "#!/bin/sh\nrm '{dir}' && mv '{away}' '{dir}'\n",
        dir = repo.join("dir").display(),
        away = repo.join(".git").join("dir-away").display(),
    );
    std::fs::write(&hook, script).unwrap();
    std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
    hook
}

/// The folder `dir` is a link at git's listing and the real folder, with the tracked file
/// `dir/below.txt`, at the daemon's look. The count is of the real folder: it is the same
/// with and without a file of the tracked name behind the link.
#[test]
fn git_files_search_counts_a_file_of_a_folder_that_was_a_link_at_the_listing_by_the_folder() {
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = repository_with_a_link_to_a_folder_with(outside_file);
        let hook = swap_back_after(&repo, "after-files-listing");
        let result = client.search(&repo, "below");
        std::fs::remove_file(&hook).unwrap();
        let dir = std::fs::symlink_metadata(repo.join("dir")).unwrap();
        assert!(dir.is_dir(), "the stand-in git did not put the folder back");
        assert_eq!(result["total_matches"], 1, "{outside_file} was behind the link: {result}");
        let path = &result["results"][0]["path"];
        assert_eq!(*path, "dir/below.txt", "{outside_file} was behind the link: {result}");
    }
}

/// The folder `dir` is a link at git's listing and a real folder with no file at the daemon's
/// look. The tracked `dir/below.txt` is not in the work tree: it is no match and no result,
/// with and without a file of its name behind the link.
#[test]
fn git_files_search_gives_no_path_of_an_empty_folder_that_was_a_link_at_the_listing() {
    let mut client = Client::of_a_new_daemon();
    for outside_file in BEHIND_THE_LINK {
        let repo = repository_with_a_link_to_a_folder_with(outside_file);
        let hook = repo.join(".git").join("after-files-listing");
        let script =
            format!("#!/bin/sh\nrm '{dir}' && mkdir '{dir}'\n", dir = repo.join("dir").display());
        std::fs::write(&hook, script).unwrap();
        std::fs::set_permissions(&hook, std::fs::Permissions::from_mode(0o755)).unwrap();
        let result = client.search(&repo, "below");
        std::fs::remove_file(&hook).unwrap();
        let dir = std::fs::symlink_metadata(repo.join("dir")).unwrap();
        assert!(dir.is_dir(), "the stand-in git did not put the real folder there");
        assert_eq!(result["total_matches"], 0, "{outside_file} was behind the link: {result}");
        assert_eq!(result["results"], json!([]), "{outside_file} was behind the link: {result}");
    }
}

/// The work tree's TOP folder has a name that ends with a line break. Beside it, a link to a
/// folder outside the repository has the same name less the line break. The names of the
/// search and of the list are the names of the work tree: they are the same whatever is
/// behind that link, and the reply's `root` is the work tree's top folder, not the link.
#[test]
fn git_files_search_gives_the_names_of_a_work_tree_whose_top_folder_name_ends_with_a_line_break() {
    let mut client = Client::of_a_new_daemon();
    let mut totals = Vec::new();
    let mut names = Vec::new();
    let mut roots = Vec::new();
    for outside_file in ["guess.txt", "other.txt"] {
        let host = fixture().dir.join(unique("h"));
        let repo = host.join("x\n");
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(repo.join("guess.txt"), "inside\n").unwrap();
        git(&repo, &["add", "guess.txt"]);
        git(&repo, &["commit", "--quiet", "-m", "guess"]);
        let outside = outside_folder(outside_file, b"outside\n");
        std::os::unix::fs::symlink(&outside, host.join("x")).unwrap();

        let result = client.search(&repo, "guess");
        totals.push(result["total_matches"].clone());
        roots.push(result["root"].as_str().unwrap_or_default().to_owned());
        names.push(client.listed_names(&repo));
    }
    // First `guess.txt` is behind the link beside the work tree, then it is not.
    assert_eq!(totals, [1, 1], "the count is of the work tree, not of the folder behind the link");
    assert_eq!(names, [["guess.txt"], ["guess.txt"]], "the list is of the work tree");
    assert!(
        roots.iter().all(|root| root.ends_with("/x\n")),
        "the root is the work tree: {roots:?}"
    );
}
