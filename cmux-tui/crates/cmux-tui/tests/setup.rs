//! `cmux setup` driven the way an agent drives it: read `list` and `status`,
//! run the fix `status` names, run it again, then run the `undo` the result
//! names, reading only the JSON each step prints. A fake HOME and acpmux
//! home, so nothing of the person's is read or written.
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
    /// Where `cmux setup` looks for an acpmux daemon.
    socket: PathBuf,
}

impl World {
    fn new(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let n = NEXT.fetch_add(1, Ordering::Relaxed);
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000;
        // Short: Unix socket paths are limited to about 100 bytes.
        let dir = Path::new("/tmp").join(format!("cxs-{name}-{}-{stamp}-{n}", std::process::id()));
        let world = Self {
            home: dir.join("home"),
            acpmux: dir.join("acpmux"),
            repo: dir.join("work").join("repo"),
            socket: dir.join("d.sock"),
        };
        for path in [&world.home, &world.acpmux, &world.repo] {
            std::fs::create_dir_all(path).unwrap();
        }
        world
    }

    /// The folder as acpmux keys it (/tmp is /private/tmp on macOS).
    fn folder(&self) -> String {
        std::fs::canonicalize(&self.repo).unwrap().to_string_lossy().into_owned()
    }

    fn record(&self) -> Option<Value> {
        let text = std::fs::read_to_string(self.acpmux.join("trust.json")).ok()?;
        Some(serde_json::from_str(&text).unwrap())
    }

    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(args)
            .current_dir(&self.repo)
            .env("HOME", &self.home)
            .env("ACPMUX_HOME", &self.acpmux)
            .env("ACPMUX_SOCKET", &self.socket)
            .env("LC_ALL", "C")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env_remove("CMUX_NEXT_CONFIG_FILE")
            .env_remove("ACPMUX_SESSION_ID")
            .env_remove("CMUX_SOCKET_PATH")
            .stdin(Stdio::null())
            .output()
            .unwrap()
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
    ] {
        let output = world.run(args);
        assert_eq!(output.status.code(), Some(2), "{args:?}");
        let error: Value = serde_json::from_slice(&output.stderr).unwrap();
        assert_eq!(error["code"], "usage.invalid", "{args:?}");
    }
    assert_eq!(world.record(), None);
}
