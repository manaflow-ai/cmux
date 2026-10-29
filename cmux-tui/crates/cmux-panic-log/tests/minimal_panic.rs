//! The std-only panic hook (feature `minimal`): a thread's panic appends one
//! line to the log, and the previous hook still runs. Its own test binary,
//! so installing the process's panic hook touches no other test.

#![cfg(feature = "minimal")]

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};

use cmux_panic_log::minimal;

const TEST_THREAD: &str = "minimal-panic-test";

static PREVIOUS_RAN: AtomicBool = AtomicBool::new(false);

fn is_test_thread(thread: &str) -> bool {
    thread == TEST_THREAD
}

fn scratch_log() -> PathBuf {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let dir = std::env::temp_dir().join(format!("cmux-mpl-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir.join("holder-panics.jsonl")
}

#[test]
fn a_minimal_panic_hook_writes_one_line_and_runs_the_previous_hook() {
    let log = scratch_log();
    // The holder traces as holder, so its lines name the role and uptime, and
    // the scopes the panic ran in, as the json writer's do.
    cmux_trace::init_blackbox(log.parent().unwrap(), cmux_trace::Role::Holder)
        .expect("the first trace start")
        .wait()
        .ok();
    std::panic::set_hook(Box::new(|_| PREVIOUS_RAN.store(true, Ordering::SeqCst)));
    let fields: minimal::Fields =
        vec![("process", "cmux-holder".into()), ("holder_pid", std::process::id().into())];
    minimal::install(log.clone(), fields, is_test_thread);

    let joined = std::thread::Builder::new()
        .name(TEST_THREAD.into())
        .spawn(|| {
            let _link = cmux_trace::trace_scope!(daemon, "daemon.holder.link");
            let _frame = cmux_trace::trace_scope!(daemon, "daemon.holder.link.frame");
            panic!("minimal \"quoted\" panic\nsecond line")
        })
        .unwrap()
        .join();
    assert!(joined.is_err(), "the thread panicked");
    assert!(PREVIOUS_RAN.load(Ordering::SeqCst), "the previous hook ran after the line");

    let text = std::fs::read_to_string(&log).unwrap();
    assert_eq!(text.lines().count(), 1, "{text}");
    let record: serde_json::Value = serde_json::from_str(text.trim_end()).unwrap();
    assert_eq!(record["message"], "minimal \"quoted\" panic\nsecond line", "{record}");
    assert_eq!(record["thread"], TEST_THREAD, "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert_eq!(record["process"], "cmux-holder", "{record}");
    assert_eq!(record["holder_pid"].as_u64(), Some(u64::from(std::process::id())), "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("minimal_panic.rs:"));
    assert!(record["backtrace"].is_string(), "{record}");
    assert_eq!(record["role"], "holder", "{record}");
    assert!(record["uptime_ms"].is_u64(), "{record}");
    assert_eq!(
        record["scopes"],
        serde_json::json!(["daemon.holder.link.frame", "daemon.holder.link"])
    );
    assert_eq!(record["scope_depth"], 2, "{record}");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&log).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let _ = std::fs::remove_dir_all(log.parent().unwrap());
}
