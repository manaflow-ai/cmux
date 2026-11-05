//! Real product CLI -> daemon -> supervised QuickJS runner -> ACP child -> exact reply.
//! Linux uses inotify condition waits; no status polling or live harness credentials.
#![cfg(target_os = "linux")]

#[path = "../../acpmux/tests/support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use acpmux::workflow_runs::{Child, RunRecord, State, Store};
use serde_json::{Value, json};
use std::collections::BTreeSet;
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
                "harnesses":{"fake":{"argv":["python3",FAKE],"family":"fake"}}
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

    fn write(&self, source: &str) {
        fs::write(self.dir.path().join("work").join(SCRIPT), source).unwrap();
    }
    fn runs(&self) -> Store {
        Store::new(self.dir.path().join("acpmux/workflows"))
    }

    fn agent_said(&self, run: &RunRecord, expected: &str) -> bool {
        let config = acpmux::config::Config::default();
        let logs = acpmux::store::open(&config.store, &self.dir.path().join("acpmux")).unwrap();
        run.activities.values().any(|activity| {
            let Child::Agent { session_id, .. } = &activity.child else { return false };
            let mut found = false;
            let _ = logs.scan_strict(session_id, 0, &mut |event| {
                found = event.msg.pointer("/params/update/content/text").and_then(Value::as_str)
                    == Some(expected);
                !found
            });
            found
        })
    }

    fn until(&self, id: &str, condition: impl Fn(&RunRecord) -> bool) -> RunRecord {
        let mut watch = Changes::new();
        watch.add(&self.dir.path().join("acpmux/workflows").join(id));
        watch.add(&self.dir.path().join("acpmux/sessions"));
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
                let config = acpmux::config::Config::default();
                if let Ok(logs) =
                    acpmux::store::open(&config.store, &self.dir.path().join("acpmux"))
                {
                    let mut seen = BTreeSet::new();
                    for activity in run.activities.values() {
                        if let Child::Agent { session_id, .. } = &activity.child
                            && seen.insert(session_id)
                        {
                            let mut tail = std::collections::VecDeque::new();
                            let _ = logs.scan_strict(session_id, 0, &mut |event| {
                                tail.push_back(format!("{event:?}"));
                                if tail.len() > 30 {
                                    tail.pop_front();
                                }
                                true
                            });
                            eprintln!("failed workflow child {session_id}: {tail:#?}");
                        }
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
