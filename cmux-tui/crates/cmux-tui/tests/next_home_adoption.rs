//! cmux NEXT keeps its agent chats and Chief memory across the per-build
//! isolation update (P0 2026-10-15). NEXT (`com.cmuxterm.app.nightly.cmux-next`)
//! used `~/.acpmux/tags/cmux-next` and NIGHTLY's shared Chief home
//! `~/.cmux/chief/default` before S2/S0; after the update it resolves
//! `~/.acpmux/builds/<key>` and `~/.cmux/chief/<bundle id>`, which were empty.
//!
//! Behavior at the CLI boundary, under a temp `HOME` with the old layout:
//! `cmux acp` of NEXT and the app's launch step (`cmux __adopt-build-homes`)
//! find the old sessions, config and Chief memory in NEXT's homes; a second
//! launch changes nothing; sessions made after the update are kept; NIGHTLY's
//! home is never changed; NIGHTLY and DEV builds never adopt.

#![cfg(unix)]

use serde_json::Value;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

const NEXT: &str = "com.cmuxterm.app.nightly.cmux-next";

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}

fn temp_home(name: &str) -> PathBuf {
    static N: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = N.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let home =
        PathBuf::from("/tmp").join(format!("cmux-adopt-{name}-{}-{stamp}-{n}", std::process::id()));
    fs::create_dir_all(&home).unwrap();
    home
}

/// Variables that could point the CLI at another home or build.
const FOREIGN: [&str; 14] = [
    "ACPMUX_HOME",
    "ACPMUX_SOCKET",
    "CMUX_SOCKET_PATH",
    "CMUX_BUNDLE_ID",
    "CMUX_TAG",
    "CMUX_TUI_SOCKET",
    "CMUX_CHIEF_HOME",
    "CMUX_NEXT_CHIEF_HOME",
    "CMUX_NEXT_MUX_HOME",
    "CMUX_NEXT_CHIEF_ROOT",
    "CMUX_NEXT_CHIEF_ISOLATED",
    "CMUX_NEXT_NO_ACTIVATE",
    "CMUX_NEXT_CHIEF_BUILD_ID",
    "CMUX_NEXT_ACPMUX_ROOT",
];

/// `cmux <args>` as the CLI of the build `bundle_id` for the person at `home`.
fn cli_as(bundle_id: &str, tag: Option<&str>, home: &Path, args: &[&str]) -> Output {
    let mut command = Command::new(bin());
    command.args(args).env("LC_ALL", "C").env("HOME", home).env("CMUX_BUNDLE_ID", bundle_id);
    for key in FOREIGN.iter().filter(|k| **k != "CMUX_BUNDLE_ID") {
        command.env_remove(key);
    }
    if let Some(tag) = tag {
        command.env("CMUX_TAG", tag);
    }
    command.stdin(Stdio::null()).output().unwrap()
}

fn text(output: &Output) -> String {
    format!(
        "status {:?}\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn session(dir: &Path, id: &str, marker: &str) {
    let path = dir.join("sessions").join(id);
    fs::create_dir_all(&path).unwrap();
    let meta = serde_json::json!({
        "schema": "acpmux.session.v1", "id": id, "name": marker, "harness": "codex",
        "harnessArgv": [], "cwd": "/tmp", "status": "idle",
        "createdAt": 1_760_000_000_000u64, "updatedAt": 1_760_000_000_000u64,
    });
    fs::write(path.join("session.json"), serde_json::to_vec_pretty(&meta).unwrap()).unwrap();
}

/// NEXT's acpmux home before S2: two sessions, the chat index, its config.
fn old_acpmux(home: &Path) -> PathBuf {
    let old = home.join(".acpmux/tags/cmux-next");
    session(&old, "01a10000-0000-7000-8000-00000000000a", "old-session-a");
    session(&old, "01a10000-0000-7000-8000-00000000000b", "old-session-b");
    fs::create_dir_all(old.join("chat-index")).unwrap();
    fs::write(old.join("chat-index/v1.json"), r#"{"marker": "old-chat-index"}"#).unwrap();
    fs::write(
        old.join("config.json"),
        r#"{"defaultHarness": "codex", "webAskingModes": {"codex": ["next-old-config"]},
            "websocket": {"listen": "127.0.0.1:0", "token": "next-adoption-test"}}"#,
    )
    .unwrap();
    old
}

fn session_dir_name(session: &str) -> String {
    let mut readable = String::new();
    let mut hash = 0xcbf2_9ce4_8422_2325_u64;
    for byte in session.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
        if readable.len() < 48 {
            let keep = byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_');
            readable.push(if keep { char::from(byte) } else { '_' });
        }
    }
    format!("{readable}-{hash:016x}")
}

fn chief_session(root: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.to_string_lossy().as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("cmux-chief-{hash:08x}")
}

fn sqlite(path: &Path, create: &str, insert: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let db = rusqlite::Connection::open(path).unwrap();
    db.execute_batch(&format!("PRAGMA journal_mode=WAL; {create}; {insert};")).unwrap();
    // Left open with its WAL, as a running owner leaves it.
    std::mem::forget(db);
}

fn query(path: &Path, sql: &str) -> Option<String> {
    let db =
        rusqlite::Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .ok()?;
    db.query_row(sql, [], |row| row.get::<_, String>(0)).ok()
}

/// The shared Chief home before S0: memory, conversations, the Chief's
/// acpmux with a preset into this home, and live runtime bits of NIGHTLY.
fn old_chief(home: &Path) -> PathBuf {
    let shared = home.join(".cmux/chief/default");
    sqlite(
        &shared.join("optchat/memory.sqlite3"),
        "CREATE TABLE memory(text TEXT)",
        "INSERT INTO memory VALUES('remember-the-pier')",
    );
    fs::write(shared.join("optchat/person.md"), "person-from-default\n").unwrap();
    let session_dir = shared.join("tui").join(session_dir_name(&chief_session(&shared)));
    sqlite(
        &session_dir.join("conversations.sqlite3"),
        "CREATE TABLE conversation(id TEXT)",
        "INSERT INTO conversation VALUES('conv-from-default')",
    );
    sqlite(
        &session_dir.join("workspace-registry.sqlite3"),
        "CREATE TABLE meta(k TEXT)",
        "SELECT 1",
    );
    fs::create_dir_all(shared.join("tui/terminal-hosts-0123456789abcdef")).unwrap();
    fs::write(shared.join("tui/terminal-hosts-0123456789abcdef/rec.json"), "{}").unwrap();
    fs::write(shared.join("tui/machine-id"), "nightly-machine").unwrap();
    session(&shared.join("acpmux"), "01a10000-0000-7000-8000-0000000000c1", "chief-turn");
    let codex_home = shared.join("optchat/turn-codex");
    fs::write(
        shared.join("acpmux/config.json"),
        serde_json::json!({"presets": {"optchat-chief-codex": {"env": {"CODEX_HOME": codex_home}}},
            "websocket": {"listen": "127.0.0.1:47999", "token": "nightly-chief-acpmux-token"}})
        .to_string(),
    )
    .unwrap();
    fs::write(shared.join("acpmux/daemon.pid"), "99999").unwrap();
    fs::create_dir_all(shared.join("acpmux/hosts")).unwrap();
    fs::write(shared.join("acpmux/hosts/01a1.json"), "{}").unwrap();
    fs::create_dir_all(shared.join("state")).unwrap();
    fs::write(shared.join("state/host.lock"), "1\n").unwrap();
    fs::write(shared.join("agent-token"), "nightly-agent-token").unwrap();
    fs::write(
        shared.join("optchat/inspector.json"),
        r#"{"port": 1, "token": "nightly-inspector"}"#,
    )
    .unwrap();
    shared
}

/// Every file under `dir` with its bytes (a home that must not change).
fn snapshot(dir: &Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut out = Vec::new();
    let mut pending = vec![dir.to_path_buf()];
    while let Some(next) = pending.pop() {
        for entry in fs::read_dir(&next).into_iter().flatten().flatten() {
            let kind = entry.file_type().unwrap();
            if kind.is_dir() {
                pending.push(entry.path());
            } else if kind.is_file() && !entry.file_name().to_string_lossy().ends_with("-shm") {
                // The `-shm` wal-index is shared memory a reader may touch, not content.
                out.push((entry.path(), fs::read(entry.path()).unwrap_or_default()));
            }
        }
    }
    out.sort();
    out
}

fn read(path: &Path) -> String {
    fs::read_to_string(path).unwrap_or_default()
}

/// Austin's case: NEXT updated, its new acpmux home does not exist yet. The
/// first `cmux acp` of NEXT finds the old sessions, chat index and config
/// in its home, the daemon lists the sessions, the old path names the same
/// home, and a second run changes nothing.
#[test]
fn next_cli_adopts_its_old_acpmux_home() {
    let home = temp_home("acpmux-cli");
    let old = old_acpmux(&home);
    let new = home.join(".acpmux/builds").join(NEXT);
    let config = cli_as(NEXT, Some("cmux-next"), &home, &["acp", "config", "--json"]);
    let mut wrong = Vec::new();
    let got: Value = serde_json::from_slice(&config.stdout).unwrap_or(Value::Null);
    if got["home"].as_str() != Some(new.to_str().unwrap()) {
        wrong.push(format!("home {} (want {})", got["home"], new.display()));
    }
    for id in ["01a10000-0000-7000-8000-00000000000a", "01a10000-0000-7000-8000-00000000000b"] {
        if !new.join("sessions").join(id).join("session.json").is_file() {
            wrong.push(format!("session {id} is not in NEXT's home"));
        }
    }
    if !read(&new.join("config.json")).contains("next-old-config") {
        wrong.push("NEXT's old config.json was not kept".into());
    }
    if !read(&new.join("chat-index/v1.json")).contains("old-chat-index") {
        wrong.push("the chat index was not kept".into());
    }
    let linked = fs::symlink_metadata(&old).is_ok_and(|m| m.file_type().is_symlink())
        && fs::canonicalize(&old).ok() == fs::canonicalize(&new).ok();
    if fs::symlink_metadata(&old).is_ok() && !linked {
        wrong.push(format!("{} is a second copy, not a link to NEXT's home", old.display()));
    }
    let record = read(&new.join("adopted.json"));
    if record.is_empty() {
        wrong.push("no adopted.json".into());
    }
    if wrong.is_empty() {
        let started = cli_as(NEXT, Some("cmux-next"), &home, &["acp", "daemon", "start", "--json"]);
        let listed = cli_as(NEXT, Some("cmux-next"), &home, &["acp", "ls", "--json"]);
        let _ = cli_as(NEXT, Some("cmux-next"), &home, &["acp", "daemon", "shutdown"]);
        let listing = String::from_utf8_lossy(&listed.stdout);
        if !listing.contains("old-session-a") || !listing.contains("old-session-b") {
            wrong.push(format!(
                "the daemon does not list the old sessions\n{}\n{}",
                text(&started),
                text(&listed)
            ));
        }
        let again = cli_as(NEXT, Some("cmux-next"), &home, &["acp", "config", "--json"]);
        if read(&new.join("adopted.json")) != record || !again.status.success() {
            wrong.push(format!("a second run changed the adoption\n{}", text(&again)));
        }
    }
    let _ = fs::remove_dir_all(&home);
    assert!(
        wrong.is_empty(),
        "NEXT lost its acpmux home:\n{}\n{}",
        wrong.join("\n"),
        text(&config)
    );
}

/// The app's launch step on a NEXT that already ran after the update: its
/// post-update sessions (one with an id the old home has too) are kept next
/// to the old ones, the old config wins, and the shared Chief home is cloned
/// into NEXT's own home (memory, conversations under NEXT's session, presets
/// pointing at NEXT's home, none of NIGHTLY's runtime state). NIGHTLY's
/// home does not change; NEXT's post-update Chief home is kept aside. A
/// second launch does nothing.
#[test]
fn next_launch_adopts_both_homes_and_keeps_post_update_state() {
    let home = temp_home("launch");
    old_acpmux(&home);
    let new = home.join(".acpmux/builds").join(NEXT);
    session(&new, "01a10000-0000-7000-8000-00000000000a", "post-update-clash");
    session(&new, "01a10000-0000-7000-8000-0000000000d1", "post-update-session");
    fs::write(new.join("config.json"), r#"{"marker": "post-update-config"}"#).unwrap();
    let shared = old_chief(&home);
    let before = snapshot(&shared);
    let next_chief = home.join(".cmux/chief").join(NEXT);
    fs::create_dir_all(next_chief.join("optchat")).unwrap();
    fs::write(next_chief.join("optchat/person.md"), "post-update-chief\n").unwrap();

    let launch = cli_as(NEXT, Some("cmux-next"), &home, &["__adopt-build-homes"]);
    let mut wrong = Vec::new();
    let sessions: Vec<(String, String)> = fs::read_dir(new.join("sessions"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| {
            let meta: Value =
                serde_json::from_str(&read(&e.path().join("session.json"))).unwrap_or(Value::Null);
            (
                e.file_name().to_string_lossy().into_owned(),
                format!("{}|{}", meta["id"], meta["name"]),
            )
        })
        .collect();
    for name in ["old-session-a", "old-session-b", "post-update-session", "post-update-clash"] {
        if !sessions.iter().any(|(_, meta)| meta.contains(name)) {
            wrong.push(format!("session {name} is missing from NEXT's acpmux home: {sessions:?}"));
        }
    }
    if sessions.iter().any(|(dir, meta)| !meta.starts_with(&format!("\"{dir}\""))) {
        wrong.push(format!("a session's id is not its folder: {sessions:?}"));
    }
    if !read(&new.join("config.json")).contains("next-old-config") {
        wrong.push("the old config.json did not win".into());
    }
    let kept_config = fs::read_dir(&new).into_iter().flatten().flatten().any(|e| {
        e.file_name().to_string_lossy().starts_with("adopted-post-update-")
            && read(&e.path().join("config.json")).contains("post-update-config")
    });
    if !kept_config {
        wrong.push("the post-update config.json was not kept".into());
    }

    let memory = query(&next_chief.join("optchat/memory.sqlite3"), "SELECT text FROM memory");
    if memory.as_deref() != Some("remember-the-pier") {
        wrong.push(format!("NEXT's Chief memory: {memory:?}"));
    }
    if read(&next_chief.join("optchat/person.md")) != "person-from-default\n" {
        wrong.push("NEXT's Chief person.md is not the shared one".into());
    }
    let session_dir = next_chief.join("tui").join(session_dir_name(&chief_session(&next_chief)));
    let conversation =
        query(&session_dir.join("conversations.sqlite3"), "SELECT id FROM conversation");
    if conversation.as_deref() != Some("conv-from-default") {
        wrong.push(format!("NEXT's owner session has conversations {conversation:?}"));
    }
    let preset = read(&next_chief.join("acpmux/config.json"));
    if preset.contains(shared.to_str().unwrap()) || !preset.contains(next_chief.to_str().unwrap()) {
        wrong.push(format!("the Chief's acpmux presets still name NIGHTLY's home: {preset}"));
    }
    if preset.contains("nightly-chief-acpmux-token") || preset.contains("47999") {
        wrong.push("the Chief's acpmux kept NIGHTLY's websocket listener and token".into());
    }
    if !next_chief
        .join("acpmux/sessions/01a10000-0000-7000-8000-0000000000c1/session.json")
        .is_file()
    {
        wrong.push("the Chief's acpmux sessions were not kept".into());
    }
    for runtime in [
        "agent-token",
        "optchat/inspector.json",
        "state",
        "acpmux/daemon.pid",
        "acpmux/hosts",
        "tui/machine-id",
        "tui/terminal-hosts-0123456789abcdef",
    ] {
        if fs::symlink_metadata(next_chief.join(runtime)).is_ok() {
            wrong.push(format!("NIGHTLY's runtime {runtime} was copied"));
        }
    }
    if session_dir.join("workspace-registry.sqlite3").exists() {
        wrong.push("NIGHTLY's workspace registry was copied".into());
    }
    let aside =
        fs::read_dir(home.join(".cmux/chief/.backups")).into_iter().flatten().flatten().any(|e| {
            e.file_name().to_string_lossy().starts_with(&format!("{NEXT}-post-update-"))
                && read(&e.path().join("optchat/person.md")) == "post-update-chief\n"
        });
    if !aside {
        wrong.push("NEXT's post-update Chief home was not kept aside".into());
    }
    if snapshot(&shared) != before {
        wrong.push("NIGHTLY's shared Chief home changed".into());
    }
    let records = (read(&new.join("adopted.json")), read(&next_chief.join("adopted.json")));
    if records.0.is_empty() || records.1.is_empty() {
        wrong.push("an adopted home has no adopted.json".into());
    }
    if wrong.is_empty() {
        let again = cli_as(NEXT, Some("cmux-next"), &home, &["__adopt-build-homes"]);
        let outcome: Value = serde_json::from_slice(&again.stdout).unwrap_or(Value::Null);
        let unchanged =
            (read(&new.join("adopted.json")), read(&next_chief.join("adopted.json"))) == records;
        if outcome["acpmux"] != "done" || outcome["chief"] != "done" || !unchanged {
            wrong.push(format!("a second launch did something\n{}", text(&again)));
        }
    }
    let _ = fs::remove_dir_all(&home);
    assert!(wrong.is_empty(), "NEXT's launch lost state:\n{}\n{}", wrong.join("\n"), text(&launch));
}

/// NIGHTLY and DEV builds never adopt NEXT's old homes, through the launch
/// step or `cmux acp`.
#[test]
fn nightly_and_dev_builds_never_adopt() {
    for bundle in [
        "com.cmuxterm.app.nightly",
        "com.cmuxterm.app.debug",
        "com.cmuxterm.app.debug.next.adopt",
        "com.cmuxterm.app",
        "com.cmuxterm.app.rc",
        "com.cmuxterm.app.staging",
    ] {
        let home = temp_home("never");
        let old = old_acpmux(&home);
        let shared = old_chief(&home);
        let before = (snapshot(&old), snapshot(&shared));
        let launch = cli_as(bundle, None, &home, &["__adopt-build-homes"]);
        let acp = cli_as(bundle, None, &home, &["acp", "config", "--json"]);
        let mut wrong = Vec::new();
        if !fs::symlink_metadata(&old).is_ok_and(|m| m.file_type().is_dir())
            || snapshot(&old) != before.0
        {
            wrong.push("NEXT's old acpmux home was changed".to_owned());
        }
        if snapshot(&shared) != before.1 {
            wrong.push("the shared Chief home was changed".to_owned());
        }
        for adopted in [home.join(".acpmux/builds").join(NEXT), home.join(".cmux/chief").join(NEXT)]
        {
            if fs::symlink_metadata(&adopted).is_ok() {
                wrong.push(format!("{} was created", adopted.display()));
            }
        }
        let _ = fs::remove_dir_all(&home);
        assert!(
            wrong.is_empty(),
            "{bundle} adopted:\n{}\n{}\n{}",
            wrong.join("\n"),
            text(&launch),
            text(&acp)
        );
    }
}

/// Stops the acpmux daemon of `home` (an explicit `ACPMUX_HOME`) when dropped.
struct StopDaemon(PathBuf, PathBuf);

impl Drop for StopDaemon {
    fn drop(&mut self) {
        let _ = acp_in(&self.0, &self.1, &["daemon", "shutdown"]);
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// `cmux acp <args>` outside any app with `ACPMUX_HOME=acpmux_home`: the
/// pre-update NEXT's daemon, which used `tags/cmux-next` as its home.
fn acp_in(home: &Path, acpmux_home: &Path, args: &[&str]) -> Output {
    let mut command = Command::new(bin());
    command.arg("acp").args(args).env("LC_ALL", "C").env("HOME", home);
    for key in FOREIGN {
        command.env_remove(key);
    }
    command.env("ACPMUX_HOME", acpmux_home).stdin(Stdio::null()).output().unwrap()
}

/// The pre-update NEXT's acpmux daemon still runs in the old home (daemons
/// outlive the app): the launch stops that daemon (agents kept), then adopts
/// its home, and the adopted home serves the old sessions.
#[test]
fn a_running_pre_update_daemon_is_stopped_before_the_adoption() {
    let home = temp_home("running");
    let old = old_acpmux(&home);
    let _guard = StopDaemon(home.clone(), old.clone());
    let started = acp_in(&home, &old, &["daemon", "start", "--json"]);
    let status: Value = serde_json::from_slice(&started.stdout).unwrap_or(Value::Null);
    let pid = status["pid"].as_u64().unwrap_or(0) as i32;
    assert!(pid > 0, "the pre-update daemon did not start\n{}", text(&started));
    let launch = cli_as(NEXT, Some("cmux-next"), &home, &["__adopt-build-homes"]);
    let mut wrong = Vec::new();
    // The daemon lets go of its lock before its process ends: give it up to 15 s.
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(15);
    // SAFETY: kill with signal 0 only checks that the process exists.
    while unsafe { libc::kill(pid, 0) } == 0 && std::time::Instant::now() < deadline {
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    // SAFETY: as above.
    if unsafe { libc::kill(pid, 0) } == 0 {
        wrong.push(format!("the pre-update daemon (pid {pid}) still runs"));
    }
    let new = home.join(".acpmux/builds").join(NEXT);
    if !new.join("adopted.json").is_file()
        || !new.join("sessions/01a10000-0000-7000-8000-00000000000a/session.json").is_file()
    {
        wrong.push("the old home was not adopted".into());
    }
    assert!(wrong.is_empty(), "{}\n{}", wrong.join("\n"), text(&launch));
}

/// `cmux acp` of NEXT never stops a daemon the app may use: with the
/// pre-update daemon running, the CLI defers and changes nothing.
#[test]
fn the_cli_never_stops_a_running_daemon_to_adopt() {
    let home = temp_home("cli-running");
    let old = old_acpmux(&home);
    let _guard = StopDaemon(home.clone(), old.clone());
    let started = acp_in(&home, &old, &["daemon", "start", "--json"]);
    let status: Value = serde_json::from_slice(&started.stdout).unwrap_or(Value::Null);
    let pid = status["pid"].as_u64().unwrap_or(0) as i32;
    assert!(pid > 0, "the pre-update daemon did not start\n{}", text(&started));
    let config = cli_as(NEXT, Some("cmux-next"), &home, &["acp", "config", "--json"]);
    // SAFETY: kill with signal 0 only checks that the process exists.
    let running = unsafe { libc::kill(pid, 0) } == 0;
    let untouched = fs::symlink_metadata(&old).is_ok_and(|m| m.file_type().is_dir());
    let recorded = home.join(".acpmux/builds").join(NEXT).join("adopted.json").exists();
    assert!(
        running && untouched && !recorded,
        "the CLI stopped or moved a running home\n{}",
        text(&config)
    );
}

/// The app's launch step as it runs in a real cmux NEXT bundle: no
/// `CMUX_BUNDLE_ID`; the CLI knows its build from the bundle around it.
#[test]
fn the_bundled_cli_of_next_adopts_without_any_identity_variable() {
    let home = temp_home("bundled");
    old_acpmux(&home);
    old_chief(&home);
    let bin_dir = home.join("apps/cmux NEXT.app/Contents/Resources/bin");
    fs::create_dir_all(&bin_dir).unwrap();
    fs::copy(bin(), bin_dir.join("cmux")).unwrap();
    fs::write(
        home.join("apps/cmux NEXT.app/Contents/Info.plist"),
        format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{NEXT}</string>
<key>LSEnvironment</key><dict><key>CMUX_TAG</key><string>cmux-next</string></dict>
</dict></plist>"#
        ),
    )
    .unwrap();
    let mut command = Command::new(bin_dir.join("cmux"));
    command.arg("__adopt-build-homes").env("LC_ALL", "C").env("HOME", &home);
    for key in FOREIGN {
        command.env_remove(key);
    }
    let launch = command.stdin(Stdio::null()).output().unwrap();
    let outcome: Value = serde_json::from_slice(&launch.stdout).unwrap_or(Value::Null);
    let sessions = home
        .join(".acpmux/builds")
        .join(NEXT)
        .join("sessions/01a10000-0000-7000-8000-00000000000a/session.json")
        .is_file();
    let memory = query(
        &home.join(".cmux/chief").join(NEXT).join("optchat/memory.sqlite3"),
        "SELECT text FROM memory",
    );
    let _ = fs::remove_dir_all(&home);
    assert!(
        outcome["acpmux"] == "adopted:rename"
            && outcome["chief"] == "adopted:clone"
            && sessions
            && memory.as_deref() == Some("remember-the-pier"),
        "the bundled NEXT CLI did not adopt\n{}",
        text(&launch)
    );
}

/// A DEV build that stands for NEXT (`CMUX_NEXT_CHIEF_BUILD_ID`, a DEBUG test
/// override) never adopts the person's real homes: only with both test
/// roots set, and then only under them.
#[test]
fn a_debug_override_adopts_only_under_test_roots() {
    let home = temp_home("override");
    let old = old_acpmux(&home);
    let shared = old_chief(&home);
    let before = (snapshot(&old), snapshot(&shared));
    let dev = "com.cmuxterm.app.debug.adopt.test";
    let bare = Command::new(bin())
        .arg("__adopt-build-homes")
        .env("LC_ALL", "C")
        .env("HOME", &home)
        .env("CMUX_BUNDLE_ID", dev)
        .env("CMUX_NEXT_CHIEF_BUILD_ID", NEXT)
        .env_remove("CMUX_NEXT_CHIEF_ROOT")
        .env_remove("CMUX_NEXT_ACPMUX_ROOT")
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let untouched = (snapshot(&old), snapshot(&shared)) == before
        && fs::symlink_metadata(&old).is_ok_and(|m| m.file_type().is_dir());
    let rooted = Command::new(bin())
        .arg("__adopt-build-homes")
        .env("LC_ALL", "C")
        .env("HOME", "/nonexistent-home-for-adoption-test")
        .env("CMUX_BUNDLE_ID", dev)
        .env("CMUX_NEXT_CHIEF_BUILD_ID", NEXT)
        .env("CMUX_NEXT_CHIEF_ROOT", home.join(".cmux/chief"))
        .env("CMUX_NEXT_ACPMUX_ROOT", home.join(".acpmux"))
        .stdin(Stdio::null())
        .output()
        .unwrap();
    let adopted = home.join(".acpmux/builds").join(NEXT).join("adopted.json").is_file()
        && home.join(".cmux/chief").join(NEXT).join("adopted.json").is_file();
    let _ = fs::remove_dir_all(&home);
    assert!(untouched, "the override without test roots adopted\n{}", text(&bare));
    assert!(adopted, "the override with test roots did not adopt under them\n{}", text(&rooted));
}

/// A Chief clone that fails puts NEXT's post-update Chief home back and
/// writes no record: the next launch tries again.
#[test]
fn a_failed_chief_clone_puts_the_post_update_home_back() {
    use std::os::unix::fs::PermissionsExt;
    let home = temp_home("rollback");
    let shared = old_chief(&home);
    let locked = shared.join("optchat/locked");
    fs::create_dir_all(&locked).unwrap();
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o000)).unwrap();
    let next_chief = home.join(".cmux/chief").join(NEXT);
    fs::create_dir_all(next_chief.join("optchat")).unwrap();
    fs::write(next_chief.join("optchat/person.md"), "post-update-chief\n").unwrap();
    let launch = cli_as(NEXT, Some("cmux-next"), &home, &["__adopt-build-homes"]);
    let outcome: Value = serde_json::from_slice(&launch.stdout).unwrap_or(Value::Null);
    let back = read(&next_chief.join("optchat/person.md")) == "post-update-chief\n";
    let recorded = next_chief.join("adopted.json").exists();
    let partials = fs::read_dir(home.join(".cmux/chief"))
        .into_iter()
        .flatten()
        .flatten()
        .any(|e| e.file_name().to_string_lossy().starts_with(".adopt-partial-"));
    fs::set_permissions(&locked, fs::Permissions::from_mode(0o700)).unwrap();
    let _ = fs::remove_dir_all(&home);
    assert!(
        outcome["chief"].as_str().is_some_and(|o| o.starts_with("deferred"))
            && back
            && !recorded
            && !partials,
        "a failed clone did not roll back\n{}",
        text(&launch)
    );
}
