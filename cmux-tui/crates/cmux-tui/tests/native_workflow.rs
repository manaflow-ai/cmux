//! Real product CLI -> daemon -> supervised QuickJS runner -> ACP child -> exact reply.
//! Linux uses inotify condition waits; no status polling or live harness credentials.
#![cfg(target_os = "linux")]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::workflow_runs::{Child, RunRecord, State, Store};
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::CString;
use std::fs;
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_workflow_agent.py");
/// The stand-in agent that answers `envs: A,B` with its own environment.
const PROBE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_agent.py");
const SCRIPT: &str = ".cmux/workflows/proof.workflow.js";

struct Machine {
    dir: tempfile::TempDir,
}

impl Machine {
    fn start() -> Self {
        let dir = tempfile::Builder::new().prefix("cmux-wf-").tempdir_in("/tmp").unwrap();
        for path in ["home/.config/cmux", "acpmux", "work/.cmux/workflows", "no-bin"] {
            fs::create_dir_all(dir.path().join(path)).unwrap();
        }
        fs::set_permissions(dir.path().join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
        fs::write(
            dir.path().join("acpmux/config.json"),
            json!({
                "defaultHarness":"fake", "permissionPolicy":"ask",
                "harnesses":{"fake":{"argv":["python3",FAKE],"family":"fake"},
                    "probe":{"argv":["python3",PROBE],"family":"fake"}}
            })
            .to_string(),
        )
        .unwrap();
        fs::write(
            dir.path().join("home/.config/cmux/cmux-next.json"),
            json!({"mcp":{"enabled":true}}).to_string(),
        )
        .unwrap();
        let work = fs::canonicalize(dir.path().join("work")).unwrap();
        fs::write(
            dir.path().join("acpmux/trust.json"),
            json!({work.to_str().unwrap():"trusted"}).to_string(),
        )
        .unwrap();
        let machine = Self { dir };
        machine.checked(&["acp", "daemon", "start"]);
        machine
    }

    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
        daemon_env::apply(&mut command, self.dir.path(), daemon_env::Agents::StandIn, &[]);
        command
            .args(args)
            .current_dir(self.dir.path().join("work"))
            .stdin(Stdio::null())
            .env("HOME", self.dir.path().join("home"))
            .env("ACPMUX_HOME", self.dir.path().join("acpmux"))
            .env("CMUX_AGENT_TOOLS_BIN_DIR", self.dir.path().join("no-bin"));
        command
    }

    fn checked(&self, args: &[&str]) -> Output {
        let output = self.command(args).output().unwrap();
        assert!(
            output.status.success(),
            "cmux {args:?}: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        output
    }

    fn json(&self, args: &[&str]) -> Value {
        let mut words = vec!["--json"];
        words.extend_from_slice(args);
        let output = self.checked(&words);
        serde_json::from_slice(&output.stdout).unwrap_or_else(|error| {
            panic!(
                "cmux {words:?} gave no JSON ({error}): {}",
                String::from_utf8_lossy(&output.stdout)
            )
        })
    }

    /// A chat of the stand-in agent ([`PROBE`]): its id, and the acpmux environment its agent
    /// got (caller token, sockets, home), which an MCP server its harness starts inherits.
    fn agent_chat(&self) -> (String, Vec<(String, String)>) {
        use std::io::{BufRead, BufReader, Write};
        let socket = self.dir.path().join("acpmux/acpmux.sock");
        let stream = std::os::unix::net::UnixStream::connect(socket).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(60))).unwrap();
        let mut reader = BufReader::new(stream);
        let mut call = |id: u64, method: &str, params: Value| {
            let request = json!({"jsonrpc":"2.0","id":id,"method":method,"params":params});
            writeln!(reader.get_mut(), "{request}").unwrap();
            let mut text = String::new();
            loop {
                let mut line = String::new();
                assert_ne!(reader.read_line(&mut line).unwrap(), 0, "closed before {method}");
                let message: Value = serde_json::from_str(&line).unwrap();
                if message["id"] == id {
                    return (message, text);
                }
                if let Some(t) =
                    message.pointer("/params/update/content/text").and_then(Value::as_str)
                {
                    text.push_str(t);
                }
            }
        };
        call(1, "initialize", json!({"protocolVersion": 1, "clientCapabilities": {}}));
        let work = fs::canonicalize(self.dir.path().join("work")).unwrap();
        let (created, _) = call(
            2,
            "session/new",
            json!({"cwd": work, "mcpServers": [], "_meta": {"acpmux": {"harness": "probe"}}}),
        );
        let session = created["result"]["sessionId"]
            .as_str()
            .unwrap_or_else(|| panic!("no chat: {created}"))
            .to_owned();
        let names = "ACPMUX_ENV,ACPMUX_HOME,ACPMUX_SOCKET,ACPMUX_SESSION_ID,ACPMUX_SESSION_TOKEN,\
            ACPMUX_SESSION_TOKEN_SOCKET,CMUX_AGENT_SESSION";
        let prompt = json!({"sessionId": session,
            "prompt": [{"type": "text", "text": format!("envs: {names}")}]});
        let (reply, text) = call(3, "session/prompt", prompt);
        assert!(reply.get("error").is_none(), "{reply}");
        let env: BTreeMap<String, String> =
            serde_json::from_str(&text).unwrap_or_else(|_| panic!("no environment: {text}"));
        let env = env.into_iter().filter(|(_, value)| !value.is_empty()).collect::<Vec<_>>();
        assert!(env.iter().any(|(k, _)| k == "ACPMUX_SESSION_TOKEN"), "no caller token");
        (session, env)
    }

    /// One `cmux_exec` call of `script` to `cmux mcp serve` run with the chat's agent `env`,
    /// with `meta` as Claude Code's `_meta`: the call's result.
    fn mcp_exec(&self, env: &[(String, String)], script: &str, meta: Value) -> Value {
        use std::io::{BufRead, BufReader, Write};
        let mut command = self.command(&["mcp", "serve"]);
        command
            .envs(env.iter().map(|(key, value)| (key, value)))
            .env("CMUX_NEXT_CONFIG_FILE", self.dir.path().join("home/.config/cmux/cmux-next.json"))
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        let mut child = command.spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        for message in [
            json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
                "protocolVersion": "2025-06-18", "capabilities": {},
                "clientInfo": {"name": "claude-code", "version": "2"}}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
            json!({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
                "name": "cmux_exec", "arguments": {"script": script}, "_meta": meta}}),
        ] {
            writeln!(stdin, "{message}").unwrap();
        }
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let result = loop {
            let line = lines.next().expect("an MCP reply").unwrap();
            let message: Value = serde_json::from_str(&line).unwrap();
            if message["id"] == 2 {
                break message["result"].clone();
            }
        };
        drop(stdin);
        let _ = child.kill();
        let _ = child.wait();
        result
    }

    fn write(&self, source: &str) {
        fs::write(self.dir.path().join("work").join(SCRIPT), source).unwrap();
    }
    fn runs(&self) -> Store {
        Store::new(self.dir.path().join("acpmux/workflows"))
    }

    /// A child session's newest events, read through the running daemon: the daemon holds
    /// the store's event journal (always on since #37118), so a second open of the store
    /// here fails with "another process holds the journal".
    fn session_events(&self, session_id: &str) -> Vec<Value> {
        let output =
            self.command(&["acp", "session", "tail", session_id, "--last", "1000"]).output();
        let Ok(output) = output else { return Vec::new() };
        String::from_utf8_lossy(&output.stdout)
            .lines()
            .filter_map(|line| serde_json::from_str::<Value>(line).ok())
            .collect()
    }

    fn agent_said(&self, run: &RunRecord, expected: &str) -> bool {
        run.activities.values().any(|activity| {
            let Child::Agent { session_id, .. } = &activity.child else { return false };
            self.session_events(session_id).iter().any(|event| {
                event.pointer("/msg/params/update/content/text").and_then(Value::as_str)
                    == Some(expected)
            })
        })
    }

    fn until(&self, id: &str, condition: impl Fn(&RunRecord) -> bool) -> RunRecord {
        let mut watch = Changes::new();
        watch.add(&self.dir.path().join("acpmux/workflows").join(id));
        watch.add(&self.dir.path().join("acpmux/sessions"));
        // A child's events reach its session log at the journal's next sync; the journal
        // itself is written as they arrive.
        watch.add(&self.dir.path().join("acpmux/journal"));
        let deadline = Instant::now() + Duration::from_secs(90);
        loop {
            let run = self.runs().get(id).unwrap();
            // Subscribe before inspecting a child's existing log, covering both creation
            // and an event that arrived before this watcher attached to that directory.
            for activity in run.activities.values() {
                if let Child::Agent { session_id, .. } = &activity.child {
                    let session = self.dir.path().join("acpmux/sessions").join(session_id);
                    watch.add(&session);
                    // inotify directory watches are not recursive. Event segments
                    // append below events/, after session metadata stops changing.
                    watch.add(&session.join("events"));
                }
            }
            assert_ne!(run.state, State::Failed, "real workflow failed: {:?}", run.outcome);
            if condition(&run) {
                return run;
            }
            watch.next(deadline, &run);
        }
    }
}

impl Drop for Machine {
    fn drop(&mut self) {
        if std::thread::panicking() {
            for run in self.runs().list().unwrap_or_default() {
                eprintln!("failed workflow record: {run:?}");
                let mut seen = BTreeSet::new();
                for activity in run.activities.values() {
                    if let Child::Agent { session_id, .. } = &activity.child
                        && seen.insert(session_id)
                    {
                        let events = self.session_events(session_id);
                        let tail = &events[events.len().saturating_sub(30)..];
                        eprintln!("failed workflow child {session_id}: {tail:#?}");
                    }
                }
            }
        }
        let _ = self.command(&["acp", "daemon", "shutdown", "--end-agents"]).output();
    }
}

/// Watch atomic run-record renames and exact child log writes. The descriptor and
/// every watch close at test end; a bounded poll waits for an OS event, never samples.
struct Changes {
    file: fs::File,
    paths: BTreeSet<PathBuf>,
}

impl Changes {
    fn new() -> Self {
        // SAFETY: a new descriptor is owned by File below and closes on drop.
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC | libc::IN_NONBLOCK) };
        assert!(fd >= 0, "inotify: {}", std::io::Error::last_os_error());
        Self { file: unsafe { fs::File::from_raw_fd(fd) }, paths: BTreeSet::new() }
    }
    fn add(&mut self, path: &Path) {
        if self.paths.contains(path) || !path.is_dir() {
            return;
        }
        let name = CString::new(path.as_os_str().as_bytes()).unwrap();
        // SAFETY: the C path and descriptor remain valid throughout this call.
        let descriptor = unsafe {
            libc::inotify_add_watch(
                self.file.as_raw_fd(),
                name.as_ptr(),
                // Store reads open the record lock for writing: CLOSE_WRITE would wake
                // this condition on its own readback and turn it into a sampling loop.
                libc::IN_CREATE | libc::IN_MODIFY | libc::IN_MOVED_TO,
            )
        };
        assert!(descriptor >= 0, "watch {}: {}", path.display(), std::io::Error::last_os_error());
        self.paths.insert(path.into());
    }
    fn next(&mut self, deadline: Instant, run: &RunRecord) {
        let remaining = deadline.saturating_duration_since(Instant::now());
        assert!(!remaining.is_zero(), "workflow {} timed out at {:?}", run.id, run.state);
        let mut descriptor =
            libc::pollfd { fd: self.file.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: poll sees one initialized descriptor for the bounded duration.
        let ready = unsafe {
            libc::poll(&mut descriptor, 1, remaining.as_millis().min(i32::MAX as u128) as i32)
        };
        assert!(
            ready > 0,
            "workflow {} had no state/log event before deadline: {:?}",
            run.id,
            run.state
        );
        let mut events = [0; 16384];
        assert!(self.file.read(&mut events).unwrap() > 0, "inotify event stream closed");
    }
}

#[test]
fn product_workflow_reads_schema_checked_agent_reply_from_real_runner() {
    let machine = Machine::start();
    machine.write(r#"export const meta={name:'Product proof'};
        const reply=await phase('Reply',()=>agent('schema-once',{harness:'fake',schema:{type:'object',required:['ok'],properties:{ok:{const:true}}}}));
        return {marker:'product-runner',reply};"#);
    let started = machine.json(&["workflow", "start", SCRIPT]);
    let id = started["runId"].as_str().unwrap_or_else(|| panic!("no run: {started}"));
    let completed = machine.until(id, |run| run.state == State::Completed);
    let status = machine.json(&["workflow", "status", id]);
    assert_eq!(status["state"], "completed", "{status}");
    assert_eq!(
        status["outcome"]["Ok"]["result"],
        json!({"marker":"product-runner","reply":{"ok":true}}),
        "{status}"
    );
    assert_eq!(
        completed.outcome.as_ref().unwrap().as_ref().unwrap()["result"],
        json!({"marker":"product-runner","reply":{"ok":true}})
    );
    assert!(completed.local_principal, "standalone CLI must use the dedicated local owner");
    let agents = completed.activities.values().filter(|activity| activity.kind == "agent").count();
    assert_eq!(agents, 1, "one workflow call must own one child");
}

#[test]
fn product_workflow_pause_resume_uses_pinned_source_and_same_agent_child() {
    let machine = Machine::start();
    let pinned = r#"export const meta={name:'Pinned proof'};
        const reply=await agent('until-cancel',{harness:'fake'});
        return {marker:'pinned-v1',reply};"#;
    machine.write(pinned);
    let started = machine.json(&["workflow", "start", SCRIPT]);
    let id = started["runId"].as_str().unwrap_or_else(|| panic!("no run: {started}"));
    let running = machine.until(id, |run| machine.agent_said(run, "working"));
    let original = running
        .activities
        .values()
        .find(|activity| activity.kind == "agent")
        .unwrap()
        .child
        .clone();
    let paused = machine.json(&["workflow", "pause", id]);
    assert_eq!(paused["state"], "paused", "{paused}");
    machine.write("throw new Error('edited source must never execute');");
    let resumed = machine.json(&["workflow", "resume", id]);
    assert_eq!(resumed["sourceHash"], started["sourceHash"], "source changed on resume");
    let completed = machine.until(id, |run| run.state == State::Completed);
    let status = machine.json(&["workflow", "status", id]);
    assert_eq!(
        status["outcome"]["Ok"]["result"],
        json!({"marker":"pinned-v1","reply":"{\"ok\":true}"}),
        "{status}"
    );
    assert_eq!(completed.source, pinned, "the daemon must run the immutable snapshot");
    let agents = completed
        .activities
        .values()
        .filter(|activity| activity.kind == "agent")
        .collect::<Vec<_>>();
    assert_eq!(agents.len(), 1, "resume duplicated the logical activity");
    assert_eq!(agents[0].child, original, "resume duplicated the child session");
}

#[test]
fn product_workflow_reads_machine_result_and_terminal_child_journal() {
    use base64::Engine;
    let machine = Machine::start();
    machine.write(
        r#"export const meta={name:'Machine result proof'};
        return await machine("printf 'workflow-machine-result'",{on:'local'});"#,
    );
    let started = machine.json(&["workflow", "start", SCRIPT]);
    let id = started["runId"].as_str().unwrap_or_else(|| panic!("no run: {started}"));
    let completed = machine.until(id, |run| run.state == State::Completed);
    let status = machine.json(&["workflow", "status", id]);
    assert_eq!(status["state"], "completed", "{status}");
    let result = &status["outcome"]["Ok"]["result"];
    assert_eq!(result["state"], "exited", "{status}");
    assert_eq!(result["exitCode"], 0, "{status}");
    assert_eq!(result["text"], "workflow-machine-result", "{status}");
    let bytes =
        base64::engine::general_purpose::STANDARD.decode(result["data"].as_str().unwrap()).unwrap();
    assert_eq!(bytes, b"workflow-machine-result");
    assert_eq!(&completed.outcome.as_ref().unwrap().as_ref().unwrap()["result"], result);
    for kind in ["machine", "machine_task"] {
        let children = completed
            .activities
            .values()
            .filter(|activity| activity.kind == kind)
            .collect::<Vec<_>>();
        assert_eq!(children.len(), 1, "one {kind} child must be journaled");
        assert!(matches!(children[0].child, Child::Machine { .. }));
        assert_eq!(
            children[0].outcome.as_ref().unwrap().as_ref().unwrap(),
            result,
            "{kind} journal must retain the exact final machine result"
        );
    }
}

/// W5-M (a), bench round 4: a Claude Code subagent that starts a workflow through cmux's MCP
/// (`cmux.cmux_workflow` in a `cmux_exec` script) owns that workflow's work as its Bash would:
/// the workflow's commands run with the subagent's mark (`ACPMUX_CALLER_SUBAGENT`), so an
/// `acpmux send` in them names the subagent, and its report goes to the subagent, not the lead.
#[test]
fn w5s_a_workflow_a_subagent_starts_runs_its_commands_as_that_subagent() {
    const SUB: &str = "a0a68e7af3df5967e";
    let machine = Machine::start();
    let (session, env) = machine.agent_chat();
    // What acpmux's PreToolUse hook records for the subagent's `cmux_exec` call (`bg_hook.rs`).
    let home = machine.dir.path().join("acpmux");
    acpmux::subagent_call::record(&home, &session, "toolu_01wf", SUB, "general-purpose").unwrap();
    let source = r#"return await machine('printf %s "$ACPMUX_CALLER_SUBAGENT"',{on:'local'});"#;
    let script = format!(
        "return await cmux.cmux_workflow({{action:'start',name:'Subagent proof',source:{}}});",
        json!(source)
    );
    let answer = machine.mcp_exec(&env, &script, json!({"claudecode/toolUseId": "toolu_01wf"}));
    assert_ne!(answer["isError"], true, "{answer}");
    let runs = machine.runs().list().unwrap();
    let [run] = runs.as_slice() else { panic!("one run expected: {answer}") };
    assert_eq!(run.owner_session_id, session, "the subagent's chat owns the run");
    let completed = machine.until(&run.id, |run| run.state == State::Completed);
    let result = &completed.outcome.as_ref().unwrap().as_ref().unwrap()["result"];
    assert_eq!(
        result["text"],
        format!("general-purpose:{SUB}"),
        "the workflow's command did not run as the subagent: {result}"
    );
}
