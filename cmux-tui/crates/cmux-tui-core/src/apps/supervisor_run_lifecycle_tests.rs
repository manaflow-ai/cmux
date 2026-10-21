//! App runs across host exit, restart and grant changes.

use super::super::host::HostProcess;
use super::super::supervisor::{HostKey, HostState};
use super::*;

/// Keep the old process alive while delivering its exit deterministically. The real
/// app journey reaches this state after a grant change; neither a sleep nor a race
/// with the scripted child determines which generation receives the next request.
fn replacement_pending(f: &Fixture) -> (HostKey, u64, Arc<HostProcess>) {
    f.install("cmux/demo");
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::Script, None),
        Box::new(move |reply| tx.send(reply).unwrap()),
    );
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(), json!({"value":"go"}));
    let key = HostKey { app: "cmux/demo".into(), preview: false };
    let mut inner = f.supervisor.inner.lock().unwrap();
    let host = inner.hosts.get_mut(&key).unwrap();
    host.state = HostState::Restarting;
    let process = host.process.take().unwrap();
    (key, host.generation, process)
}

#[test]
fn cmux_next_app_run_replacement_preserves_a_new_queued_request() {
    let f = fixture();
    let (key, generation, old) = replacement_pending(&f);
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::Script, None),
        Box::new(move |reply| tx.send(reply).unwrap()),
    );
    f.supervisor.on_host_exit(
        &key,
        generation,
        super::super::host::Exit { code: Some(0), signal: None },
    );
    old.shutdown();
    let reply = rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(reply.is_ok(), "a run queued for the replacement belongs to its new host: {reply:?}");
    assert_eq!(reply.unwrap(), json!({"value":"go"}));
}

#[test]
fn cmux_next_app_run_replacement_does_not_accept_an_old_hosts_queued_callback() {
    let f = fixture();
    let (key, generation, old) = replacement_pending(&f);
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::Script, None),
        Box::new(move |reply| tx.send(reply).unwrap()),
    );
    // The first run used callback 1; callback 2 has not been sent to this process.
    f.supervisor.on_host_message(
        &key,
        generation,
        FromHost::Done { cb: 2, ok: true, body: json!({"value":"old generation"}) },
    );
    let premature = rx.try_recv();
    f.supervisor.on_host_exit(
        &key,
        generation,
        super::super::host::Exit { code: Some(0), signal: None },
    );
    old.shutdown();
    assert!(
        matches!(premature, Err(std::sync::mpsc::TryRecvError::Empty)),
        "an old host answered an unsent run: {premature:?}"
    );
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(), json!({"value":"go"}));
}

#[test]
fn cmux_next_app_run_replacement_disable_refuses_queued_work() {
    let f = fixture();
    let (_, _, old) = replacement_pending(&f);
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::Script, None),
        Box::new(move |reply| tx.send(reply).unwrap()),
    );
    f.set("disable", "cmux/demo", Origin::User, |op| op.enabled = Some(false)).unwrap();
    old.shutdown();
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code,
        "apps.disabled"
    );
}

#[test]
fn runs_answer_through_the_responder_and_a_crash_restarts_with_reset() {
    let f = fixture();
    f.install("cmux/demo");
    let (tx, rx) = channel();
    let tx2 = tx.clone();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::User, None),
        Box::new(move |r| tx.send(r).unwrap()),
    );
    assert_eq!(
        rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap(),
        json!({ "value": "go" })
    );
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    f.supervisor.run(
        run_request("cmux/demo", "demo.crash", None, Origin::User, None),
        Box::new(move |r| tx2.send(r).unwrap()),
    );
    assert_eq!(rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap_err().code, "apps.host");
    f.wait("crash", |e| e["event"] == "apps-host" && e["state"] == "crashed");
    let rerender = f.wait("re-render", |e| e["event"] == "apps-scene" && e["mount_id"] == "m1");
    assert_eq!(rerender["reset"], true, "the first batch after a restart starts a fresh tree");
    assert_eq!(f.supervisor.list()["apps"].as_array().unwrap().len(), 2);
}

#[test]
fn idle_hosts_stop_after_the_last_mount_and_disconnect_unmounts() {
    let f = fixture_with(&[], Duration::from_millis(50), temp_dir());
    f.install("cmux/demo");
    f.mount("m1", "cmux/demo", "cmux.section/1", json!({}));
    // A second connection observes the stop after the first one goes away.
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    f.supervisor
        .register_client(8, Arc::new(move |v: &Value| tx.lock().unwrap().send(v.clone()).is_ok()));
    f.supervisor.disconnect(CLIENT);
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let event =
            rx.recv_timeout(deadline.saturating_duration_since(Instant::now())).expect("idle stop");
        if event["event"] == "apps-host" && event["state"] == "stopped" {
            break;
        }
    }
}
