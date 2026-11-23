//! Bring Back over a projected folder (RFD 0007; Leo: "each chat gets its own copy-on-write layer
//! over the projection so nothing touches the person's files until it comes back"): the agent's
//! edits sit in the projection's upper layer on the machine and come back to the Mac in O(edits),
//! planned against the manifest the chat started from.
//!
//! The harness is `link_project.rs`'s: the real `FsService` and `projection-v1` server of
//! `cmux_tui_core` on a machine behind a link that delays every byte [`RTT`]/2 each way, and the
//! real `cmux link start-chat copy` and `cmux link seed pull --or-copy` (Bring Back's own pull).
//! `a_bench_of_bring_back` times Bring Back of the same folder with the same edits, projected and
//! copied (today's pull); it is ignored by default (`CMUX_WAY_BACK_FILES` sets the folder's size).
#![cfg(target_os = "linux")]

use std::collections::BTreeMap;
use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::fs::PermissionsExt as _;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use serde_json::{Value, json};

/// The link's round trip: about Leo's to a Cloud machine.
const RTT: Duration = Duration::from_millis(50);
/// One start key per chat: the projection is named by it (`chat-<key>`), so each test has its own.
const KEYS: [&str; 3] = [
    "b0ac0001-0b0a-4908-8706-050403020100",
    "b0ac0002-0b0a-4908-8706-050403020101",
    "b0ac0003-0b0a-4908-8706-050403020102",
];

/// Copies `from` to `to`, each read arriving `RTT`/2 after it left.
fn delayed(mut from: UnixStream, mut to: UnixStream) {
    let (due, arrivals) = std::sync::mpsc::channel::<(Instant, Vec<u8>)>();
    std::thread::spawn(move || {
        for (at, bytes) in arrivals {
            std::thread::sleep(at.saturating_duration_since(Instant::now()));
            if to.write_all(&bytes).is_err() {
                break;
            }
        }
        let _ = to.shutdown(std::net::Shutdown::Write);
    });
    std::thread::spawn(move || {
        let mut buffer = vec![0u8; 256 * 1024];
        loop {
            match from.read(&mut buffer) {
                Ok(0) | Err(_) => return,
                Ok(read) => {
                    if due.send((Instant::now() + RTT / 2, buffer[..read].to_vec())).is_err() {
                        return;
                    }
                }
            }
        }
    });
}

/// A Cloud machine on `socket` over `home` (see `link_project.rs`).
fn machine(socket: &Path, home: &Path) {
    let listener = UnixListener::bind(socket).unwrap();
    let home = home.to_path_buf();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.clone()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let (near, far) = UnixStream::pair().unwrap();
            delayed(connection.try_clone().unwrap(), near.try_clone().unwrap());
            delayed(near, connection);
            let home = home.clone();
            std::thread::spawn(move || serve(far, service, &home));
        }
    });
}

fn serve(connection: UnixStream, service: &FsService, home: &Path) {
    let mut writer = connection.try_clone().unwrap();
    let mut reader = BufReader::new(connection.try_clone().unwrap());
    let mut first = true;
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        if first && cmux_tui_core::projection::frame_command(&line).is_some() {
            let leftover = reader.buffer().to_vec();
            cmux_tui_core::projection::serve(
                &connection,
                line.trim_end(),
                leftover,
                &[home.to_path_buf()],
            );
            return;
        }
        first = false;
        let request: Value = serde_json::from_str(&line).unwrap();
        let id = request["id"].clone();
        let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
        let reply = if cmd == "identify" {
            json!({"id": id, "ok": true, "data": {"capabilities": [
                fs_ops::FS_CAPABILITY, fs_ops::FS_SYMLINK_CAPABILITY,
                fs_ops::FS_WRITE_DEFLATE_CAPABILITY, fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
                cmux_tui_core::projection::PROJECTION_CAPABILITY,
            ]}})
        } else {
            stream::answer(&id, service.call("local", &cmd, request))
        };
        let mut text = reply.to_string();
        text.push('\n');
        if writer.write_all(text.as_bytes()).is_err() {
            return;
        }
    }
}

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3").arg("-V").output().is_ok_and(|out| out.status.success())
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(["-c", "core.checkStat=minimal", "-c", "core.trustctime=false"])
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).into_owned()
}

/// A repository `app` (with a `.gitignore` for `target/`) and `files` notes in folders of 100.
fn folder(at: &Path, files: usize) {
    let repo = at.join("app");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    for index in 0..20 {
        write(&repo.join(format!("src/m{index:02}.rs")), &format!("fn f{index}() {{}}\n"));
    }
    write(&repo.join(".gitignore"), "target/\n");
    write(&repo.join("src/long.rs"), "// one\n// two\n// three\n// four\n// five\n");
    write(&repo.join("README.md"), "# app\n");
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "init"]);
    for index in 0..files {
        write(
            &at.join(format!("notes/d{:04}/f{index:06}.md", index / 100)),
            &format!("note {index}\n"),
        );
    }
}

/// A sparse 21 GiB disk image (no disk spent) that puts `at` past the copy's limits, so a start
/// projects it.
fn past_the_limits(at: &Path) {
    let image = at.join("Downloads/disk.img");
    std::fs::create_dir_all(image.parent().unwrap()).unwrap();
    std::fs::File::create(&image).unwrap().set_len(21 * 1024 * 1024 * 1024).unwrap();
}

/// `cmux link start-chat copy` of `local`, projection on or off: the machine's folder.
fn start_chat(
    state: &Path,
    socket: &Path,
    local: &Path,
    work: &Path,
    projected: bool,
    key: &str,
) -> (PathBuf, Value) {
    // The machine keeps a projection's upper layer until Bring Back drops it, by chat: an earlier
    // run's chat of the same key would hand its edits to this one.
    let _ = std::fs::remove_dir_all(projection_state(&format!("chat-{key}")));
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .env("CMUX_PROJECTED_FOLDERS", if projected { "1" } else { "0" })
        .env_remove("CMUX_SYNC_COPY_RATE")
        .args(["link", "start-chat", "copy", "--key", key, "--account", "leo", "--machine", "vm-a"])
        .arg("--socket")
        .arg(socket)
        .arg("--local")
        .arg(local)
        .arg("--work-root")
        .arg(work)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = last_json(&stdout);
    assert_eq!(
        answer["ok"],
        true,
        "start-chat: {stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    if projected {
        assert_eq!(answer["mode"], "projected", "{answer}");
    }
    (PathBuf::from(answer["folder"].as_str().unwrap()), answer)
}

fn last_json(text: &str) -> Value {
    text.lines()
        .rev()
        .find_map(|line| serde_json::from_str::<Value>(line).ok())
        .unwrap_or(Value::Null)
}

/// Bring Back's pull (`cmux link seed pull --or-copy`, what Bring Back Local runs): its answer
/// and how long it took.
fn bring_back(state: &Path, socket: &Path, local: &Path, remote: &Path) -> (Value, Duration) {
    let started = Instant::now();
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .args(["link", "seed", "pull", "--or-copy", "--socket"])
        .arg(socket)
        .arg(local)
        .arg(remote)
        .output()
        .unwrap();
    let took = started.elapsed();
    let stdout = String::from_utf8_lossy(&output.stdout);
    let answer = last_json(&stdout);
    assert!(
        !answer.is_null(),
        "bring back printed no answer: {stdout}{}",
        String::from_utf8_lossy(&output.stderr)
    );
    (answer, took)
}

fn stop(state: &Path, folder: &Path) {
    let _ = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .args(["link", "project", "stop", "--at"])
        .arg(folder)
        .output();
    let _ = Command::new("fusermount3").args(["-u", "-z"]).arg(folder).status();
}

struct World {
    _root: tempfile::TempDir,
    _sockets: tempfile::TempDir,
    base: PathBuf,
    local: PathBuf,
    home: PathBuf,
    socket: PathBuf,
}

fn world(files: usize) -> World {
    let root = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(root.path()).unwrap();
    let local = base.join("Folder");
    folder(&local, files);
    let home = base.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("pb").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    machine(&socket, &home);
    World { _root: root, _sockets: sockets, base, local, home, socket }
}

/// The machine's projection state folder for projection `name` (the copy answer's
/// `projected.name`), where this test process's daemon keeps it.
fn projection_state(name: &str) -> PathBuf {
    cmux_tui_core::platform::workspace_state_dir().unwrap().join("projections").join(name)
}

#[test]
fn edits_on_a_projected_folder_come_back_and_nothing_else_changes() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(300);
    let state = w.base.join("state");
    past_the_limits(&w.local);
    let (remote, started) =
        start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, KEYS[0]);
    let name = started["projected"]["name"].as_str().expect("the copy answer names the projection");
    let upper_state = projection_state(name);
    assert!(upper_state.is_dir(), "{} holds the upper layer", upper_state.display());

    // The agent's turn, on the machine.
    let app = remote.join("app");
    write(&app.join("src/m00.rs"), "fn f0() { /* machine */ }\n");
    write(&app.join("src/new.rs"), "fn new() {}\n");
    std::fs::remove_file(app.join("src/m01.rs")).unwrap();
    std::fs::rename(app.join("src/m02.rs"), app.join("src/renamed.rs")).unwrap();
    std::fs::set_permissions(app.join("src/m03.rs"), std::fs::Permissions::from_mode(0o755))
        .unwrap();
    write(&app.join("target/debug/huge.o"), "build output\n");
    write(&remote.join("notes/d0000/f000001.md"), "edited on the machine\n");
    write(&remote.join("notes/d0001/f000100.md"), "the machine's version\n");
    // `git status` refreshes the index's stat data only (hard case 13); `git add` stages one.
    git(&app, &["status", "--short"]);
    git(&app, &["add", "src/new.rs"]);
    write(&app.join("src/long.rs"), "// one\n// two\n// three\n// four\n// five, machine\n");
    // Meanwhile on the Mac: an edit the machine also made, and one it did not.
    write(&w.local.join("app/src/long.rs"), "// one, mac\n// two\n// three\n// four\n// five\n");
    write(&w.local.join("notes/d0001/f000100.md"), "the Mac's version\n");
    write(&w.local.join("notes/d0002/f000200.md"), "the Mac's own edit\n");

    let (answer, _) = bring_back(&state, &w.socket, &w.local, &remote);
    assert_eq!(answer["ok"], true, "{answer}");
    assert_eq!(answer["mode"], "projection", "{answer}");
    let local = &w.local;
    let read = |path: &str| std::fs::read_to_string(local.join(path)).ok();
    assert_eq!(read("app/src/m00.rs").as_deref(), Some("fn f0() { /* machine */ }\n"));
    assert_eq!(read("app/src/new.rs").as_deref(), Some("fn new() {}\n"));
    assert_eq!(read("app/src/m01.rs"), None);
    assert_eq!(read("app/src/m02.rs"), None);
    assert_eq!(read("app/src/renamed.rs").as_deref(), Some("fn f2() {}\n"));
    let mode = std::fs::metadata(local.join("app/src/m03.rs")).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o755);
    assert_eq!(read("app/target/debug/huge.o"), None, "ignored build output stays on the machine");
    assert_eq!(read("notes/d0000/f000001.md").as_deref(), Some("edited on the machine\n"));
    // The conflict: the Mac's file stays, the machine's version beside it.
    assert_eq!(read("notes/d0001/f000100.md").as_deref(), Some("the Mac's version\n"));
    assert_eq!(
        read("notes/d0001/f000100.md.cmux-sync-conflict").as_deref(),
        Some("the machine's version\n")
    );
    assert_eq!(read("notes/d0002/f000200.md").as_deref(), Some("the Mac's own edit\n"));
    // Changed on both, different lines: merged three-way against the base commit.
    assert_eq!(
        read("app/src/long.rs").as_deref(),
        Some("// one, mac\n// two\n// three\n// four\n// five, machine\n"),
        "{answer}"
    );
    // The report and the diff against the base commit.
    assert_eq!(answer["report"]["conflicted"], json!(["notes/d0001/f000100.md"]), "{answer}");
    let skipped = answer["report"]["skipped"].as_array().unwrap();
    assert!(skipped.contains(&json!("app/target")), "{answer}");
    assert!(skipped.iter().all(|p| p.as_str().unwrap().starts_with("app/target")), "{answer}");
    let applied = answer["report"]["applied"].as_array().unwrap();
    assert!(
        applied.contains(&json!("app/src/long.rs")) && applied.contains(&json!("app/src/m01.rs"))
    );
    let diff = &answer["diffs"][0];
    assert_eq!(diff["repo"], "app", "{answer}");
    let patch = std::fs::read_to_string(diff["patch"].as_str().unwrap()).unwrap();
    assert!(
        patch.contains("+fn f0() { /* machine */ }") && patch.contains("+// five, machine"),
        "{patch}"
    );
    // The staged file came back staged; the stat-only index refresh did nothing more.
    let staged = git(local.join("app").as_path(), &["diff", "--cached", "--name-only"]);
    assert_eq!(staged.trim(), "src/new.rs", "{answer}");
    assert_eq!(answer["conflicts"].as_array().map(Vec::len), Some(1), "{answer}");
    // Applied, so the machine dropped the projection's upper layer.
    assert_eq!(answer["dropped"], true, "{answer}");
    assert!(!upper_state.exists(), "the upper layer is gone once applied");
    stop(&state, &remote);
}

#[test]
fn a_git_conflict_brings_nothing_back_and_keeps_the_upper_layer() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let w = world(10);
    let state = w.base.join("state");
    past_the_limits(&w.local);
    let (remote, _) = start_chat(&state, &w.socket, &w.local, &w.home.join("work"), true, KEYS[1]);
    let app = remote.join("app");
    write(&app.join("src/m00.rs"), "fn f0() { /* machine */ }\n");
    git(&app, &["commit", "-qam", "machine"]);
    // The Mac commits too: both moved the branch.
    write(&w.local.join("app/src/m05.rs"), "fn f5() { /* mac */ }\n");
    git(&w.local.join("app"), &["commit", "-qam", "mac"]);

    let (answer, _) = bring_back(&state, &w.socket, &w.local, &remote);
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["error_code"], "sync_conflict", "{answer}");
    assert_eq!(
        std::fs::read_to_string(w.local.join("app/src/m00.rs")).unwrap(),
        "fn f0() {}\n",
        "nothing changed here"
    );
    // The machine still has it all: a second Bring Back after the Mac resolves can take it.
    assert_eq!(
        std::fs::read_to_string(app.join("src/m00.rs")).unwrap(),
        "fn f0() { /* machine */ }\n"
    );
    stop(&state, &remote);
}

/// The agent's 50 edits: 48 notes changed, one made, one deleted.
fn fifty_edits(folder: &Path, files: usize) {
    let step = files / 50;
    for n in 0..48 {
        let index = n * step;
        write(
            &folder.join(format!("notes/d{:04}/f{index:06}.md", index / 100)),
            &format!("note {index}, edited on the machine\n"),
        );
    }
    write(&folder.join("notes/d0000/new.md"), "made on the machine\n");
    let gone = 49 * step;
    std::fs::remove_file(folder.join(format!("notes/d{:04}/f{gone:06}.md", gone / 100))).unwrap();
}

#[test]
#[ignore = "a bench: CMUX_WAY_BACK_FILES=100000 cargo test --test link_project_back -- --ignored --nocapture"]
fn a_bench_of_bring_back() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let files =
        std::env::var("CMUX_WAY_BACK_FILES").ok().and_then(|n| n.parse().ok()).unwrap_or(20_000);
    let w = world(files);
    for projected in [false, true] {
        let state = w.base.join(if projected { "state-p" } else { "state-c" });
        let work = w.home.join(if projected { "work-p" } else { "work-c" });
        std::fs::create_dir_all(&work).unwrap();
        let local = w.base.join(if projected { "Folder-p" } else { "Folder-c" });
        let copied = Command::new("cp").arg("-a").arg(&w.local).arg(&local).status().unwrap();
        assert!(copied.success());
        if projected {
            past_the_limits(&local);
        }
        let key = if projected { KEYS[2] } else { KEYS[0] };
        let (remote, _) = start_chat(&state, &w.socket, &local, &work, projected, key);
        fifty_edits(&remote, files);
        let (answer, took) = bring_back(&state, &w.socket, &local, &remote);
        assert_eq!(answer["ok"], true, "{answer}");
        let row = json!({
            "path": if projected { "projected" } else { "copy (today)" },
            "mode": answer["mode"],
            "files": files,
            "edits": 50,
            "bring_back_ms": took.as_millis(),
            "plan_ms": answer["timings"]["plan_ms"],
            "listed_ms": answer["timings"]["listed_ms"],
            "bytes": answer["bytes"],
        });
        println!("WAY-BACK {row}");
        if projected {
            stop(&state, &remote);
        }
    }
    // The plan alone, in memory: a manifest of the folder, 50 edits, their stats.
    let plan_cost = plan_alone(files);
    println!("WAY-BACK {plan_cost}");
    println!("folder: {files} notes + a repository; link {} ms RTT", RTT.as_millis());
}

/// The pure plan's cost over a `files`-file manifest with 50 edits (median of 20 runs).
fn plan_alone(files: usize) -> Value {
    use cmux_projection::manifest::{Item, Kind, Manifest};
    use cmux_projection::way_back::{self, MacStat, Upper};
    let items: Vec<Item> = (0..files)
        .map(|index| Item {
            path: format!("notes/d{:04}/f{index:06}.md", index / 100),
            kind: Kind::File,
            mode: 0o644,
            size: 10,
            mtime_ns: 1,
            link: None,
        })
        .collect();
    let manifest = Manifest::build(1, items).unwrap();
    let step = files / 50;
    let upper: Vec<Upper> = (0..50)
        .map(|n| Upper {
            path: format!("notes/d{:04}/f{:06}.md", n * step / 100, n * step),
            kind: Kind::File,
            size: 11,
            mode: 0o644,
            mtime_ns: 2,
            link: None,
        })
        .collect();
    let mut samples = Vec::new();
    for _ in 0..20 {
        let started = Instant::now();
        let touched = way_back::touched(&manifest, &upper, &[]);
        let mac: BTreeMap<String, MacStat> = touched
            .into_iter()
            .map(|path| {
                (path, MacStat { kind: Kind::File, size: 10, mode: 0o644, mtime_ns: 1, link: None })
            })
            .collect();
        let plan = way_back::plan(&manifest, &upper, &[], &mac, &|path: &str| path.to_lowercase());
        assert_eq!(plan.writes.len(), 50);
        samples.push(started.elapsed().as_micros());
    }
    samples.sort_unstable();
    json!({"path": "plan only (in memory)", "files": files, "edits": 50, "plan_us": samples[10]})
}
