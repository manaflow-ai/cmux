//! Push-on-send ([`super`]) against the real `FsService` behind a socket, with
//! this Mac's watcher ([`super::super::watch`]) running in a thread: what
//! changed arrives with one push and nothing else is read, nothing changed is
//! no request at all, skipped paths never go, the machine's own edits stay,
//! too much change rescans, and random edits end where a full push would.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

use cmux_tui_core::fs_ops::{FsService, Roots, stream};
use serde_json::{Value, json};

use super::super::listed::OPENED;
use super::super::watch::{Mark, Place};
use super::{Kept, Only, Pushed, keep, load, on_send_with, run_worker};

/// The state folder and watcher every test here shares (each test has folders of its own),
/// set for the calling test's thread only: other tests in this process see neither.
fn shared() -> &'static Place {
    static PLACE: OnceLock<(tempfile::TempDir, Place)> = OnceLock::new();
    let (state, place) = PLACE.get_or_init(|| {
        let state = tempfile::tempdir().unwrap();
        let place = Place::in_dir(state.path().join("link-sync-watch"), false);
        let serving = place.clone();
        std::thread::spawn(move || super::super::watch::serve(&serving).unwrap());
        for _ in 0..200 {
            if std::os::unix::net::UnixStream::connect(&place.socket).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        (state, place)
    });
    super::super::set_test_state_dir(Some(state.path().to_path_buf()));
    Place::set_for_tests(Some(place.clone()));
    place
}

/// A fake machine: the real fs ops over `home` on a socket, counting requests.
struct Machine {
    _dir: tempfile::TempDir,
    home: PathBuf,
    socket: PathBuf,
    asked: Arc<AtomicUsize>,
}

fn machine() -> Machine {
    let dir = tempfile::Builder::new().prefix("m").tempdir_in("/tmp").unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir_all(&home).unwrap();
    let home = std::fs::canonicalize(home).unwrap();
    let socket = dir.path().join("s");
    let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.clone()]))));
    let asked = Arc::new(AtomicUsize::new(0));
    let counted = asked.clone();
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let counted = counted.clone();
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    counted.fetch_add(1, Ordering::SeqCst);
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let reply = stream::answer(&id, service.call("local", &cmd, request));
                    if writer.write_all(format!("{reply}\n").as_bytes()).is_err() {
                        return;
                    }
                }
            });
        }
    });
    Machine { _dir: dir, home, socket, asked }
}

impl Machine {
    fn root(&self, name: &str) -> String {
        format!("{}/{name}", self.home.display())
    }
}

/// A folder of this Mac's with `files`.
fn folder(files: &[(&str, &str)]) -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let local = std::fs::canonicalize(dir.path()).unwrap().join("work");
    for (path, text) in files {
        write(&local, path, text);
    }
    std::fs::create_dir_all(&local).unwrap();
    (dir, local)
}

fn write(local: &Path, path: &str, text: &str) {
    let path = local.join(path);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

/// Every regular file below `root` but the sync's own record, with its text and whether it
/// runs.
fn tree(root: &Path) -> BTreeMap<String, (Vec<u8>, bool)> {
    let mut found = BTreeMap::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let meta = std::fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                stack.push(path);
            } else if meta.is_file() {
                let relative = path.strip_prefix(root).unwrap().to_str().unwrap().to_owned();
                // A push's record, and git's objects (whose packs depend on which pushes
                // made them: [`git_view`] compares what they hold).
                let own = matches!(relative.as_str(), ".cmux-sync.json" | ".git/cmux-sync.json")
                    || relative.starts_with(".git/objects/")
                    || relative.ends_with(".cmux-sync-part");
                if !own {
                    let runs = meta.permissions().mode() & 0o100 != 0;
                    found.insert(relative, (std::fs::read(&path).unwrap(), runs));
                }
            }
        }
    }
    found
}

/// The full push the chat's copy makes ([`super::super::push`]), which keeps the mark.
fn full_push(machine: &Machine, local: &Path, root: &str) {
    shared();
    super::super::push(&machine.socket, local, root).unwrap();
}

/// A push-on-send's worker pushing over the link with [`super::super::push_changed`].
fn on_send(machine: &Machine, local: &Path, root: &str) -> Value {
    let place = shared();
    run_worker(Some(place), local, root, &|only| changed_push(machine, local, root, only))
}

fn changed_push(
    machine: &Machine,
    local: &Path,
    root: &str,
    only: &Only,
) -> anyhow::Result<Pushed> {
    let summary = super::super::push_changed(&machine.socket, local, root, only)?;
    Ok(Pushed {
        mode: "copy",
        unchanged: summary.written == 0 && summary.deleted == 0,
        written: summary.written,
        deleted: summary.deleted,
        conflicts: summary.conflicts,
    })
}

/// What `run` opened of the files below `local`.
fn opened_below(local: &Path, run: impl FnOnce() -> Value) -> (Value, BTreeSet<String>) {
    let answer = run();
    let opened = OPENED
        .lock()
        .unwrap()
        .iter()
        .filter_map(|path| path.strip_prefix(local).ok())
        .map(|path| path.to_str().unwrap().to_owned())
        .collect();
    (answer, opened)
}

fn forget_opened(local: &Path) {
    OPENED.lock().unwrap().retain(|path| !path.starts_with(local));
}

/// Edits, a new file, a deleted one and a renamed one after the first push all arrive with
/// one push of what changed, and of this folder it opens only the files that changed.
#[test]
fn what_changed_arrives_in_one_push_and_nothing_else_is_read() {
    let files: Vec<(String, String)> =
        (0..40).map(|n| (format!("src/f{n}.txt"), format!("text {n}\n"))).collect();
    let files: Vec<(&str, &str)> = files.iter().map(|(p, t)| (p.as_str(), t.as_str())).collect();
    let (_dir, local) = folder(&files);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    write(&local, "src/f1.txt", "edited\n");
    write(&local, "src/new.txt", "new\n");
    std::fs::remove_file(local.join("src/f2.txt")).unwrap();
    std::fs::rename(local.join("src/f3.txt"), local.join("src/moved.txt")).unwrap();
    forget_opened(&local);
    let (answer, opened) = opened_below(&local, || on_send(&machine, &local, &root));
    assert_eq!(answer["state"], "sent", "{answer}");
    assert_eq!(answer["rescan"], false, "{answer}");
    assert_eq!(tree(&local), tree(Path::new(&root)));
    let allowed: BTreeSet<String> =
        ["src/f1.txt", "src/new.txt", "src/moved.txt"].into_iter().map(str::to_owned).collect();
    assert!(opened.is_subset(&allowed), "opened {opened:?}");
    assert!(opened.contains("src/f1.txt"), "opened {opened:?}");
    // And the next one finds nothing to send.
    let before = machine.asked.load(Ordering::SeqCst);
    assert_eq!(on_send(&machine, &local, &root)["state"], "unchanged");
    assert_eq!(machine.asked.load(Ordering::SeqCst), before);
}

/// With nothing changed since the push, a send answers at once and the machine hears no
/// request; the worker is never started.
#[test]
fn nothing_changed_is_no_request() {
    let (_dir, local) = folder(&[("a.txt", "a\n"), ("b/c.txt", "c\n")]);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    let before = machine.asked.load(Ordering::SeqCst);
    let never = |_: Duration| -> anyhow::Result<Option<Value>> {
        panic!("nothing changed: no push may start")
    };
    let answer = on_send_with(Some(shared()), &local, &root, Duration::from_secs(3), &never);
    assert_eq!(answer["state"], "unchanged", "{answer}");
    assert_eq!(machine.asked.load(Ordering::SeqCst), before);
}

/// A file saved the moment before the send is in it: the watcher's flush waits for its event.
#[test]
fn a_file_saved_right_before_the_send_goes() {
    let (_dir, local) = folder(&[("a.txt", "0\n")]);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    for round in 1..=20 {
        write(&local, "a.txt", &format!("{round}\n"));
        let answer = on_send(&machine, &local, &root);
        assert_eq!(answer["state"], "sent", "round {round}: {answer}");
        assert_eq!(
            std::fs::read_to_string(Path::new(&root).join("a.txt")).unwrap(),
            format!("{round}\n")
        );
    }
}

/// Secrets and heavy folders the push leaves out never go with a push of what changed, and
/// are never read.
#[test]
fn skipped_paths_never_go() {
    let (_dir, local) = folder(&[("package.json", "{}\n"), ("a.txt", "a\n")]);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    write(&local, ".env", "TOKEN=secret\n");
    write(&local, "node_modules/x/index.js", "x\n");
    write(&local, "a.txt", "b\n");
    forget_opened(&local);
    let (answer, opened) = opened_below(&local, || on_send(&machine, &local, &root));
    assert_eq!(answer["state"], "sent", "{answer}");
    assert!(!Path::new(&root).join(".env").exists());
    assert!(!Path::new(&root).join("node_modules").exists());
    assert!(!opened.contains(".env") && !opened.iter().any(|p| p.starts_with("node_modules")));
    assert_eq!(std::fs::read_to_string(Path::new(&root).join("a.txt")).unwrap(), "b\n");
}

/// A file the machine changed since the last push, changed here too, keeps the machine's
/// edit: it is named a conflict, its record stays the last push's, and Bring Back Local
/// sees the two edits as a conflict rather than taking either. A file only this Mac
/// changed still goes.
#[test]
fn a_machine_edit_since_the_last_push_is_kept() {
    let (_dir, local) = folder(&[("both.txt", "base\n"), ("mine.txt", "base\n")]);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    // The machine's edit lands a moment later than the push's write.
    std::thread::sleep(Duration::from_millis(20));
    std::fs::write(Path::new(&root).join("both.txt"), "machine edit\n").unwrap();
    write(&local, "both.txt", "mac edit\n");
    write(&local, "mine.txt", "mac only\n");
    let answer = on_send(&machine, &local, &root);
    assert_eq!(answer["conflicts"], json!(["both.txt"]), "{answer}");
    assert_eq!(
        std::fs::read_to_string(Path::new(&root).join("both.txt")).unwrap(),
        "machine edit\n"
    );
    assert_eq!(std::fs::read_to_string(Path::new(&root).join("mine.txt")).unwrap(), "mac only\n");
    // Looked at again on the next send, and still kept.
    let again = on_send(&machine, &local, &root);
    assert_eq!(again["conflicts"], json!(["both.txt"]), "{again}");
    // A pull merges against the last push's record: both changed, so nothing comes back.
    match super::super::pull::pull(&machine.socket, &local, &root).unwrap() {
        super::super::pull::Pulled::Conflict(conflicts, _, _) => {
            assert_eq!(conflicts, vec!["both.txt".to_string()]);
        }
        super::super::pull::Pulled::Done(summary) => panic!("pulled over a conflict: {summary}"),
    }
    assert_eq!(std::fs::read_to_string(local.join("both.txt")).unwrap(), "mac edit\n");
}

/// A file made on both sides since the last push (the agent's on the machine, the person's
/// here) is never written over: it is a conflict on every send until settled, and the record
/// leaves it out, so this Mac's base never claims the machine had the Mac's file.
#[test]
fn a_file_new_on_both_sides_is_kept() {
    let (_dir, local) = folder(&[("a.txt", "a\n")]);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    std::fs::write(Path::new(&root).join("NOTES.md"), "the agent's\n").unwrap();
    write(&local, "NOTES.md", "mine\n");
    write(&local, "new.txt", "only here\n");
    let answer = on_send(&machine, &local, &root);
    assert_eq!(answer["conflicts"], json!(["NOTES.md"]), "{answer}");
    assert_eq!(
        std::fs::read_to_string(Path::new(&root).join("NOTES.md")).unwrap(),
        "the agent's\n"
    );
    assert_eq!(std::fs::read_to_string(Path::new(&root).join("new.txt")).unwrap(), "only here\n");
    let again = on_send(&machine, &local, &root);
    assert_eq!(again["conflicts"], json!(["NOTES.md"]), "{again}");
    let kept = super::super::base::kept(&local, &root).unwrap().unwrap();
    assert!(!kept.files.contains_key("NOTES.md"));
    assert!(kept.files.contains_key("new.txt"));
}

/// More paths changed than an answer names: the push rescans, and everything still goes.
#[test]
fn too_many_changes_rescan() {
    // The folders are there before the push: each new file is one change the watcher sees.
    let keep: Vec<String> = (0..50).map(|n| format!("many/{n}/keep.txt")).collect();
    let keep: Vec<(&str, &str)> = keep.iter().map(|path| (path.as_str(), "k\n")).collect();
    let (_dir, local) = folder(&keep);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    for n in 0..=super::super::watch::MOST_ANSWERED {
        write(&local, &format!("many/{}/{n}.txt", n % 50), "x\n");
    }
    let answer = on_send(&machine, &local, &root);
    assert_eq!(answer["rescan"], true, "{answer}");
    assert_eq!(tree(&local), tree(Path::new(&root)));
}

/// A mark from a watcher that is no longer running (another session) rescans, never
/// "nothing changed".
#[test]
fn a_mark_of_another_watcher_session_rescans() {
    let (_dir, local) = folder(&[("a.txt", "a\n")]);
    let machine = machine();
    let root = machine.root("work");
    full_push(&machine, &local, &root);
    let stale = Kept { mark: Some(Mark { session: "gone".into(), seq: 1 }), ..Kept::default() };
    keep(shared(), &local, &root, &stale);
    write(&local, "a.txt", "b\n");
    let answer = on_send_with(Some(shared()), &local, &root, Duration::from_secs(10), &|_| {
        Ok(Some(on_send(&machine, &local, &root)))
    });
    assert_eq!(answer["rescan"], true, "{answer}");
    assert_eq!(std::fs::read_to_string(Path::new(&root).join("a.txt")).unwrap(), "b\n");
    assert_ne!(load(shared(), &local, &root).mark.unwrap().session, "gone");
}

/// A push still under way past the bound answers `arriving`, with a note for the agent; it
/// goes on behind. The worker is given the send's bound to wait at most.
#[test]
fn a_slow_push_answers_arriving() {
    let (_dir, local) = folder(&[("a.txt", "a\n")]);
    let answer = on_send_with(None, &local, "/r", Duration::from_millis(50), &|within| {
        assert!(within <= Duration::from_millis(50), "{within:?}");
        Ok(None)
    });
    assert_eq!(answer["state"], "arriving", "{answer}");
    assert!(answer["notice"].as_str().unwrap().contains("still"), "{answer}");
}

/// A push that fails before it answers is a failed send-time sync, never "unchanged".
#[test]
fn a_push_that_fails_answers_sync_failed() {
    let (_dir, local) = folder(&[("a.txt", "a\n")]);
    let answer = on_send_with(None, &local, "/r", Duration::from_secs(1), &|_| {
        anyhow::bail!("it ended without an answer")
    });
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["error_code"], "sync_failed", "{answer}");
}

/// A git working copy: an edit, a staged change and a commit go with a push of what
/// changed, and the machine ends as a full push leaves it.
#[test]
fn a_git_folder_ends_as_a_full_push_leaves_it() {
    let (_dir, local) = folder(&[("a.txt", "a\n"), ("src/b.rs", "fn b() {}\n")]);
    let git = |args: &[&str]| {
        let status = std::process::Command::new("git")
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .current_dir(&local)
            .status()
            .unwrap();
        assert!(status.success(), "git {args:?}");
    };
    git(&["init", "-q", "-b", "main"]);
    git(&["add", "-A"]);
    git(&["commit", "-qm", "one"]);
    let machine = machine();
    let (changed, full) = (machine.root("changed"), machine.root("full"));
    full_push(&machine, &local, &changed);
    write(&local, "a.txt", "edited\n");
    write(&local, "src/c.rs", "fn c() {}\n");
    git(&["add", "src/c.rs"]);
    write(&local, "d.txt", "d\n");
    git(&["add", "d.txt"]);
    git(&["commit", "-qm", "two"]);
    let answer = on_send(&machine, &local, &changed);
    assert_eq!(answer["state"], "sent", "{answer}");
    full_push(&machine, &local, &full);
    assert_eq!(tree(Path::new(&changed)), tree(Path::new(&full)));
    assert_eq!(git_view(Path::new(&changed)), git_view(Path::new(&full)));
    assert_eq!(git_view(Path::new(&changed)), git_view(&local));
}

/// What git says of the repository at `dir`: its history, index and status, and that every
/// object is whole.
fn git_view(dir: &Path) -> Vec<String> {
    let run = |args: &[&str]| {
        let output =
            std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
        assert!(output.status.success(), "git {args:?} in {}", dir.display());
        String::from_utf8(output.stdout).unwrap()
    };
    run(&["fsck", "--no-progress", "--no-dangling"]);
    vec![run(&["log", "--format=%H %s"]), run(&["ls-files", "-s"]), run(&["status", "--porcelain"])]
}

/// Random edits (new, changed, deleted, renamed files and folders, permission changes)
/// then a push-on-send leave the machine exactly as a full push of the same folder does,
/// round after round.
#[test]
fn random_edits_then_push_on_send_equal_a_full_push() {
    let (_dir, local) = folder(&[("seed.txt", "seed\n")]);
    let machine = machine();
    let (changed, full) = (machine.root("changed"), machine.root("full"));
    full_push(&machine, &local, &changed);
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut next = |bound: u64| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        state % bound
    };
    for round in 0..12 {
        for _ in 0..(1 + next(15)) {
            let files: Vec<String> = tree(&local).into_keys().collect();
            let pick = |n: u64| files.get(n as usize % files.len().max(1)).cloned();
            match next(7) {
                0 | 1 => write(
                    &local,
                    &format!("d{}/f{}.txt", next(4), next(30)),
                    &format!("{}\n", next(1000)),
                ),
                2 => {
                    if let Some(file) = pick(next(1000)) {
                        write(&local, &file, &format!("edit {}\n", next(1000)));
                    }
                }
                3 => {
                    if let Some(file) = pick(next(1000)) {
                        let _ = std::fs::remove_file(local.join(file));
                    }
                }
                4 => {
                    if let Some(file) = pick(next(1000)) {
                        let to = format!("r{}/moved{}.txt", next(3), next(1000));
                        std::fs::create_dir_all(local.join(&to).parent().unwrap()).unwrap();
                        let _ = std::fs::rename(local.join(file), local.join(to));
                    }
                }
                5 => {
                    let from = local.join(format!("d{}", next(4)));
                    let to = local.join(format!("moved-dir-{}", next(1000)));
                    let _ = std::fs::rename(from, to);
                }
                _ => {
                    if let Some(file) = pick(next(1000)) {
                        let mode = if next(2) == 0 { 0o755 } else { 0o644 };
                        let _ = std::fs::set_permissions(
                            local.join(file),
                            std::fs::Permissions::from_mode(mode),
                        );
                    }
                }
            }
        }
        let answer = on_send(&machine, &local, &changed);
        assert_eq!(answer["ok"], true, "round {round}: {answer}");
        let _ = std::fs::remove_dir_all(&full);
        full_push(&machine, &local, &full);
        assert_eq!(tree(Path::new(&changed)), tree(Path::new(&full)), "round {round}");
        assert_eq!(tree(&local), tree(Path::new(&changed)), "round {round}");
        // This Mac's base copy is what a full push leaves too (a pull merges against it).
        let kept = |root: &str| super::super::base::kept(&local, root).unwrap().unwrap().files;
        let shape =
            |files: BTreeMap<String, super::super::Pushed>| -> BTreeMap<String, (String, u32)> {
                files
                    .into_iter()
                    .map(|(path, pushed)| (path, (pushed.sha256, pushed.permissions)))
                    .collect()
            };
        assert_eq!(shape(kept(&changed)), shape(kept(&full)), "round {round}");
    }
}
