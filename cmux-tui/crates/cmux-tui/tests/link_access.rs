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
