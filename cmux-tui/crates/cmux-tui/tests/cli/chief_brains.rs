//! The daemon's Chief brain supervisor (cx-ebm.60.6) against a real headless
//! daemon and a stub brain executable that records its env and argv: a Chief
//! the person makes gets its own brain in `<home>/c/<id tail>` with its own
//! token; a person's message starts a stopped brain; a prompt change
//! restarts it between turns; delete and daemon shutdown stop it (delete also
//! removes its brain folder). The
//! default Chief is never started by the daemon.
//!
//! One acpmux per Chief home (hq-6d 2026-10-14): every brain uses the Chief
//! home's acpmux (`<home>/acpmux`, the default Chief's) with
//! `OPTCHAT_ACPMUX_SHARED=1`; delete ends only that Chief's sessions (the
//! brain's `end-sessions`), never `acpmux daemon shutdown` of the shared
//! home; the old per-Chief homes `<home>/c/<id>/a` are removed.

use super::*;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

/// Records the start (`n`), its env, the `claude` its PATH finds, argv and
/// pid in `$MUX_HOME`, then runs
/// until SIGTERM. The first start exits 0 at once when the Chief home had
/// an `exit-first` file before its pid file was written.
const STUB: &str = r#"#!/bin/sh
if [ "$1" = end-sessions ]; then echo "$MUX_HOME $ACPMUX_HOME" >> "$CMUX_CHIEF_HOME/ended"; exit 0; fi
n=$(cat "$MUX_HOME/starts" 2>/dev/null || echo 0)
n=$((n+1))
echo "$n" > "$MUX_HOME/starts"
quit=0
if [ "$n" = 1 ] && [ -e "$CMUX_CHIEF_HOME/exit-first" ]; then quit=1; fi
env > "$MUX_HOME/env.$n"
command -v claude > "$MUX_HOME/claude.$n" 2>/dev/null
echo "$@" > "$MUX_HOME/argv.$n"
echo "$$" > "$MUX_HOME/pid.tmp" && mv "$MUX_HOME/pid.tmp" "$MUX_HOME/pid.$n"
if [ "$quit" = 1 ]; then exit 0; fi
exec sleep 600
"#;

fn v2(conn: &mut Conn, operation: &str, params: Value) -> Value {
    let id = format!("brains-{}", conn.next);
    conn.next += 1;
    let mut params = params.as_object().cloned().unwrap_or_default();
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!("current"));
    let frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                       "operation": operation, "params": params});
    writeln!(conn.writer, "{frame}").unwrap();
    loop {
        let line = conn.line();
        if line["id"] == json!(id) && line["type"] == "response" {
            return line;
        }
    }
}

/// Waits (bounded) until `path` exists and is not empty (a stub's `>>`
/// creates the file before it writes); its trimmed contents.
fn wait_file(path: &std::path::Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if let Ok(text) = fs::read_to_string(path)
            && !text.trim().is_empty()
        {
            return text.trim().to_owned();
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("{} never appeared", path.display());
}

/// A brain's directory: `<home>/c/<last 8 of the id, lowercased>`.
fn brain_dir(home: &std::path::Path, chief: &str) -> PathBuf {
    home.join("c").join(chief[chief.len() - 8..].to_ascii_lowercase())
}

/// Waits (bounded) until `path` is gone.
fn wait_absent(path: &std::path::Path, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if !path.exists() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("{what} is still there: {}", path.display());
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Waits (bounded) until `pid` has ended.
fn wait_gone(pid: i32, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        if !alive(pid) {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("{what}: brain pid {pid} still runs");
}

fn env_of(path: &std::path::Path) -> BTreeMap<String, String> {
    fs::read_to_string(path)
        .unwrap()
        .lines()
        .filter_map(|line| line.split_once('='))
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .collect()
}

fn make_chief(server: &HeadlessServer, name: &str, role: &str) -> String {
    make_chief_with_brain(server, name, role).0
}

/// A new Chief's id and what its create answered about its brain.
fn make_chief_with_brain(server: &HeadlessServer, name: &str, role: &str) -> (String, Value) {
    let output = chief_cli(server, &["new", "--name", name, "--role", role, "--json"], "");
    assert_success(&output);
    let made: Value = serde_json::from_slice(&output.stdout).unwrap();
    (made["id"].as_str().unwrap().to_owned(), made["brain"].clone())
}

fn dm(home: &mut Conn, key: &str, chief: &str, name: &str) -> String {
    let created = home.request(
        "conversation-create",
        json!({"idempotency_key": key, "actor": "user_local", "title": name,
               "participants": [
                   {"id": "user_local", "kind": "human", "display_name": "Tester"},
                   {"id": chief, "kind": "agent", "display_name": name}]}),
    );
    created["conversation"]["id"].as_str().unwrap().to_owned()
}

fn say(home: &mut Conn, conversation: &str, key: &str, text: &str) {
    home.request(
        "conversation-op",
        json!({"conversation": conversation, "idempotency_key": key,
               "op": {"kind": "message.send", "client_msg_id": key,
                      "parts": [{"type": "text", "text": text}]}}),
    );
}

#[test]
fn each_chief_gets_its_own_brain_that_the_daemon_starts_and_stops() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cb");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    // A stub acpmux that records each call (its args and ACPMUX_HOME).
    let acpmux = files.join("acpmux.sh");
    let calls = files.join("acpmux-calls");
    // It exits 1 as the real one does when no daemon runs in that home (cx-qryd0 review).
    fs::write(
        &acpmux,
        format!("#!/bin/sh\necho \"$* $ACPMUX_HOME\" >> '{}'\nexit 1\n", calls.display()),
    )
    .unwrap();
    fs::set_permissions(&acpmux, fs::Permissions::from_mode(0o755)).unwrap();
    // Short: the brains' sockets live under it (103-byte limit).
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    // An old per-Chief acpmux home (before one acpmux per Chief home): removed, also when its
    // stop fails because no daemon runs there.
    let old = chief_home.join("c/0ldch1ef/a");
    fs::create_dir_all(old.join("state")).unwrap();
    fs::write(old.join("config.json"), "{}").unwrap();
    // One whose daemon still holds its lock (the stop failed): kept.
    let held = chief_home.join("c/h3ldch1ef/a");
    fs::create_dir_all(held.join("state")).unwrap();
    let mut holder = Command::new("python3")
        .args(["-c", "import fcntl,sys,time; f=open(sys.argv[1],'a'); fcntl.flock(f, fcntl.LOCK_EX); print('held', flush=True); time.sleep(120)"])
        .arg(held.join("daemon.lock"))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut line = String::new();
        BufReader::new(holder.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "held");
    }
    // The shared home stays as it is.
    let shared = chief_home.join("acpmux");
    fs::create_dir_all(&shared).unwrap();
    fs::write(shared.join("keep"), "").unwrap();
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": acpmux},
    })
    .to_string();
    let mut server = HeadlessServer::start_with_options(
        "chief-brains",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let mut home = Conn::open(&server.socket);

    // A new Chief gets its own brain at once, in its own directory, and the
    // create says so from the supervisor's real state.
    let (scout, brain) = make_chief_with_brain(&server, "Scout", "Researcher");
    assert_eq!(brain, json!({"state": "started"}), "{brain}");
    let scout_home = brain_dir(&chief_home, &scout);
    let scout_pid: i32 = wait_file(&scout_home.join("pid.1")).parse().unwrap();
    assert!(alive(scout_pid));
    let env = env_of(&scout_home.join("env.1"));
    let expect = |key: &str, value: &str| {
        assert_eq!(env.get(key).map(String::as_str), Some(value), "{key}: {env:?}");
    };
    expect("MUX_HOME", scout_home.to_str().unwrap());
    expect("OPTCHAT_CHIEF_PARTICIPANT", &scout);
    expect("OPTCHAT_GROUP_WAKE", "every");
    expect("MUX_AGENT_TOKEN_FILE", scout_home.join("agent-token").to_str().unwrap());
    expect("MUX_HOST_LOG", scout_home.join("host.log").to_str().unwrap());
    expect("CMUX_CHIEF_HOME", chief_home.to_str().unwrap());
    expect("ACPMUX_HOME", shared.to_str().unwrap());
    expect("OPTCHAT_ACPMUX_SHARED", "1");
    expect("CMUX_SOCKET_PATH", chief_home.join("state/app.sock").to_str().unwrap());
    expect("MUX_USER_NAME", "Test Person");
    expect("ACPMUX_BIN", acpmux.to_str().unwrap());
    assert!(env["PATH"].starts_with("/opt/cmux-test/bin:"), "{env:?}");
    assert!(!env.contains_key("CMUX_TUI_CHIEF_BRAINS"), "{env:?}");
    assert!(!env.contains_key("ACPMUX_SOCKET"), "{env:?}");
    assert_eq!(
        fs::read_to_string(scout_home.join("argv.1")).unwrap().trim(),
        format!(
            "host --daemon-socket {} --mux-home {}",
            server.socket.display(),
            scout_home.display()
        ),
    );
    // Its token is its own, 0600, and binds as that Chief.
    let token_file = scout_home.join("agent-token");
    assert_eq!(fs::metadata(&token_file).unwrap().permissions().mode() & 0o777, 0o600);
    let token = fs::read_to_string(&token_file).unwrap();
    let mut as_scout = Conn::open(&server.socket);
    as_scout.request("conversation-bind", json!({"participant": scout, "token": token}));
    let me = v2(&mut as_scout, "chief.profile.get", json!({"chief": scout}));
    assert_eq!(me["ok"], true, "{me}");

    // A second Chief whose first brain exits 0: it stays stopped until a
    // person's message in a conversation it is in starts it again.
    fs::write(chief_home.join("exit-first"), "").unwrap();
    let ops = make_chief(&server, "Ops", "Release captain");
    let ops_home = brain_dir(&chief_home, &ops);
    wait_file(&ops_home.join("pid.1"));
    fs::remove_file(chief_home.join("exit-first")).unwrap();
    // A message to the default Chief starts nothing here (the app runs it).
    let main = dm(&mut home, "dm-main", "agent_mux", "Chief");
    say(&mut home, &main, "to-main", "hello Chief");
    let ops_dm = dm(&mut home, "dm-ops", &ops, "Ops");
    say(&mut home, &ops_dm, "to-ops", "status?");
    let ops_pid: i32 = wait_file(&ops_home.join("pid.2")).parse().unwrap();
    assert!(alive(ops_pid));
    assert_eq!(env_of(&ops_home.join("env.2"))["OPTCHAT_CHIEF_PARTICIPANT"], ops);
    assert!(!brain_dir(&chief_home, "agent_mux").exists(), "the default Chief got a daemon brain");
    assert_ne!(token, fs::read_to_string(ops_home.join("agent-token")).unwrap());

    // A prompt change restarts the brain, but only after its turn: the
    // brain types while a main turn runs.
    let scout_dm = dm(&mut home, "dm-scout", &scout, "Scout");
    as_scout.request("conversation-typing", json!({"conversation": scout_dm, "on": true}));
    let edited = chief_cli(&server, &["edit", &scout, "--role", "Night watch", "--json"], "");
    assert_success(&edited);
    // After the edit the brain still runs its turn.
    let _ = v2(&mut home, "chief.profile.list", json!({}));
    assert!(alive(scout_pid), "the brain was stopped in its turn");
    assert!(!scout_home.join("pid.2").exists(), "the brain restarted in its turn");
    as_scout.request("conversation-typing", json!({"conversation": scout_dm, "on": false}));
    let restarted: i32 = wait_file(&scout_home.join("pid.2")).parse().unwrap();
    wait_gone(scout_pid, "after the prompt change");
    assert!(alive(restarted));

    // Delete stops that Chief's brain only.
    let deleted = chief_cli(&server, &["delete", &ops, "--json"], "");
    assert_success(&deleted);
    wait_gone(ops_pid, "after delete");
    // ...and its sessions on the shared acpmux, by the brain's own
    // `end-sessions` as that Chief; the shared daemon keeps running.
    assert_eq!(
        wait_file(&chief_home.join("ended")),
        format!("{} {}", ops_home.display(), shared.display()),
        "the deleted Chief's sessions were not ended"
    );
    let called = fs::read_to_string(&calls).unwrap_or_default();
    assert!(
        !called.lines().any(|l| l.starts_with("daemon shutdown")
            && !l.ends_with("/c/0ldch1ef/a")
            && !l.ends_with("/c/h3ldch1ef/a")),
        "a daemon shutdown other than the old per-Chief home's: {called}"
    );
    assert!(shared.join("keep").exists(), "the shared acpmux home was touched");
    // ...and its brain folder (its memory and state) goes once its sessions ended; the other
    // Chief's stays.
    wait_absent(&ops_home, "the deleted Chief's brain folder");
    assert!(scout_home.join("starts").exists(), "another Chief's brain folder was touched");
    assert!(!old.exists(), "the old per-Chief acpmux home is still there");
    assert!(held.exists(), "an old Chief home whose daemon holds its lock was removed");
    let _ = holder.kill();
    let _ = holder.wait();
    assert!(alive(restarted));

    // Daemon shutdown stops the rest.
    let daemon = i32::try_from(server.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = server.child.wait();
    wait_gone(restarted, "after daemon shutdown");
}

/// Each Chief's brain titles its conversation with the Chief's own name
/// (hq-6d 2026-10-14): `MUX_CHIEF_TITLE` is the record's display_name for a
/// Chief that is not the default (the brain's create request and DM title,
/// optchat-chief daemon.rs `names_from_env`), not the app's "Chief", so two
/// Chiefs never show as two "Chief" rows. A rename reaches the next start:
/// the brain restarts with the new name.
///
/// One cmux MCP server per Chief turn (hq-6d 2026-10-14): acpmux gives every
/// agent chat its own `cmux mcp serve`, so a brain gets no
/// `CMUX_MCP_COMMAND`, also from an app that still passes `mcp_command`.
#[test]
fn each_chief_brain_is_titled_with_its_own_name() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbt");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false",
                "mcp_command": "/opt/cmux-test/bin/cmux"},
    })
    .to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-brains-title",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let server = &owned;
    let scout = make_chief(server, "Scout", "Researcher");
    let ops = make_chief(server, "Ops", "Release captain");
    let scout_home = brain_dir(&chief_home, &scout);
    let ops_home = brain_dir(&chief_home, &ops);
    let scout_pid: i32 = wait_file(&scout_home.join("pid.1")).parse().unwrap();
    let ops_pid: i32 = wait_file(&ops_home.join("pid.1")).parse().unwrap();
    let title = |home: &std::path::Path, n: u32| {
        env_of(&home.join(format!("env.{n}"))).get("MUX_CHIEF_TITLE").cloned()
    };
    assert_eq!(title(&scout_home, 1).as_deref(), Some("Scout"));
    assert_eq!(title(&ops_home, 1).as_deref(), Some("Ops"));
    let env = env_of(&scout_home.join("env.1"));
    assert!(!env.contains_key("CMUX_MCP_COMMAND"), "{env:?}");

    let renamed = chief_cli(server, &["edit", &scout, "--name", "Scout Two", "--json"], "");
    assert_success(&renamed);
    let renamed_pid: i32 = wait_file(&scout_home.join("pid.2")).parse().unwrap();
    assert_eq!(title(&scout_home, 2).as_deref(), Some("Scout Two"));
    wait_gone(scout_pid, "after the rename");

    // Stop the daemon so it stops the brains it started.
    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    wait_gone(renamed_pid, "after daemon shutdown");
    wait_gone(ops_pid, "after daemon shutdown");
}

/// A Chief's brain finds the harnesses the person's login shell finds
/// (hq-6d P1 2026-10-14, "acpmux has no harness named claude"): the brain
/// and its own acpmux start from an empty environment, and a claude that is
/// not in one of the fixed tool directories (Homebrew elsewhere, nvm, a
/// login-shell PATH) was not found. The app passes its captured login PATH
/// once (`app.path`); the brain's PATH has it after the bundle's `bin`.
#[test]
fn a_chief_brain_finds_claude_on_the_persons_login_path() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbp");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    // claude only in a directory outside every fixed tool directory.
    let tools = files.join("login-tools");
    fs::create_dir_all(&tools).unwrap();
    let claude = tools.join("claude");
    fs::write(&claude, "#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    // A relative entry is dropped (a file planted in a project never runs).
    let login_path = format!(".:relative/bin:{}:/usr/bin:/bin", tools.display());
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false",
                "path": login_path},
    })
    .to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-brains-path",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let server = &owned;
    let scout = make_chief(server, "Scout", "Researcher");
    let scout_home = brain_dir(&chief_home, &scout);
    let pid: i32 = wait_file(&scout_home.join("pid.1")).parse().unwrap();
    let found = fs::read_to_string(scout_home.join("claude.1")).unwrap_or_default();
    let path = env_of(&scout_home.join("env.1")).get("PATH").cloned().unwrap_or_default();
    assert_eq!(found.trim(), claude.display().to_string(), "PATH={path}");
    assert!(path.starts_with("/opt/cmux-test/bin:"), "the bundle's bin stays first: {path}");
    assert!(path.split(':').all(|d| d.starts_with('/')), "absolute entries only: {path}");

    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    wait_gone(pid, "after daemon shutdown");
}

/// The account's home directory (the user database), as the app's default
/// Chief host gets it (`FileManager.homeDirectoryForCurrentUser`).
fn account_home() -> String {
    // SAFETY: getpwuid returns a pointer into static storage or null; it is
    // read at once, on this thread.
    unsafe {
        let record = libc::getpwuid(libc::getuid());
        assert!(!record.is_null(), "no user database record");
        std::ffi::CStr::from_ptr((*record).pw_dir).to_str().unwrap().to_owned()
    }
}

/// A new Chief's brain gets the same HOME as the default Chief's (hq-6d P1
/// 2026-10-14, mac26 401): the account's home, not the HOME of the process
/// that started the app. An app started by a job runner with its own HOME
/// (nx-remote on mac26: HOME is the job root) gave the daemon that HOME; the
/// new Chief's host then read the person's Claude settings env (the
/// subrouter route) from `<job root>/.claude/settings.json`, found none,
/// and its turns signed in with the account's expired login.
#[test]
fn a_chief_brain_gets_the_accounts_home_like_the_default_chief() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbh");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    // The job runner's own HOME, which the daemon inherits.
    let job_home = files.join("job-home");
    fs::create_dir_all(job_home.join(".claude")).unwrap();
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false"},
    })
    .to_string();
    let job_home_text = job_home.display().to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-brains-home",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str()), ("HOME", job_home_text.as_str())],
    );
    let server = &owned;
    let scout = make_chief(server, "Scout", "Researcher");
    let scout_home = brain_dir(&chief_home, &scout);
    let pid: i32 = wait_file(&scout_home.join("pid.1")).parse().unwrap();
    let env = env_of(&scout_home.join("env.1"));
    assert_eq!(
        env.get("HOME").map(String::as_str),
        Some(account_home().as_str()),
        "the brain's HOME is not the account's (the job runner's was {job_home_text})"
    );

    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    wait_gone(pid, "after daemon shutdown");
}

/// cx-tgf4h: a daemon started with agents off in its build session
/// (`ACPMUX_AGENT_LAUNCH=deny`, as a GUI build job sets it) starts no brain
/// for a new Chief, also on a message to it, and `cmux chief engine` says
/// why at once instead of "not running".
#[test]
fn a_daemon_with_agents_off_starts_no_brain_and_says_why() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbd");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false"},
    })
    .to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-brains-deny",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str()), ("ACPMUX_AGENT_LAUNCH", "deny")],
    );
    let server = &owned;
    let mut home = Conn::open(&server.socket);
    let (scout, brain) = make_chief_with_brain(server, "Scout", "Researcher");
    assert_eq!(brain, json!({"state": "not_started", "reason": "launch_disabled"}), "{brain}");
    let conversation = dm(&mut home, "deny-dm", &scout, "Scout");
    say(&mut home, &conversation, "deny-1", "hello");
    // The supervisor says, once, that the brain does not start.
    let deadline = Instant::now() + Duration::from_secs(20);
    let line = format!("Chief brain {scout} does not start: agents are disabled");
    while !server.stderr_tail().contains(&line) {
        assert!(
            Instant::now() < deadline,
            "no refusal line; daemon stderr: {}",
            server.stderr_tail()
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let scout_home = brain_dir(&chief_home, &scout);
    assert!(!scout_home.join("starts").exists(), "a brain started under deny");

    let engine = chief_cli(server, &["engine", "--json"], "");
    assert_eq!(engine.status.code(), Some(1), "{}", String::from_utf8_lossy(&engine.stderr));
    let stderr = String::from_utf8_lossy(&engine.stderr);
    assert!(stderr.contains("agents are disabled in this build session"), "{stderr}");

    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    let _ = fs::remove_dir_all(&files);
}

/// A fake brain tools socket at `path` (bound by the test, as the brain host
/// binds `$MUX_HOME/optchat/tools.sock`): it records each line it gets and
/// answers with its own `label` as the engine harness, so an answer names
/// the brain that gave it.
fn fake_tools_socket(path: &std::path::Path, label: &'static str) -> Arc<Mutex<Vec<Value>>> {
    fake_tools_socket_answering(
        path,
        json!({"engine": {"harness": label}, "choice": {}, "stopped": true}),
    )
}

/// [`fake_tools_socket`] that answers every line with `answer`.
fn fake_tools_socket_answering(path: &std::path::Path, answer: Value) -> Arc<Mutex<Vec<Value>>> {
    use std::os::unix::net::UnixListener;
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    let listener = UnixListener::bind(path).unwrap();
    let lines = Arc::new(Mutex::new(Vec::new()));
    let seen = lines.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            let mut line = String::new();
            if BufReader::new(&stream).read_line(&mut line).is_ok()
                && let Ok(value) = serde_json::from_str::<Value>(&line)
            {
                seen.lock().unwrap().push(value);
                let _ = writeln!(&stream, "{answer}");
            }
        }
    });
    lines
}

/// `v2` with an idempotency key (chief.engine.set and chief.stop need one).
fn v2_keyed(conn: &mut Conn, operation: &str, key: &str, params: Value) -> Value {
    let id = format!("brains-{}", conn.next);
    conn.next += 1;
    let mut params = params.as_object().cloned().unwrap_or_default();
    params.insert("machine".into(), json!("current"));
    params.insert("session".into(), json!("current"));
    let frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": id,
                       "operation": operation, "idempotency_key": key, "params": params});
    writeln!(conn.writer, "{frame}").unwrap();
    loop {
        let line = conn.line();
        if line["id"] == json!(id) && line["type"] == "response" {
            return line;
        }
    }
}

/// chief-brains-v1 (cx-ebm.60.11): `chief.engine.get`, `chief.engine.set`
/// and `chief.stop` take `chief` and act on that Chief's brain only (its
/// tools socket under `<home>/c/<id tail>`); without `chief`, or with the
/// default Chief's id, they reach the default Chief's brain
/// (`CMUX_TUI_CHIEF_TOOLS_SOCKET`) as before. An unknown Chief reaches no
/// brain. The daemon advertises the capability in `identify`.
#[test]
fn chief_engine_and_stop_act_on_the_named_chief_only() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbn");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let default_socket = files.join("d.sock");
    let default_lines = fake_tools_socket(&default_socket, "default");
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false"},
    })
    .to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-brains-named",
        None,
        None,
        &[
            ("CMUX_TUI_CHIEF_BRAINS", brains.as_str()),
            ("CMUX_TUI_CHIEF_TOOLS_SOCKET", default_socket.to_str().unwrap()),
        ],
    );
    let server = &owned;
    let mut home = Conn::open(&server.socket);

    let identity = home.request("identify", json!({}));
    let capabilities = identity["capabilities"].as_array().cloned().unwrap_or_default();
    assert!(capabilities.contains(&json!("chief-brains-v1")), "{identity}");

    let scout = make_chief(server, "Scout", "Researcher");
    let ops = make_chief(server, "Ops", "Release captain");
    let scout_home = brain_dir(&chief_home, &scout);
    let ops_home = brain_dir(&chief_home, &ops);
    wait_file(&scout_home.join("pid.1"));
    wait_file(&ops_home.join("pid.1"));
    let scout_lines = fake_tools_socket(&scout_home.join("optchat/tools.sock"), "scout");
    let ops_lines = fake_tools_socket(&ops_home.join("optchat/tools.sock"), "ops");
    let counts =
        || [&default_lines, &scout_lines, &ops_lines].map(|lines| lines.lock().unwrap().len());
    let harness = |answer: &Value| answer["result"]["engine"]["harness"].clone();

    // engine.get names Scout: only Scout's brain is asked.
    let got = v2(&mut home, "chief.engine.get", json!({"chief": scout}));
    assert_eq!(got["ok"], true, "{got}");
    assert_eq!(harness(&got), json!("scout"), "{got}");
    assert_eq!(counts(), [0, 1, 0]);
    assert_eq!(scout_lines.lock().unwrap()[0], json!({"tool": "engine", "action": "show"}));

    // engine.set names Ops: only Ops's brain gets the change.
    let set = v2_keyed(
        &mut home,
        "chief.engine.set",
        "named-set-1",
        json!({"chief": ops, "harness": "codex"}),
    );
    assert_eq!(set["ok"], true, "{set}");
    assert_eq!(counts(), [0, 1, 1]);
    assert_eq!(
        ops_lines.lock().unwrap()[0],
        json!({"tool": "engine", "action": "set", "harness": "codex"})
    );

    // stop names Scout: only Scout's turn stops.
    let stopped = v2_keyed(&mut home, "chief.stop", "named-stop-1", json!({"chief": scout}));
    assert_eq!(stopped["ok"], true, "{stopped}");
    assert_eq!(stopped["result"]["value"]["stopped"], true, "{stopped}");
    assert_eq!(counts(), [0, 2, 1]);
    assert_eq!(scout_lines.lock().unwrap()[1], json!({"tool": "stop"}));

    // No chief, or the default Chief's id: the default Chief, as today.
    let plain = v2(&mut home, "chief.engine.get", json!({}));
    assert_eq!(harness(&plain), json!("default"), "{plain}");
    let named_default = v2(&mut home, "chief.engine.get", json!({"chief": "agent_mux"}));
    assert_eq!(harness(&named_default), json!("default"), "{named_default}");
    let default_stop = v2_keyed(&mut home, "chief.stop", "plain-stop-1", json!({}));
    assert_eq!(default_stop["ok"], true, "{default_stop}");
    assert_eq!(counts(), [3, 2, 1]);
    assert_eq!(default_lines.lock().unwrap()[2], json!({"tool": "stop"}));

    // A Chief that does not exist reaches no brain.
    let missing = "agent_01ZZZZZZZZZZZZZZZZZZZZZZZZ";
    let unknown = v2(&mut home, "chief.engine.get", json!({"chief": missing}));
    assert_eq!(unknown["ok"], false, "{unknown}");
    assert_eq!(unknown["error"]["details"]["reason"], "not_found", "{unknown}");
    assert_eq!(counts(), [3, 2, 1]);

    // A live Chief whose brain serves no socket: a read is unavailable and
    // does not fall back to another Chief's brain.
    fs::remove_file(ops_home.join("optchat/tools.sock")).unwrap();
    let idle = v2(&mut home, "chief.engine.get", json!({"chief": ops}));
    assert_eq!(idle["ok"], false, "{idle}");
    assert_eq!(idle["error"]["details"]["reason"], "unavailable", "{idle}");
    assert_eq!(counts(), [3, 2, 1]);

    // A Chief whose brain stopped (its first start exits 0, as after an idle
    // stop): reads and stop do not start it; engine.set starts it on demand
    // and reaches it once it serves its socket.
    fs::write(chief_home.join("exit-first"), "").unwrap();
    let night = make_chief(server, "Night", "Night watch");
    let night_home = brain_dir(&chief_home, &night);
    let first: i32 = wait_file(&night_home.join("pid.1")).parse().unwrap();
    fs::remove_file(chief_home.join("exit-first")).unwrap();
    wait_gone(first, "the first Night brain");
    let read = v2(&mut home, "chief.engine.get", json!({"chief": night}));
    assert_eq!(read["error"]["details"]["reason"], "unavailable", "{read}");
    let stop = v2_keyed(&mut home, "chief.stop", "night-stop-1", json!({"chief": night}));
    assert_eq!(stop["error"]["details"]["reason"], "unavailable", "{stop}");
    assert!(!night_home.join("pid.2").exists(), "a read or stop started the brain");
    let frame = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "night-set",
                       "operation": "chief.engine.set", "idempotency_key": "night-set-1",
                       "params": {"machine": "current", "session": "current",
                                  "chief": night, "model": "m2"}});
    writeln!(home.writer, "{frame}").unwrap();
    wait_file(&night_home.join("pid.2"));
    let night_lines = fake_tools_socket(&night_home.join("optchat/tools.sock"), "night");
    let set = loop {
        let line = home.line();
        if line["id"] == "night-set" && line["type"] == "response" {
            break line;
        }
    };
    assert_eq!(set["ok"], true, "{set}");
    // Started once by the set, never by the read or the stop before it.
    assert_eq!(fs::read_to_string(night_home.join("starts")).unwrap().trim(), "2");
    assert_eq!(
        night_lines.lock().unwrap().clone(),
        vec![json!({"tool": "engine", "action": "set", "model": "m2"})]
    );
    assert_eq!(counts(), [3, 2, 1]);

    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    let _ = fs::remove_dir_all(&files);
}

/// A Chief made before the daemon's brain supervisor is installed (the
/// control socket accepts clients first): the create waits for the
/// supervisor's real answer instead of saying "not started". A test-only
/// FIFO gate (debug builds) holds the install until the create is committed,
/// so the test proves that path every run.
#[test]
fn a_chief_made_before_the_brain_supervisor_runs_reports_its_brain_started() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbe");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let gate = files.join("gate");
    let gate_c = std::ffi::CString::new(gate.to_str().unwrap()).unwrap();
    // SAFETY: a valid C path; the test's own directory.
    assert_eq!(unsafe { libc::mkfifo(gate_c.as_ptr(), 0o600) }, 0);
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false"},
    })
    .to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-brains-early",
        None,
        None,
        &[
            ("CMUX_TUI_CHIEF_BRAINS", brains.as_str()),
            ("CMUX_TUI_TEST_CHIEF_BRAINS_GATE", gate.to_str().unwrap()),
        ],
    );
    let socket = owned.socket.clone();
    let made = std::thread::spawn(move || {
        let mut command = Command::new(bin());
        command
            .arg("--socket")
            .arg(&socket)
            .args(["chief", "new", "--name", "Scout", "--role", "Researcher", "--json"])
            .env("LC_ALL", "C")
            .env_remove("CMUX_TUI_SOCKET");
        for key in [
            "ACPMUX_ENV",
            "ACPMUX_SESSION_ID",
            "ACPMUX_SESSION_NAME",
            "CMUX_CHIEF_OWNER_SOCKET",
            "CMUX_AGENT_PRINCIPAL",
            "CMUX_AGENT_CLASS",
            "CMUX_AGENT_HARNESS",
        ] {
            command.env_remove(key);
        }
        command.output().unwrap()
    });
    // The create is committed while the supervisor is held: it now waits.
    let mut home = Conn::open(&owned.socket);
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let listed = v2(&mut home, "chief.profile.list", json!({}));
        if listed["result"]["chiefs"]
            .as_array()
            .is_some_and(|c| c.iter().any(|r| r["display_name"] == "Scout"))
        {
            break;
        }
        assert!(Instant::now() < deadline, "the create never committed: {listed}");
        std::thread::sleep(Duration::from_millis(25));
    }
    assert!(!made.is_finished(), "the create answered before the supervisor ran");
    // Release the install: the supervisor handles the queued create and answers.
    let writer = fs::OpenOptions::new().write(true).open(&gate).unwrap();
    let output = made.join().unwrap();
    drop(writer);
    assert_success(&output);
    let record: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(record["brain"], json!({"state": "started"}), "{record}");
    let scout = record["id"].as_str().unwrap().to_owned();
    let pid: i32 = wait_file(&brain_dir(&chief_home, &scout).join("pid.1")).parse().unwrap();
    assert!(alive(pid));

    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    wait_gone(pid, "the brain after daemon shutdown");
    let _ = fs::remove_dir_all(&files);
}

/// cx-di8pd: `cmux chief edit --name` renames the Chief's own conversation
/// (its oldest DM with the person) in the owner, so every reader of the
/// title (Home's header and list, the CLI, a page) follows the registry.
/// A later conversation with the same Chief keeps the title its person gave
/// it, and an edit of another field changes no title.
#[test]
fn a_chief_rename_retitles_its_own_conversation_only() {
    let server = HeadlessServer::start("chief-rename-title");
    let mut home = Conn::open(&server.socket);
    let scout = make_chief(&server, "Scout", "Researcher");
    let direct = dm(&mut home, "scout-dm", &scout, "Scout");
    // A later conversation with only Scout and a title of its own (a channel).
    std::thread::sleep(Duration::from_millis(5)); // distinct created_at for the oldest-first rule
    let channel = dm(&mut home, "scout-notes", &scout, "Scout notes");
    let title = |home: &mut Conn, id: &str| -> String {
        let listed = home.request("conversation-list", json!({}));
        listed["conversations"]
            .as_array()
            .unwrap()
            .iter()
            .find(|c| c["id"] == json!(id))
            .map(|c| c["title"].as_str().unwrap_or_default().to_owned())
            .unwrap_or_else(|| panic!("{id} is not listed: {listed}"))
    };

    let renamed = chief_cli(&server, &["edit", &scout, "--name", "Scout Two", "--json"], "");
    assert_success(&renamed);
    assert_eq!(title(&mut home, &direct), "Scout Two");
    assert_eq!(title(&mut home, &channel), "Scout notes");

    let role = chief_cli(&server, &["edit", &scout, "--role", "Night watch", "--json"], "");
    assert_success(&role);
    assert_eq!(title(&mut home, &direct), "Scout Two");

    let again = chief_cli(&server, &["edit", &scout, "--name", "Scout Three", "--json"], "");
    assert_success(&again);
    assert_eq!(title(&mut home, &direct), "Scout Three");
    assert_eq!(title(&mut home, &channel), "Scout notes");

    // A title the person gave the DM stays through an edit that sends the same name.
    home.request(
        "conversation-op",
        json!({"conversation": direct, "idempotency_key": "my-title",
               "op": {"kind": "title.set", "title": "My scout"}}),
    );
    let same = chief_cli(
        &server,
        &["edit", &scout, "--name", "Scout Three", "--role", "Day watch", "--json"],
        "",
    );
    assert_success(&same);
    assert_eq!(title(&mut home, &direct), "My scout");
}

/// cx-mbbee: `cmux chief engine --chief ID` (show and set) and `cmux chief
/// stop --chief ID` send the daemon's `chief` field (chief-brains-v1): each
/// reaches that Chief's brain only; without `--chief` the default Chief's.
#[test]
fn chief_engine_and_stop_cli_take_a_chief() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cbc");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let default_socket = files.join("d.sock");
    let default_lines = fake_tools_socket(&default_socket, "default");
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false"},
    })
    .to_string();
    let server = HeadlessServer::start_with_options(
        "chief-brains-cli",
        None,
        None,
        &[
            ("CMUX_TUI_CHIEF_BRAINS", brains.as_str()),
            ("CMUX_TUI_CHIEF_TOOLS_SOCKET", default_socket.to_str().unwrap()),
        ],
    );
    let scout = make_chief(&server, "Scout", "Researcher");
    let scout_home = brain_dir(&chief_home, &scout);
    wait_file(&scout_home.join("pid.1"));
    let scout_lines = fake_tools_socket(&scout_home.join("optchat/tools.sock"), "scout");
    let counts = || [&default_lines, &scout_lines].map(|lines| lines.lock().unwrap().len());

    let shown = chief_cli(&server, &["engine", "--chief", &scout, "--json"], "");
    assert_success(&shown);
    let report: Value = serde_json::from_slice(&shown.stdout).unwrap();
    assert_eq!(report["engine"]["harness"], "scout", "{report}");
    assert_eq!(counts(), [0, 1]);

    let set = chief_cli(&server, &["engine", "--chief", &scout, "--effort", "low", "--json"], "");
    assert_success(&set);
    assert_eq!(counts(), [0, 2]);
    assert_eq!(
        scout_lines.lock().unwrap()[1],
        json!({"tool": "engine", "action": "set", "effort": "low"})
    );

    let stopped = chief_cli(&server, &["stop", "--chief", &scout], "");
    assert_success(&stopped);
    assert_eq!(counts(), [0, 3]);
    assert_eq!(scout_lines.lock().unwrap()[2], json!({"tool": "stop"}));

    let plain = chief_cli(&server, &["engine", "--json"], "");
    assert_success(&plain);
    let report: Value = serde_json::from_slice(&plain.stdout).unwrap();
    assert_eq!(report["engine"]["harness"], "default", "{report}");
    assert_eq!(counts(), [1, 3]);

    // --chief goes with engine or stop only.
    let stray = chief_cli(&server, &["--chief", &scout, "-p", "hi"], "");
    assert_eq!(stray.status.code(), Some(2), "{stray:?}");
}

/// The record is a Chief's backend (u2586, 2026-10-19): a committed write
/// that changes its engine writes `harness`, `model` and `effort` into the
/// engine file its brain reads at each turn (`<brain home>/optchat/
/// engine.json`; the Chief home root for the default Chief), keeping the
/// file's other fields; a write that leaves the engine as it is leaves the
/// file alone; a `chief.engine.set` the brain took is written back into the
/// record.
#[test]
fn a_chiefs_engine_is_written_where_its_brain_reads_it() {
    use std::os::unix::fs::PermissionsExt;

    let files = unique_temp_dir("cme");
    fs::create_dir_all(&files).unwrap();
    let stub = files.join("brain.sh");
    fs::write(&stub, STUB).unwrap();
    fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();
    let chief_home = files.join("h");
    fs::create_dir_all(&chief_home).unwrap();
    let brains = json!({
        "executable": stub,
        "home": chief_home,
        "app": {"bin_dir": "/opt/cmux-test/bin", "user_name": "Test Person",
                "chief_title": "Chief", "acpmux_bin": "/usr/bin/false"},
    })
    .to_string();
    let mut owned = HeadlessServer::start_with_options(
        "chief-engine-mirror",
        None,
        None,
        &[("CMUX_TUI_CHIEF_BRAINS", brains.as_str())],
    );
    let server = &owned;
    let read = |path: &std::path::Path| -> Value {
        serde_json::from_slice(
            &fs::read(path).unwrap_or_else(|e| panic!("{}: {e}", path.display())),
        )
        .unwrap()
    };

    let made = chief_cli(
        server,
        &["new", "--name", "Scout", "--harness", "codex", "--model", "m1", "--json"],
        "",
    );
    assert_success(&made);
    let scout =
        serde_json::from_slice::<Value>(&made.stdout).unwrap()["id"].as_str().unwrap().to_owned();
    let file = brain_dir(&chief_home, &scout).join("optchat/engine.json");
    assert_eq!(read(&file), json!({"harness": "codex", "model": "m1"}));
    #[cfg(unix)]
    assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);

    // The brain's own fields stay; the record's three replace the file's.
    fs::write(&file, r#"{"harness": "codex", "model": "m1", "speed": "fast"}"#).unwrap();
    assert_success(&chief_cli(server, &["edit", &scout, "--model", "m2", "--effort", "high"], ""));
    assert_eq!(
        read(&file),
        json!({"harness": "codex", "model": "m2", "effort": "high", "speed": "fast"})
    );
    // A rename leaves the engine, and so the file, as it is.
    fs::write(&file, r#"{"harness": "claude"}"#).unwrap();
    assert_success(&chief_cli(server, &["edit", &scout, "--name", "Scout Two"], ""));
    assert_eq!(read(&file), json!({"harness": "claude"}));

    // The default Chief's engine file is the Chief home root's.
    assert_success(&chief_cli(server, &["edit", "agent_mux", "--effort", "low"], ""));
    assert_eq!(read(&chief_home.join("optchat/engine.json")), json!({"effort": "low"}));

    // A change the brain took through chief.engine.set is the record's too.
    let socket = brain_dir(&chief_home, &scout).join("optchat/tools.sock");
    let _ = fs::remove_file(&socket);
    let lines = fake_tools_socket_answering(
        &socket,
        json!({"engine": {"harness": "opencode"},
               "choice": {"harness": "opencode", "model": "byo/llama"}}),
    );
    let mut home = Conn::open(&server.socket);
    let set = v2_keyed(
        &mut home,
        "chief.engine.set",
        "mirror-set-1",
        json!({"chief": scout, "harness": "opencode", "model": "byo/llama"}),
    );
    assert_eq!(set["ok"], true, "{set}");
    assert_eq!(lines.lock().unwrap().len(), 1);
    let record = v2(&mut home, "chief.profile.get", json!({"chief": scout}));
    assert_eq!(
        record["result"]["engine"],
        json!({"harness": "opencode", "model": "byo/llama"}),
        "{record}"
    );
    let history = v2(&mut home, "chief.profile.history", json!({"chief": scout}));
    assert_eq!(
        history["result"]["revisions"][0]["actor"], "user_local via chief.engine.set",
        "{history}"
    );

    let daemon = i32::try_from(owned.child.id()).unwrap();
    // SAFETY: the test's own daemon child.
    unsafe { libc::kill(daemon, libc::SIGTERM) };
    let _ = owned.child.wait();
    let _ = fs::remove_dir_all(&files);
}
