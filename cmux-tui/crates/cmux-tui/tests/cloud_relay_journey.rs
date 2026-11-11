//! Move to another Cloud machine, end to end on one Linux box with real
//! processes: a chat and its dirty checkout go from one daemon shaped like a
//! personal Cloud VM to another, with this "Mac" as the pump between them
//! and nothing of the folder written on its disk.
//!
//! - The Mac seeds a dirty working copy onto VM one (`cmux link seed push`),
//!   and the chat runs there: its folder then gets work of the VM's own (a
//!   staged change, an executable script, a symlink, a stash, a dependency
//!   folder the project rebuilds).
//! - `cmux link sync relay` copies the folder VM one to VM two, through the
//!   two machine links.
//! - `cmux link agent move --sync relay` moves the chat mid-turn, sending
//!   only what the frozen chat wrote since the relay.
//!
//! Linux only, as a Cloud host is.
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::json;

const HISTORY: &str = "hello from vm one";
const QUEUED: &str = "queued for vm two";
const QUEUED_ID: &str = "p-relay-queued";
const DRAFT: &str = "an unsent thought on vm one";

fn dirty_repo(at: &Path, github: &Path) -> PathBuf {
    let repo = at.join("app");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\n").unwrap();
    fs::write(repo.join("Cargo.toml"), "[package]\nname = \"app\"\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let bare = github.join("acme/app.git");
    fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare"]);
    git(&bare, &["config", "uploadpack.allowFilter", "true"]);
    git(&repo, &["remote", "add", "origin", "https://github.com/acme/app.git"]);
    let local = format!("url.file://{}/.insteadOf", github.display());
    git(&repo, &["config", &local, "https://github.com/"]);
    git(&repo, &["-c", "protocol.file.allow=always", "push", "-q", "-u", "origin", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\nuncommitted change\n").unwrap();
    fs::write(repo.join("notes.txt"), "untracked\n").unwrap();
    repo
}

fn vm(root: &Path, name: &str, github: &Path) -> Machine {
    Machine::start(
        root,
        name,
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", format!("vm-relay-{name}")),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    )
}

/// Every name, mode, link and byte under `folder`, `.git` included, as one number.
fn digest(folder: &Path) -> u64 {
    use std::hash::{Hash as _, Hasher as _};
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    let mut stack = vec![folder.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let mut entries: Vec<_> = fs::read_dir(&dir).unwrap().map(|e| e.unwrap().path()).collect();
        entries.sort();
        for path in entries {
            let meta = fs::symlink_metadata(&path).unwrap();
            path.strip_prefix(folder).unwrap().hash(&mut hasher);
            meta.permissions().mode().hash(&mut hasher);
            if meta.file_type().is_symlink() {
                fs::read_link(&path).unwrap().hash(&mut hasher);
            } else if meta.is_dir() {
                stack.push(path);
            } else {
                fs::read(&path).unwrap().hash(&mut hasher);
            }
        }
    }
    hasher.finish()
}

fn relay(
    mac: &Machine,
    from: &Machine,
    from_folder: &Path,
    to: &Machine,
    to_folder: &Path,
) -> serde_json::Value {
    let (ok, summary) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "relay", "--from-socket"])
            .arg(&from.socket)
            .arg("--socket")
            .arg(&to.socket)
            .arg(from_folder)
            .arg(to_folder),
    );
    assert!(ok && summary["ok"] == json!(true), "relay: {summary}");
    summary
}

#[test]
fn a_chat_and_its_dirty_checkout_move_from_one_cloud_vm_to_another() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("crj-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let github = root.join("github");
    let mac = Machine::start(&root, "mac", Vec::new());
    let one = vm(&root, "one", &github);
    let two = vm(&root, "two", &github);

    // The folder on VM one, as Move to Cloud put it there.
    let repo = dirty_repo(&mac.home(), &github);
    let first = one.home().join("work/app");
    let (ok, seeded) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "seed", "push", "--socket"])
            .arg(&one.socket)
            .arg(&repo)
            .arg(&first),
    );
    assert!(ok && seeded["ok"] == json!(true), "seed push: {seeded}");

    // Work of VM one's own: a commit, a staged change, a stash, an executable,
    // a symlink inside the folder and one outside it, and a Cargo target.
    git(&first, &["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-am", "on vm one"]);
    fs::write(first.join("src/staged.txt"), "staged on vm one\n").unwrap();
    git(&first, &["add", "src/staged.txt"]);
    fs::write(first.join("src/lib.txt"), "committed\nuncommitted change\nmore on vm one\n")
        .unwrap();
    fs::write(first.join("stashme.txt"), "to stash\n").unwrap();
    git(&first, &["add", "stashme.txt"]);
    git(
        &first,
        &["-c", "user.name=t", "-c", "user.email=t@t", "stash", "push", "-q", "--", "stashme.txt"],
    );
    fs::write(first.join("run.sh"), "#!/bin/sh\necho hi\n").unwrap();
    fs::set_permissions(first.join("run.sh"), fs::Permissions::from_mode(0o755)).unwrap();
    std::os::unix::fs::symlink("src/lib.txt", first.join("lib-link")).unwrap();
    std::os::unix::fs::symlink("/etc/hostname", first.join("outside-link")).unwrap();
    // A chain whose links come in name order before what they point at.
    std::os::unix::fs::symlink("chain-b", first.join("chain-a")).unwrap();
    std::os::unix::fs::symlink("chain-c", first.join("chain-b")).unwrap();
    std::os::unix::fs::symlink("src/lib.txt", first.join("chain-c")).unwrap();
    fs::create_dir_all(first.join("target/debug")).unwrap();
    fs::write(first.join("target/debug/big.o"), vec![7u8; 1 << 20]).unwrap();
    // A folder VM two later swaps for a symlink, and a group-writable file.
    fs::create_dir_all(first.join("deep")).unwrap();
    fs::write(first.join("deep/gone.txt"), "deleted after the bulk\n").unwrap();
    fs::write(first.join("shared.txt"), "group writable\n").unwrap();
    fs::set_permissions(first.join("shared.txt"), fs::Permissions::from_mode(0o664)).unwrap();
    // A file big enough to be streamed part by part.
    fs::write(
        first.join("data.bin"),
        (0..(12u32 << 20)).map(|i| (i % 251) as u8).collect::<Vec<_>>(),
    )
    .unwrap();

    // 1. The bulk: VM one's folder to VM two.
    let second = two.home().join("work/app");
    let bulk = relay(&mac, &one, &first, &two, &second);
    assert!(bulk["written"].as_u64().unwrap() > 0, "{bulk}");
    let status = ["status", "--porcelain=v2", "--branch"];
    // The same status but for what the relay leaves out on purpose (checked below).
    let kept = |text: String| {
        text.lines()
            .filter(|line| !matches!(*line, "? outside-link" | "? target/"))
            .collect::<Vec<_>>()
            .join("\n")
    };
    assert_eq!(
        kept(git(&second, &status)),
        kept(git(&first, &status)),
        "git status differs on VM two"
    );
    assert_eq!(git(&second, &["rev-parse", "HEAD"]), git(&first, &["rev-parse", "HEAD"]));
    assert_eq!(git(&second, &["stash", "list"]), git(&first, &["stash", "list"]));
    assert_eq!(git(&second, &["diff", "--cached"]), git(&first, &["diff", "--cached"]));
    assert_eq!(
        fs::read(second.join("data.bin")).unwrap(),
        fs::read(first.join("data.bin")).unwrap(),
        "the streamed file differs"
    );
    let mode = fs::metadata(second.join("run.sh")).unwrap().permissions().mode();
    assert_eq!(mode & 0o111, 0o111, "run.sh lost its executable bit: {mode:o}");
    assert_eq!(fs::read_link(second.join("lib-link")).unwrap(), PathBuf::from("src/lib.txt"));
    assert!(!second.join("outside-link").exists(), "a symlink out of the folder was kept");
    assert_eq!(fs::read_link(second.join("chain-a")).unwrap(), PathBuf::from("chain-b"));
    assert_eq!(
        fs::read(second.join("chain-a")).unwrap(),
        fs::read(first.join("src/lib.txt")).unwrap()
    );
    assert!(!second.join("target").exists(), "the Cargo target went too");
    let skipped = bulk["skipped_files"].as_array().unwrap();
    assert!(skipped.iter().any(|s| s["path"] == "target"), "{bulk}");
    assert!(skipped.iter().any(|s| s["path"] == "outside-link"), "{bulk}");
    // Nothing of the folder was written on the Mac.
    let leaked =
        walk_names(&mac.dir).into_iter().any(|name| name == "data.bin" || name == "run.sh");
    assert!(!leaked, "the relay wrote the folder on the Mac");

    // Again, with nothing changed: nothing is written.
    let again = relay(&mac, &one, &first, &two, &second);
    assert_eq!(again["written"], json!(0), "{again}");

    // Work VM two put where a relayed symlink was is never deleted when the source drops the link.
    fs::remove_file(second.join("lib-link")).unwrap();
    fs::create_dir(second.join("lib-link")).unwrap();
    fs::write(second.join("lib-link/mine.txt"), "made on vm two\n").unwrap();
    fs::remove_file(first.join("lib-link")).unwrap();
    relay(&mac, &one, &first, &two, &second);
    assert_eq!(
        fs::read_to_string(second.join("lib-link/mine.txt")).unwrap(),
        "made on vm two\n",
        "the relay deleted VM two's own work"
    );
    fs::remove_dir_all(second.join("lib-link")).unwrap();

    // VM two swaps a relayed folder for a symlink to a copy outside the folder: a file the
    // source deletes then goes only inside the target folder, never through the symlink.
    let outside = two.home().join("work/saved-deep");
    fs::rename(second.join("deep"), &outside).unwrap();
    std::os::unix::fs::symlink(&outside, second.join("deep")).unwrap();
    fs::remove_file(first.join("deep/gone.txt")).unwrap();
    relay(&mac, &one, &first, &two, &second);
    assert!(outside.join("gone.txt").exists(), "a relay deleted through a symlinked folder");
    fs::remove_file(second.join("deep")).unwrap();

    // A folder VM two already has, that no relay made, is never written over.
    let theirs = two.home().join("work/theirs");
    fs::create_dir_all(&theirs).unwrap();
    fs::write(theirs.join("keep.txt"), "not ours\n").unwrap();
    let (ok, refused) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "relay", "--from-socket"])
            .arg(&one.socket)
            .arg("--socket")
            .arg(&two.socket)
            .arg(&first)
            .arg(&theirs),
    );
    assert!(!ok && refused["error_code"] == json!("relay.target_exists"), "{refused}");
    assert_eq!(fs::read_to_string(theirs.join("keep.txt")).unwrap(), "not ours\n");

    // 2. The chat moves mid-turn, and what its turn wrote after the bulk goes along. VM one's
    // folder came from this Mac's seed, so the move goes as git, VM one to VM two (seed_cli::hop),
    // into a folder VM two does not have yet, and this Mac's folder is never touched. Symlinks
    // made on a machine stop step 4's Bring Back Local (its own rule), so VM one's go first
    // (lib-link went above).
    for link in ["outside-link", "chain-a", "chain-b", "chain-c"] {
        fs::remove_file(first.join(link)).unwrap();
    }
    let moved_to = two.home().join("work/moved");
    let mut one_acpmux = one.acpmux();
    let created = one_acpmux.call("session/new", json!({"cwd": first, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    one_acpmux.call("session/prompt", prompt(&session, HISTORY, "p-relay-history"));
    one_acpmux.send("session/prompt", prompt(&session, "until-cancel", "p-relay-running"));
    wait_until(20, "the running turn", || {
        one_acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    one_acpmux.send("session/prompt", prompt(&session, QUEUED, QUEUED_ID));
    wait_until(20, "the queued prompt", || {
        one_acpmux.summary(&session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
    });
    one_acpmux.call("_acpmux/draft_set", json!({"sessionId": session, "text": DRAFT}));
    let surface = bound_agent_tab(&one, &session);
    fs::write(first.join("src/turn.txt"), "written by the running turn\n").unwrap();
    fs::remove_file(first.join("notes.txt")).unwrap();

    let move_to = |to: &PathBuf, pump: &str| {
        run_json(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "agent", "move", "--from-socket"])
                .arg(&one.socket)
                .args(["--surface", &surface.to_string(), "--to-socket"])
                .arg(&two.socket)
                .arg("--cwd")
                .arg(to)
                .arg("--interrupt")
                .args(["--vm-kind", "owner"])
                .args(["--sync", "relay", "--sync-from-socket"])
                .arg(&one.socket)
                .arg("--sync-socket")
                .arg(&two.socket)
                .arg("--sync-local")
                .arg(&first)
                .arg("--sync-remote")
                .arg(to)
                .arg("--sync-seed-local")
                .arg(&repo)
                .arg("--state-dir")
                .arg(root.join(pump)),
        )
    };
    // A move into a folder VM two already has is refused before the chat freezes, and the
    // folder keeps its work: the hop never seeds over it, and the relay it falls back to refuses.
    let (ok, refused) = move_to(&theirs, "pump-refused");
    assert!(!ok, "a move into VM two's own folder: {refused}");
    assert_eq!(fs::read_to_string(theirs.join("keep.txt")).unwrap(), "not ours\n");
    assert!(one_acpmux.summary(&session).is_some_and(|s| s["status"] != "closed"), "chat left");
    // The folder step 1's relay made is that copy's, not this chat's: its record is not this
    // move's, so the move is refused there too and never copies over it.
    let (ok, refused) = move_to(&second, "pump-refused-relayed");
    assert!(!ok, "a move into another relay's folder: {refused}");
    let mac_before = digest(&repo);
    let (ok, moved) = move_to(&moved_to, "pump");
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved}");
    assert_eq!(moved["session_id"], json!(session), "{moved}");
    assert_eq!(
        fs::read_to_string(moved_to.join("src/turn.txt")).unwrap(),
        "written by the running turn\n",
        "the turn's last change stayed on VM one"
    );
    assert!(!moved_to.join("notes.txt").exists(), "a file the turn deleted came back on VM two");
    assert_eq!(digest(&repo), mac_before, "the move wrote into this Mac's folder");
    // A copy machine to machine would have brought VM one's seed record along; the hop's delta
    // seed records VM one's export.
    assert_ne!(
        git(&moved_to, &["rev-parse", "refs/cmux-seed/work"]),
        git(&first, &["rev-parse", "refs/cmux-seed/work"]),
        "the move copied machine to machine instead of sending git"
    );

    // 3. On VM two: the chat with its history and draft, and its queue ran there once.
    let mut two_acpmux = two.acpmux();
    let landed = wait_until(30, "the queued prompt's turn on VM two", || {
        let events = two_acpmux.events(&session);
        let done =
            events.iter().any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID);
        done.then_some(events)
    });
    assert_eq!(count(&landed, "user_message", USER_TEXT, HISTORY), 1, "history: {landed:?}");
    let draft = two_acpmux.call("_acpmux/draft_get", json!({"sessionId": session}));
    assert_eq!(draft["draft"], json!(DRAFT), "{draft}");
    let there = two_acpmux.summary(&session).expect("the chat is on VM two");
    assert_eq!(there["cwd"], json!(fs::canonicalize(&moved_to).unwrap()), "{there}");

    // 4. Bring Back Local from VM two merges into the Mac's folder against the record the hop
    // left for VM two's folder.
    fs::write(moved_to.join("src/on-two.txt"), "made on vm two\n").unwrap();
    let (ok, back) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "seed", "pull", "--socket"])
            .arg(&two.socket)
            .arg(&repo)
            .arg(&moved_to)
            .arg("--or-copy"),
    );
    assert!(ok && back["ok"] == json!(true), "bring back from VM two: {back}");
    assert_eq!(back["mode"], json!("seed"), "{back}");
    assert_eq!(
        fs::read_to_string(repo.join("src/turn.txt")).unwrap(),
        "written by the running turn\n",
        "the turn's change did not come back from VM two"
    );
    assert_eq!(fs::read_to_string(repo.join("src/on-two.txt")).unwrap(), "made on vm two\n");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), git(&moved_to, &["rev-parse", "HEAD"]));

    // 5. On VM one: the chat moved away and its queue never ran there.
    let left = one_acpmux.summary(&session);
    assert!(left.as_ref().is_none_or(|s| s["status"] == "closed"), "still open: {left:?}");
    let events = one_acpmux.events(&session);
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 0, "ran on VM one too");
}

/// A folder Move to Cloud copied rather than seeded (no git here) moves VM to VM by relay, and
/// Bring Back Local from VM two still merges against the copy's own base, carried to the new path.
#[test]
fn a_copied_folder_moved_to_another_vm_still_brings_back() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("crc-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let github = root.join("github");
    let mac = Machine::start(&root, "mac", Vec::new());
    let one = vm(&root, "one", &github);
    let two = vm(&root, "two", &github);
    let cli = || {
        let mut command = Command::new(bin());
        command
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null");
        command
    };

    let folder = mac.home().join("notes");
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("a.txt"), "from this mac\n").unwrap();
    let first = one.home().join("work/notes");
    let (ok, pushed) = run_json(
        cli().args(["link", "seed", "push", "--socket"]).arg(&one.socket).arg(&folder).arg(&first),
    );
    assert!(ok && pushed["ok"] == json!(true), "copy push: {pushed}");
    assert_eq!(pushed["mode"], json!("copy"), "{pushed}");

    let mut one_acpmux = one.acpmux();
    let created = one_acpmux.call("session/new", json!({"cwd": first, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    let surface = bound_agent_tab(&one, &session);
    fs::write(first.join("b.txt"), "written on vm one\n").unwrap();

    let moved_to = two.home().join("work/notes-moved");
    let (ok, moved) = run_json(
        cli()
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&one.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&two.socket)
            .arg("--cwd")
            .arg(&moved_to)
            .args(["--vm-kind", "owner", "--sync", "relay", "--sync-from-socket"])
            .arg(&one.socket)
            .arg("--sync-socket")
            .arg(&two.socket)
            .arg("--sync-local")
            .arg(&first)
            .arg("--sync-remote")
            .arg(&moved_to)
            .arg("--sync-seed-local")
            .arg(&folder)
            .arg("--state-dir")
            .arg(root.join("pump-copy")),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved}");
    assert_eq!(fs::read_to_string(moved_to.join("b.txt")).unwrap(), "written on vm one\n");

    fs::write(moved_to.join("c.txt"), "made on vm two\n").unwrap();
    let (ok, back) = run_json(
        cli()
            .args(["link", "seed", "pull", "--socket"])
            .arg(&two.socket)
            .arg(&folder)
            .arg(&moved_to)
            .arg("--or-copy"),
    );
    assert!(ok && back["ok"] == json!(true), "bring back from VM two: {back}");
    assert_eq!(fs::read_to_string(folder.join("b.txt")).unwrap(), "written on vm one\n");
    assert_eq!(fs::read_to_string(folder.join("c.txt")).unwrap(), "made on vm two\n");
    assert_eq!(fs::read_to_string(folder.join("a.txt")).unwrap(), "from this mac\n");
}

/// Every file name under `dir`.
fn walk_names(dir: &Path) -> Vec<String> {
    let mut names = Vec::new();
    let Ok(entries) = fs::read_dir(dir) else { return names };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() && !path.is_symlink() {
            names.extend(walk_names(&path));
        } else {
            names.push(entry.file_name().to_string_lossy().into_owned());
        }
    }
    names
}
