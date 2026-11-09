//! `_acpmux/sleep_handoff`: the app's will-sleep notice (Settings > Agents > Keep Chats Running
//! When This Mac Sleeps). The daemon answers at once and runs `acpmux session sleep-handoff`
//! (`cli/run/sleep_handoff.rs`) as its own process, so the moves never hold a request, a lock or
//! the daemon's runtime, and the Mac's sleep does not wait on the answer. One run at a time: a
//! notice while one runs is answered `already`. A run ends by itself, or is ended at
//! `RUN_DEADLINE` (a move that hangs on a machine that went away); a sleep the moves did not
//! finish before goes on after the wake, each move giving its chat back if it fails.

use serde_json::{Value, json};
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The longest one run may take before it is ended.
const RUN_DEADLINE: Duration = Duration::from_secs(15 * 60);

static RUNNING: AtomicBool = AtomicBool::new(false);

/// Starts a run unless one runs: `{"started": true}`, or `{"started": false, "already": true}`.
pub(super) fn start() -> Value {
    if RUNNING.swap(true, Ordering::SeqCst) {
        return json!({"started": false, "already": true});
    }
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(e) => {
            RUNNING.store(false, Ordering::SeqCst);
            return json!({"started": false, "error": format!("this daemon's program: {e}")});
        }
    };
    let child = tokio::process::Command::new(exe)
        .args(["session", "sleep-handoff"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn();
    let child = match child {
        Ok(child) => child,
        Err(e) => {
            RUNNING.store(false, Ordering::SeqCst);
            return json!({"started": false, "error": format!("starting the handoff: {e}")});
        }
    };
    tokio::spawn(async move {
        // Dropped at the deadline: `kill_on_drop` ends the run.
        match tokio::time::timeout(RUN_DEADLINE, child.wait_with_output()).await {
            Ok(Ok(out)) if !out.status.success() || !out.stderr.is_empty() => {
                let said = String::from_utf8_lossy(&out.stderr);
                eprintln!("acpmux: sleep handoff ({}): {}", out.status, said.trim_end());
            }
            Ok(Ok(_)) => {}
            Ok(Err(e)) => eprintln!("acpmux: sleep handoff: {e}"),
            Err(_) => eprintln!("acpmux: sleep handoff ran past {RUN_DEADLINE:?} and was ended"),
        }
        RUNNING.store(false, Ordering::SeqCst);
    });
    json!({"started": true})
}
