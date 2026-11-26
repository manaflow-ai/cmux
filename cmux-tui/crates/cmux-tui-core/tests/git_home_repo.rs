#![cfg(unix)]
//! The git reads of a folder in the home folder's own repository, over a real session socket.
//!
//! A person who keeps the home folder in git (a dotfiles repository, `~/.git`) has every folder
//! of the home folder in that repository: a terminal in `~/itp-rs/tools`, which has no
//! repository of its own, is in the one whose top level is `~`. Every file that repository does
//! not track is one of its untracked files, so a read that lists them walks the whole home
//! folder, the Photos library and Desktop included. On a test Mac that walk raised "cmux would
//! like to access your Photos library" and three Full Disk Access requests at launch.
//!
//! Each read below still answers (the branch, the tracked change), and none of its git children
//! lists the home folder's untracked files: no `ls-files --others`, no `status` that lists
//! untracked files, run in the home folder. The person's own search of a folder lists that folder
//! and nothing above it. A repository of its own below the home folder still lists its untracked
//! files.
//!
//! The git on `PATH` is a stand-in that writes its arguments to a log named as its working
//! directory, and then is the real git. One test per process: `HOME` is process-wide.

use cmux_tui_core::{Mux, SurfaceOptions, server};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

struct Fixture {
    root: PathBuf,
    real: PathBuf,
}

impl Fixture {
    /// A folder of this process with a stand-in `git` first on `PATH`.
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("ghome-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("bin")).unwrap();
        std::fs::create_dir_all(root.join("log")).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        let path = std::env::var_os("PATH").expect("PATH is set");
        let real = std::env::split_paths(&path)
            .map(|dir| dir.join("git"))
            .find(|candidate| candidate.is_file())
            .expect("git is on PATH");
        let script = format!(
            "#!/bin/sh\necho \"$*\" >> \"{log}/$(basename \"$PWD\")\"\nexec \"{real}\" \"$@\"\n",
            log = root.join("log").display(),
            real = real.display(),
        );
        let shim = root.join("bin").join("git");
        std::fs::write(&shim, script).unwrap();
        std::fs::set_permissions(&shim, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut search = root.join("bin").into_os_string();
        search.push(":");
        search.push(path);
        // SAFETY: the one test of this process sets it before it starts a daemon or a child.
        unsafe { std::env::set_var("PATH", search) };
        Self { root, real }
    }

    /// Runs the real git in `directory`, apart from the host's git config.
    fn git(&self, directory: &Path, arguments: &[&str]) {
        let ended = Command::new(&self.real)
            .arg("-C")
            .arg(directory)
            .args([
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@e.test",
                "-c",
                "maintenance.auto=false",
            ])
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

    /// The git children that ran in a folder named `name` since [`Fixture::forget`].
    fn children(&self, name: &str) -> Vec<String> {
        let log = std::fs::read_to_string(self.root.join("log").join(name)).unwrap_or_default();
        log.lines().map(str::to_owned).collect()
    }

    fn forget(&self) {
        let _ = std::fs::remove_dir_all(self.root.join("log"));
        std::fs::create_dir_all(self.root.join("log")).unwrap();
    }
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// Whether a git child's arguments list untracked files: `ls-files --others` (with or without
/// `--ignored`), or a `status` that does not say `--untracked-files=no`.
fn lists_untracked(arguments: &str) -> bool {
    let words: Vec<&str> = arguments.split(' ').collect();
    let has = |word: &str| words.contains(&word);
    if has("ls-files") && (has("--others") || has("-o")) {
        return true;
    }
    has("status") && !has("--untracked-files=no") && !has("-uno")
}

struct Client {
    stream: BufReader<UnixStream>,
    next: u64,
}

impl Client {
    fn of_a_new_daemon(fixture: &Fixture) -> Self {
        let socket = fixture.root.join("d.sock");
        // A session with durable state: checkpoints are kept there.
        let state = fixture.root.join("state");
        let name = format!("git-home-repo-{}", std::process::id());
        let mux = Mux::open_persistent(name, SurfaceOptions::default(), &state).unwrap();
        server::serve(mux.clone(), Some(socket.clone())).unwrap();
        // The daemon lives as long as the test process.
        std::mem::forget(mux);
        let stream = UnixStream::connect(&socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        Self { stream: BufReader::new(stream), next: 0 }
    }

    /// The result of one read `operation` with `params`; the read must succeed.
    fn read(&mut self, operation: &str, mut params: Value) -> Value {
        self.next += 1;
        let id = format!("r{}", self.next);
        params["machine"] = json!("current");
        params["session"] = json!("current");
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
                assert_eq!(reply["ok"], true, "{request} failed: {reply}");
                return reply["result"].clone();
            }
        }
    }
}

/// The `path` of each object of `list` (an array of objects).
fn paths(list: &Value) -> Vec<String> {
    list.as_array()
        .unwrap_or_else(|| panic!("not a list: {list}"))
        .iter()
        .filter_map(|item| item["path"].as_str().or_else(|| item["name"].as_str()))
        .map(str::to_owned)
        .collect()
}

#[test]
fn cmux_next_git_reads_never_list_the_home_folders_untracked_files() {
    let fixture = Fixture::new();
    // The home folder, kept in git: one tracked dotfile, changed since its commit.
    let home = fixture.root.join("home");
    std::fs::create_dir_all(&home).unwrap();
    fixture.git(&home, &["init", "--quiet", "--initial-branch=main"]);
    write(&home.join(".zshrc"), "export A=1\n");
    fixture.git(&home, &["add", ".zshrc"]);
    fixture.git(&home, &["commit", "--quiet", "-m", "dotfiles"]);
    write(&home.join(".zshrc"), "export A=2\n");
    // What the repository does not track: the person's files.
    write(&home.join("Pictures/Photos Library.photoslibrary/database/Photos.sqlite"), "photos\n");
    write(&home.join("Documents/notes.txt"), "notes\n");
    // A terminal's folder with no repository of its own.
    let tools = home.join("itp-rs").join("tools");
    write(&tools.join("run.py"), "print(1)\n");
    // A repository of its own below the home folder, with a new file.
    let app = home.join("code").join("app");
    std::fs::create_dir_all(&app).unwrap();
    fixture.git(&app, &["init", "--quiet", "--initial-branch=main"]);
    write(&app.join("lib.rs"), "\n");
    fixture.git(&app, &["add", "lib.rs"]);
    fixture.git(&app, &["commit", "--quiet", "-m", "app"]);
    write(&app.join("new.rs"), "\n");

    // SAFETY: set before this process starts a daemon or a child; git and the daemon read it.
    unsafe { std::env::set_var("HOME", &home) };
    let mut client = Client::of_a_new_daemon(&fixture);
    let tools_path = tools.to_string_lossy().into_owned();
    let walks_home = |fixture: &Fixture, read: &str| {
        let walked: Vec<String> =
            fixture.children("home").into_iter().filter(|line| lists_untracked(line)).collect();
        assert!(
            walked.is_empty(),
            "{read} listed the home folder's untracked files: {walked:?}\nall children: {:?}",
            fixture.children("home")
        );
    };

    // The branch still reads, from the refs.
    fixture.forget();
    let status = client.read("git.status", json!({"path": tools_path}));
    assert_eq!(status["branch"], "main", "{status}");
    assert_eq!(status["root"], home.to_string_lossy().as_ref(), "{status}");
    walks_home(&fixture, "git.status");

    // A diff tab's freshness read, each 4 s while it shows.
    fixture.forget();
    let fingerprint =
        client.read("git.fingerprint", json!({"path": tools_path, "scope": "uncommitted"}));
    assert_eq!(fingerprint["fingerprint"].as_str().map(str::len), Some(64), "{fingerprint}");
    walks_home(&fixture, "git.fingerprint");

    // The Changes view and a chat's change counts: the tracked change, no untracked file.
    fixture.forget();
    let diff = client.read("git.diff", json!({"path": tools_path, "scope": "uncommitted"}));
    let changed = paths(&diff["files"]);
    assert_eq!(changed, [".zshrc"], "the tracked change only: {diff}");
    walks_home(&fixture, "git.diff");

    // A turn's checkpoint candidates.
    fixture.forget();
    let checkpoints =
        client.read("git.checkpoint.list", json!({"path": tools_path, "include_candidates": true}));
    let candidates = paths(&checkpoints["candidates"]);
    assert!(candidates.is_empty(), "no untracked candidate in the home folder: {checkpoints}");
    walks_home(&fixture, "git.checkpoint.list");

    // The Files page: the folder's own children, read from the disk.
    fixture.forget();
    let listed = client.read("git.files.list", json!({"path": tools_path}));
    assert_eq!(paths(&listed["entries"]), ["run.py"], "{listed}");
    walks_home(&fixture, "git.files.list");

    // The person's file search in the folder lists that folder only.
    fixture.forget();
    let found = client.read("git.files.search", json!({"path": tools_path, "query": "run"}));
    assert_eq!(paths(&found["results"]), ["run.py"], "{found}");
    walks_home(&fixture, "git.files.search in a folder");
    // In the home folder itself, only what the repository tracks.
    fixture.forget();
    let found =
        client.read("git.files.search", json!({"path": home.to_string_lossy(), "query": "photos"}));
    assert_eq!(paths(&found["results"]), Vec::<String>::new(), "{found}");
    walks_home(&fixture, "git.files.search in the home folder");

    // A repository of its own below the home folder keeps its untracked files.
    fixture.forget();
    let diff =
        client.read("git.diff", json!({"path": app.to_string_lossy(), "scope": "uncommitted"}));
    assert_eq!(paths(&diff["files"]), ["new.rs"], "{diff}");
    assert!(
        fixture.children("app").iter().any(|line| lists_untracked(line)),
        "a repository of its own lists its untracked files: {:?}",
        fixture.children("app")
    );
    walks_home(&fixture, "git.diff of a repository below the home folder");
    let _ = std::fs::remove_dir_all(&fixture.root);
}
