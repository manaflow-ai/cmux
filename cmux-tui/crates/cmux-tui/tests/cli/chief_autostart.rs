//! `cmux chief` with no app: it starts the Chief home's session daemon and
//! brain, never a second brain, never on a brain socket, and an isolated
//! home never touches the default one. The brain is a stand-in script (the
//! real optchat-chief is not in this workspace) that keeps the brain's
//! contract: it takes `state/host.lock`, binds as agent_mux with the token
//! file, and answers like the Chief.

use super::*;

/// The stand-in brain: `host --daemon-socket S --mux-home H`.
const FAKE_BRAIN: &str = r#"#!/usr/bin/env python3
import fcntl, json, os, socket, sys, time
args = sys.argv[1:]
sock_path = args[args.index("--daemon-socket") + 1]
home = args[args.index("--mux-home") + 1]
os.makedirs(os.path.join(home, "state"), exist_ok=True)
inherited = os.environ.get("FAKE_BRAIN_LOCK_FD")
if inherited:
    # The app's restart of a brain that exited (restart-on-term): the lock
    # passes to the new brain with no gap.
    lock = os.fdopen(int(inherited), "a+")
else:
    lock = open(os.path.join(home, "state", "host.lock"), "a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        sys.exit(0)
# The holder's pid first, as optchat-chief's lock.rs writes it.
lock.seek(0)
lock.truncate()
lock.write("%d\n1\nflock\n" % os.getpid())
lock.flush()
with open(os.path.join(home, "brain-starts.log"), "a") as log:
    log.write("%d\n" % os.getpid())
# The names (never the values) of the environment the brain got.
with open(os.path.join(home, "brain-env-names"), "w") as names:
    names.write("\n".join(sorted(os.environ)))
with open(os.path.join(home, "brain-home"), "w") as user_home:
    user_home.write(os.environ.get("HOME", ""))
with open(os.path.join(home, "brain.pid"), "w") as pid:
    pid.write(str(os.getpid()))
with open(os.path.join(home, "daemon-socket"), "w") as where:
    where.write(sock_path)
if inherited:
    while True:
        time.sleep(1)
if os.path.exists(os.path.join(home, "restart-on-term")):
    import signal, subprocess
    # The app (ChiefBrainWatch) starts a new brain when one exits, also
    # after a SIGTERM; this stand-in does it once.
    def restart(signum, frame):
        env = dict(os.environ, FAKE_BRAIN_LOCK_FD=str(lock.fileno()))
        subprocess.Popen([sys.executable] + sys.argv, env=env, pass_fds=(lock.fileno(),),
                         start_new_session=True)
        os._exit(0)
    signal.signal(signal.SIGTERM, restart)
conn = socket.socket(socket.AF_UNIX)
conn.connect(sock_path)
reader = conn.makefile("r")
next_id = [0]
def request(cmd, **params):
    next_id[0] += 1
    params.update({"id": next_id[0], "cmd": cmd})
    conn.sendall((json.dumps(params) + "\n").encode())
    while True:
        line = json.loads(reader.readline())
        if line.get("id") == next_id[0]:
            assert line.get("ok"), line
            return line.get("data")
token = open(os.environ["MUX_AGENT_TOKEN_FILE"]).read().strip()
chats = request("conversation-list")["conversations"]
chief = [c for c in chats if any(p["id"] == "agent_mux" for p in c["participants"])][0]["id"]
request("conversation-bind", participant="agent_mux", token=token)
request("subscribe")
done = [0]
def answer(message):
    seq = message["seq"]
    if message.get("author") != "user_local" or seq <= done[0]:
        return
    done[0] = seq
    text = message["parts"][0]["text"]
    request("conversation-op", conversation=chief, idempotency_key="cursor:%d" % seq,
            op={"kind": "read_cursor.set", "seq": seq})
    request("conversation-typing", conversation=chief, on=True)
    key = "turn:fake:%d" % seq
    # The owner limits how fast an agent posts (agent_rate): retry.
    for _ in range(20):
        try:
            request("conversation-op", conversation=chief, idempotency_key=key,
                    op={"kind": "message.send", "client_msg_id": key,
                        "parts": [{"type": "text", "text": "echo: " + text}]})
            break
        except AssertionError:
            time.sleep(0.5)
    request("conversation-typing", conversation=chief, on=False)
# Catch up first, as the real brain does: what came before it subscribed.
history = request("conversation-snapshot", conversation=chief, tail=50)["messages"]
answered = max([m["seq"] for m in history if m["author"] == "agent_mux"] + [0])
done[0] = answered
for message in history:
    answer(message)
while True:
    line = reader.readline()
    if not line:
        break
    event = json.loads(line)
    change = event.get("change") or {}
    if event.get("event") == "conversation-changed" and change.get("kind") == "message":
        answer(change["message"])
"#;

/// A temp user home, runtime directory and stand-in brain; stops what the
/// CLI started when dropped.
struct Sandbox {
    dir: PathBuf,
    brain: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let dir = unique_temp_dir(name);
        fs::create_dir_all(dir.join("home")).unwrap();
        fs::create_dir_all(dir.join("run")).unwrap();
        fs::set_permissions(dir.join("run"), fs::Permissions::from_mode(0o700)).unwrap();
        let brain = dir.join("fake-brain");
        fs::write(&brain, FAKE_BRAIN).unwrap();
        fs::set_permissions(&brain, fs::Permissions::from_mode(0o755)).unwrap();
        Self { dir, brain }
    }

    fn chief(&self, args: &[&str]) -> Output {
        self.chief_with(args, &[])
    }

    fn chief_with(&self, args: &[&str], env: &[(&str, &str)]) -> Output {
        let child = Command::new(bin())
            .arg("chief")
            .args(args)
            .env("LC_ALL", "C")
            .env("HOME", self.dir.join("home"))
            .env("XDG_RUNTIME_DIR", self.dir.join("run"))
            .env("TMPDIR", self.dir.join("run"))
            .env("CMUX_CHIEF_BRAIN_BIN", &self.brain)
            .env_remove("CMUX_TUI_SOCKET")
            .env_remove("CMUX_CHIEF_HOME")
            .env_remove("CMUX_NEXT_CHIEF_HOME")
            .env_remove("CMUX_NEXT_MUX_HOME")
            .env_remove("CMUX_NEXT_CHIEF_ROOT")
            .env_remove("CMUX_NEXT_CHIEF_ACCOUNT")
            .env_remove("CMUX_NEXT_CHIEF_BUILD_ID")
            .env_remove("CMUX_NEXT_CHIEF_ISOLATED")
            .env_remove("CMUX_NEXT_NO_ACTIVATE")
            .env_remove("CMUX_SOCKET_PATH")
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            // The build-session kill switch only where a test sets it.
            .env_remove("ACPMUX_AGENT_LAUNCH")
            .env_remove("CMUX_AGENTS_DISABLED")
            // The test's own variables last, so no removal above drops one.
            .envs(env.iter().copied())
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let pid = child.id();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(child.wait_with_output());
        });
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(output) => output.unwrap(),
            Err(_) => {
                // SAFETY: kill(2) of the CLI this test spawned.
                unsafe { libc::kill(pid as i32, libc::SIGKILL) };
                let output = rx.recv_timeout(Duration::from_secs(10)).ok().and_then(Result::ok);
                let home = self.isolated();
                panic!(
                    "cmux chief did not exit; stderr: {}\nhost.log: {}\nbrain starts: {}",
                    output.map(|o| stderr_of(&o)).unwrap_or_default(),
                    fs::read_to_string(home.join("host.log")).unwrap_or_default(),
                    fs::read_to_string(home.join("brain-starts.log")).unwrap_or_default(),
                );
            }
        }
    }

    fn isolated(&self) -> PathBuf {
        self.dir.join("iso")
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        // The isolated home and every per-build home under the sandbox's ~/.cmux/chief.
        let chiefs = fs::read_dir(self.dir.join("home/.cmux/chief"))
            .into_iter()
            .flatten()
            .flatten()
            .map(|entry| entry.path());
        let homes: Vec<PathBuf> = std::iter::once(self.isolated()).chain(chiefs).collect();
        for home in &homes {
            if let Ok(pid) = fs::read_to_string(home.join("brain.pid"))
                && let Ok(pid) = pid.trim().parse::<i32>()
            {
                // SAFETY: kill(2) of the stand-in brain this test started.
                unsafe { libc::kill(pid, libc::SIGKILL) };
            }
        }
        // The daemons the CLI started for the homes end with their terminals
        // (on macOS their sockets are in the Darwin temp directory, not run/).
        let started: Vec<PathBuf> = homes
            .iter()
            .filter_map(|home| fs::read_to_string(home.join("daemon-socket")).ok())
            .map(PathBuf::from)
            .collect();
        for socket in sockets(&self.dir.join("run")).into_iter().chain(started) {
            // shutdown-daemon names the daemon's pid and generation (identify).
            let identity =
                try_json_socket_request(&socket, serde_json::json!({"id": 1, "cmd": "identify"}));
            if let Some(identity) = identity {
                let _ = try_json_socket_request(
                    &socket,
                    serde_json::json!({"id": 2, "cmd": "shutdown-daemon", "pid": identity["pid"],
                                       "generation": identity["generation"], "end_terminals": true}),
                );
            }
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn sockets(dir: &std::path::Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            match entry.file_type() {
                Ok(kind) if kind.is_dir() => stack.push(path),
                Ok(kind) if kind.is_socket() => found.push(path),
                _ => {}
            }
        }
    }
    found
}

fn brain_starts(home: &std::path::Path) -> usize {
    fs::read_to_string(home.join("brain-starts.log")).unwrap_or_default().lines().count()
}

#[test]
fn chief_starts_its_daemon_and_brain_when_none_runs() {
    let sandbox = Sandbox::new("chief-autostart");
    let home = sandbox.isolated();
    let home_arg = home.to_str().unwrap();
    let output = sandbox.chief(&["--chief-home", home_arg, "-p", "hello"]);
    assert_success(&output);
    assert_eq!(String::from_utf8_lossy(&output.stdout), "echo: hello\n");
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(stderr.contains("started the Chief's session daemon"), "{stderr}");
    assert!(stderr.contains("started the Chief at"), "{stderr}");
    assert_eq!(brain_starts(&home), 1);
    assert!(home.join("tui").is_dir(), "the owner keeps its state in the home");

    // A second run finds both running: nothing new starts.
    let again = sandbox.chief(&["--chief-home", home_arg, "-p", "again"]);
    assert_success(&again);
    assert_eq!(String::from_utf8_lossy(&again.stdout), "echo: again\n");
    assert!(String::from_utf8_lossy(&again.stderr).is_empty(), "{}", stderr_of(&again));
    assert_eq!(brain_starts(&home), 1, "never a second brain");

    // The isolated home never touched the default Chief.
    assert!(!sandbox.dir.join("home/.cmux/chief/default").exists());
}

#[test]
fn chief_opens_the_chief_of_the_app_build_it_belongs_to() {
    // One Chief per build: the CLI in a DEV build's terminal (CMUX_BUNDLE_ID)
    // starts that build's own Chief; NIGHTLY's CLI the shared home it keeps.
    let sandbox = Sandbox::new("chief-per-build");
    let chiefs = sandbox.dir.join("home/.cmux/chief");
    let dev_home = chiefs.join("com.cmuxterm.app.debug.t1");
    let nightly_home = chiefs.join("default");
    let dev =
        sandbox.chief_with(&["-p", "dev"], &[("CMUX_BUNDLE_ID", "com.cmuxterm.app.debug.t1")]);
    let dev_ok = dev.status.success();
    let dev_brains = brain_starts(&dev_home);
    let nightly_before = nightly_home.exists();
    let nightly =
        sandbox.chief_with(&["-p", "nightly"], &[("CMUX_BUNDLE_ID", "com.cmuxterm.app.nightly")]);
    let nightly_ok = nightly.status.success();
    let nightly_brains = brain_starts(&nightly_home);
    let dev_brains_after = brain_starts(&dev_home);
    // Stop both stand-in brains before any assertion can fail.
    for home in [&dev_home, &nightly_home] {
        if let Ok(pid) = fs::read_to_string(home.join("brain.pid"))
            && let Ok(pid) = pid.trim().parse::<i32>()
        {
            // SAFETY: kill(2) of a stand-in brain this test started.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
    }
    assert!(dev_ok, "{}", stderr_of(&dev));
    assert_eq!(String::from_utf8_lossy(&dev.stdout), "echo: dev\n");
    assert_eq!(dev_brains, 1, "the DEV build's CLI starts the DEV build's Chief");
    assert!(!nightly_before, "the DEV build's CLI never touches NIGHTLY's home");
    assert!(nightly_ok, "{}", stderr_of(&nightly));
    assert_eq!(String::from_utf8_lossy(&nightly.stdout), "echo: nightly\n");
    assert_eq!(nightly_brains, 1, "NIGHTLY's CLI starts the Chief of the shared home");
    assert_eq!(dev_brains_after, 1, "never a second brain in the DEV home");
}

#[test]
fn chief_starts_nothing_on_a_brain_socket() {
    let sandbox = Sandbox::new("chief-brain-socket");
    let socket = sandbox.dir.join("home/.cmux/brains/chief/daemon/cmux.sock");
    let output = sandbox.chief(&["--socket", socket.to_str().unwrap(), "-p", "hi"]);
    assert_eq!(output.status.code(), Some(1), "{}", stderr_of(&output));
    assert!(stderr_of(&output).contains("brain"), "{}", stderr_of(&output));
    assert!(sockets(&sandbox.dir.join("run")).is_empty(), "no daemon was started");
    assert!(!sandbox.dir.join("home/.cmux/chief").exists());
}

fn stderr_of(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

#[test]
fn a_cli_started_brain_gets_the_harness_environment_an_app_started_one_gets() {
    let sandbox = Sandbox::new("chief-autostart-env");
    let home = sandbox.isolated();
    let output = sandbox.chief_with(
        &["--chief-home", home.to_str().unwrap(), "-p", "hello"],
        &[
            ("CLAUDE_CODE_OAUTH_TOKEN", "test-token-not-real"),
            ("CODEX_HOME", "/tmp/codex-home"),
            ("ANTHROPIC_BASE_URL", "http://127.0.0.1:9"),
            ("OPTCHAT_CHIEF_HARNESS", "claude"),
            ("SHELL", "/bin/zsh"),
            ("NOT_FOR_THE_BRAIN", "x"),
        ],
    );
    assert_success(&output);
    let names = fs::read_to_string(home.join("brain-env-names")).unwrap();
    let names: Vec<&str> = names.lines().collect();
    for wanted in [
        "HOME",
        "PATH",
        "USER",
        "SHELL",
        "TMPDIR",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CODEX_HOME",
        "ANTHROPIC_BASE_URL",
        "OPTCHAT_CHIEF_HARNESS",
        "MUX_AGENT_TOKEN_FILE",
        "ACPMUX_HOME",
    ] {
        assert!(names.contains(&wanted), "{wanted} did not reach the brain: {names:?}");
    }
    assert!(!names.contains(&"NOT_FOR_THE_BRAIN"), "only the allowlist passes");
}

/// cosmic-gray 2026-10-14 (cg-steward): `cmux chief shutdown` timed out after
/// 40 s and left the session daemon running, so the Chief kept its old code
/// across an upgrade. The app restarts a brain that exits, so the home lock
/// never came free: the CLI waited for the lock, gave up, and never stopped
/// the daemon. Shutdown stops the brain it signalled, the one started in its
/// place, and the session daemon.
#[test]
fn chief_shutdown_stops_a_restarted_brain_and_the_session_daemon() {
    let sandbox = Sandbox::new("chief-shutdown-restart");
    let home = sandbox.isolated();
    let home_arg = home.to_str().unwrap();
    // The CLI passes the brain only an allowlisted environment: a file in
    // the home turns the stand-in's restart on.
    fs::create_dir_all(&home).unwrap();
    fs::write(home.join("restart-on-term"), "").unwrap();
    let output = sandbox.chief(&["--chief-home", home_arg, "-p", "hello"]);
    assert_success(&output);
    let socket = PathBuf::from(fs::read_to_string(home.join("daemon-socket")).unwrap());
    assert!(UnixStream::connect(&socket).is_ok(), "the session daemon runs");

    let shutdown = sandbox.chief(&["shutdown", "--chief-home", home_arg]);
    let brains: Vec<u32> = fs::read_to_string(home.join("brain-starts.log"))
        .unwrap_or_default()
        .lines()
        .filter_map(|line| line.trim().parse().ok())
        .collect();
    let brains_gone = wait_for_processes_to_exit(&brains, Duration::from_secs(10));
    let daemon_gone = UnixStream::connect(&socket).is_err();
    assert_success(&shutdown);
    assert_eq!(brains.len(), 2, "the stand-in restarted once: {brains:?}");
    assert!(brains_gone, "both brains stopped: {brains:?}");
    assert!(daemon_gone, "the session daemon stopped; stderr: {}", stderr_of(&shutdown));
}

#[test]
fn chief_shutdown_tells_the_app_until_the_next_chief_starts_it() {
    // The app (ChiefBrainWatch) does not start a brain again while
    // `state/shutdown` is there; the next `cmux chief` starts it and
    // takes the marker away, so a later crash restarts as before.
    let sandbox = Sandbox::new("chief-shutdown-marker");
    let home = sandbox.isolated();
    let home_arg = home.to_str().unwrap();
    let marker = home.join("state/shutdown");
    assert_success(&sandbox.chief(&["--chief-home", home_arg, "-p", "hello"]));
    assert!(!marker.exists(), "a started Chief has no shutdown marker");

    assert_success(&sandbox.chief(&["shutdown", "--chief-home", home_arg]));
    assert!(marker.exists(), "the shutdown leaves its marker for the app");

    assert_success(&sandbox.chief(&["--chief-home", home_arg, "-p", "hello again"]));
    assert!(!marker.exists(), "the next cmux chief takes the marker away");
    assert_success(&sandbox.chief(&["shutdown", "--chief-home", home_arg]));
}

#[test]
fn chief_says_at_once_that_agents_are_disabled_and_starts_nothing() {
    // cx-tgf4h: a GUI build job runs with ACPMUX_AGENT_LAUNCH=deny (or
    // CMUX_AGENTS_DISABLED=1). `cmux chief -p` waited 240 s for a reply that
    // no turn could give; it must fail at once with the typed refusal and
    // start no daemon and no brain.
    let sandbox = Sandbox::new("chief-agents-disabled");
    let home = sandbox.isolated();
    let home_arg = home.to_str().unwrap();
    for (key, value) in [("ACPMUX_AGENT_LAUNCH", "deny"), ("CMUX_AGENTS_DISABLED", "1")] {
        let started = Instant::now();
        let output =
            sandbox.chief_with(&["--chief-home", home_arg, "-p", "hello"], &[(key, value)]);
        assert!(started.elapsed() < Duration::from_secs(10), "{key}: not at once");
        assert_eq!(output.status.code(), Some(1), "{key}: {}", stderr_of(&output));
        assert!(output.stdout.is_empty(), "{key}: no reply");
        let stderr = stderr_of(&output);
        assert!(stderr.contains("agents are disabled in this build session"), "{key}: {stderr}");

        let json = sandbox
            .chief_with(&["--chief-home", home_arg, "--json", "-p", "hello"], &[(key, value)]);
        assert_eq!(json.status.code(), Some(1), "{key}: {}", stderr_of(&json));
        let error: Value = serde_json::from_str(stderr_of(&json).trim())
            .unwrap_or_else(|e| panic!("{key}: typed JSON error: {e}: {}", stderr_of(&json)));
        assert_eq!(error["code"], "operation.failed", "{key}: {error}");
        assert_eq!(error["details"]["reason"], "agent_launch_disabled", "{key}: {error}");
        assert_eq!(error["retryable"], false, "{key}: {error}");
    }
    assert_eq!(brain_starts(&home), 0, "no brain started");
    assert!(!home.join("tui").exists(), "no session daemon started");
}

/// The account's home directory in the user database; None without a record.
fn account_home() -> Option<String> {
    // SAFETY: getpwuid returns a pointer into static storage or null; it is
    // read at once, on this thread.
    unsafe {
        let record = libc::getpwuid(libc::getuid());
        if record.is_null() {
            return None;
        }
        Some(std::ffi::CStr::from_ptr((*record).pw_dir).to_str().unwrap().to_owned())
    }
}

#[test]
fn a_cli_started_brain_gets_the_accounts_home_not_the_callers() {
    // A job runner (nx-remote) runs `cmux chief -p` with its own HOME; the
    // brain then read the person's Claude settings (the model route) from
    // the job root and its turns got 401. Like the daemon's brains
    // (c47dd2fd0112) and the app's (FileManager.homeDirectoryForCurrentUser),
    // the brain gets the account's home from the user database.
    let Some(account) = account_home() else {
        // No user database record: the CLI keeps the caller's HOME.
        return;
    };
    let sandbox = Sandbox::new("chief-brain-home");
    let home = sandbox.isolated();
    let home_arg = home.to_str().unwrap();
    assert_success(&sandbox.chief(&["--chief-home", home_arg, "-p", "hello"]));
    let caller_home = sandbox.dir.join("home");
    let brain_home = fs::read_to_string(home.join("brain-home")).unwrap();
    assert_eq!(
        brain_home,
        account,
        "the brain's HOME is not the account's (the caller's was {})",
        caller_home.display()
    );
}
