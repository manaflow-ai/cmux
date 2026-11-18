//! `project-pull`: each rule of the way back and of its trust boundary, against a fake machine
//! daemon that answers `projfs.upper` from a list and `fs.stat` / `fs.read` from a folder that
//! stands for the merged (mounted) folder; then the ledger across pulls, and a seeded randomized
//! run ([`random`]).

use std::collections::BTreeSet;
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime};

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::{RECORD, Record, build, stage};
use super::*;

#[path = "projected_pull_ledger_tests.rs"]
mod journal;
#[path = "projected_pull_moves_tests.rs"]
mod moves;
#[path = "projected_pull_random_tests.rs"]
mod random;

const STATE: &str = "/home/cmux/.projfs";

/// What the fake daemon answers from.
#[derive(Default)]
struct State {
    /// The merged folder on the machine.
    dir: PathBuf,
    upper: Vec<Value>,
    /// Paths whose `fs.read` drops the connection.
    broken: BTreeSet<String>,
    /// Paths whose `fs.read` the machine refuses (an I/O error there).
    refusing: BTreeSet<String>,
    /// Paths whose `fs.read` never ends: every answer is a part with more to come.
    endless: BTreeSet<String>,
    /// Every path the Mac asked about.
    asked: Vec<String>,
}

/// A machine daemon on a socket of its own.
struct Daemon {
    _dir: tempfile::TempDir,
    socket: PathBuf,
    state: Arc<Mutex<State>>,
}

impl Daemon {
    fn start() -> Daemon {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("d.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        let state = Arc::new(Mutex::new(State::default()));
        let shared = state.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                let state = shared.clone();
                std::thread::spawn(move || serve(stream, &state));
            }
        });
        Daemon { _dir: dir, socket, state }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap()
    }
}

fn serve(stream: UnixStream, state: &Mutex<State>) {
    let mut out = stream.try_clone().unwrap();
    for line in BufReader::new(stream).lines().map_while(Result::ok) {
        let request: Value = serde_json::from_str(&line).unwrap();
        let Some(mut answer) = answer(&request, state) else { return };
        answer["id"] = request["id"].clone();
        if out.write_all(format!("{answer}\n").as_bytes()).is_err() {
            return;
        }
    }
}

fn display(mode: u32) -> String {
    (0..9)
        .map(|bit| if mode & (0o400 >> bit) == 0 { '-' } else { b"rwx"[bit % 3] as char })
        .collect()
}

fn answer(request: &Value, state: &Mutex<State>) -> Option<Value> {
    let mut state = state.lock().unwrap();
    let path = request["path"].as_str().unwrap_or_default().to_owned();
    let refuse = |code: &str| json!({ "ok": false, "error_code": code, "error": code });
    if !path.is_empty() {
        assert!(Path::new(&path).starts_with(&state.dir), "asked outside the folder: {path}");
        state.asked.push(path.clone());
    }
    let data = match request["cmd"].as_str().unwrap() {
        "projfs.upper" => {
            assert_eq!(request["state"], STATE);
            json!({ "ok": true, "changes": state.upper })
        }
        "fs.stat" => {
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                return Some(refuse("fs.not_found"));
            };
            let kind = if meta.is_symlink() {
                "symlink"
            } else if meta.is_dir() {
                "dir"
            } else {
                "file"
            };
            let mtime = meta.mtime() * 1000 + meta.mtime_nsec() / 1_000_000;
            json!({ "kind": kind, "size": meta.size(), "mtime": mtime,
                    "mode_display": display(meta.mode()),
                    "revision": format!("s{}-m{mtime}", meta.size()) })
        }
        "fs.read" => {
            if state.broken.contains(&path) {
                return None;
            }
            if state.refusing.contains(&path) {
                return Some(refuse("fs.io"));
            }
            if state.endless.contains(&path) {
                let part = base64::engine::general_purpose::STANDARD.encode(vec![b'x'; 1 << 20]);
                return Some(json!({ "ok": true, "data": {
                    "bytes_base64": part, "truncated": true, "size": u64::MAX } }));
            }
            let Ok(bytes) = std::fs::read(&path) else { return Some(refuse("fs.not_found")) };
            let offset = usize::try_from(request["offset"].as_u64().unwrap()).unwrap();
            let max = usize::try_from(request["max_bytes"].as_u64().unwrap()).unwrap();
            let start = offset.min(bytes.len());
            let end = offset.saturating_add(max).min(bytes.len());
            json!({ "bytes_base64": base64::engine::general_purpose::STANDARD.encode(&bytes[start..end]),
                    "truncated": end < bytes.len(), "size": bytes.len() })
        }
        other => return Some(refuse(&format!("unknown.{other}"))),
    };
    Some(json!({ "ok": true, "data": data }))
}

fn put(top: &Path, relative: &str, bytes: &[u8]) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

/// The machine's clock: every machine write gets a later whole second, so its revision (size
/// and mtime in milliseconds) always changes.
static CLOCK: AtomicU64 = AtomicU64::new(1_800_000_000);

/// A Mac folder projected as `start-chat project` keeps it, the machine's merged folder (a copy
/// of it at the start), and a folder outside both.
struct Fixture<'d> {
    _dir: tempfile::TempDir,
    daemon: &'d Daemon,
    root: PathBuf,
    kept: PathBuf,
    machine: PathBuf,
    outside: PathBuf,
}

impl<'d> Fixture<'d> {
    fn new(daemon: &'d Daemon, files: &[(&str, &[u8])]) -> Self {
        Self::made(daemon, files, |_| {})
    }

    /// With `prepare` run on this Mac's folder before it is listed.
    fn made(daemon: &'d Daemon, files: &[(&str, &[u8])], prepare: impl Fn(&Path)) -> Self {
        let dir = tempfile::tempdir().unwrap();
        let base = std::fs::canonicalize(dir.path()).unwrap();
        let (root, kept) = (base.join("mac"), base.join("kept"));
        let (machine, outside) = (base.join("machine"), base.join("outside"));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&machine).unwrap();
        prepare(&root);
        for (path, bytes) in files {
            put(&root, path, bytes);
            put(&machine, path, bytes);
        }
        put(&outside, "secret.txt", b"outside");
        let listing = crate::link::sync_cli::stat_listing(&root).unwrap();
        let (manifest, rewritten) = build(&root, &listing, 1).unwrap();
        stage(&kept, &manifest.encode().unwrap(), &rewritten).unwrap();
        let record = Record {
            mount: "p-test".into(),
            account: "u1".into(),
            machine: "m1".into(),
            local_root: root.display().to_string(),
            machine_path: machine.display().to_string(),
            folder: machine.display().to_string(),
            state_dir: STATE.into(),
            socket: daemon.socket.display().to_string(),
            made_at: 1,
        };
        std::fs::write(kept.join(RECORD), serde_json::to_vec(&record).unwrap()).unwrap();
        let mut state = daemon.state();
        state.dir.clone_from(&machine);
        state.upper.clear();
        state.broken.clear();
        state.refusing.clear();
        state.endless.clear();
        state.asked.clear();
        drop(state);
        Fixture { _dir: dir, daemon, root, kept, machine, outside }
    }

    fn upper(&self, changes: &Value) {
        self.daemon.state().upper = changes.as_array().unwrap().clone();
    }

    /// Writes a file on the machine, at a later mtime than any before.
    fn machine_write(&self, relative: &str, bytes: &[u8]) {
        put(&self.machine, relative, bytes);
        let seconds = CLOCK.fetch_add(1, Ordering::Relaxed);
        let file = std::fs::File::options().write(true).open(self.machine.join(relative)).unwrap();
        file.set_modified(SystemTime::UNIX_EPOCH + Duration::from_secs(seconds)).unwrap();
    }

    fn pull(&self) -> Value {
        run(&self.kept, None, false)
    }

    fn dry(&self) -> Value {
        run(&self.kept, None, true)
    }

    fn mac(&self, relative: &str) -> Option<Vec<u8>> {
        std::fs::read(self.root.join(relative)).ok()
    }

    /// Every name in this Mac's folder, folders too.
    fn tree(&self) -> BTreeSet<String> {
        tree(&self.root)
    }
}

fn tree(top: &Path) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut stack = vec![top.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            out.insert(path.strip_prefix(top).unwrap().display().to_string());
            if entry.file_type().unwrap().is_dir() {
                stack.push(path);
            }
        }
    }
    out
}

fn change(path: &str, kind: &str) -> Value {
    json!({ "path": path, "kind": kind })
}

fn ok(summary: &Value) -> &Value {
    assert_eq!(summary["ok"], true, "{summary}");
    summary
}

fn beside_of(summary: &Value, path: &str) -> String {
    let conflict = summary["conflicts"].as_array().unwrap().iter().find(|c| c["path"] == path);
    conflict.and_then(|c| c["beside"].as_str()).unwrap_or_else(|| panic!("{summary}")).to_owned()
}

fn refused(summary: &Value) -> Vec<(String, String)> {
    let list = summary["refused"].as_array().unwrap();
    let text = |c: &Value, k: &str| c[k].as_str().unwrap().to_owned();
    list.iter().map(|c| (text(c, "path"), text(c, "reason"))).collect()
}

#[test]
fn a_new_file_is_created_and_an_unchanged_one_replaced() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"old"), ("d/b.txt", b"b")]);
    f.machine_write("a.txt", b"new from the machine");
    f.machine_write("d/n/new.txt", b"made there");
    f.upper(&json!([
        change("a.txt", "file"),
        change("d", "dir"),
        change("d/n", "dir"),
        change("d/n/new.txt", "file")
    ]));
    let summary = f.pull();
    assert_eq!(ok(&summary)["mount"], "p-test");
    assert_eq!(f.mac("a.txt").unwrap(), b"new from the machine");
    assert_eq!(f.mac("d/n/new.txt").unwrap(), b"made there");
    assert_eq!(summary["created"], 2, "the folder and the file: {summary}");
    assert_eq!(summary["applied"], 3);
    assert_eq!(summary["bytes"], 30);
    assert!(summary["conflicts"].as_array().unwrap().is_empty());
}

#[test]
fn a_file_this_mac_changed_meanwhile_is_kept_and_the_machines_goes_beside() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"base")]);
    put(&f.root, "a.txt", b"edited on this Mac");
    put(&f.root, "mine.txt", b"made on this Mac");
    f.machine_write("a.txt", b"edited on the machine");
    f.machine_write("mine.txt", b"made on the machine");
    f.upper(&json!([change("a.txt", "file"), change("mine.txt", "file")]));
    let summary = f.pull();
    assert_eq!(f.mac("a.txt").unwrap(), b"edited on this Mac");
    assert_eq!(f.mac("mine.txt").unwrap(), b"made on this Mac", "no base: a conflict");
    assert_eq!(beside_of(ok(&summary), "a.txt"), "a.txt.cmux-sync-conflict");
    assert_eq!(f.mac("a.txt.cmux-sync-conflict").unwrap(), b"edited on the machine");
    assert_eq!(f.mac(&beside_of(&summary, "mine.txt")).unwrap(), b"made on the machine");
    assert_eq!(summary["conflicts"][0]["kept"], "a.txt");
    assert_eq!(summary["applied"], 0);
}

#[test]
fn a_delete_removes_only_what_still_equals_its_base() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a"), ("b.txt", b"b")]);
    put(&f.root, "b.txt", b"edited on this Mac");
    for path in ["a.txt", "b.txt"] {
        std::fs::remove_file(f.machine.join(path)).unwrap();
    }
    f.upper(&json!([change("a.txt", "delete"), change("b.txt", "delete")]));
    let summary = f.pull();
    assert_eq!(ok(&summary)["deleted"], 1);
    assert_eq!(f.mac("a.txt"), None);
    assert_eq!(f.mac("b.txt").unwrap(), b"edited on this Mac");
    assert_eq!(summary["conflicts"], json!([{ "path": "b.txt", "kept": "b.txt", "beside": null }]));
}

#[test]
fn a_deleted_folder_takes_only_what_the_machine_was_shown() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("d/x.txt", b"x"), ("d/y.txt", b"y"), ("d/e/z.txt", b"z")]);
    put(&f.root, "d/y.txt", b"edited on this Mac");
    put(&f.root, "d/new.txt", b"made on this Mac");
    std::fs::remove_dir_all(f.machine.join("d")).unwrap();
    f.upper(&json!([change("d", "delete")]));
    let summary = f.pull();
    assert_eq!(f.mac("d/x.txt"), None);
    assert_eq!(f.mac("d/e/z.txt"), None);
    assert!(!f.root.join("d/e").exists(), "an emptied folder goes");
    assert_eq!(f.mac("d/y.txt").unwrap(), b"edited on this Mac");
    assert_eq!(f.mac("d/new.txt").unwrap(), b"made on this Mac");
    assert_eq!(ok(&summary)["conflicts"], json!([{ "path": "d", "kept": "d", "beside": null }]));
    // A folder this Mac left alone goes whole.
    let f = Fixture::new(&daemon, &[("d/x.txt", b"x"), ("d/e/z.txt", b"z")]);
    std::fs::remove_dir_all(f.machine.join("d")).unwrap();
    f.upper(&json!([change("d", "delete")]));
    assert_eq!(ok(&f.pull())["deleted"], 4, "two files, two folders");
    assert!(!f.root.join("d").exists());
}

#[test]
fn a_folder_is_made_and_an_opaque_one_deletes_what_it_hides() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("d/x.txt", b"x"), ("d/s/y.txt", b"y"), ("keep.txt", b"k")]);
    std::fs::remove_dir_all(f.machine.join("d")).unwrap();
    f.machine_write("d/n.txt", b"new");
    std::fs::create_dir(f.machine.join("empty")).unwrap();
    f.upper(&json!([change("d", "opaque_dir"), change("d/n.txt", "file"), change("empty", "dir")]));
    let summary = f.pull();
    assert_eq!(ok(&summary)["conflicts"], json!([]));
    assert_eq!(f.mac("d/x.txt"), None);
    assert!(!f.root.join("d/s").exists());
    assert_eq!(f.mac("d/n.txt").unwrap(), b"new");
    assert!(f.root.join("empty").is_dir());
    assert_eq!(f.mac("keep.txt").unwrap(), b"k");
}

#[test]
fn a_symlink_is_made_from_its_text_and_one_leaving_the_folder_is_refused() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.upper(&json!([
        { "path": "l", "kind": "symlink", "link": "a.txt" },
        { "path": "out", "kind": "symlink", "link": "../outside/secret.txt" },
        { "path": "abs", "kind": "symlink", "link": "/etc/passwd" },
    ]));
    let summary = f.pull();
    assert_eq!(std::fs::read_link(f.root.join("l")).unwrap(), Path::new("a.txt"));
    assert!(std::fs::symlink_metadata(f.root.join("out")).is_err());
    assert!(std::fs::symlink_metadata(f.root.join("abs")).is_err());
    let reasons: BTreeSet<String> = refused(ok(&summary)).into_iter().map(|(_, r)| r).collect();
    assert_eq!(reasons, BTreeSet::from(["link_leaves_folder".to_owned()]));
    assert_eq!(summary["created"], 1);
}

#[test]
fn a_permission_change_applies_the_mode_and_never_the_owner() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("run.sh", b"#!/bin/sh\n")]);
    let mode = |top: &Path| std::fs::metadata(top.join("run.sh")).unwrap().mode() & 0o777;
    std::fs::set_permissions(f.machine.join("run.sh"), std::fs::Permissions::from_mode(0o775))
        .unwrap();
    f.upper(&json!([change("run.sh", "metadata")]));
    let summary = f.pull();
    assert_eq!(ok(&summary)["applied"], 1);
    assert_eq!(mode(&f.root), 0o755, "the synced permissions of 0775");
    assert_eq!(summary["bytes"], 0, "no bytes are read for it");
    assert_eq!(ok(&f.pull())["unchanged"], 1);
}

#[test]
fn a_moved_folder_comes_back_as_a_delete_and_a_create() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("d/x.txt", b"x"), ("d/s/y.txt", b"y")]);
    std::fs::rename(f.machine.join("d"), f.machine.join("e")).unwrap();
    f.machine_write("e/x.txt", b"x, edited after the move");
    f.upper(&json!([
        change("d", "delete"),
        { "path": "e", "kind": "redirect", "from": "/d" },
        change("e/x.txt", "file"),
    ]));
    let summary = f.pull();
    assert_eq!(ok(&summary)["conflicts"], json!([]), "{summary}");
    assert!(!f.root.join("d").exists());
    assert_eq!(f.mac("e/x.txt").unwrap(), b"x, edited after the move");
    assert_eq!(f.mac("e/s/y.txt").unwrap(), b"y");
    let again = f.pull();
    assert_eq!(ok(&again)["applied"], 0, "{again}");
}

#[test]
fn a_move_this_mac_cannot_map_refuses_the_whole_pull() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("d/x.txt", b"x")]);
    f.machine_write("new.txt", b"would be created");
    f.upper(
        &json!([change("new.txt", "file"), { "path": "e", "kind": "redirect", "from": "/nope" }]),
    );
    let before = f.tree();
    let summary = f.pull();
    assert_eq!(summary["ok"], false);
    assert_eq!(summary["code"], "redirect_unmapped");
    assert_eq!(f.tree(), before, "nothing changed");
    assert!(!f.kept.join(PULLED).exists());
}

#[test]
fn an_unsupported_change_is_refused_and_skipped() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.upper(&json!([{ "path": "a.txt", "kind": "unsupported", "reason": "a metacopy file" }]));
    let summary = f.pull();
    let want = vec![("a.txt".to_owned(), "unsupported: a metacopy file".to_owned())];
    assert_eq!(refused(ok(&summary)), want);
    assert_eq!(f.mac("a.txt").unwrap(), b"a");
}

#[test]
fn gits_own_files_are_skipped_and_counted() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    for path in [".git/config", "sub/.GIT/HEAD"] {
        f.machine_write(path, b"[core]");
    }
    f.upper(&json!([
        change(".git", "dir"),
        change(".git/config", "file"),
        change("sub/.GIT/HEAD", "file"),
        change(".git/index", "delete")
    ]));
    let summary = f.pull();
    assert_eq!(ok(&summary)["skipped_git"], 4);
    assert_eq!(f.mac(".git/config"), None);
    assert!(!f.root.join("sub").exists());
}

#[test]
fn a_new_name_folding_onto_another_is_a_conflict() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("Readme.md", b"this Mac's"), ("Docs/a.txt", b"a")]);
    f.machine_write("README.md", b"the machine's");
    f.machine_write("docs/b.txt", b"b");
    f.upper(&json!([
        change("README.md", "file"),
        change("docs", "dir"),
        change("docs/b.txt", "file")
    ]));
    let summary = f.pull();
    assert_eq!(f.mac("Readme.md").unwrap(), b"this Mac's");
    let beside = beside_of(ok(&summary), "README.md");
    assert_eq!(f.mac(&beside).unwrap(), b"the machine's");
    assert!(f.tree().iter().all(|name| !name.starts_with("docs")), "{:?}", f.tree());
    assert_eq!(summary["created"], 0);
}

#[test]
fn paths_the_walker_would_not_list_are_never_written() {
    let daemon = Daemon::start();
    let git = |root: &Path| {
        let status = Command::new("git").arg("init").arg("-q").arg(root).status().unwrap();
        assert!(status.success());
        put(root, ".gitignore", b"*.log\n");
    };
    let f = Fixture::made(&daemon, &[("package.json", b"{}"), ("a.txt", b"a")], git);
    let made = [
        "debug.log",
        ".env",
        ".ssh/id_ed25519",
        "node_modules/x.js",
        ".cmux-sync-x",
        "a.txt.cmux-sync-conflict",
    ];
    for path in made {
        f.machine_write(path, b"must stay on the machine");
    }
    let mut changes: Vec<Value> = made.iter().map(|path| change(path, "file")).collect();
    changes.push(change("node_modules", "dir"));
    f.upper(&Value::Array(changes));
    let summary = f.pull();
    let mut got = refused(ok(&summary));
    got.sort();
    let want = [
        (".cmux-sync-x", "reserved"),
        (".env", "secret"),
        (".ssh/id_ed25519", "secret"),
        ("a.txt.cmux-sync-conflict", "reserved"),
        ("debug.log", "ignored"),
        ("node_modules", "heavy"),
        ("node_modules/x.js", "heavy"),
    ];
    let want: Vec<(String, String)> =
        want.iter().map(|(p, r)| ((*p).to_owned(), (*r).to_owned())).collect();
    assert_eq!(got, want);
    for path in made {
        assert_eq!(f.mac(path), None, "{path}");
    }
}

#[test]
fn trust_every_machine_path_must_be_plain() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    let before = tree(&f.outside);
    let paths =
        ["../outside/secret.txt", "/etc/passwd", "a//b", "./a.txt", "d/../a.txt", "a\0b", ""];
    f.upper(&Value::Array(paths.iter().map(|path| change(path, "delete")).collect()));
    let summary = f.pull();
    let got = refused(ok(&summary));
    assert_eq!(got.len(), paths.len());
    assert!(got.iter().all(|(_, reason)| reason == "unsafe_path"), "{got:?}");
    assert_eq!(f.mac("a.txt").unwrap(), b"a");
    assert_eq!(tree(&f.outside), before);
    assert_eq!(std::fs::read(f.outside.join("secret.txt")).unwrap(), b"outside");
    assert!(daemon.state().asked.is_empty(), "no unsafe path is asked of the machine");
}

#[test]
fn trust_no_folder_on_the_way_may_be_a_symlink() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("d/secret.txt", b"in the folder")]);
    std::fs::rename(f.root.join("d"), f.root.join("d-old")).unwrap();
    std::os::unix::fs::symlink(&f.outside, f.root.join("d")).unwrap();
    f.machine_write("d/secret.txt", b"over the outside file");
    f.machine_write("d/new.txt", b"a new file outside");
    f.upper(&json!([change("d/secret.txt", "file"), change("d/new.txt", "file")]));
    let summary = f.pull();
    let got = refused(ok(&summary));
    assert_eq!(got.len(), 2, "{summary}");
    assert!(got.iter().all(|(_, reason)| reason == "symlink_on_the_way"));
    assert_eq!(std::fs::read(f.outside.join("secret.txt")).unwrap(), b"outside");
    assert!(!f.outside.join("new.txt").exists());
}

#[test]
fn trust_writes_are_a_new_file_renamed_into_place() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"old"), ("b.txt", b"old b")]);
    let inode = std::fs::metadata(f.root.join("a.txt")).unwrap().ino();
    let held = std::fs::File::open(f.root.join("a.txt")).unwrap();
    f.machine_write("a.txt", b"new");
    f.upper(&json!([change("a.txt", "file")]));
    ok(&f.pull());
    assert_ne!(std::fs::metadata(f.root.join("a.txt")).unwrap().ino(), inode, "a new file");
    let mut old = String::new();
    std::io::Read::read_to_string(&mut &held, &mut old).unwrap();
    assert_eq!(old, "old", "the old file was never written over");
    // A read that breaks partway leaves the old file whole and nothing beside it.
    f.machine_write("b.txt", b"new b");
    let broken = f.machine.join("b.txt").display().to_string();
    daemon.state().broken.insert(broken);
    f.upper(&json!([change("b.txt", "file")]));
    let summary = f.pull();
    assert_eq!(summary["ok"], false, "{summary}");
    assert_eq!(f.mac("b.txt").unwrap(), b"old b");
    let names = f.tree();
    assert!(names.iter().all(|name| !name.contains(".cmux-pull")), "{names:?}");
}

#[test]
fn trust_a_read_past_the_stated_size_is_refused_and_its_part_file_removed() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"old")]);
    f.machine_write("big.bin", b"12 bytes said");
    f.machine_write("a.txt", b"new");
    let endless = f.machine.join("big.bin").display().to_string();
    daemon.state().endless.insert(endless);
    f.upper(&json!([change("a.txt", "file"), change("big.bin", "file")]));
    let summary = f.pull();
    assert_eq!(refused(ok(&summary)), [("big.bin".to_owned(), "machine_grew".to_owned())]);
    assert_eq!(f.mac("big.bin"), None);
    assert_eq!(f.mac("a.txt").unwrap(), b"new", "the rest of the pull goes on");
    let names = f.tree();
    assert!(names.iter().all(|name| !name.contains(".cmux-pull")), "{names:?}");
}

#[test]
fn trust_nothing_is_written_outside_the_folder() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    std::os::unix::fs::symlink(&f.outside, f.root.join("out")).unwrap();
    std::os::unix::fs::symlink(f.outside.join("secret.txt"), f.root.join("s")).unwrap();
    let before = tree(&f.outside);
    f.machine_write("out/secret.txt", b"x");
    f.machine_write("s", b"over the link");
    f.upper(&json!([
        change("out/secret.txt", "file"),
        change("out/f.txt", "delete"),
        change("s", "file"),
        change("out", "delete")
    ]));
    let summary = f.pull();
    let got = refused(ok(&summary));
    assert_eq!(got.len(), 2, "the two below the link: {summary}");
    assert_eq!(f.mac(&beside_of(&summary, "s")).unwrap(), b"over the link", "inside the folder");
    assert_eq!(tree(&f.outside), before);
    assert_eq!(std::fs::read(f.outside.join("secret.txt")).unwrap(), b"outside");
    assert!(std::fs::symlink_metadata(f.root.join("out")).unwrap().is_symlink(), "{summary}");
}

#[test]
fn a_second_pull_after_no_machine_change_applies_nothing() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.machine_write("a.txt", b"edited");
    f.machine_write("n/new.txt", b"new");
    f.upper(&json!([change("a.txt", "file"), change("n", "dir"), change("n/new.txt", "file")]));
    assert_eq!(ok(&f.pull())["applied"], 3);
    let again = f.pull();
    assert_eq!(ok(&again)["applied"], 0, "{again}");
    assert_eq!(again["unchanged"], 3);
    assert_eq!(again["bytes"], 0);
}

#[test]
fn a_second_machine_edit_of_a_file_brought_back_applies_cleanly() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.machine_write("a.txt", b"first");
    f.machine_write("new.txt", b"made");
    f.upper(&json!([change("a.txt", "file"), change("new.txt", "file")]));
    ok(&f.pull());
    f.machine_write("a.txt", b"second");
    f.machine_write("new.txt", b"made, then edited");
    let summary = f.pull();
    assert_eq!(ok(&summary)["applied"], 2, "{summary}");
    assert_eq!(summary["conflicts"], json!([]));
    assert_eq!(f.mac("a.txt").unwrap(), b"second");
    assert_eq!(f.mac("new.txt").unwrap(), b"made, then edited");
}

#[test]
fn a_mac_edit_between_two_pulls_of_the_same_file_is_a_conflict() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.machine_write("a.txt", b"first");
    f.upper(&json!([change("a.txt", "file")]));
    ok(&f.pull());
    put(&f.root, "a.txt", b"edited on this Mac");
    f.machine_write("a.txt", b"second");
    let summary = f.pull();
    assert_eq!(f.mac("a.txt").unwrap(), b"edited on this Mac");
    assert_eq!(f.mac(&beside_of(ok(&summary), "a.txt")).unwrap(), b"second");
    f.machine_write("a.txt", b"third");
    let third = f.pull();
    assert_eq!(f.mac(&beside_of(ok(&third), "a.txt")).unwrap(), b"third", "{third}");
    assert_eq!(f.mac("a.txt").unwrap(), b"edited on this Mac");
}

#[test]
fn a_file_the_machine_made_then_deleted_is_deleted_here() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    f.machine_write("tmp.txt", b"scratch");
    f.machine_write("kept.txt", b"scratch");
    f.upper(&json!([change("tmp.txt", "file"), change("kept.txt", "file")]));
    ok(&f.pull());
    put(&f.root, "kept.txt", b"this Mac took it up");
    f.upper(&json!([]));
    let summary = f.pull();
    assert_eq!(f.mac("tmp.txt"), None);
    assert_eq!(ok(&summary)["deleted"], 1);
    assert_eq!(f.mac("kept.txt").unwrap(), b"this Mac took it up");
    assert_eq!(summary["conflicts"][0]["path"], "kept.txt");
}

#[test]
fn a_dry_run_reports_the_same_and_changes_nothing() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a"), ("b.txt", b"b"), ("c.txt", b"c")]);
    put(&f.root, "b.txt", b"edited on this Mac");
    f.machine_write("a.txt", b"edited");
    f.machine_write("b.txt", b"edited too");
    f.machine_write("new.txt", b"new");
    std::fs::remove_file(f.machine.join("c.txt")).unwrap();
    f.upper(&json!([
        change("a.txt", "file"),
        change("b.txt", "file"),
        change("new.txt", "file"),
        change("c.txt", "delete")
    ]));
    let before = f.tree();
    let dry = f.dry();
    assert_eq!(f.tree(), before);
    assert_eq!(f.mac("a.txt").unwrap(), b"a");
    assert!(!f.kept.join(PULLED).exists());
    assert_eq!(ok(&dry)["dry_run"], true);
    let real = f.pull();
    for key in ["applied", "created", "deleted", "conflicts", "refused", "skipped_git"] {
        assert_eq!(dry[key], real[key], "{key}: {dry} {real}");
    }
}

#[test]
fn a_failure_is_one_line_with_its_code() {
    let daemon = Daemon::start();
    let f = Fixture::new(&daemon, &[("a.txt", b"a")]);
    let gone = run(&f.kept.join("nope"), None, false);
    assert_eq!((gone["ok"].clone(), gone["code"].clone()), (json!(false), json!("record_missing")));
    let away = run(&f.kept, Some(f.kept.join("no.sock")), false);
    assert_eq!(away["code"], "unreachable", "{away}");
    std::fs::write(f.kept.join(PULLED), b"not json").unwrap();
    assert_eq!(f.pull()["code"], "ledger_unreadable");
}
