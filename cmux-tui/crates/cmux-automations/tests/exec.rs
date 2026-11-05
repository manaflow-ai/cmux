//! A run's real process: exit codes, the timeout kill, the log, the env.

use std::time::Instant;

use cmux_automations::exec::run_job;
use cmux_automations::{
    AutomationSpec, Body, CatchUp, ExecOutcome, Executor, Job, RunState, Store, Trigger,
    start_manual,
};

struct Pending;
impl Executor for Pending {
    fn start(&mut self, _job: &Job) -> Result<u32, String> {
        Ok(std::process::id())
    }
    fn is_alive(&self, _pid: u32) -> bool {
        true
    }
}

fn store(tag: &str) -> Store {
    let dir =
        std::env::temp_dir().join(format!("cmux-automations-exec-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    Store::open(&dir).unwrap()
}

fn command(store: &Store, name: &str, cmd: &str, timeout_seconds: u64) -> String {
    let spec = AutomationSpec {
        name: name.into(),
        trigger: Trigger::Manual,
        body: Body::Command {
            command: cmd.into(),
            folder: Some(std::env::temp_dir().to_string_lossy().into_owned()),
        },
        catch_up: CatchUp::default(),
        timeout_seconds,
        enabled: true,
    };
    store.create(spec, 0).unwrap().id
}

#[test]
fn exit_code_output_and_env_reach_the_record_and_the_log() {
    let s = store("exit");
    let id = command(&s, "Echo", "echo \"hello $CMUX_AUTOMATION_RUN_ID\"; exit 3", 30);
    let run = start_manual(&s, &id, "k", 1, &mut Pending).unwrap();
    assert_eq!(run_job(&s, &id, &run).unwrap(), ExecOutcome::Exited { code: 3 });
    let r = s.run(&id, &run).unwrap().unwrap();
    assert_eq!(r.state, RunState::Failed);
    assert_eq!(r.exit_code, Some(3));
    let log = std::fs::read_to_string(s.log_path(&id, &run)).unwrap();
    assert!(log.contains(&format!("hello {run}")), "{log}");
}

#[test]
fn success_is_succeeded() {
    let s = store("ok");
    let id = command(&s, "True", "true", 30);
    let run = start_manual(&s, &id, "k", 1, &mut Pending).unwrap();
    run_job(&s, &id, &run).unwrap();
    assert_eq!(s.run(&id, &run).unwrap().unwrap().state, RunState::Succeeded);
}

#[test]
fn a_run_past_its_timeout_is_stopped_with_its_children() {
    let s = store("timeout");
    // The shell's child would outlive a kill of the shell alone.
    let id = command(&s, "Slow", "sleep 60 & wait", 1);
    let run = start_manual(&s, &id, "k", 1, &mut Pending).unwrap();
    let began = Instant::now();
    assert_eq!(run_job(&s, &id, &run).unwrap(), ExecOutcome::TimedOut);
    assert!(began.elapsed().as_secs() < 8, "SIGTERM to the group ends it, no 60 s wait");
    let r = s.run(&id, &run).unwrap().unwrap();
    assert_eq!(r.reason.as_deref(), Some("timeout"));
}
