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
lock = open(os.path.join(home, "state", "host.lock"), "a+")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
with open(os.path.join(home, "brain-starts.log"), "a") as log:
    log.write("%d\n" % os.getpid())
# The names (never the values) of the environment the brain got.
with open(os.path.join(home, "brain-env-names"), "w") as names:
    names.write("\n".join(sorted(os.environ)))
with open(os.path.join(home, "brain.pid"), "w") as pid:
    pid.write(str(os.getpid()))
with open(os.path.join(home, "daemon-socket"), "w") as where:
    where.write(sock_path)
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
            .envs(env.iter().copied())
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
        let home = self.isolated();
        if let Ok(pid) = fs::read_to_string(home.join("brain.pid"))
            && let Ok(pid) = pid.trim().parse::<i32>()
        {
            // SAFETY: kill(2) of the stand-in brain this test started.
            unsafe { libc::kill(pid, libc::SIGKILL) };
        }
        // The daemon the CLI started for the home ends with its terminals.
        let started = fs::read_to_string(home.join("daemon-socket")).ok().map(PathBuf::from);
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
