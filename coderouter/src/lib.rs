mod cli;
mod config;
mod control_plane;
mod handoff;
mod loading;
mod oauth;
mod process;
mod status;
mod telemetry;
mod tui;

use std::ffi::OsString;
use std::sync::{Mutex, OnceLock};

static RUN_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn run_lock() -> &'static Mutex<()> {
    RUN_LOCK.get_or_init(|| Mutex::new(()))
}

pub fn run(args: impl IntoIterator<Item = OsString>) -> i32 {
    // Handoff activation is stored in process-global state because the public
    // entry point is also used by both binaries. Serialize complete
    // invocations so one caller cannot clear or consume another caller's
    // hidden request while it is being routed.
    let _run_guard = run_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let _handoff_state_reset = handoff::HiddenStateReset::new();
    let mut args: Vec<OsString> = args.into_iter().collect();
    let remaining = args.get(1..).unwrap_or_default();
    match handoff::rewrite_hidden_args(remaining) {
        Ok(Some(rewritten)) => {
            let program = args
                .first()
                .cloned()
                .unwrap_or_else(|| OsString::from("coderouter"));
            args.clear();
            args.push(program);
            args.extend(rewritten);
        }
        Ok(None) => {}
        Err(error) => {
            eprintln!("coderouter: {error}");
            return 1;
        }
    }
    let telemetry = telemetry::CommandTelemetry::start(&args);
    let result = cli::run(args);
    let exit_code = match &result {
        Ok(code) => *code,
        Err(error) => {
            eprintln!("coderouter: {error}");
            1
        }
    };
    telemetry.finish(&result, exit_code);
    exit_code
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;

    #[test]
    fn public_runs_are_serialized_and_reset_hidden_state() {
        handoff::clear_hidden_state();
        let guard = run_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (started_tx, started_rx) = mpsc::channel();
        let (done_tx, done_rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            started_tx.send(()).unwrap();
            done_tx
                .send(run([OsString::from("cr"), OsString::from("--help")]))
                .unwrap();
        });
        started_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        assert!(done_rx.recv_timeout(Duration::from_millis(50)).is_err());
        drop(guard);
        assert_eq!(done_rx.recv_timeout(Duration::from_secs(2)).unwrap(), 0);
        worker.join().unwrap();

        let binding = handoff::team_binding("team-handoff");
        let hidden_args = [
            OsString::from("__cmux-handoff-v2"),
            OsString::from("/tmp/coderouter-run-state.sock"),
            OsString::from(binding),
            OsString::from("--"),
            OsString::from("codex"),
        ];
        handoff::rewrite_hidden_args(&hidden_args).unwrap();
        assert!(handoff::requested());
        assert_eq!(
            run([
                OsString::from("cr"),
                OsString::from("capabilities"),
                OsString::from("--json"),
            ]),
            0
        );
        assert!(!handoff::requested());
    }
}
