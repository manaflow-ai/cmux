//! `cmux setup` driven the way an agent drives it: read `list` and `status`,
//! run the fix `status` names, run it again, then run the `undo` the result
//! names, reading only the JSON each step prints. A fake HOME, acpmux home
//! and PATH (with fake harness CLIs), so nothing of the person's is read or
//! written.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

struct World {
    home: PathBuf,
    acpmux: PathBuf,
    repo: PathBuf,
    /// The fake harness CLIs (and `ssh` and `scp` with `with_fake_ssh`),
    /// first on PATH.
    bin: PathBuf,
    /// Where `cmux setup` looks for an acpmux daemon.
    socket: PathBuf,
    /// `bin` has a fake `ssh` and `scp`.
    fake_ssh: bool,
}

impl World {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
        // Short: Unix socket paths are limited to about 100 bytes.
        let dir = Path::new("/tmp").join(format!("cxs-{name}-{}-{stamp}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        // The real folder (/tmp is /private/tmp on macOS): a harness's install
        // channel is read from where its file really is, under HOME.
        let dir = std::fs::canonicalize(dir).unwrap();
        let world = Self {
            home: dir.join("home"),
            acpmux: dir.join("acpmux"),
            repo: dir.join("work").join("repo"),
            bin: dir.join("bin"),
            socket: dir.join("d.sock"),
            fake_ssh: false,
        };
        for path in [&world.home, &world.acpmux, &world.repo, &world.bin] {
            std::fs::create_dir_all(path).unwrap();
        }
        world
    }

    /// Puts a fake `ssh` and `scp` on PATH for every command. The fake
    /// ssh logs each call and answers what `acp host setup|update` asks
    /// (Linux, a version, an empty config); a host whose name has
    /// `unreachable` refuses the connection like a machine that is down.
    fn with_fake_ssh(mut self) -> Self {
        use std::os::unix::fs::PermissionsExt;
        let ssh = r#"#!/bin/sh
echo "ssh $*" >> "$FAKE_SSH_LOG"
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
host=$1
script=$2
case "$host" in *unreachable*)
  echo "ssh: connect to host $host port 22: Connection refused" >&2
  exit 255;;
esac
case "$script" in
  *--version*) echo "acpmux 0.0.0-fake";;
  *"cat ~/.acpmux/config.json"*) echo '{}';;
  "uname -s") echo Linux;;
  *"daemon start"*) echo "daemon started (fake)";;
esac
exit 0
"#;
        let scp = "#!/bin/sh\necho \"scp $*\" >> \"$FAKE_SSH_LOG\"\nexit 0\n";
        for (name, body) in [("ssh", ssh), ("scp", scp)] {
            let file = self.bin.join(name);
            std::fs::write(&file, body).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        self.fake_ssh = true;
        self
    }

    fn ssh_log(&self) -> PathBuf {
        self.home.parent().unwrap().join("ssh.log")
    }

    /// The ssh and scp calls since the last `take_ssh_calls`.
    fn take_ssh_calls(&self) -> Vec<String> {
        let text = std::fs::read_to_string(self.ssh_log()).unwrap_or_default();
        let _ = std::fs::remove_file(self.ssh_log());
        text.lines().map(str::to_owned).collect()
    }

    /// The folder as acpmux keys it.
    fn folder(&self) -> String {
        std::fs::canonicalize(&self.repo).unwrap().to_string_lossy().into_owned()
    }

    fn record(&self) -> Option<Value> {
        let text = std::fs::read_to_string(self.acpmux.join("trust.json")).ok()?;
        Some(serde_json::from_str(&text).unwrap())
    }

    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        command
            .args(args)
            .current_dir(&self.repo)
            .env("HOME", &self.home)
            .env("ACPMUX_HOME", &self.acpmux)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("PATH", self.path())
            .env("LC_ALL", "C")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env_remove("CMUX_NEXT_CONFIG_FILE")
            .env_remove("ACPMUX_SESSION_ID")
            .env_remove("ACPMUX_AGENT_LAUNCH")
            .env_remove("CMUX_AGENTS_DISABLED")
            .env_remove("CLAUDE_CONFIG_DIR")
            .env_remove("CODEX_HOME")
            .env_remove("CMUX_SOCKET_PATH")
            .stdin(Stdio::null());
        if self.fake_ssh {
            // The fake ssh and scp are first on PATH; nothing reaches a real machine.
            command.env("FAKE_SSH_LOG", self.ssh_log());
        }
        command
    }

    /// Runs `args`, expects exit 0 and one JSON object on stdout.
    fn json(&self, args: &[&str]) -> Value {
        let output = self.run(args);
        assert!(
            output.status.success(),
            "{args:?} exited {:?}: {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr)
        );
        serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
            panic!("{args:?}: {error}: {}", String::from_utf8_lossy(&output.stdout))
        })
    }

    /// The fake CLIs, OpenCode's own installer folder, and the system's tools
    /// the fakes use: no harness of the machine's own is found.
    fn path(&self) -> String {
        format!("{}:{}:/usr/bin:/bin", self.bin.display(), self.opencode_bin().display())
    }

    /// Where OpenCode's own installer puts it (`~/.opencode/bin`), which
    /// updates itself with `opencode upgrade`.
    fn opencode_bin(&self) -> PathBuf {
        self.home.join(".opencode").join("bin")
    }

    /// A fake ACP harness CLI at `path`: `--version` prints `version`; on
    /// stdin it answers `initialize`, and `session/new` with ACP's
    /// "authentication required" until `signed_in(path)` exists. Every line
    /// it reads goes to `path.log`. A short-lived `sh` writes it so no sibling
    /// test's fork inherits a write descriptor (ETXTBSY).
    fn harness(&self, path: &Path, version: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let script = format!(
            r#"#!/bin/sh
[ "$1" = --version ] && {{ echo "{version}"; exit 0; }}
while IFS= read -r line; do
  printf '%s\n' "$line" >>"$0.log"
  id=${{line#*\"id\":}}; id=${{id%%,*}}
  case $line in
    *'"method":"initialize"'*)
      printf '{{"jsonrpc":"2.0","id":%s,"result":{{"protocolVersion":1,"authMethods":[{{"id":"oauth","name":"Sign in"}}]}}}}\n' "$id" ;;
    *'"method":"session/new"'*)
      if [ -e "$0.signed-in" ]; then
        printf '{{"jsonrpc":"2.0","id":%s,"result":{{"sessionId":"s1"}}}}\n' "$id"
      else
        printf '{{"jsonrpc":"2.0","id":%s,"error":{{"code":-32000,"message":"Authentication required"}}}}\n' "$id"
      fi ;;
  esac
done
"#
        );
        let mut child = Command::new("/bin/sh")
            .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
            .arg(path)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(script.as_bytes()).unwrap();
        assert!(child.wait().unwrap().success());
    }

    /// What the fake harness at `path` read.
    fn harness_log(path: &Path) -> String {
        std::fs::read_to_string(format!("{}.log", path.display())).unwrap_or_default()
    }

    /// The person finishing the sign-in of the fake harness at `path`.
    fn sign_in(path: &Path) {
        std::fs::write(format!("{}.signed-in", path.display()), "").unwrap();
    }

    /// Every file under the acpmux home, with its bytes.
    fn acpmux_files(&self) -> Vec<(PathBuf, Vec<u8>)> {
        let mut files = Vec::new();
        let mut dirs = vec![self.acpmux.clone()];
        while let Some(dir) = dirs.pop() {
            for entry in std::fs::read_dir(&dir).unwrap() {
                let path = entry.unwrap().path();
                if path.is_dir() {
                    dirs.push(path);
                } else {
                    let bytes = std::fs::read(&path).unwrap();
                    files.push((path, bytes));
                }
            }
        }
        files.sort();
        files
    }

    /// Runs a command a result named (`cmux setup ...`), as an agent's shell would.
    fn follow(&self, command: &str) -> Value {
        let words = shell_words(command);
        assert_eq!(words.first().map(String::as_str), Some("cmux"), "{command}");
        self.json(&words[1..].iter().map(String::as_str).collect::<Vec<_>>())
    }
}

/// Splits a command the way sh does for the quoting `cmux setup` writes:
/// bare words and single-quoted words.
fn shell_words(command: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quoted = false;
    let mut chars = command.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\'' => quoted = !quoted,
            '\\' if !quoted => word.extend(chars.next()),
            ' ' if !quoted => {
                if !word.is_empty() {
                    words.push(std::mem::take(&mut word));
                }
            }
            c => word.push(c),
        }
    }
    if !word.is_empty() {
        words.push(word);
    }
    words
}

#[test]
fn cmux_setup_trust_an_agent_runs_the_fix_reruns_it_and_undoes_it() {
    let world = World::new("trust");
    let folder = world.folder();
    let claude_json = world.home.join(".claude.json");
    std::fs::write(&claude_json, r#"{"projects":{}}"#).unwrap();

    // The agent reads where things stand.
    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][0];
    assert_eq!(check["task"], "trust", "{status}");
    assert_eq!(check["state"], "needs_setup", "{status}");
    assert_eq!(check["folder"], folder.as_str());
    let fix = check["fix"].as_str().expect("status names its fix").to_owned();

    // A dry run plans and writes nothing (agents add --json out of habit).
    let planned = world.json(&["setup", "trust", "--dry-run", "--json"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert_eq!(planned["dry_run"], true);
    assert!(planned["undo"].is_string(), "{planned}");
    assert_eq!(world.record(), None, "a dry run wrote the record");

    // The fix status named.
    let changed = world.follow(&fix);
    assert_eq!(changed["state"], "changed", "{changed}");
    assert_eq!(changed["through"], "record");
    assert_eq!(changed["via"], Value::Null);
    assert_eq!(changed["written"], folder.as_str());
    assert_eq!(changed["before"]["level"], "unknown");
    assert_eq!(changed["after"]["level"], "trusted");
    assert_eq!(world.record(), Some(json!({folder.as_str(): "trusted"})));
    let undo = changed["undo"].as_str().expect("a change names its undo").to_owned();

    // Again: nothing to do, nothing written.
    let again = world.json(&["setup", "trust", &folder]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["undo"], Value::Null);
    assert_eq!(world.json(&["setup", "status"])["checks"][0]["state"], "ok");

    // The undo puts the record back the way it was.
    let undone = world.follow(&undo);
    assert_eq!(undone["state"], "changed", "{undone}");
    assert_eq!(undone["after"]["level"], "unknown");
    assert_eq!(world.record(), Some(json!({})));

    // A refusal is recorded the same way, and its undo clears it.
    let refused = world.json(&["setup", "trust", ".", "--level", "untrusted"]);
    assert_eq!(refused["after"]["level"], "untrusted", "{refused}");
    assert_eq!(refused["undo"], format!("cmux setup trust {folder} --level unknown"));

    // Claude Code's own file has one writer, and it is not cmux.
    assert_eq!(std::fs::read_to_string(&claude_json).unwrap(), r#"{"projects":{}}"#);
}

#[test]
fn cmux_setup_trust_goes_through_a_running_acpmux_daemon() {
    let world = World::new("daemon");
    let folder = world.folder();
    let requests = Arc::new(Mutex::new(Vec::new()));
    let listener = UnixListener::bind(&world.socket).unwrap();
    let seen = requests.clone();
    std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut writer = stream;
        let mut line = String::new();
        while reader.read_line(&mut line).unwrap_or(0) > 0 {
            let request: Value = serde_json::from_str(&line).unwrap();
            line.clear();
            let result = match request["method"].as_str() {
                Some("initialize") => json!({"protocolVersion": 1}),
                _ => json!({"cwd": request["params"]["cwd"], "level": request["params"]["level"]}),
            };
            seen.lock().unwrap().push(request.clone());
            let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
            if writeln!(writer, "{reply}").is_err() {
                break;
            }
        }
    });

    let changed = world.json(&["setup", "trust"]);
    assert_eq!(changed["state"], "changed", "{changed}");
    assert_eq!(changed["through"], "daemon");
    let requests = requests.lock().unwrap();
    let set = requests
        .iter()
        .find(|request| request["method"] == "acp.trust.set")
        .unwrap_or_else(|| panic!("no acp.trust.set in {requests:?}"));
    assert_eq!(set["params"], json!({"cwd": folder, "level": "trusted"}));
    assert_eq!(world.record(), None, "the CLI wrote the record beside the daemon");
}

#[test]
fn cmux_setup_trust_answers_a_worktree_from_its_repository_and_forgets_it_there() {
    let world = World::new("via");
    // The repository and a linked worktree of it, as git writes them.
    let repo = world.folder();
    let gitdir = world.repo.join(".git").join("worktrees").join("wt");
    std::fs::create_dir_all(&gitdir).unwrap();
    let worktree_path = world.repo.parent().unwrap().join("wt");
    std::fs::create_dir_all(&worktree_path).unwrap();
    let worktree = std::fs::canonicalize(&worktree_path).unwrap().to_string_lossy().into_owned();
    std::fs::write(worktree_path.join(".git"), format!("gitdir: {}\n", gitdir.display())).unwrap();
    std::fs::write(gitdir.join("gitdir"), format!("{worktree}/.git\n")).unwrap();
    std::fs::write(gitdir.join("commondir"), "../..\n").unwrap();

    // The person trusts the repository; its worktree has that answer.
    world.json(&["setup", "trust", &repo]);
    let again = world.json(&["setup", "trust", &worktree]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["via"], repo.as_str(), "{again}");
    assert_eq!(again["written"], Value::Null);
    assert_eq!(world.record(), Some(json!({repo.as_str(): "trusted"})), "ok wrote the record");

    // Forgetting the worktree's answer forgets it where it was made.
    let planned = world.json(&["setup", "trust", &worktree, "--level", "unknown", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert_eq!(planned["written"], repo.as_str(), "{planned}");
    assert_eq!(world.record(), Some(json!({repo.as_str(): "trusted"})), "a dry run wrote");
    let forgot = world.json(&["setup", "trust", &worktree, "--level", "unknown"]);
    assert_eq!(forgot["state"], "changed", "{forgot}");
    assert_eq!(forgot["written"], repo.as_str(), "{forgot}");
    assert_eq!(forgot["after"]["level"], "unknown", "{forgot}");
    assert_eq!(world.record(), Some(json!({})));
    let undo = forgot["undo"].as_str().expect("a change names its undo").to_owned();
    assert_eq!(undo, format!("cmux setup trust {repo} --level trusted"));

    // Its undo gives the repository, and so the worktree, the answer back.
    world.follow(&undo);
    assert_eq!(world.json(&["setup", "trust", &worktree])["state"], "ok");

    // A different level for the worktree is the worktree's own.
    let refused = world.json(&["setup", "trust", &worktree, "--level", "untrusted"]);
    assert_eq!(refused["written"], worktree.as_str(), "{refused}");
    assert_eq!(refused["after"]["level"], "untrusted", "{refused}");
    assert_eq!(refused["undo"], format!("cmux setup trust {worktree} --level unknown"));
    assert_eq!(
        world.record(),
        Some(json!({repo.as_str(): "trusted", worktree.as_str(): "untrusted"}))
    );
}

#[test]
fn cmux_setup_list_names_every_task_and_bad_arguments_exit_2() {
    let world = World::new("list");
    let list = world.json(&["setup", "list"]);
    let tasks = list["tasks"].as_array().unwrap();
    let ids = tasks.iter().map(|task| task["id"].as_str().unwrap()).collect::<Vec<_>>();
    for id in ["trust", "harness", "machine", "accounts", "computer_use", "team_invites"] {
        assert!(ids.contains(&id), "{id} missing from {ids:?}");
    }
    for task in tasks {
        assert!(task["summary"].is_string(), "{task}");
        assert!(task["apply"].as_array().is_some_and(|apply| !apply.is_empty()), "{task}");
    }
    assert_eq!(world.json(&["setup"]), list);

    for args in [
        &["setup", "nope"][..],
        &["setup", "trust", "--level", "maybe"],
        &["setup", "trust", "a", "b"],
        &["setup", "list", "extra"],
        &["setup", "machine"],
        &["setup", "machine", "-oProxyCommand=touch"],
        &["setup", "machine", "box:2222"],
        &["setup", "machine", "a", "b"],
        &["setup", "machine", "box", "--name", "two words"],
        &["setup", "machine", "box", "--name", "--dry-run"],
    ] {
        let output = world.run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        let error: Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["code"], "usage.invalid", "{args:?}");
    }
    assert_eq!(world.record(), None);
}

/// A fake acpmux daemon on the world's socket that keeps a peer list the
/// way the real one answers `_acpmux/peers`, `peer_add`, `peer_reconnect`
/// and `peer_remove`: a peer added or reconnected is connected and on this
/// build. Every request is kept, for the test to read.
struct FakeDaemon {
    peers: Arc<Mutex<Vec<Value>>>,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeDaemon {
    fn start(world: &World, peers: Vec<Value>) -> Self {
        let daemon =
            Self { peers: Arc::new(Mutex::new(peers)), requests: Arc::new(Mutex::new(Vec::new())) };
        let listener = UnixListener::bind(&world.socket).unwrap();
        let (peers, requests) = (daemon.peers.clone(), daemon.requests.clone());
        std::thread::spawn(move || {
            for stream in listener.incoming() {
                let Ok(stream) = stream else { break };
                let (peers, requests) = (peers.clone(), requests.clone());
                std::thread::spawn(move || serve(stream, &peers, &requests));
            }
        });
        daemon
    }

    fn peers(&self) -> Vec<Value> {
        self.peers.lock().unwrap().clone()
    }

    fn methods(&self) -> Vec<String> {
        let requests = self.requests.lock().unwrap();
        requests.iter().filter_map(|r| r["method"].as_str().map(str::to_owned)).collect()
    }
}

fn serve(
    stream: std::os::unix::net::UnixStream,
    peers: &Mutex<Vec<Value>>,
    requests: &Mutex<Vec<Value>>,
) {
    stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut writer = stream;
    let mut line = String::new();
    while reader.read_line(&mut line).unwrap_or(0) > 0 {
        let request: Value = serde_json::from_str(&line).unwrap();
        line.clear();
        requests.lock().unwrap().push(request.clone());
        let params = &request["params"];
        let mut list = peers.lock().unwrap();
        let result = match request["method"].as_str() {
            Some("initialize") => json!({"protocolVersion": 1}),
            Some("_acpmux/peer_add") => {
                list.retain(|peer| peer["name"] != params["name"]);
                list.push(json!({
                    "name": params["name"], "url": params["url"], "connected": true,
                    "outdated": false, "remoteBuild": "this", "error": null,
                }));
                json!({"peers": *list})
            }
            Some("_acpmux/peer_reconnect") => {
                for peer in list.iter_mut().filter(|peer| peer["name"] == params["name"]) {
                    peer["connected"] = json!(true);
                    peer["outdated"] = json!(false);
                    peer["remoteBuild"] = json!("this");
                }
                json!({"peers": *list})
            }
            Some("_acpmux/peer_remove") => {
                list.retain(|peer| peer["name"] != params["name"]);
                json!({"peers": *list})
            }
            _ => json!({"peers": *list}),
        };
        drop(list);
        let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
        if writeln!(writer, "{reply}").is_err() {
            break;
        }
    }
}

/// The key-only ssh probe `cmux setup machine` runs, as the fake ssh logs it.
fn probe_call(target: &str) -> String {
    format!("ssh -o BatchMode=yes -o ConnectTimeout=15 -- {target} true")
}

#[test]
fn cmux_setup_machine_an_agent_adds_a_peer_reruns_it_and_undoes_it() {
    let world = World::new("machine").with_fake_ssh();
    let daemon = FakeDaemon::start(&world, Vec::new());

    // The agent reads where things stand: no machine yet.
    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][1];
    assert_eq!(check["task"], "machine", "{status}");
    assert_eq!(check["state"], "ok", "{status}");
    assert_eq!(check["daemon"], "running");
    assert_eq!(check["peers"], json!([]));

    // A dry run checks ssh, plans, and changes nothing.
    let planned = world.json(&["setup", "machine", "box.example", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert_eq!(planned["dry_run"], true);
    assert_eq!(planned["name"], "box");
    assert_eq!(planned["before"], Value::Null);
    assert_eq!(planned["plan"], json!(["cmux acp host setup box.example --name box --json"]));
    assert_eq!(planned["ssh"]["reachable"], true, "{planned}");
    assert_eq!(planned["undo"], "cmux acp host rm box");
    assert_eq!(world.take_ssh_calls(), [probe_call("box.example")], "a dry run only probes");
    assert!(daemon.peers().is_empty(), "a dry run registered a peer");
    assert!(!daemon.methods().iter().any(|m| m == "_acpmux/peer_add"));

    // The change: acpmux installs and registers the machine.
    let changed = world.json(&["setup", "machine", "box.example"]);
    assert_eq!(changed["state"], "changed", "{changed}");
    assert_eq!(changed["after"]["name"], "box");
    assert_eq!(changed["after"]["connected"], true);
    assert_eq!(changed["after"]["url"], "ssh://box.example");
    assert_eq!(changed["remote_version"], "acpmux 0.0.0-fake");
    assert_eq!(changed["reverse"]["supported"], false);
    assert_eq!(changed["user_action"], Value::Null);
    let undo = changed["undo"].as_str().expect("a new peer names its undo").to_owned();
    assert_eq!(undo, "cmux acp host rm box");
    let calls = world.take_ssh_calls();
    assert_eq!(calls.first(), Some(&probe_call("box.example")), "{calls:?}");
    assert!(calls.iter().any(|call| call.starts_with("scp ")), "nothing installed: {calls:?}");
    assert_eq!(daemon.peers().len(), 1);

    // Again: connected and current, so nothing runs, not even ssh.
    let again = world.json(&["setup", "machine", "box.example"]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["plan"], json!([]));
    assert_eq!(again["undo"], Value::Null);
    assert_eq!(again["after"]["connected"], true);
    assert!(world.take_ssh_calls().is_empty(), "a rerun reached the machine");

    // Status lists the peer, healthy.
    let status = world.json(&["setup", "status"]);
    let peers = &status["checks"][1]["peers"];
    assert_eq!(peers[0]["name"], "box", "{status}");
    assert_eq!(peers[0]["connected"], true);
    assert_eq!(peers[0]["outdated"], false);
    assert_eq!(peers[0]["fix"], Value::Null);

    // The undo removes the peer.
    let words = shell_words(&undo);
    let output = world.run(&words[1..].iter().map(String::as_str).collect::<Vec<_>>());
    assert!(output.status.success(), "{undo}: {}", String::from_utf8_lossy(&output.stderr));
    assert!(daemon.peers().is_empty(), "{:?}", daemon.peers());
    assert!(!world.home.join(".ssh").exists(), "setup wrote ssh config");
}

#[test]
fn cmux_setup_machine_updates_an_outdated_peer_and_says_why_there_is_no_undo() {
    let world = World::new("outdated").with_fake_ssh();
    let daemon = FakeDaemon::start(
        &world,
        vec![json!({
            "name": "box", "url": "ssh://dev@box.example", "connected": true,
            "outdated": true, "remoteBuild": "old", "error": null,
        })],
    );

    // Status names the fix for the outdated peer.
    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][1];
    assert_eq!(check["state"], "needs_setup", "{status}");
    assert_eq!(check["peers"][0]["outdated"], true);
    let fix = check["peers"][0]["fix"].as_str().expect("an outdated peer names its fix");
    assert_eq!(fix, "cmux setup machine dev@box.example --name box");

    let updated = world.follow(fix);
    assert_eq!(updated["state"], "changed", "{updated}");
    assert_eq!(updated["before"]["outdated"], true);
    assert_eq!(updated["plan"], json!(["cmux acp host update box --json"]));
    assert_eq!(updated["after"]["outdated"], false);
    assert_eq!(updated["undo"], Value::Null);
    assert!(updated["undo_note"].as_str().is_some_and(|why| !why.is_empty()), "{updated}");
    assert!(daemon.methods().iter().any(|m| m == "_acpmux/peer_reconnect"));
    assert!(!daemon.methods().iter().any(|m| m == "_acpmux/peer_add"), "update re-added it");
    world.take_ssh_calls();

    let again = world.json(&["setup", "machine", "dev@box.example"]);
    assert_eq!(again["state"], "ok", "{again}");
    assert!(world.take_ssh_calls().is_empty());
}

#[test]
fn cmux_setup_machine_never_moves_a_peer_by_its_default_name() {
    let world = World::new("taken").with_fake_ssh();
    let ws = json!({
        "name": "box", "url": "wss://box.relay.example/acp", "connected": true,
        "outdated": false, "remoteBuild": "this", "error": null,
    });
    let daemon = FakeDaemon::start(&world, vec![ws.clone()]);

    // `box` is the default name for box.example, but it names another peer:
    // nothing runs, not even ssh, and the person picks a name.
    for dry_run in [true, false] {
        let mut args = vec!["setup", "machine", "box.example"];
        if dry_run {
            args.push("--dry-run");
        }
        let result = world.json(&args);
        assert_eq!(result["state"], "needs_user", "{result}");
        assert_eq!(result["user_action"]["kind"], "name", "{result}");
        assert_eq!(result["user_action"]["command"], "cmux setup machine box.example --name NAME");
        assert_eq!(result["before"]["url"], ws["url"]);
        assert_eq!(result["plan"], json!([]));
        assert_eq!(result["undo"], Value::Null);
        assert!(world.take_ssh_calls().is_empty(), "a taken name reached the machine");
    }
    assert_eq!(daemon.peers(), [ws.clone()]);

    // A new name adds the machine beside it.
    let added = world.json(&["setup", "machine", "box.example", "--name", "box2"]);
    assert_eq!(added["state"], "changed", "{added}");
    assert_eq!(added["undo"], "cmux acp host rm box2");
    world.take_ssh_calls();
    let peers = daemon.peers();
    assert_eq!(peers.len(), 2, "{peers:?}");
    assert_eq!(peers[0], ws);

    // Without --name, the peer at that host is found under its own name.
    let again = world.json(&["setup", "machine", "box.example"]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["name"], "box2");
    assert!(world.take_ssh_calls().is_empty());

    // An ssh peer moved by an explicit --name names the way back.
    let moved = world.json(&["setup", "machine", "other.example", "--name", "box2", "--dry-run"]);
    assert_eq!(moved["state"], "planned", "{moved}");
    assert_eq!(moved["before"]["url"], "ssh://box.example");
    assert_eq!(moved["undo"], "cmux acp host add box2 ssh://box.example");
}

#[test]
fn cmux_setup_machine_an_unreachable_host_needs_the_user() {
    let world = World::new("unreachable").with_fake_ssh();
    let daemon = FakeDaemon::start(&world, Vec::new());
    let expected = "ssh -o BatchMode=yes -o ConnectTimeout=15 unreachable.example true";

    for dry_run in [true, false] {
        let mut args = vec!["setup", "machine", "unreachable.example"];
        if dry_run {
            args.push("--dry-run");
        }
        let result = world.json(&args);
        assert_eq!(result["state"], "needs_user", "{result}");
        assert_eq!(result["dry_run"], dry_run);
        let action = &result["user_action"];
        assert_eq!(action["kind"], "ssh", "{result}");
        assert_eq!(action["command"], expected);
        assert!(action["text"].as_str().is_some_and(|text| text.contains("Connection refused")));
        assert!(action.get("url").is_some(), "{action}");
        assert_eq!(result["ssh"]["reachable"], false);
        assert_eq!(result["undo"], Value::Null);
        assert_eq!(world.take_ssh_calls(), [probe_call("unreachable.example")]);
    }
    assert!(daemon.peers().is_empty());
    assert!(!daemon.methods().iter().any(|m| m == "_acpmux/peer_add"));
    assert!(!world.home.join(".ssh").exists(), "setup wrote ssh config");
}

#[test]
fn cmux_setup_harness_an_agent_hands_the_person_the_sign_in_and_checks_again() {
    let world = World::new("harness");
    let gemini = world.bin.join("gemini");
    world.harness(&gemini, "gemini 0.1.0");
    let opencode = world.opencode_bin().join("opencode");
    world.harness(&opencode, "1.0.0");
    World::sign_in(&opencode);
    // The daemon's last check read a newer OpenCode than this one.
    let saved = json!([{
        "id": "opencode", "program": opencode, "path": opencode, "channel": "native",
        "package": "opencode-ai", "version": "1.0.0", "latest": "9.9.9",
        "latestCheckedAt": 1, "outdated": true, "auth": "signedIn", "checkedAt": 1,
    }]);
    std::fs::write(world.acpmux.join("harness-health.json"), saved.to_string()).unwrap();
    let before = world.acpmux_files();

    // `setup list` names the command, and `setup status` finds the sign-in.
    let list = world.json(&["setup", "list"]);
    let task = list["tasks"].as_array().unwrap().iter().find(|t| t["id"] == "harness").unwrap();
    assert_eq!(task["setup"], "cmux setup harness [ID ...] [--dry-run]", "{task}");
    let status = world.json(&["setup", "status"]);
    let tasks = status["checks"].as_array().unwrap().iter().map(|c| &c["task"]).collect::<Vec<_>>();
    assert_eq!(tasks, [&json!("trust"), &json!("machine"), &json!("harness")], "{status}");
    let check = &status["checks"][2];
    assert_eq!(check["state"], "needs_user", "{status}");
    assert_eq!(check["user_action"]["command"], "cmux harness login gemini", "{status}");

    // Every configured or found harness; UniiChat, offered everywhere, is not one.
    let all = world.json(&["setup", "harness"]);
    assert_eq!(all["task"], "harness", "{all}");
    assert_eq!(all["state"], "needs_user", "{all}");
    assert_eq!(all["dry_run"], false);
    assert_eq!(all["undo"], Value::Null);
    let ids = all["harnesses"].as_array().unwrap().iter().map(|h| &h["id"]).collect::<Vec<_>>();
    assert_eq!(ids, [&json!("gemini"), &json!("opencode")], "{all}");
    let signed_out = &all["harnesses"][0];
    assert_eq!(signed_out["state"], "needs_user", "{signed_out}");
    assert_eq!(signed_out["installed"], true);
    assert_eq!(signed_out["configured"], true);
    assert_eq!(signed_out["version"], "0.1.0");
    assert_eq!(signed_out["signed_in"], false, "{signed_out}");
    let action = &signed_out["user_action"];
    assert_eq!(action["kind"], "oauth", "{action}");
    assert_eq!(action["command"], "cmux harness login gemini");
    assert!(action["text"].as_str().is_some_and(|text| !text.is_empty()), "{action}");
    assert_eq!(all["user_action"], *action, "the task names the first thing to do");
    let current = &all["harnesses"][1];
    assert_eq!(current["state"], "ok", "{current}");
    assert_eq!(current["signed_in"], true, "{current}");
    assert_eq!(current["outdated"], true, "{current}");
    assert_eq!(current["latest"], "9.9.9");
    let update = current["update"].as_str().expect("an outdated harness names its update");
    assert!(update.ends_with(" upgrade"), "{update}");
    assert_eq!(current["user_action"], Value::Null);

    // A harness that is not installed: its shipped profile's docs.
    let missing = world.json(&["setup", "harness", "codex"]);
    assert_eq!(missing["state"], "needs_user", "{missing}");
    let codex = &missing["harnesses"][0];
    assert_eq!(codex["id"], "codex", "{missing}");
    assert_eq!(codex["configured"], false, "{codex}");
    assert_eq!(codex["installed"], false, "{codex}");
    assert_eq!(codex["user_action"]["kind"], "install", "{codex}");
    assert_eq!(codex["user_action"]["url"], "https://developers.openai.com/codex/cli");

    // The person signs in; the agent checks that harness again.
    World::sign_in(&gemini);
    let again = world.json(&["setup", "harness", "gemini", "--dry-run"]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["dry_run"], true);
    assert_eq!(again["user_action"], Value::Null);
    assert_eq!(again["harnesses"][0]["signed_in"], true, "{again}");
    assert_eq!(world.json(&["setup", "status"])["checks"][2]["state"], "ok");

    // A status check: no prompt turn (that is `cmux harness doctor`), nothing written.
    for log in [World::harness_log(&gemini), World::harness_log(&opencode)] {
        assert!(log.contains("\"session/new\""), "{log}");
        assert!(!log.contains("session/prompt"), "{log}");
    }
    assert_eq!(world.acpmux_files(), before, "setup harness wrote acpmux state");

    for args in [&["setup", "harness", "nope"][..], &["setup", "harness", "--bogus"]] {
        let output = world.run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        let error: Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["code"], "usage.invalid", "{args:?}");
    }
}

#[test]
fn cmux_setup_harness_with_none_installed_asks_for_one() {
    let world = World::new("noharness");
    let none = world.json(&["setup", "harness"]);
    assert_eq!(none["state"], "needs_user", "{none}");
    assert_eq!(none["harnesses"], json!([]));
    assert_eq!(none["user_action"]["kind"], "install", "{none}");
    assert!(none["user_action"]["url"].is_string(), "{none}");
}
