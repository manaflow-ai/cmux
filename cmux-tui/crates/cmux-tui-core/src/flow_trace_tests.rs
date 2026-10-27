//! Test support for key-press flow records (p09-observability-102): a test that records flows runs
//! in a child process of the test binary, since a process has one recording and the tests beside it
//! must not write into it (as `server/request_spans_tests.rs` runs its child).

use std::path::PathBuf;

use cmux_trace::{Phase, decode};

/// Runs test `name` (its path from the crate root) again in a child of this test binary with
/// `CMUX_TRACE_FLOWS` naming a scratch directory, and asserts the child passed: returns false, so the
/// parent's test body stops. In that child it starts the flows and returns true: the body runs there.
pub(crate) fn in_recording_child(name: &str) -> bool {
    if std::env::var_os("CMUX_TRACE_FLOWS").is_some() {
        assert!(cmux_flow_trace::init(), "key-press flows did not start in the child");
        return true;
    }
    let dir = scratch_dir(name);
    let status = std::process::Command::new(std::env::current_exe().expect("the test binary"))
        .args(["--exact", name, "--nocapture", "--test-threads=1"])
        .env("CMUX_TRACE_FLOWS", &dir)
        .status()
        .expect("the child runs");
    let _ = std::fs::remove_dir_all(&dir);
    assert!(status.success(), "the recording child of {name} failed (see its output above)");
    false
}

fn scratch_dir(name: &str) -> PathBuf {
    let leaf = name.rsplit("::").next().unwrap_or(name);
    let dir = std::env::temp_dir().join(format!("cmux-flow-{leaf}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("a scratch dir");
    dir
}

/// The flow steps of key press `flow` this process recorded, in time order: each record's name
/// with `>` for a flow out (`s`, queued) and `<` for a flow in (`f`, taken), as `key.echo.line_out>`.
pub(crate) fn flow_steps(flow: u64) -> Vec<String> {
    let status = cmux_trace::status().expect("the flows started tracing");
    let path = status.recording_path.expect("the recording is a file");
    let decoded = decode(&std::fs::read(path).expect("the recording reads")).expect("it decodes");
    let mut steps: Vec<_> = decoded
        .records
        .iter()
        .filter(|record| record.arg1 == flow)
        .filter_map(|record| {
            let mark = match record.phase {
                phase if phase == Phase::FlowOut as u8 => '>',
                phase if phase == Phase::FlowIn as u8 => '<',
                _ => return None,
            };
            let name = decoded.name(record.name)?;
            Some((record.t_ns, format!("{name}{mark}")))
        })
        .collect();
    steps.sort_by_key(|(at, _)| *at);
    steps.into_iter().map(|(_, step)| step).collect()
}

/// [`flow_steps`] of the `key.echo.*` handoffs only.
pub(crate) fn handoff_steps(flow: u64) -> Vec<String> {
    flow_steps(flow).into_iter().filter(|step| step.starts_with("key.echo.")).collect()
}
