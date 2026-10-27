//! The script session's reader for the cmux-tui/fuzz `app_host_script_session`
//! target (feature `fuzzing`; no production build turns it on).
//!
//! A script host is untrusted: the VM inside it runs the script. The input is
//! what such a host writes on its channel; [`one_input`] runs the session's
//! own reader ([`Shared::read_host`]) over it, with the real call, subscribe,
//! log and fatal handling, then ends the session the way the reader thread
//! does when the host goes away.

use std::io::Read;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Once, mpsc};

use serde_json::{Value, json};

use super::{LogSink, MAX_INFLIGHT, ScriptRouter, Shared, lock};

/// A router that answers at once and records how many calls ran together.
#[derive(Default)]
struct Router {
    running: AtomicUsize,
    most: AtomicUsize,
    watches: AtomicUsize,
}

impl ScriptRouter for Router {
    fn call(&self, op: &str, params: Value, _options: Value) -> Result<Value, Value> {
        let now = self.running.fetch_add(1, Ordering::AcqRel) + 1;
        self.most.fetch_max(now, Ordering::AcqRel);
        let answer = if op.len().is_multiple_of(2) {
            Ok(json!({ "value": params }))
        } else {
            Err(json!({ "code": "op.failed", "message": op, "retryable": false }))
        };
        self.running.fetch_sub(1, Ordering::AcqRel);
        answer
    }

    fn watch(&self, publish: Arc<dyn Fn(&str) + Send + Sync>) -> Box<dyn Send> {
        self.watches.fetch_add(1, Ordering::AcqRel);
        publish("resource.changed");
        Box::new(())
    }
}

/// Runs the session's reader over `data`, as the host's channel, then ends
/// the session. Panics when the session breaks one of its own bounds.
pub fn one_input(data: &[u8]) {
    // The daemon that links this is a Rust program, which ignores SIGPIPE; a
    // libFuzzer binary does not, and a call answered after the session ended
    // writes to a closed channel.
    static IGNORE_SIGPIPE: Once = Once::new();
    // SAFETY: setting a signal disposition to SIG_IGN has no handler to race.
    IGNORE_SIGPIPE.call_once(|| unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_IGN);
    });

    // A machine out of descriptors or threads runs no input: not a finding.
    let Ok((ours, theirs)) = UnixStream::pair() else { return };
    // The host's side reads what the session sends until the session ends.
    let drain =
        cmux_threads::spawn("cmux-script-fuzz-drain", super::SCRIPT_THREAD_QOS, move || {
            let mut theirs = theirs;
            let mut sink = [0u8; 4096];
            while matches!(theirs.read(&mut sink), Ok(n) if n > 0) {}
        });
    let Ok(drain) = drain else { return };
    let router = Arc::new(Router::default());
    let log: LogSink = Arc::new(|_, _| {});
    let Ok(shared) = Shared::new(ours, router.clone(), log) else { return };
    let (ready_tx, ready_rx) = mpsc::channel();
    let mut ready = Some(ready_tx);
    shared.read_host(data, &mut ready);
    assert!(lock(&shared.subs).len() <= super::MAX_SUBSCRIPTIONS, "subscriptions past the cap");
    assert!(router.watches.load(Ordering::Acquire) <= 1, "the router was watched twice");
    shared.kill();
    shared.mark_dead();
    drop(ready);
    // Every call thread holds the session until it has answered.
    while Arc::strong_count(&shared) > 1 {
        std::thread::yield_now();
    }
    assert!(drain.join().is_ok(), "the drain thread panicked");
    assert!(ready_rx.try_iter().count() <= 1, "the session was told it started twice");
    assert_eq!(shared.inflight.load(Ordering::Acquire), 0, "calls still counted in flight");
    assert!(router.most.load(Ordering::Acquire) <= MAX_INFLIGHT, "more calls at once than the cap");
    assert!(lock(&shared.waiters).is_empty(), "waiters left after the host died");
    assert!(lock(&shared.subs).is_empty(), "subscriptions left after the host died");
    assert!(lock(&shared.watch).is_none(), "the router watch outlived the host");
}
