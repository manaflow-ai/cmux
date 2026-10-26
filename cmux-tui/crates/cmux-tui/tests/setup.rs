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

#[path = "setup/browser_import.rs"]
mod browser_import;
#[path = "setup/cloud_machine.rs"]
mod cloud_machine;
#[path = "setup/notifications.rs"]
mod notifications;
#[path = "setup/tailnet.rs"]
mod tailnet;

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
    /// The app's control socket every command reaches (`CMUX_SOCKET_PATH`),
    /// a `FakeApp`; none when unset.
    app: Option<PathBuf>,
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
            app: None,
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
# acpmux runs every remote script as `exec /bin/sh -c '<script>'` (hosts.rs ssh_argv).
case "$script" in "exec /bin/sh -c '"*)
  script=$(printf '%s\n' "$script" | sed -e "1s|^exec /bin/sh -c '||" -e "\$s|'\$||" -e "s|'\\\\''|'|g");;
esac
case "$host" in *unreachable*)
  echo "ssh: connect to host $host port 22: Connection refused" >&2
  exit 255;;
esac
# An install or update holds the host's update lease for its length (41f11ee0253,
# host_lock.rs): the holder says it took the lease and runs until its stdin closes.
case "$script" in *"echo ACPMUX_UPDATE_LOCKED"*)
  echo ACPMUX_UPDATE_LOCKED
  cat >/dev/null
  exit 0;;
esac
# Every step of it is fenced for that lease: answer the script inside the fence.
case "$script" in *"} 8>&- 9>&-")
  script=$(printf '%s\n' "$script" | awk '!f && $0 == "{" {f=1; next} f && $0 != "} 8>&- 9>&-" {print}');;
esac
case "$script" in
  # `acp host update`'s probe (c9e045f2e48): this machine's own `uname -sm`,
  # so the update pushes this binary, then a daemon on an older build.
  *ACPMUX_UNAME=*)
    printf 'ACPMUX_UNAME=%s\n\nACPMUX_PROBE\n{"pid":1,"build":"0000000 2026-01-01"}\n\nACPMUX_PROBE\n\nACPMUX_PROBE\n' "$(uname -sm)";;
  # Its wait for the restarted daemon: one answers.
  *"i=0; while :; do s="*) echo '{"pid":2,"build":"fake-new"}';;
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
            .env_remove("CMUX_BUNDLE_ID")
            .env_remove("CMUX_TAG")
            // Setup's own state (the Cloud machine it made) stays in the world.
            .env("CMUX_TUI_STATE_DIR", self.home.parent().unwrap().join("state").join("sessions"))
            .stdin(Stdio::null());
        if let Some(app) = &self.app {
            // Only the fake app: never the cmux app of the machine running the tests.
            command.env("CMUX_SOCKET_PATH", app);
        }
        // No Claude sign-in from the runner's own env.
        for key in [
            "ANTHROPIC_API_KEY",
            "ANTHROPIC_AUTH_TOKEN",
            "CLAUDE_CODE_OAUTH_TOKEN",
            "CLAUDE_CODE_USE_BEDROCK",
            "CLAUDE_CODE_USE_VERTEX",
            "CLAUDE_CODE_USE_FOUNDRY",
        ] {
            command.env_remove(key);
        }
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
            "{args:?} exited {:?}: {} {}",
            output.status.code(),
            String::from_utf8_lossy(&output.stderr),
            String::from_utf8_lossy(&output.stdout)
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
    /// it reads goes to `path.log`.
    fn harness(&self, path: &Path, version: &str) {
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
        World::executable(path, &script);
    }

    /// Writes the script `body` at `path`, executable. A short-lived `sh`
    /// writes it so no sibling test's fork inherits a write descriptor
    /// (ETXTBSY).
    fn executable(path: &Path, body: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        let mut child = Command::new("/bin/sh")
            .args(["-c", "cat >\"$1\" && chmod 755 \"$1\"", "sh"])
            .arg(path)
            .stdin(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(body.as_bytes()).unwrap();
        assert!(child.wait().unwrap().success());
    }

    /// acpmux's config.json with `harnesses` (id to profile), owner-only as
    /// acpmux wants it.
    fn configure(&self, harnesses: Value) {
        use std::os::unix::fs::PermissionsExt;
        let path = self.acpmux.join("config.json");
        std::fs::write(&path, json!({"harnesses": harnesses}).to_string()).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }

    /// A Codex home at `name` under HOME with `config` as its config.toml.
    fn codex_home(&self, name: &str, config: &str) -> PathBuf {
        let home = self.home.join(name);
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join("config.toml"), config).unwrap();
        home
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

impl World {
    /// Fake `claude` and `codex` CLIs whose `mcp add` and `mcp remove` write
    /// the user-scope config the real ones write (`~/.claude.json`,
    /// `$CODEX_HOME/config.toml`), holding only that one server. Every `mcp`
    /// call goes to `mcp.log` under the world (the harness check's
    /// `--version` does not).
    fn with_fake_mcp_clients(self) -> Self {
        let log = self.mcp_log();
        let claude = format!(
            r#"#!/bin/sh
f="${{CLAUDE_CONFIG_DIR:-$HOME}}/.claude.json"
[ "$1" = mcp ] || exit 2
echo "claude $*" >>'{log}'
op=$2; shift 2
[ "$1" = --scope ] && [ "$2" = user ] || {{ echo "not user scope" >&2; exit 3; }}
shift 2
case $op in
add)
  name=$1; shift; [ "$1" = -- ] || exit 3; shift
  cmd=$1; shift; args=""
  for a in "$@"; do args="$args${{args:+,}}\"$a\""; done
  printf '{{"mcpServers":{{"%s":{{"type":"stdio","command":"%s","args":[%s],"env":{{}}}}}}}}' "$name" "$cmd" "$args" >"$f" ;;
remove) printf '{{"mcpServers":{{}}}}' >"$f" ;;
*) exit 2 ;;
esac
"#,
            log = log.display()
        );
        let codex = format!(
            r#"#!/bin/sh
f="${{CODEX_HOME:-$HOME/.codex}}/config.toml"
mkdir -p "$(dirname "$f")"
[ "$1" = mcp ] || exit 2
echo "codex $*" >>'{log}'
case $2 in
add)
  shift 2; name=$1; shift; [ "$1" = -- ] || exit 3; shift
  cmd=$1; shift; args=""
  for a in "$@"; do args="$args${{args:+, }}\"$a\""; done
  printf '[mcp_servers.%s]\ncommand = "%s"\nargs = [%s]\n' "$name" "$cmd" "$args" >"$f" ;;
remove) : >"$f" ;;
*) exit 2 ;;
esac
"#,
            log = log.display()
        );
        World::executable(&self.bin.join("claude"), &claude);
        World::executable(&self.bin.join("codex"), &codex);
        self
    }

    fn mcp_log(&self) -> PathBuf {
        self.home.parent().unwrap().join("mcp.log")
    }

    /// The fake `claude` and `codex` calls since the last `take_mcp_calls`.
    fn take_mcp_calls(&self) -> Vec<String> {
        let text = std::fs::read_to_string(self.mcp_log()).unwrap_or_default();
        let _ = std::fs::remove_file(self.mcp_log());
        text.lines().map(str::to_owned).collect()
    }

    /// The settings file the app writes (`~/.config/cmux/cmux-next.json`).
    fn settings(&self, document: &Value) {
        let path = self.home.join(".config/cmux/cmux-next.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, document.to_string()).unwrap();
    }

    /// Runs a shell line a result named (an `undo` of `claude` and `codex`
    /// calls), as an agent's shell would, with the world's PATH and HOME.
    fn shell(&self, line: &str) {
        let output = Command::new("/bin/sh")
            .args(["-c", line])
            .current_dir(&self.repo)
            .env("HOME", &self.home)
            .env("PATH", self.path())
            .env_remove("CLAUDE_CONFIG_DIR")
            .env_remove("CODEX_HOME")
            .output()
            .unwrap();
        assert!(output.status.success(), "{line}: {}", String::from_utf8_lossy(&output.stderr));
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

/// An agent, or the person, reads a Chief prompt for every task from `setup
/// list`, and docs/chief-setup-prompts.md is exactly what `setup list
/// --prompts-md` prints: a change to the task list that is not regenerated
/// fails here (`cmux setup list --prompts-md > docs/chief-setup-prompts.md`).
#[test]
fn cmux_setup_list_gives_a_chief_prompt_per_task_and_the_page_matches() {
    let world = World::new("prompts");
    let list = world.json(&["setup", "list"]);
    let status_prompt = list["status_prompt"].as_str().unwrap_or_default();
    assert!(status_prompt.contains("`cmux setup status`"), "{list}");
    for task in list["tasks"].as_array().unwrap() {
        let prompt = task["prompt"].as_str().unwrap_or_default();
        assert!(!prompt.is_empty(), "{task}");
        if let Some(setup) = task["setup"].as_str() {
            let words = setup.split_whitespace().take(3).collect::<Vec<_>>().join(" ");
            assert!(prompt.contains(&format!("`{words}")), "{task}");
        }
    }
    let machine = list["tasks"].as_array().unwrap().iter().find(|t| t["id"] == "machine").unwrap();
    assert!(
        machine["prompt"].as_str().unwrap().contains(
            "`cmux acp host doctor <name> --json`, where <name> is the `name` that result reports"
        ),
        "{machine}"
    );

    let output = world.run(&["setup", "list", "--prompts-md"]);
    assert_eq!(output.status.code(), Some(0), "{}", String::from_utf8_lossy(&output.stderr));
    let page = String::from_utf8(output.stdout).unwrap();
    let file = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../docs/chief-setup-prompts.md");
    let checked_in = std::fs::read_to_string(&file).unwrap_or_default();
    assert!(
        page == checked_in,
        "{} differs from `cmux setup list --prompts-md`; regenerate it:\n{page}",
        file.display()
    );
    for task in list["tasks"].as_array().unwrap() {
        assert!(page.contains(task["prompt"].as_str().unwrap()), "{task}");
    }
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
    assert_eq!(daemon.peers(), std::slice::from_ref(&ws));

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
    assert_eq!(
        tasks,
        [
            &json!("trust"),
            &json!("machine"),
            &json!("harness"),
            &json!("mcp"),
            &json!("computer_use"),
            &json!("cloud_machine"),
            &json!("notifications"),
            &json!("browser_import"),
            &json!("tailnet")
        ],
        "{status}"
    );
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

/// A harness whose start would read the login keychain (its profile env
/// names a Keychain item, Codex keeps its login in the keychain, or it is
/// Claude Code, whose login may be its keychain item) is not
/// asked its sign-in, by `setup status` or by name: setup never reads the
/// keychain, as acpmux's own check does not (cx-hh0vu). Its sign-in stays
/// unknown, with the reason.
#[test]
fn cmux_setup_harness_never_starts_a_harness_whose_sign_in_is_in_the_keychain() {
    let world = World::new("hkeychain");
    // Off macOS the secret store is `secret-tool` on PATH: this one answers
    // and leaves a mark, so a lookup would show.
    World::executable(&world.bin.join("secret-tool"), "#!/bin/sh\n: >\"$0.asked\"\necho secret\n");
    let vault = world.bin.join("vault-acp");
    world.harness(&vault, "1.0.0");
    let codex = world.bin.join("keyring-codex-acp");
    world.harness(&codex, "0.9.0");
    let codex_home =
        world.codex_home("keyring-codex", "cli_auth_credentials_store = \"keyring\"\n");
    // A Claude Code ACP adapter with no sign-in in its env or files.
    let claude = world.bin.join("claude-agent-acp");
    world.harness(&claude, "0.5.0");
    world.configure(json!({
        "vault": {
            "argv": [vault],
            "env": {"VAULT_API_KEY": "${keychain:cmux-harness/vault/VAULT_API_KEY}"},
        },
        "keyring-codex": {"argv": [codex], "env": {"CODEX_HOME": codex_home}},
        "my-claude": {"argv": [claude]},
    }));

    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][2];
    assert_eq!(check["task"], "harness", "{status}");
    let named = world.json(&["setup", "harness", "vault", "keyring-codex", "my-claude"]);
    let mut reports = check["harnesses"].as_array().unwrap().clone();
    reports.extend(named["harnesses"].as_array().unwrap().iter().cloned());
    let ids = reports.iter().map(|r| r["id"].as_str().unwrap()).collect::<Vec<_>>();
    let each = ["keyring-codex", "my-claude", "vault"];
    assert_eq!(ids, [each, each].concat(), "{status} {named}");
    for report in &reports {
        assert_eq!(report["installed"], true, "{report}");
        assert_eq!(report["signed_in"], Value::Null, "{report}");
        assert_eq!(report["state"], "ok", "{report}");
        let detail = report["auth_detail"].as_str().unwrap_or_default();
        assert!(detail.contains("keychain"), "{report}");
    }
    for fake in [&vault, &codex, &claude] {
        assert_eq!(World::harness_log(fake), "", "{} was started", fake.display());
    }
    assert!(!world.bin.join("secret-tool.asked").exists(), "the secret store was asked");
}

/// An unknown sign-in the check explains (Codex's provider reads a key that
/// is not set) stays as the check said: the harness is not asked, since its
/// answer to `session/new` says nothing about that key.
#[test]
fn cmux_setup_harness_keeps_the_reason_the_check_gave_for_an_unknown_sign_in() {
    let world = World::new("hreason");
    let codex = world.bin.join("router-codex-acp");
    world.harness(&codex, "0.9.0");
    // Asked, it would answer `session/new`.
    World::sign_in(&codex);
    let config = r#"model_provider = "router"
[model_providers.router]
base_url = "https://r.example/v1"
env_key = "CXS_UNSET_ROUTER_KEY"
"#;
    let codex_home = world.codex_home("router-codex", config);
    world.configure(json!({"router-codex": {"argv": [codex], "env": {"CODEX_HOME": codex_home}}}));

    let status = world.json(&["setup", "status"]);
    let named = world.json(&["setup", "harness", "router-codex"]);
    for report in [&status["checks"][2]["harnesses"][0], &named["harnesses"][0]] {
        assert_eq!(report["id"], "router-codex", "{report}");
        assert_eq!(report["installed"], true, "{report}");
        assert_eq!(report["signed_in"], Value::Null, "{report}");
        let detail = report["auth_detail"].as_str().unwrap_or_default();
        assert!(detail.contains("CXS_UNSET_ROUTER_KEY"), "{report}");
    }
    assert_eq!(World::harness_log(&codex), "", "the harness was asked");
}

/// The cmux MCP server for Claude Code and Codex started outside cmux: the
/// agent reads `status`, hands the person the switch only they turn on,
/// then adds the server through each harness's own CLI, runs it again
/// (nothing to do), and runs the `undo` it named.
#[test]
fn cmux_setup_mcp_an_agent_gives_claude_code_and_codex_the_cmux_server_and_undoes_it() {
    let world = World::new("mcp").with_fake_mcp_clients();
    let cmux = env!("CARGO_BIN_EXE_cmux-tui");
    let claude_json = world.home.join(".claude.json");
    let codex_toml = world.home.join(".codex").join("config.toml");

    let list = world.json(&["setup", "list"]);
    let task = list["tasks"].as_array().unwrap().iter().find(|t| t["id"] == "mcp").unwrap();
    assert_eq!(task["setup"], "cmux setup mcp [claude|codex ...] [--dry-run]", "{task}");
    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][3];
    assert_eq!(check["task"], "mcp", "{status}");
    assert_eq!(check["state"], "needs_setup", "{check}");
    assert_eq!(check["enabled"], false, "{check}");
    assert_eq!(check["fix"], "cmux setup mcp", "{check}");

    // The switch is the person's: setup names it and writes nothing.
    let off = world.follow(check["fix"].as_str().unwrap());
    assert_eq!(off["state"], "needs_user", "{off}");
    assert_eq!(off["enabled"], false);
    assert_eq!(off["user_action"]["kind"], "setting", "{off}");
    let text = off["user_action"]["text"].as_str().unwrap();
    assert!(text.contains("\"mcp\": {\"enabled\": true}"), "{text}");
    assert!(text.contains("cmux-next.json"), "{text}");
    let states = off["clients"].as_array().unwrap().iter().map(|c| &c["state"]).collect::<Vec<_>>();
    assert_eq!(states, [&json!("planned"), &json!("planned")], "{off}");
    assert_eq!(off["undo"], Value::Null);
    assert!(world.take_mcp_calls().is_empty(), "setup wrote with the switch off");
    assert!(!claude_json.exists() && !codex_toml.exists());

    // The person turns it on. A dry run plans and runs no CLI.
    world.settings(&json!({"mcp": {"enabled": true}}));
    let planned = world.json(&["setup", "mcp", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert_eq!(planned["dry_run"], true);
    assert!(world.take_mcp_calls().is_empty(), "a dry run ran a CLI");

    // Each harness's own CLI adds the server, user scope.
    let changed = world.json(&["setup", "mcp"]);
    assert_eq!(changed["state"], "changed", "{changed}");
    assert_eq!(
        changed["server"],
        json!({"name": "cmux", "command": cmux, "args": ["mcp", "serve"]})
    );
    assert_eq!(
        world.take_mcp_calls(),
        [
            format!("claude mcp add --scope user cmux -- {cmux} mcp serve"),
            format!("codex mcp add cmux -- {cmux} mcp serve"),
        ]
    );
    let claude: Value =
        serde_json::from_str(&std::fs::read_to_string(&claude_json).unwrap()).unwrap();
    assert_eq!(claude["mcpServers"]["cmux"]["command"], cmux, "{claude}");
    assert_eq!(claude["mcpServers"]["cmux"]["args"], json!(["mcp", "serve"]));
    let codex: toml::Table = std::fs::read_to_string(&codex_toml).unwrap().parse().unwrap();
    assert_eq!(codex["mcp_servers"]["cmux"]["command"].as_str(), Some(cmux), "{codex}");
    let undo = changed["undo"].as_str().expect("a change names its undo").to_owned();
    assert_eq!(undo, "claude mcp remove --scope user cmux && codex mcp remove cmux");

    // Again: nothing to do, no CLI run; status agrees.
    let again = world.json(&["setup", "mcp"]);
    assert_eq!(again["state"], "ok", "{again}");
    assert_eq!(again["clients"][0]["entry"]["command"], cmux, "{again}");
    assert!(world.take_mcp_calls().is_empty(), "a second run ran a CLI");
    assert_eq!(world.json(&["setup", "status"])["checks"][3]["state"], "ok");

    // The undo puts both back.
    world.shell(&undo);
    world.take_mcp_calls();
    assert_eq!(world.json(&["setup", "mcp", "--dry-run"])["state"], "planned");

    // One harness by name; one not installed is the person's install.
    std::fs::remove_file(world.bin.join("codex")).unwrap();
    let named = world.json(&["setup", "mcp", "codex"]);
    assert_eq!(named["state"], "needs_user", "{named}");
    assert_eq!(named["clients"].as_array().unwrap().len(), 1, "{named}");
    assert_eq!(named["user_action"]["kind"], "install", "{named}");
    assert_eq!(named["user_action"]["command"], "cmux setup harness codex");
    // Not named and not installed: left out of the work.
    let default = world.json(&["setup", "mcp", "--dry-run"]);
    assert_eq!(default["clients"][1]["state"], "not_applicable", "{default}");

    for args in [&["setup", "mcp", "nope"][..], &["setup", "mcp", "--bogus"]] {
        let output = world.run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        let error: Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["code"], "usage.invalid", "{args:?}");
    }
}

/// Neither Claude Code nor Codex installed: nothing to wire, so `status`
/// and the run agree on `ok` and the switch is not asked for.
#[test]
fn cmux_setup_mcp_with_neither_harness_installed_is_ok() {
    let world = World::new("mcpnone");
    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][3];
    assert_eq!((&check["task"], &check["state"]), (&json!("mcp"), &json!("ok")), "{check}");
    assert_eq!(check["fix"], Value::Null, "{check}");
    let result = world.json(&["setup", "mcp"]);
    assert_eq!(result["state"], "ok", "{result}");
    assert_eq!(result["enabled"], false, "{result}");
    assert_eq!(result["user_action"], Value::Null, "{result}");
    let clients = result["clients"].as_array().unwrap();
    assert!(clients.iter().all(|c| c["state"] == "not_applicable"), "{result}");
    // Named but not installed: the install comes before the switch.
    let named = world.json(&["setup", "mcp", "claude"]);
    assert_eq!(named["state"], "needs_user", "{named}");
    assert_eq!(named["user_action"], named["clients"][0]["user_action"], "{named}");
    assert_eq!(named["user_action"]["kind"], "install", "{named}");
}

/// A `cmux` server whose command is gone (an app that moved) is replaced,
/// and its undo puts the old one back; a `cmux` server that runs something
/// else is the person's, left as it is.
#[test]
fn cmux_setup_mcp_replaces_a_moved_cmux_and_leaves_another_server_named_cmux() {
    let world = World::new("mcpold").with_fake_mcp_clients();
    let cmux = env!("CARGO_BIN_EXE_cmux-tui");
    world.settings(&json!({"mcp": {"enabled": true}}));
    let gone = "/Applications/gone.app/Contents/Resources/bin/cmux";
    let claude_json = world.home.join(".claude.json");
    let old = json!({"mcpServers": {"cmux": {"type": "stdio", "command": gone, "args": ["mcp", "serve"]}}});
    std::fs::write(&claude_json, old.to_string()).unwrap();
    let codex_toml = world
        .codex_home(".codex", "[mcp_servers.cmux]\ncommand = \"/bin/echo\"\nargs = [\"hi\"]\n");
    let codex_toml = codex_toml.join("config.toml");
    let codex_before = std::fs::read_to_string(&codex_toml).unwrap();

    let result = world.json(&["setup", "mcp"]);
    assert_eq!(result["state"], "needs_user", "{result}");
    let claude = &result["clients"][0];
    assert_eq!(claude["state"], "changed", "{claude}");
    assert_eq!(claude["entry"]["command"], gone, "{claude}");
    let codex = &result["clients"][1];
    assert_eq!(codex["state"], "needs_user", "{codex}");
    assert_eq!(codex["user_action"]["kind"], "conflict", "{codex}");
    assert_eq!(codex["user_action"]["command"], "codex mcp remove cmux");
    assert_eq!(result["user_action"], codex["user_action"]);
    assert_eq!(
        world.take_mcp_calls(),
        [
            "claude mcp remove --scope user cmux".to_owned(),
            format!("claude mcp add --scope user cmux -- {cmux} mcp serve"),
        ]
    );
    assert_eq!(std::fs::read_to_string(&codex_toml).unwrap(), codex_before, "setup touched Codex");

    let undo = result["undo"].as_str().unwrap();
    assert_eq!(
        undo,
        format!(
            "claude mcp remove --scope user cmux && claude mcp add --scope user cmux -- {gone} mcp serve"
        )
    );
    world.shell(undo);
    let back: Value =
        serde_json::from_str(&std::fs::read_to_string(&claude_json).unwrap()).unwrap();
    assert_eq!(back["mcpServers"]["cmux"]["command"], gone, "{back}");
}

/// Answers the app control requests on `listener` with `answer(method,
/// params)`, one connection after another, keeping every request in
/// `requests` before it replies; `None` closes the connection unanswered.
fn serve_app(
    listener: UnixListener,
    requests: Arc<Mutex<Vec<Value>>>,
    answer: impl Fn(&str, &Value) -> Option<Result<Value, Value>> + Send + 'static,
) {
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(stream) = stream else { break };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut line = String::new();
            while reader.read_line(&mut line).unwrap_or(0) > 0 {
                let request: Value = serde_json::from_str(&line).unwrap();
                line.clear();
                let answer =
                    answer(request["method"].as_str().unwrap_or_default(), &request["params"]);
                let response = match answer {
                    Some(Ok(result)) => json!({"id": request["id"], "ok": true, "result": result}),
                    Some(Err(error)) => json!({"id": request["id"], "ok": false, "error": error}),
                    None => Value::Null,
                };
                requests.lock().unwrap().push(request);
                if response.is_null() || writeln!(writer, "{response}").is_err() {
                    break;
                }
            }
        }
    });
}

/// A fake cmux app on a socket of the world's that serves what `cmux setup
/// computer-use` and `cmux settings set` ask: `computer_use.status` answers
/// `status`; `settings.set computerUse.enabled` with `confirm` is the
/// person's sheet, approved while `approve` is set (true turns Computer Use
/// on with the grants of `on`, false turns it off) and declined otherwise,
/// or left unanswered past the app's deadline (`timeout`) while `unanswered`
/// is set; `settings.get computerUse.enabled` reads the last approved value.
/// Every request is kept.
struct FakeApp {
    status: Arc<Mutex<Value>>,
    approve: Arc<std::sync::atomic::AtomicBool>,
    unanswered: Arc<std::sync::atomic::AtomicBool>,
    enabled: Arc<std::sync::atomic::AtomicBool>,
    requests: Arc<Mutex<Vec<Value>>>,
}

impl FakeApp {
    fn start(world: &mut World, off: Value, on: Value) -> Self {
        let socket = world.home.parent().unwrap().join("app.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        world.app = Some(socket);
        let app = Self {
            status: Arc::new(Mutex::new(off.clone())),
            approve: Arc::new(std::sync::atomic::AtomicBool::new(true)),
            unanswered: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            enabled: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            requests: Arc::new(Mutex::new(Vec::new())),
        };
        let (status, approve, unanswered, enabled) =
            (app.status.clone(), app.approve.clone(), app.unanswered.clone(), app.enabled.clone());
        serve_app(listener, app.requests.clone(), move |method, params| {
            Some(match method {
                "computer_use.status" => Ok(status.lock().unwrap().clone()),
                "settings.get" if params["path"] == "computerUse.enabled" => {
                    Ok(json!({"value": enabled.load(Ordering::SeqCst)}))
                }
                "settings.set"
                    if params["path"] == "computerUse.enabled" && params["confirm"] == true =>
                {
                    if unanswered.load(Ordering::SeqCst) {
                        Err(json!({"code": "timeout",
                        "message": "settings.set did not finish within 120000ms"}))
                    } else if approve.load(Ordering::SeqCst) {
                        let next = if params["value"] == true { &on } else { &off };
                        enabled.store(params["value"] == true, Ordering::SeqCst);
                        *status.lock().unwrap() = next.clone();
                        Ok(json!({"path": params["path"], "value": params["value"]}))
                    } else {
                        Err(json!({"code": "setting_user_only", "message": "declined",
                        "data": {"declined": true}}))
                    }
                }
                "settings.set" => Err(json!({"code": "setting_user_only",
                "message": "computerUse.enabled is the person's; pass --confirm"})),
                _ => Err(json!({"code": "method_not_found", "message": "unknown"})),
            })
        });
        app
    }

    /// The `settings.set` params the app received, in order.
    fn settings_sets(&self) -> Vec<Value> {
        let requests = self.requests.lock().unwrap();
        requests
            .iter()
            .filter(|r| r["method"] == "settings.set")
            .map(|r| r["params"].clone())
            .collect()
    }
}

/// Computer Use driven the way an agent drives it: `status` names it, a dry
/// run asks nothing, the person declines and then allows it on the app's
/// sheet (one click), each missing macOS grant comes back as the System
/// Settings pane to open, and the `undo` turns it off on the same sheet.
#[test]
fn cmux_setup_computer_use_turns_it_on_with_the_persons_ok_and_names_each_grant() {
    const UNDO: &str = "cmux settings set computerUse.enabled false --confirm";
    let mut world = World::new("cu");
    let off =
        json!({"phase": "off", "accessibility": null, "screen_recording": null, "helper": null});
    let on =
        json!({"phase": "ready", "accessibility": false, "screen_recording": true, "helper": "1"});
    let app = FakeApp::start(&mut world, off, on);

    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][4];
    assert_eq!(check["task"], "computer_use", "{status}");
    assert_eq!(check["state"], "needs_setup", "{check}");
    let fix = check["fix"].as_str().expect("status names its fix").to_owned();
    assert_eq!(fix, "cmux setup computer-use");

    let planned = world.json(&["setup", "computer-use", "--dry-run"]);
    assert_eq!(planned["state"], "planned", "{planned}");
    assert_eq!(planned["undo"], UNDO);
    assert!(app.settings_sets().is_empty(), "a dry run asked the person");

    // The person declines: nothing changed, and the agent does not ask again.
    app.approve.store(false, Ordering::SeqCst);
    let declined = world.follow(&fix);
    assert_eq!(declined["state"], "needs_user", "{declined}");
    assert_eq!(declined["user_action"]["kind"], "declined", "{declined}");
    assert_eq!(declined["undo"], Value::Null);

    // The sheet is left unanswered until the app's deadline: also not allowed.
    app.unanswered.store(true, Ordering::SeqCst);
    let unanswered = world.follow(&fix);
    assert_eq!(unanswered["state"], "needs_user", "{unanswered}");
    assert_eq!(unanswered["user_action"]["kind"], "declined", "{unanswered}");
    let text = unanswered["user_action"]["text"].as_str().unwrap();
    assert!(text.contains("did not answer the sheet"), "{text}");
    assert_eq!(unanswered["undo"], Value::Null);
    app.unanswered.store(false, Ordering::SeqCst);

    // The person allows it: on, and the one grant still missing.
    app.approve.store(true, Ordering::SeqCst);
    let on = world.follow(&fix);
    assert_eq!(on["state"], "needs_user", "{on}");
    assert_eq!(on["undo"], UNDO, "{on}");
    assert_eq!(on["before"]["phase"], "off");
    assert_eq!(on["after"]["phase"], "ready");
    let action = &on["user_action"];
    assert_eq!(action["kind"], "grant", "{action}");
    let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility";
    assert_eq!(action["url"], url);
    assert_eq!(action["command"], format!("open '{url}'"));
    let sets = app.settings_sets();
    assert_eq!(sets.len(), 3, "{sets:?}");
    assert_eq!(sets[2]["path"], "computerUse.enabled");
    assert_eq!(sets[2]["value"], true);
    assert_eq!(sets[2]["confirm"], true);

    // The person turns the switch on; nothing is left and nothing is asked.
    app.status.lock().unwrap()["accessibility"] = json!(true);
    let ready = world.json(&["setup", "computer-use"]);
    assert_eq!(ready["state"], "ok", "{ready}");
    assert_eq!(ready["undo"], Value::Null);
    assert_eq!(ready["user_action"], Value::Null);
    assert_eq!(app.settings_sets().len(), 3, "an ok run asked the person");
    assert_eq!(world.json(&["setup", "status"])["checks"][4]["state"], "ok");

    // The undo, as the agent's shell runs it: the same sheet, turned off.
    let words = shell_words(UNDO);
    let args = words[1..].iter().map(String::as_str).collect::<Vec<_>>();
    let output = world.run(&args);
    assert!(output.status.success(), "{UNDO}: {}", String::from_utf8_lossy(&output.stderr));
    let sets = app.settings_sets();
    assert_eq!((&sets[3]["value"], &sets[3]["confirm"]), (&json!(false), &json!(true)), "{sets:?}");
    assert_eq!(world.json(&["setup", "computer-use", "--dry-run"])["state"], "planned");

    let output = world.run(&["setup", "computer-use", "now"]);
    assert_eq!(output.status.code(), Some(2));
}

/// Managed settings, a helper that is not ready, and no app: each is named
/// for the person and nothing is asked of the app but its status.
#[test]
fn cmux_setup_computer_use_names_what_it_cannot_change() {
    for (phase, kind) in [("disabled_by_policy", "policy"), ("version_mismatch", "app")] {
        let mut world = World::new("cupolicy");
        let status = json!({"phase": phase, "accessibility": null, "screen_recording": null});
        let app = FakeApp::start(&mut world, status.clone(), status);
        let result = world.json(&["setup", "computer-use"]);
        assert_eq!(result["state"], "needs_user", "{result}");
        assert_eq!(result["user_action"]["kind"], kind, "{result}");
        assert_eq!(result["undo"], Value::Null);
        assert!(app.settings_sets().is_empty(), "{phase}: setup changed a setting");
    }
    let mut world = World::new("cunoapp");
    world.app = Some(world.home.parent().unwrap().join("gone.sock"));
    let result = world.json(&["setup", "computer-use"]);
    assert_eq!(result["state"], "needs_user", "{result}");
    assert_eq!(result["user_action"]["kind"], "app", "{result}");
}

/// Allowed, but the app still reads `off` (its phase follows the setting a
/// moment later): setup says to wait, not to ask the person again, `status`
/// agrees, and no rerun asks for a second sheet, before or after the phase
/// caught up.
#[test]
fn cmux_setup_computer_use_waits_when_the_phase_lags_the_ok() {
    let mut world = World::new("culag");
    let off = json!({"phase": "off", "accessibility": null, "screen_recording": null});
    let app = FakeApp::start(&mut world, off.clone(), off);
    let result = world.json(&["setup", "computer-use"]);
    assert_eq!(result["state"], "needs_user", "{result}");
    assert_eq!(result["user_action"]["kind"], "wait", "{result}");
    assert_eq!(result["undo"], "cmux settings set computerUse.enabled false --confirm");
    let early = world.json(&["setup", "computer-use"]);
    assert_eq!(early["user_action"]["kind"], "wait", "{early}");
    assert_eq!(early["undo"], Value::Null, "{early}");
    let status = world.json(&["setup", "status"]);
    let check = &status["checks"][4];
    assert_eq!(check["task"], "computer_use", "{check}");
    assert_eq!(check["state"], "needs_user", "{check}");
    assert_eq!(check["user_action"], early["user_action"], "{check}");
    *app.status.lock().unwrap() =
        json!({"phase": "ready", "accessibility": true, "screen_recording": true, "helper": "1"});
    let rerun = world.json(&["setup", "computer-use"]);
    assert_eq!(rerun["state"], "ok", "{rerun}");
    assert_eq!(app.settings_sets().len(), 1, "the rerun showed a second sheet");
}

/// A decision recorded under another spelling of the folder (made before the folder moved behind
/// a link) is the folder's own: setup reads it as acpmux does, and `--level unknown` forgets it.
#[test]
fn cmux_setup_trust_forgets_a_decision_recorded_under_another_spelling() {
    let world = World::new("trust-spelling");
    let folder = world.folder();
    let link = world.home.parent().unwrap().join("spelled-through-a-link");
    std::os::unix::fs::symlink(&folder, &link).unwrap();
    let old = link.to_string_lossy().into_owned();
    std::fs::create_dir_all(&world.acpmux).unwrap();
    std::fs::write(world.acpmux.join("trust.json"), json!({old.as_str(): "untrusted"}).to_string())
        .unwrap();

    let held = world.json(&["setup", "trust", &folder, "--level", "untrusted"]);
    assert_eq!(held["state"], "ok", "{held}");
    assert_eq!(held["recorded"], "untrusted", "{held}");

    let forgot = world.json(&["setup", "trust", &folder, "--level", "unknown"]);
    assert_eq!(forgot["state"], "changed", "{forgot}");
    assert_eq!(forgot["after"]["level"], "unknown", "{forgot}");
    assert_eq!(world.record(), Some(json!({})));
}
