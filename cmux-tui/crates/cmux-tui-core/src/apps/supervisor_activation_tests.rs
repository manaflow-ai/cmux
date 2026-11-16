//! Supervisor tests of manifest `activation` (`activation.rs`): an app with
//! `onStartup` or `onEvent:<stream>` runs its host with no view open, hears
//! the events its top-level code subscribed to, and is not stopped by the
//! idle timer. Disabling, uninstalling and revoking stop it; the crash
//! backoff and its limit still apply.

use super::super::supervisor::{HostKey, HostState, MAX_CRASHES};
use super::*;

const IDLE: Duration = Duration::from_millis(200);

/// Writes a scripted app whose top-level code is `main` (the scripted host
/// reads `SUBSCRIBE_AT_INIT <stream>` and `EXIT_AFTER_READY` from it).
fn write_background_app(root: &Path, dir: &str, id: &str, activation: Value, main: &str) {
    write_app(root, dir, id, json!({ "workspace:read": "Hear when a workspace changes." }));
    let app = root.join(dir);
    let path = app.join("cmux-app.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
    if !activation.is_null() {
        manifest["activation"] = activation;
    }
    std::fs::write(&path, manifest.to_string()).unwrap();
    std::fs::write(app.join("dist/main.js"), main).unwrap();
}

const LISTENS: &str = "// SUBSCRIBE_AT_INIT workspace.changed\nvar __cmuxAppExports = {};";

/// A fixture with a short idle stop and these background apps:
/// `cmux/startup` (`onStartup`), `cmux/onevent` (`onEvent:workspace.changed`),
/// `cmux/crashy` (`onStartup`, exits after `ready`) and `local/startup`
/// (`onStartup`). `cmux/demo` has no `activation`.
fn background_root() -> TempDir {
    let root = temp_dir();
    let bundled = root.0.join("bundled");
    let local = root.0.join("state/apps/local");
    write_background_app(&bundled, "startup", "cmux/startup", json!(["onStartup"]), LISTENS);
    write_background_app(
        &bundled,
        "onevent",
        "cmux/onevent",
        json!(["onEvent:workspace.changed"]),
        LISTENS,
    );
    write_background_app(
        &bundled,
        "crashy",
        "cmux/crashy",
        json!(["onStartup"]),
        "// EXIT_AFTER_READY\nvar __cmuxAppExports = {};",
    );
    write_background_app(&local, "startup", "local/startup", json!(["onStartup"]), LISTENS);
    root
}

fn key(app: &str) -> HostKey {
    HostKey { app: app.into(), preview: false }
}

fn host_state(f: &Fixture, app: &str) -> Option<HostState> {
    f.supervisor.inner.lock().unwrap().hosts.get(&key(app)).map(|host| host.state)
}

fn wait_host(f: &Fixture, app: &str, state: &str) -> Value {
    f.wait(&format!("{app} {state}"), |e| {
        e["event"] == "apps-host" && e["app"] == app && e["state"] == state
    })
}

fn log_lines(f: &Fixture, app: &str, message: &str) -> usize {
    f.supervisor.logs(CLIENT, app, false)["lines"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|line| line["message"] == message)
        .count()
}

/// Waits until `app`'s log ring holds `count` lines `message`. The ring is
/// read again on every client event and at least every 50 ms: a host that
/// started inside `Supervisor::new` logs before any client follows it.
fn wait_lines(f: &Fixture, app: &str, message: &str, count: usize) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let seen = log_lines(f, app, message);
        if seen >= count {
            assert_eq!(seen, count, "{app} logged {message:?} {seen} times");
            return;
        }
        assert!(Instant::now() < deadline, "{app} logged {message:?} {seen} of {count} times");
        let _ = f.events.recv_timeout(Duration::from_millis(50));
    }
}

/// The host's own log line after its top-level subscribe: the supervisor
/// handles a host's lines in order, so the subscription is in.
fn wait_subscribed(f: &Fixture, app: &str) {
    wait_lines(f, app, "subscribed", 1);
}

/// Publishes `workspace.changed` `n` times; `app` has then heard `total`.
fn publish_and_count(f: &Fixture, app: &str, n: usize, total: usize) {
    for _ in 0..n {
        f.supervisor.publish("workspace.changed", json!({}));
    }
    wait_lines(f, app, "event 1", total);
}

/// No `apps-host stopped` for `app` among the events received so far.
fn assert_not_stopped(f: &Fixture, app: &str) {
    while let Ok(event) = f.events.try_recv() {
        assert!(
            !(event["event"] == "apps-host" && event["app"] == app && event["state"] == "stopped"),
            "{app} stopped: {event}"
        );
    }
}

fn counts_events_with_no_view(app: &str) {
    let f = fixture_with(&[], IDLE, background_root());
    f.supervisor.logs(CLIENT, app, true);
    f.install(app);
    wait_host(&f, app, "running");
    wait_subscribed(&f, app);
    assert!(f.supervisor.inner.lock().unwrap().mounts.is_empty(), "no view is mounted");
    publish_and_count(&f, app, 10, 10);
    // Well past the idle stop: still running, still hearing events.
    std::thread::sleep(IDLE * 4);
    assert_not_stopped(&f, app);
    assert_eq!(host_state(&f, app), Some(HostState::Running));
    publish_and_count(&f, app, 1, 11);
}

#[test]
fn an_on_startup_app_counts_workspace_events_with_no_view() {
    counts_events_with_no_view("cmux/startup");
}

#[test]
fn an_on_event_app_counts_workspace_events_with_no_view() {
    counts_events_with_no_view("cmux/onevent");
}

#[test]
fn installed_on_startup_apps_start_with_the_daemon_and_disabled_ones_do_not() {
    let f = fixture_with(&[], IDLE, background_root());
    f.install("cmux/startup");
    f.install("local/startup");
    wait_host(&f, "local/startup", "running");
    f.set("off", "local/startup", Origin::User, |o| o.enabled = Some(false)).unwrap();
    wait_host(&f, "local/startup", "stopped");
    // The next daemon over the same state.
    let Fixture { supervisor, _root, .. } = f;
    drop(supervisor);
    let f = fixture_with(&[], IDLE, _root);
    f.supervisor.logs(CLIENT, "cmux/startup", true);
    wait_subscribed(&f, "cmux/startup");
    publish_and_count(&f, "cmux/startup", 3, 3);
    assert_eq!(host_state(&f, "local/startup"), None, "a disabled app is not started");
}

#[test]
fn an_app_without_activation_still_idles_out() {
    let f = fixture_with(&[], IDLE, background_root());
    f.install("cmux/demo");
    assert_eq!(host_state(&f, "cmux/demo"), None, "installing starts no host");
    let (tx, rx) = channel();
    f.supervisor.run(
        run_request("cmux/demo", "demo.go", None, Origin::User, None),
        Box::new(move |result| drop(tx.send(result))),
    );
    rx.recv_timeout(Duration::from_secs(10)).unwrap().unwrap();
    wait_host(&f, "cmux/demo", "stopped");
    assert_eq!(host_state(&f, "cmux/demo"), None);
}

#[test]
fn disabling_uninstalling_and_revoking_stop_a_background_app() {
    let f = fixture_with(&[], IDLE, background_root());
    // Disable, then enable again: it comes back with no view.
    f.install("cmux/startup");
    wait_host(&f, "cmux/startup", "running");
    f.set("off", "cmux/startup", Origin::User, |o| o.enabled = Some(false)).unwrap();
    wait_host(&f, "cmux/startup", "stopped");
    assert_eq!(host_state(&f, "cmux/startup"), None);
    f.set("on", "cmux/startup", Origin::User, |o| o.enabled = Some(true)).unwrap();
    wait_host(&f, "cmux/startup", "running");
    // Uninstall.
    f.install("local/startup");
    wait_host(&f, "local/startup", "running");
    f.set("rm", "local/startup", Origin::User, |o| o.installed = Some(false)).unwrap();
    wait_host(&f, "local/startup", "stopped");
    // Revoking the read its `onEvent` stream needs.
    f.install("cmux/onevent");
    wait_host(&f, "cmux/onevent", "running");
    f.set("revoke", "cmux/onevent", Origin::User, |o| {
        o.grant = Some(("workspace:read".into(), false));
    })
    .unwrap();
    wait_host(&f, "cmux/onevent", "stopped");
    // Another commit runs activation again; none of them comes back.
    f.install("cmux/demo");
    assert_eq!(host_state(&f, "local/startup"), None);
    assert_eq!(host_state(&f, "cmux/onevent"), None);
}

#[test]
fn a_crash_looping_background_app_is_stopped_after_its_backoff() {
    let f = fixture_with(&[], IDLE, background_root());
    f.install("cmux/crashy");
    wait_host(&f, "cmux/crashy", "crashed");
    // It waits for its backoff and restarts: no view holds it, activation does.
    let state = host_state(&f, "cmux/crashy");
    assert!(matches!(state, Some(HostState::Waiting | HostState::Starting)), "{state:?}");
    f.supervisor.inner.lock().unwrap().hosts.get_mut(&key("cmux/crashy")).unwrap().crashes =
        MAX_CRASHES;
    f.wait("the crash limit", |e| {
        e["event"] == "apps-host"
            && e["app"] == "cmux/crashy"
            && e["reason"] == "the app crashed repeatedly"
    });
    // Another commit does not start it again.
    f.install("cmux/demo");
    assert_eq!(host_state(&f, "cmux/crashy"), None);
}
