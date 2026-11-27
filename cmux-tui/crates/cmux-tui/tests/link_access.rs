//! `cmux link access`: a folder of this Mac shared with a chat on a Cloud
//! machine (Move to Cloud, cmuxterm-hq#1874 slice 6). A grant names one
//! folder, one machine and one chat there, and is read-only or read-write;
//! `sync` pushes every grant again, and brings a read-write grant's machine
//! edits back. Only folders strictly under the home folder, outside its dot
//! folders and `~/Library`, can be shared; secret files in them never go.
//! The machine side is the real `FsService` behind a socket that answers
//! lines the way the daemon's `fs_wire` does.
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use serde_json::Value;

/// Serves `fs.*` lines on `socket` with the real owner over `home`, one
/// thread per connection, until the test process ends.
fn serve_fs(socket: &Path, home: &Path) {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let reply = stream::answer(&id, service.call("local", &cmd, request));
                    let mut text = reply.to_string();
                    text.push('\n');
                    if writer.write_all(text.as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
}

/// This Mac (its home and state folders) and one Cloud machine (its home,
/// with `~/work`, behind a socket).
struct World {
    _root: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    home: PathBuf,
    state: PathBuf,
    machine_home: PathBuf,
    socket: PathBuf,
}

impl World {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(root.path()).unwrap();
        let home = base.join("mac-home");
        let machine_home = base.join("machine-home");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::create_dir_all(machine_home.join("work")).unwrap();
        // A socket path must stay under SUN_LEN; the temp folder can be deep.
        let sockets = tempfile::Builder::new().prefix("ca").tempdir_in("/tmp").unwrap();
        let socket = sockets.path().join("fs.sock");
        serve_fs(&socket, &machine_home);
        Self {
            _root: root,
            _sockets: sockets,
            home,
            state: base.join("state"),
            machine_home,
            socket,
        }
    }

    fn work(&self) -> PathBuf {
        self.machine_home.join("work")
    }

    /// `cmux link access ARGS` on this Mac: whether it exited 0, and its
    /// one JSON line.
    fn access(&self, args: &[&str]) -> (bool, Value) {
        let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .env("HOME", &self.home)
            .env("CMUX_TUI_STATE_DIR", &self.state)
            .args(["link", "access"])
            .args(args)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let line = stdout.lines().last().unwrap_or_default();
        let answer: Value = serde_json::from_str(line).unwrap_or_else(|_| {
            panic!(
                "no JSON line from link access {args:?}: {}{}",
                stdout,
                String::from_utf8_lossy(&output.stderr)
            )
        });
        (output.status.success(), answer)
    }

    fn grant(&self, session: &str, mode: &str, folder: &Path) -> (bool, Value) {
        let work = self.work();
        self.access(&[
            "grant",
            "--socket",
            self.socket.to_str().unwrap(),
            "--machine",
            "machine-1",
            "--session",
            session,
            "--remote-root",
            work.to_str().unwrap(),
            "--mode",
            mode,
            folder.to_str().unwrap(),
        ])
    }

    fn sync(&self, extra: &[&str]) -> Value {
        let mut args =
            vec!["sync", "--socket", self.socket.to_str().unwrap(), "--machine", "machine-1"];
        args.extend_from_slice(extra);
        let (ok, answer) = self.access(&args);
        assert!(ok, "sync failed: {answer}");
        answer
    }
}

/// A plain folder under the Mac's home with a nested file and secret files
/// that never go.
fn designs(home: &Path) -> PathBuf {
    let folder = home.join("projects/designs");
    std::fs::create_dir_all(folder.join("sub")).unwrap();
    std::fs::write(folder.join("a.txt"), "one\n").unwrap();
    std::fs::write(folder.join("sub/b.txt"), "two\n").unwrap();
    std::fs::write(folder.join(".env"), "API_KEY=fake-secret-1\n").unwrap();
    std::fs::write(folder.join("sub/.env.local"), "API_KEY=fake-secret-2\n").unwrap();
    std::fs::write(folder.join(".netrc"), "machine x login y password fake-secret-3\n").unwrap();
    folder
}

fn read(path: &Path) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

#[test]
fn a_read_only_grant_syncs_changes_one_way_and_stops_when_revoked() {
    let world = World::new();
    let folder = designs(&world.home);

    let (ok, granted) = world.grant("session-1", "read", &folder);
    assert!(ok, "grant failed: {granted}");
    let remote = PathBuf::from(granted["grant"]["remote"].as_str().unwrap());
    assert!(remote.starts_with(world.work().join("local")), "{granted}");
    assert_eq!(granted["grant"]["mode"], "read", "{granted}");
    assert_eq!(read(&remote.join("a.txt")), "one\n");
    assert_eq!(read(&remote.join("sub/b.txt")), "two\n");
    for secret in [".env", "sub/.env.local", ".netrc"] {
        assert!(!remote.join(secret).exists(), "{secret} reached the machine");
    }

    // This Mac's changes go; the machine's never come back, and a file the
    // machine changed is the Mac's again after the next sync.
    std::fs::write(folder.join("a.txt"), "one\nedited here\n").unwrap();
    std::fs::write(folder.join("c.txt"), "new here\n").unwrap();
    std::fs::write(remote.join("sub/b.txt"), "changed on the machine\n").unwrap();
    std::fs::write(remote.join("vm.txt"), "made on the machine\n").unwrap();
    let synced = world.sync(&[]);
    assert_eq!(synced["synced"].as_array().map(Vec::len), Some(1), "{synced}");
    assert_eq!(synced["synced"][0]["ok"], true, "{synced}");
    assert_eq!(read(&remote.join("a.txt")), "one\nedited here\n");
    assert_eq!(read(&remote.join("c.txt")), "new here\n");
    assert_eq!(read(&remote.join("sub/b.txt")), "two\n");
    assert_eq!(read(&folder.join("sub/b.txt")), "two\n");
    assert!(!folder.join("vm.txt").exists(), "a machine file came back through a read-only grant");

    // Grants are per chat: another chat's sync and revoke leave this one.
    let other = world.sync(&["--session", "session-2"]);
    assert_eq!(other["synced"].as_array().map(Vec::len), Some(0), "{other}");
    let (ok, listed) = world.access(&["grants", "--machine", "machine-1"]);
    assert!(ok, "{listed}");
    assert_eq!(listed["grants"].as_array().map(Vec::len), Some(1), "{listed}");
    assert_eq!(listed["grants"][0]["session"], "session-1", "{listed}");
    assert_eq!(listed["grants"][0]["folder"], folder.to_str().unwrap(), "{listed}");
    let socket = world.socket.to_str().unwrap();
    let (ok, untouched) = world.access(&[
        "revoke",
        "--socket",
        socket,
        "--machine",
        "machine-1",
        "--session",
        "session-2",
        "--all",
    ]);
    assert!(ok, "{untouched}");
    assert_eq!(untouched["revoked"], 0, "{untouched}");
    assert!(remote.join("a.txt").exists());

    // Revoked: the machine's copy goes, and nothing is sent again.
    let (ok, revoked) = world.access(&[
        "revoke",
        "--socket",
        socket,
        "--machine",
        "machine-1",
        "--session",
        "session-1",
        folder.to_str().unwrap(),
    ]);
    assert!(ok, "{revoked}");
    assert_eq!(revoked["revoked"], 1, "{revoked}");
    assert!(!remote.exists(), "a revoked read-only grant left its copy on the machine");
    std::fs::write(folder.join("a.txt"), "after the revoke\n").unwrap();
    let after = world.sync(&[]);
    assert_eq!(after["synced"].as_array().map(Vec::len), Some(0), "{after}");
    assert!(!remote.exists(), "a revoked grant was synced");
}

#[test]
fn a_grant_of_a_folder_that_may_not_be_shared_is_refused_and_sends_nothing() {
    let world = World::new();
    let home = &world.home;
    for dir in [".ssh", "Library/Keychains", ".config/tool", "projects"] {
        std::fs::create_dir_all(home.join(dir)).unwrap();
    }
    std::fs::write(home.join(".ssh/id_ed25519"), "fake-private-key\n").unwrap();
    let outside = home.parent().unwrap().join("outside");
    std::fs::create_dir_all(&outside).unwrap();
    std::os::unix::fs::symlink(home.join(".ssh"), home.join("projects/keys")).unwrap();

    let refused = [
        home.clone(),
        home.join(".ssh"),
        home.join("Library/Keychains"),
        home.join(".config/tool"),
        outside,
        home.join("projects/keys"),
        home.join("projects/missing"),
    ];
    for folder in &refused {
        let (ok, answer) = world.grant("session-1", "read", folder);
        assert!(!ok, "{} was shared: {answer}", folder.display());
        assert_eq!(answer["ok"], false, "{answer}");
        assert_eq!(answer["error_code"], "grant_refused", "{} {answer}", folder.display());
    }
    assert!(!world.work().join("local").exists(), "a refused grant wrote to the machine");
    let (ok, listed) = world.access(&["grants"]);
    assert!(ok, "{listed}");
    assert_eq!(listed["grants"].as_array().map(Vec::len), Some(0), "{listed}");
}

#[test]
fn a_read_write_grant_brings_machine_edits_back_and_stops_on_a_conflict() {
    let world = World::new();
    let folder = designs(&world.home);
    let (ok, granted) = world.grant("session-1", "write", &folder);
    assert!(ok, "grant failed: {granted}");
    let remote = PathBuf::from(granted["grant"]["remote"].as_str().unwrap());

    std::fs::write(remote.join("a.txt"), "one\nfrom the machine\n").unwrap();
    std::fs::write(folder.join("c.txt"), "new here\n").unwrap();
    let synced = world.sync(&[]);
    assert_eq!(synced["synced"][0]["ok"], true, "{synced}");
    assert_eq!(read(&folder.join("a.txt")), "one\nfrom the machine\n");
    assert_eq!(read(&remote.join("c.txt")), "new here\n");

    // Both sides changed one file: nothing moves either way.
    std::fs::write(remote.join("sub/b.txt"), "machine side\n").unwrap();
    std::fs::write(folder.join("sub/b.txt"), "mac side\n").unwrap();
    let conflicted = world.sync(&[]);
    assert_eq!(conflicted["synced"][0]["ok"], false, "{conflicted}");
    assert_eq!(conflicted["synced"][0]["error_code"], "sync_conflict", "{conflicted}");
    assert_eq!(read(&folder.join("sub/b.txt")), "mac side\n");
    assert_eq!(read(&remote.join("sub/b.txt")), "machine side\n");

    // A second chat may not share the same folder with another mode.
    let (ok, mixed) = world.grant("session-2", "read", &folder);
    assert!(!ok, "{mixed}");
    assert_eq!(mixed["error_code"], "grant_mode_conflict", "{mixed}");

    // A read-write folder that became a git working copy stops syncing.
    git(&folder, &["init", "-q", "-b", "main"]);
    let stopped = world.sync(&[]);
    assert_eq!(stopped["synced"][0]["error_code"], "grant_folder_changed", "{stopped}");

    // Revoking a read-write grant keeps the machine's copy: it may hold work
    // not brought back yet.
    let (ok, revoked) = world.access(&[
        "revoke",
        "--socket",
        world.socket.to_str().unwrap(),
        "--machine",
        "machine-1",
        "--session",
        "session-1",
        "--all",
    ]);
    assert!(ok, "{revoked}");
    assert_eq!(revoked["revoked"], 1, "{revoked}");
    assert!(remote.join("sub/b.txt").exists(), "{revoked}");
}

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "commit.gpgsign=false"])
        .args(args)
        .current_dir(dir)
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

#[test]
fn a_grant_of_a_working_copy_sends_no_repository_ignored_file_or_file_past_a_symlink() {
    let world = World::new();
    let home = &world.home;
    // A git working copy: a tracked secret file, ignored output, a remote
    // URL with a token, and a tracked folder later swapped for a symlink
    // to a private folder.
    let repo = home.join("projects/app");
    for dir in ["src", "config", "build", "data"] {
        std::fs::create_dir_all(repo.join(dir)).unwrap();
    }
    git(&repo, &["init", "-q", "-b", "main"]);
    std::fs::write(repo.join("src/a.txt"), "tracked\n").unwrap();
    std::fs::write(repo.join(".gitignore"), "build/\n").unwrap();
    std::fs::write(repo.join("config/.env.production"), "TOKEN=fake-secret-5\n").unwrap();
    std::fs::write(repo.join("data/x.txt"), "public\n").unwrap();
    std::fs::write(repo.join("build/out.o"), "ignored\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    git(&repo, &["remote", "add", "origin", "https://u:fake-secret-6@example.com/app.git"]);
    let private = home.join("private");
    std::fs::create_dir_all(&private).unwrap();
    std::fs::write(private.join("x.txt"), "fake-secret-7\n").unwrap();
    std::fs::remove_dir_all(repo.join("data")).unwrap();
    std::os::unix::fs::symlink(&private, repo.join("data")).unwrap();
    // A plain folder holding a repository.
    let many = home.join("projects/many");
    std::fs::create_dir_all(many.join("sub/.git")).unwrap();
    std::fs::write(many.join("sub/readme.txt"), "readme\n").unwrap();
    std::fs::write(many.join("sub/.git/HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(
        many.join("sub/.git/config"),
        "[remote \"origin\"]\n\turl = https://u:fake-secret-8@example.com/s.git\n",
    )
    .unwrap();

    let (ok, granted) = world.grant("session-1", "read", &repo);
    assert!(ok, "grant failed: {granted}");
    let remote = PathBuf::from(granted["grant"]["remote"].as_str().unwrap());
    assert_eq!(read(&remote.join("src/a.txt")), "tracked\n");
    assert_eq!(read(&remote.join(".gitignore")), "build/\n");
    for kept_here in [
        ".git/HEAD",
        ".git/config",
        ".git/index",
        "build/out.o",
        "config/.env.production",
        "data/x.txt",
    ] {
        assert!(!remote.join(kept_here).exists(), "{kept_here} reached the machine");
    }
    let (ok, granted) = world.grant("session-1", "read", &many);
    assert!(ok, "grant failed: {granted}");
    let remote = PathBuf::from(granted["grant"]["remote"].as_str().unwrap());
    assert_eq!(read(&remote.join("sub/readme.txt")), "readme\n");
    assert!(!remote.join("sub/.git").exists(), "a nested repository reached the machine");
    let everything = files_below(&world.machine_home);
    for secret in ["fake-secret-5", "fake-secret-6", "fake-secret-7", "fake-secret-8"] {
        assert!(
            !everything.iter().any(|bytes| String::from_utf8_lossy(bytes).contains(secret)),
            "{secret} reached the machine"
        );
    }

    // The machine never writes into a git working copy here.
    let (ok, refused) = world.grant("session-1", "write", &repo);
    assert!(!ok, "{refused}");
    assert_eq!(refused["error_code"], "grant_refused", "{refused}");
    // Revoking a folder that is not shared says so.
    let (ok, missing) = world.access(&[
        "revoke",
        "--machine",
        "machine-1",
        "--session",
        "session-1",
        private.to_str().unwrap(),
    ]);
    assert!(!ok, "{missing}");
    assert_eq!(missing["error_code"], "grant_not_found", "{missing}");
}

/// The bytes of every file below `dir`.
fn files_below(dir: &Path) -> Vec<Vec<u8>> {
    let mut found = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        let meta = std::fs::symlink_metadata(&path).unwrap();
        if meta.is_dir() {
            found.extend(files_below(&path));
        } else if meta.is_file() {
            found.push(std::fs::read(&path).unwrap());
        }
    }
    found
}

/// `cmux link access upload FILES` on this Mac, with `tmp` as its temporary
/// folder (where the app writes what the person pasted).
fn upload(world: &World, tmp: &Path, files: &[&Path]) -> (bool, Value) {
    let work = world.work();
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("HOME", &world.home)
        .env("CMUX_TUI_STATE_DIR", &world.state)
        .env("TMPDIR", tmp)
        .args(["link", "access", "upload", "--socket"])
        .arg(&world.socket)
        .arg("--remote-root")
        .arg(&work)
        .args(files);
    let output = command.output().unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let line = stdout.lines().last().unwrap_or_default();
    let answer: Value = serde_json::from_str(line).unwrap_or_else(|_| {
        panic!("no JSON line from upload: {stdout}{}", String::from_utf8_lossy(&output.stderr))
    });
    (output.status.success(), answer)
}

/// A folder the person dropped on a new Cloud chat's first message goes
/// whole, as a shared folder's files do: never a secret file, a credential
/// or dot folder's files, or a symlink. A folder no grant could share stays
/// refused, and nothing of the call goes.
#[test]
fn an_upload_sends_a_dropped_folder_without_its_secrets() {
    let world = World::new();
    let home = &world.home;
    let base = home.parent().unwrap().to_path_buf();
    let tmp = base.join("tmp");
    let app = home.join("projects/app");
    for dir in [
        "src/deep",
        "gcloud",
        "nested/.ssh",
        "empty",
        ".hidden",
        "Library/Keychains",
        "docs/.config",
    ] {
        std::fs::create_dir_all(app.join(dir)).unwrap();
    }
    for dir in [".ssh", "Library/Preferences", "Keychains", "backup/keychains"] {
        std::fs::create_dir_all(home.join(dir)).unwrap();
    }
    std::fs::write(home.join("Keychains/login.plist"), "fake-folder-keychain-root\n").unwrap();
    std::fs::write(home.join("backup/keychains/meta.db"), "fake-folder-keychain-file\n").unwrap();
    std::fs::create_dir_all(&tmp).unwrap();
    std::fs::create_dir_all(base.join("elsewhere")).unwrap();
    std::fs::write(app.join("README.md"), "the app\n").unwrap();
    std::fs::write(app.join("src/deep/main.rs"), "fn main() {}\n").unwrap();
    std::fs::write(app.join(".env"), "TOKEN=fake-folder-env\n").unwrap();
    std::fs::write(app.join("server.pem"), "fake-folder-pem\n").unwrap();
    std::fs::write(app.join("gcloud/adc.json"), "fake-folder-gcloud\n").unwrap();
    std::fs::write(app.join("nested/.ssh/config"), "fake-folder-ssh\n").unwrap();
    std::fs::write(app.join(".hidden/token"), "fake-folder-hidden\n").unwrap();
    std::fs::write(app.join("Library/Keychains/login.plist"), "fake-folder-keychain\n").unwrap();
    std::fs::write(app.join("docs/.config/app.toml"), "fake-folder-config\n").unwrap();
    std::fs::write(app.join(".bash_history"), "fake-folder-history\n").unwrap();
    std::fs::write(base.join("elsewhere/other.txt"), "fake-folder-outside\n").unwrap();
    std::os::unix::fs::symlink(base.join("elsewhere/other.txt"), app.join("link.txt")).unwrap();
    let dropped = home.join("projects/shot.png");
    std::fs::write(&dropped, b"\x89PNG fake image").unwrap();

    let (ok, sent) = upload(&world, &tmp, &[&app, &dropped]);
    assert!(ok, "{sent}");
    let folder = &sent["uploads"][0];
    assert_eq!(folder["folder"], true, "{sent}");
    let at = PathBuf::from(folder["path"].as_str().unwrap());
    assert!(at.starts_with(world.work().join("local/uploads")), "{sent}");
    assert_eq!(at.file_name().unwrap(), "app", "{sent}");
    assert_eq!(std::fs::read_to_string(at.join("README.md")).unwrap(), "the app\n");
    assert_eq!(std::fs::read_to_string(at.join("src/deep/main.rs")).unwrap(), "fn main() {}\n");
    assert_eq!(folder["files"], 2, "{sent}");
    for name in [
        ".env",
        "server.pem",
        "gcloud/adc.json",
        "nested/.ssh/config",
        ".hidden/token",
        "Library/Keychains/login.plist",
        "docs/.config/app.toml",
        ".bash_history",
        "link.txt",
        ".cmux-sync.json",
    ] {
        assert!(std::fs::symlink_metadata(at.join(name)).is_err(), "{name} went: {sent}");
    }
    assert!(sent["uploads"][1]["path"].as_str().unwrap().ends_with("/shot.png"), "{sent}");
    for bytes in files_below(&world.machine_home) {
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("fake-folder"), "a secret reached the machine: {text}");
    }

    // The home folder, a dot folder, ~/Library, a folder outside the home
    // and a keychain folder or a file in one: refused, and the file beside
    // them does not go either.
    for refused in [
        home.clone(),
        home.join(".ssh"),
        home.join("Library/Preferences"),
        base.join("elsewhere"),
        home.join("Keychains"),
        home.join("backup/keychains/meta.db"),
    ] {
        let before = files_below(&world.machine_home).len();
        let (ok, answer) = upload(&world, &tmp, &[&dropped, &refused]);
        assert!(!ok, "{} was uploaded: {answer}", refused.display());
        assert_eq!(answer["error_code"], "upload_refused", "{answer}");
        assert_eq!(files_below(&world.machine_home).len(), before, "{answer}");
    }
}

/// A folder that cannot go whole still goes: a dot folder this Mac's user
/// cannot read (`.config` of mode 000) is skipped, never a failed upload,
/// in a plain folder and in a git working copy, and the skipped count names
/// every path left out, symlinks and sockets and FIFOs included.
#[test]
fn an_upload_skips_an_unreadable_dot_folder_and_counts_every_path_left_out() {
    use std::os::unix::fs::PermissionsExt as _;
    let world = World::new();
    let home = &world.home;
    let base = home.parent().unwrap().to_path_buf();
    let tmp = base.join("tmp");
    std::fs::create_dir_all(&tmp).unwrap();
    std::fs::create_dir_all(base.join("elsewhere")).unwrap();
    std::fs::write(base.join("elsewhere/other.txt"), "fake-odds-outside\n").unwrap();
    let mode = |path: &Path, mode: u32| {
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    };

    let odds = home.join("projects/odds");
    std::fs::create_dir_all(odds.join(".config")).unwrap();
    std::fs::write(odds.join("readme.txt"), "odds\n").unwrap();
    std::fs::write(odds.join(".config/app.toml"), "fake-odds-config\n").unwrap();
    std::fs::write(odds.join(".env"), "TOKEN=fake-odds-env\n").unwrap();
    std::os::unix::fs::symlink(base.join("elsewhere/other.txt"), odds.join("out.txt")).unwrap();
    std::os::unix::fs::symlink("readme.txt", odds.join("in.txt")).unwrap();
    let fifo = std::ffi::CString::new(odds.join("pipe").to_str().unwrap()).unwrap();
    assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o644) }, 0, "no FIFO");
    let _socket = UnixListener::bind(odds.join("s.sock")).unwrap();
    mode(&odds.join(".config"), 0o000);

    let (ok, sent) = upload(&world, &tmp, &[&odds]);
    mode(&odds.join(".config"), 0o755);
    assert!(ok, "an unreadable dot folder failed the upload: {sent}");
    let entry = &sent["uploads"][0];
    assert_eq!(entry["files"], 1, "{sent}");
    // `.config/`, `.env`, the two symlinks, the FIFO and the socket.
    assert_eq!(entry["skipped"], 6, "{sent}");
    let at = PathBuf::from(entry["path"].as_str().unwrap());
    assert_eq!(std::fs::read_to_string(at.join("readme.txt")).unwrap(), "odds\n");

    // In git, a tracked file in the unreadable folder is skipped with it.
    let repo = home.join("projects/odds-repo");
    std::fs::create_dir_all(repo.join(".config")).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("readme.txt"), "repo\n").unwrap();
    std::fs::write(repo.join(".config/app.toml"), "fake-odds-tracked\n").unwrap();
    std::fs::write(repo.join(".config/more.toml"), "fake-odds-tracked\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "first"]);
    mode(&repo.join(".config"), 0o000);
    let (ok, sent) = upload(&world, &tmp, &[&repo]);
    mode(&repo.join(".config"), 0o755);
    assert!(ok, "an unreadable dot folder in git failed the upload: {sent}");
    assert_eq!(sent["uploads"][0]["files"], 1, "{sent}");
    assert_eq!(sent["uploads"][0]["skipped"], 1, "{sent}");
    for bytes in files_below(&world.machine_home) {
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("fake-odds"), "a left-out file reached the machine: {text}");
    }
}

/// A folder in a git working copy goes by git's ignore rules, its top or any
/// folder inside it, and listing it never runs what the repository's own
/// config names (here an fsmonitor that would leave a mark).
#[test]
fn an_upload_of_a_folder_in_git_keeps_its_ignore_rules_and_runs_none_of_its_config() {
    let world = World::new();
    let home = &world.home;
    let base = home.parent().unwrap().to_path_buf();
    let tmp = base.join("tmp");
    std::fs::create_dir_all(&tmp).unwrap();
    let repo = home.join("projects/repo");
    std::fs::create_dir_all(repo.join("docs")).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join(".gitignore"), "*.log\n").unwrap();
    std::fs::write(repo.join("docs/guide.md"), "the guide\n").unwrap();
    std::fs::write(repo.join("docs/build.log"), "fake-git-ignored\n").unwrap();
    std::fs::write(repo.join("top.txt"), "the top\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "first"]);
    let mark = base.join("fsmonitor-ran");
    let hook = repo.join(".git/watch");
    std::fs::write(&hook, format!("#!/bin/sh\ntouch '{}'\n", mark.display())).unwrap();
    std::fs::set_permissions(&hook, std::os::unix::fs::PermissionsExt::from_mode(0o755)).unwrap();
    git(&repo, &["config", "core.fsmonitor", hook.to_str().unwrap()]);

    for (folder, kept, files) in [
        (repo.join("docs"), vec!["guide.md"], 1),
        (repo.clone(), vec!["top.txt", "docs/guide.md"], 2),
    ] {
        let (ok, sent) = upload(&world, &tmp, &[&folder]);
        assert!(ok, "{} was refused: {sent}", folder.display());
        let entry = &sent["uploads"][0];
        assert_eq!(entry["folder"], true, "{sent}");
        assert_eq!(entry["files"], files, "{sent}");
        let at = PathBuf::from(entry["path"].as_str().unwrap());
        for name in kept {
            assert!(at.join(name).is_file(), "{name} did not go: {sent}");
        }
        for name in ["build.log", "docs/build.log", ".git", ".gitignore"] {
            assert!(std::fs::symlink_metadata(at.join(name)).is_err(), "{name} went: {sent}");
        }
    }
    assert!(!mark.exists(), "listing the folder ran the repository's fsmonitor");

    // A bare repository, in a plain folder or in a working copy, sends none
    // of its state; a bare repository dropped by itself is refused.
    let plain = home.join("projects/plain");
    std::fs::create_dir_all(&plain).unwrap();
    std::fs::write(plain.join("notes.txt"), "notes\n").unwrap();
    for holder in [&plain, &repo] {
        let bare = holder.join("mirror");
        git(holder, &["init", "-q", "--bare", "mirror"]);
        git(&bare, &["config", "remote.origin.url", "https://fake-git-token@example.com/r"]);
        let (ok, sent) = upload(&world, &tmp, &[holder]);
        assert!(ok, "{sent}");
        let at = PathBuf::from(sent["uploads"][0]["path"].as_str().unwrap());
        assert!(
            std::fs::symlink_metadata(at.join("mirror")).is_err(),
            "the bare repo went: {sent}"
        );
        for inside in [bare.clone(), bare.join("objects"), bare.join("refs")] {
            let (ok, answer) = upload(&world, &tmp, &[&inside]);
            assert!(!ok, "{} was uploaded: {answer}", inside.display());
        }
    }
    // A bare repository's shape counts with its objects a symlink, too.
    let linked = plain.join("linked");
    std::fs::create_dir_all(linked.join("refs")).unwrap();
    std::fs::create_dir_all(base.join("elsewhere-objects")).unwrap();
    std::os::unix::fs::symlink(base.join("elsewhere-objects"), linked.join("objects")).unwrap();
    std::fs::write(linked.join("HEAD"), "ref: refs/heads/main\n").unwrap();
    std::fs::write(linked.join("config"), "[remote \"o\"]\nurl = https://fake-git-linked@x/r\n")
        .unwrap();
    let (ok, sent) = upload(&world, &tmp, &[&plain]);
    assert!(ok, "{sent}");
    assert_eq!(sent["uploads"][0]["files"], 1, "{sent}");

    // Another repository inside a dropped folder stays whole, its ignored
    // files with it.
    let bundle = home.join("projects/bundle");
    std::fs::create_dir_all(bundle.join("inner")).unwrap();
    git(&bundle.join("inner"), &["init", "-q"]);
    std::fs::write(bundle.join("inner/.gitignore"), "private.json\n").unwrap();
    std::fs::write(bundle.join("inner/private.json"), "fake-git-nested\n").unwrap();
    std::fs::write(bundle.join("readme.md"), "bundle\n").unwrap();
    let (ok, sent) = upload(&world, &tmp, &[&bundle]);
    assert!(ok, "{sent}");
    assert_eq!(sent["uploads"][0]["files"], 1, "{sent}");

    // A `.git` pointing nowhere is refused, never walked plainly.
    let broken = home.join("projects/broken");
    std::fs::create_dir_all(&broken).unwrap();
    std::fs::write(broken.join(".git"), "gitdir: /nowhere/at/all\n").unwrap();
    std::fs::write(broken.join(".gitignore"), "private.json\n").unwrap();
    std::fs::write(broken.join("private.json"), "fake-git-broken\n").unwrap();
    let (ok, answer) = upload(&world, &tmp, &[&broken]);
    assert!(!ok, "a broken working copy was walked: {answer}");

    // A working copy git will not read (an extension it does not know) is
    // refused, never walked plainly past its ignore rules.
    let odd = home.join("projects/odd");
    std::fs::create_dir_all(&odd).unwrap();
    git(&odd, &["init", "-q"]);
    std::fs::write(odd.join(".gitignore"), "private.json\n").unwrap();
    std::fs::write(odd.join("private.json"), "fake-git-private\n").unwrap();
    git(&odd, &["config", "core.repositoryformatversion", "1"]);
    git(&odd, &["config", "extensions.cmuxUnknown", "true"]);
    let before = files_below(&world.machine_home).len();
    let (ok, answer) = upload(&world, &tmp, &[&odd]);
    assert!(!ok, "a repository git cannot read was walked: {answer}");
    assert_eq!(files_below(&world.machine_home).len(), before, "{answer}");
    for bytes in files_below(&world.machine_home) {
        assert!(!String::from_utf8_lossy(&bytes).contains("fake-git"), "an ignored file went");
    }
}

#[test]
fn an_upload_sends_the_files_the_person_dropped_and_refuses_secret_files() {
    let world = World::new();
    let home = &world.home;
    let base = home.parent().unwrap().to_path_buf();
    let tmp = base.join("tmp");
    for dir in ["Desktop", ".ssh", "projects"] {
        std::fs::create_dir_all(home.join(dir)).unwrap();
    }
    std::fs::create_dir_all(&tmp).unwrap();
    std::fs::create_dir_all(base.join("elsewhere")).unwrap();
    let dropped = home.join("Desktop/shot.png");
    std::fs::write(&dropped, b"\x89PNG fake image").unwrap();
    // The app writes a pasted image to its temporary folder first.
    std::fs::create_dir_all(tmp.join("cmux-pastes/.hidden")).unwrap();
    let pasted = tmp.join("cmux-pastes/pasted.png");
    std::fs::write(&pasted, b"\x89PNG pasted").unwrap();
    std::fs::write(home.join(".ssh/id_ed25519"), "fake-upload-key\n").unwrap();
    std::fs::write(home.join("projects/.env"), "TOKEN=fake-upload-env\n").unwrap();
    std::fs::write(base.join("elsewhere/other.txt"), "fake-upload-outside\n").unwrap();
    std::fs::write(tmp.join("loose.txt"), "fake-upload-loose\n").unwrap();
    std::fs::write(tmp.join("cmux-pastes/.hidden/x.txt"), "fake-upload-hidden\n").unwrap();
    std::os::unix::fs::symlink(home.join(".ssh/id_ed25519"), home.join("Desktop/key.png")).unwrap();

    let (ok, sent) = upload(&world, &tmp, &[&dropped, &pasted]);
    assert!(ok, "{sent}");
    let uploads = sent["uploads"].as_array().unwrap();
    assert_eq!(uploads.len(), 2, "{sent}");
    let at: Vec<PathBuf> =
        uploads.iter().map(|u| PathBuf::from(u["path"].as_str().unwrap())).collect();
    for (path, name) in at.iter().zip(["shot.png", "pasted.png"]) {
        assert!(path.starts_with(world.work().join("local/uploads")), "{sent}");
        assert_eq!(path.file_name().unwrap(), name, "{sent}");
    }
    assert_ne!(at[0].parent(), at[1].parent(), "each upload gets its own folder: {sent}");
    assert_eq!(std::fs::read(&at[0]).unwrap(), b"\x89PNG fake image");
    assert_eq!(std::fs::read(&at[1]).unwrap(), b"\x89PNG pasted");

    // Secret files, dot folders, a symlink into one, a file outside the home
    // and temporary folders: refused, and nothing of the call goes, not even
    // the file beside them that may.
    for refused in [
        home.join(".ssh/id_ed25519"),
        home.join("projects/.env"),
        home.join("Desktop/key.png"),
        base.join("elsewhere/other.txt"),
        tmp.join("loose.txt"),
        tmp.join("cmux-pastes/.hidden/x.txt"),
        home.join("Desktop/missing.png"),
        home.join(".ssh"),
    ] {
        let before = files_below(&world.machine_home).len();
        let (ok, answer) = upload(&world, &tmp, &[&dropped, &refused]);
        assert!(!ok, "{} was uploaded: {answer}", refused.display());
        assert_eq!(answer["error_code"], "upload_refused", "{answer}");
        assert_eq!(files_below(&world.machine_home).len(), before, "{answer}");
    }
    for bytes in files_below(&world.machine_home) {
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains("fake-upload"), "a refused file reached the machine: {text}");
    }
}
