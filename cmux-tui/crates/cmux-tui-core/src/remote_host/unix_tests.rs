use super::{
    Connection, HostRecord, Inner, QUIT_REASON, State, screen_device_id_from_status,
    validated_screen_device_id,
};
use serde_json::{Value, json};
use std::sync::Arc;
use std::sync::{Condvar, Mutex};
use std::time::Instant;

fn connection(status: Value) -> Arc<Connection> {
    let (writer, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
    Arc::new(Connection {
        pid: 7,
        record: HostRecord {
            pid: 7,
            start_sec: 1,
            start_usec: 2,
            secret: "secret".into(),
            bundle_digest: "digest".into(),
            socket: "/tmp/cmux-remote-test.sock".into(),
        },
        adopted: false,
        started: Instant::now(),
        writer: Mutex::new(writer),
        pending: Mutex::new(std::collections::HashMap::new()),
        next_id: std::sync::atomic::AtomicU64::new(1),
        status: Mutex::new(status),
        closed: (Mutex::new(false), Condvar::new()),
        quit: std::sync::atomic::AtomicBool::new(false),
    })
}

#[test]
fn app_permissions_show_in_status_and_never_reach_config_or_the_switches() {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let root =
        std::env::temp_dir().join(format!("cmux-rh-app-perms-{}-{nanos}", std::process::id()));
    let paths = super::Paths {
        runtime: root.join("run"),
        state: root.join("state"),
        scope: "stest".into(),
        daemon_socket: root.join("d.sock"),
    };
    let supervisor = super::RemoteHostSupervisor::default();
    *super::lock(&supervisor.inner.paths) = Some(paths.clone());
    assert!(supervisor.status().get("app").is_none(), "nothing reported yet");

    let status = supervisor.set_app_permissions(crate::remote_host::AppPermissions {
        screen_recording: Some(true),
        accessibility: Some(false),
    });
    assert_eq!(
        status["app"],
        json!({"permissions": {"screen_recording": true, "accessibility": false}})
    );
    // No switch moved, no host started, nothing saved.
    assert_eq!(status["state"], "off");
    assert_eq!(
        status["config"],
        json!({"computer_use": false, "screen_sharing": false, "headless": true})
    );
    assert!(!paths.config().exists(), "app permissions are memory only");

    // A switch change saves the switches only and keeps the app's grants in status.
    let status = supervisor.set_config(&json!({"headless": false})).unwrap();
    assert_eq!(status["app"]["permissions"]["screen_recording"], true);
    let saved: Value = serde_json::from_slice(&std::fs::read(paths.config()).unwrap()).unwrap();
    assert_eq!(saved, json!({"computer_use": false, "screen_sharing": false, "headless": false}));
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn nothing_turned_on_says_computer_use_is_off_never_cmux_remote() {
    // A Mac without cmux Remote (NIGHTLY) showed "cmux Remote is off: turn on Computer Use
    // (Upstream driver) ...": a product it does not carry, and a driver setting that is gone.
    let supervisor = super::RemoteHostSupervisor::default();
    let reason = supervisor.call("computer_use.endpoint", json!({})).unwrap_err();
    assert_eq!(reason, "Computer Use is off. Turn it on in Settings > Computer Use.");
    // computer_use_command.rs reads "is off" as the off state.
    assert!(reason.contains("is off"));
    assert!(!reason.contains("cmux Remote") && !reason.contains("Upstream"));
}

#[test]
fn screen_identity_rejects_missing_malformed_and_wrong_shape_values() {
    for status in [
        json!({}),
        json!({"host":{"screen":{"device_id":"not-a-uuid"}}}),
        json!({"host":{"screen":{"device_id":42}}}),
    ] {
        assert_eq!(screen_device_id_from_status(&status), None);
    }
    assert_eq!(validated_screen_device_id("not-a-uuid"), None);
}

#[test]
fn screen_identity_reads_only_the_authenticated_status_path() {
    let status = json!({
        "device_id": "550e8400-e29b-41d4-a716-446655440000",
        "screen": {"device_id": "550e8400-e29b-41d4-a716-446655440000"}
    });
    let expected = Some("550e8400-e29b-41d4-a716-446655440000".to_string());
    assert_eq!(screen_device_id_from_status(&status), expected);
}

#[test]
fn screen_identity_normalizes_a_valid_uuid() {
    assert_eq!(
        validated_screen_device_id("550E8400-E29B-41D4-A716-446655440000"),
        Some("550e8400-e29b-41d4-a716-446655440000".to_string())
    );
}

#[test]
fn screen_identity_cache_dedupes_rotation_and_removal() {
    let inner = Arc::new(Inner::default());
    let first = "550e8400-e29b-41d4-a716-446655440000".to_string();
    let second = "6ba7b810-9dad-11d1-80b4-00c04fd430c8".to_string();
    assert!(Inner::set_screen_device_id(&inner, Some(first.clone())));
    assert!(!Inner::set_screen_device_id(&inner, Some(first)));
    assert!(Inner::set_screen_device_id(&inner, Some(second)));
    assert!(Inner::set_screen_device_id(&inner, None));
    assert!(!Inner::set_screen_device_id(&inner, None));
}

#[test]
fn screen_identity_ready_status_is_seeded_when_connection_becomes_running() {
    let inner = Arc::new(Inner::default());
    let id = "550e8400-e29b-41d4-a716-446655440000";
    let installed =
        Inner::install_running(&inner, connection(json!({"screen": {"device_id": id}}))).unwrap();

    assert_eq!(super::lock(&inner.screen_device_id).clone(), Some(id.to_string()));
    assert!(matches!(
        &*super::lock(&inner.state),
        State::Running(current) if Arc::ptr_eq(current, &installed)
    ));
}

#[test]
fn screen_identity_ready_update_while_idle_is_ignored_until_install() {
    let inner = Arc::new(Inner::default());
    let id = "550e8400-e29b-41d4-a716-446655440000";
    let connection = connection(json!({"screen": {"device_id": id}}));

    Inner::update_screen_device_id(
        &Arc::downgrade(&inner),
        &connection,
        &json!({"screen": {"device_id": id}}),
    );
    assert_eq!(super::lock(&inner.screen_device_id).clone(), None);
    Inner::install_running(&inner, connection).unwrap();
    assert_eq!(super::lock(&inner.screen_device_id).clone(), Some(id.to_string()));
}

#[test]
fn screen_identity_closed_connection_is_rejected_before_install() {
    let inner = Arc::new(Inner::default());
    let connection = connection(json!({
        "screen": {"device_id": "550e8400-e29b-41d4-a716-446655440000"}
    }));
    *super::lock(&connection.closed.0) = true;

    let error = Inner::install_running(&inner, connection)
        .err()
        .expect("closed connection must be rejected");
    assert_eq!(error, "cmux Remote closed before becoming current");
    assert!(matches!(&*super::lock(&inner.state), State::Idle));
    assert_eq!(super::lock(&inner.screen_device_id).clone(), None);
}

#[test]
fn stopping_a_running_host_clears_screen_identity_before_reader_exit() {
    let inner = Arc::new(Inner::default());
    let id = "550e8400-e29b-41d4-a716-446655440000";
    Inner::install_running(
        &inner,
        connection(json!({
            "screen": {"device_id": id}
        })),
    )
    .unwrap();

    Inner::stop(&inner);

    assert!(matches!(&*super::lock(&inner.state), State::Idle));
    assert_eq!(super::lock(&inner.screen_device_id).clone(), None);
}

#[test]
fn screen_identity_stale_reader_cannot_restore_identity_after_clear_and_replacement() {
    let inner = Arc::new(Inner::default());
    let first_id = "550e8400-e29b-41d4-a716-446655440000";
    let second_id = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
    let first = connection(json!({"screen": {"device_id": first_id}}));
    let second = connection(json!({"screen": {"device_id": second_id}}));

    Inner::install_running(&inner, Arc::clone(&first)).unwrap();
    Inner::host_gone(&inner, &first);
    assert_eq!(super::lock(&inner.screen_device_id).clone(), None);
    Inner::install_running(&inner, Arc::clone(&second)).unwrap();

    Inner::host_gone(&inner, &first);
    assert_eq!(super::lock(&inner.screen_device_id).clone(), Some(second_id.to_string()));

    Inner::update_screen_device_id(
        &Arc::downgrade(&inner),
        &first,
        &json!({"screen": {"device_id": first_id}}),
    );
    assert_eq!(super::lock(&inner.screen_device_id).clone(), Some(second_id.to_string()));
    assert!(matches!(
        &*super::lock(&inner.state),
        State::Running(current) if Arc::ptr_eq(current, &second)
    ));
}

/// The daemon's reader for a host that writes `lines` and then exits.
fn read_until_exit(inner: &Arc<Inner>, running: &Arc<Connection>, lines: &str) {
    use std::io::Write;
    let (reader, mut host) = std::os::unix::net::UnixStream::pair().unwrap();
    host.write_all(lines.as_bytes()).unwrap();
    drop(host);
    Inner::read(&Arc::downgrade(inner), running, std::io::BufReader::new(reader));
}

#[test]
fn a_host_the_person_quit_is_not_started_again() {
    let inner = Arc::new(Inner::default());
    super::lock(&inner.config).computer_use = true;
    let running = Inner::install_running(&inner, connection(json!({}))).unwrap();

    read_until_exit(&inner, &running, "{\"type\":\"event\",\"event\":\"quit\"}\n");

    assert!(matches!(&*super::lock(&inner.state), State::Idle));
    assert_eq!(super::lock(&inner.unavailable).as_deref(), Some(QUIT_REASON));
    assert!(super::lock(&inner.backoff).is_none(), "a quit host must not schedule a restart");
}

#[test]
fn a_host_that_exits_without_quit_is_started_again() {
    let inner = Arc::new(Inner::default());
    super::lock(&inner.config).computer_use = true;
    let running = Inner::install_running(&inner, connection(json!({}))).unwrap();

    read_until_exit(&inner, &running, "{\"type\":\"event\",\"event\":\"status\",\"status\":{}}\n");

    assert!(matches!(&*super::lock(&inner.state), State::Idle));
    assert_eq!(super::lock(&inner.unavailable).as_deref(), None);
    assert!(super::lock(&inner.backoff).is_some(), "a crashed host restarts after the backoff");
}

/// F17 fault: the person quits cmux Remote, the host exits, and nothing starts it again
/// within a bound (not the restart after its exit, not the next daemon start); then the
/// person's explicit start (`cmux remote-host restart`) runs a start again. Off macOS a
/// start ends in `adopt_or_start`'s "runs on macOS only", which is how a start shows here.
#[cfg(not(target_os = "macos"))]
#[test]
fn fault_a_quit_host_never_respawns_until_an_explicit_start() {
    use std::io::Write;
    use std::time::Duration;
    let dir = std::env::temp_dir().join(format!("cmux-remote-quit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let paths = super::Paths {
        runtime: dir.join("run"),
        state: dir.join("state"),
        scope: "s0".into(),
        daemon_socket: dir.join("d.sock"),
    };
    let intent_file = paths.state.join("stop-intent.json");
    let started = |inner: &Arc<Inner>| {
        super::lock(&inner.unavailable).as_deref().is_some_and(|r| r.contains("macOS only"))
    };
    let inner = Arc::new(Inner::default());
    *super::lock(&inner.paths) = Some(paths.clone());
    super::lock(&inner.config).computer_use = true;
    let running = Inner::install_running(&inner, connection(json!({}))).unwrap();

    // The host announces the quit, then its process exits: EOF on its supervisor link.
    let (reader, mut host) = std::os::unix::net::UnixStream::pair().unwrap();
    host.write_all(b"{\"type\":\"event\",\"event\":\"quit\"}\n").unwrap();
    drop(host);
    Inner::read(&Arc::downgrade(&inner), &running, std::io::BufReader::new(reader));
    assert!(matches!(&*super::lock(&inner.state), State::Idle));

    // The bound: ten times the first restart delay (200 ms). A respawn is a start attempt.
    std::thread::sleep(Duration::from_secs(2));
    assert!(!started(&inner), "a host the person quit was started again within 2 s");
    assert!(intent_file.exists(), "the quit is written down as a stop intent");

    // The next daemon start reads the same intent and starts nothing.
    let next_daemon = Arc::new(Inner::default());
    *super::lock(&next_daemon.paths) = Some(paths);
    super::lock(&next_daemon.config).computer_use = true;
    let _ = Inner::ensure(&next_daemon);
    assert!(!started(&next_daemon), "the next daemon start brought the quit host back");

    // The person's explicit start clears the intent and starts again.
    let supervisor = super::RemoteHostSupervisor { inner: Arc::clone(&inner) };
    let _ = supervisor.call("restart", json!({"worker": "computer-use", "force": false}));
    assert!(started(&inner), "an explicit start must run a start again");
    assert!(!intent_file.exists(), "an explicit start clears the stop intent");
    let _ = std::fs::remove_dir_all(&dir);
}

/// F17 fault: the person runs `cmux remote-host restart` while the host they quit is still
/// ending its workers. The restart waits for that host to exit and then starts a new one,
/// instead of answering from the host that is leaving and leaving cmux Remote stopped.
#[cfg(not(target_os = "macos"))]
#[test]
fn fault_a_restart_while_the_quit_host_drains_starts_it_again() {
    use std::io::Write;
    use std::time::{Duration, Instant};
    let dir = std::env::temp_dir().join(format!("cmux-remote-drain-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let paths = super::Paths {
        runtime: dir.join("run"),
        state: dir.join("state"),
        scope: "s0".into(),
        daemon_socket: dir.join("d.sock"),
    };
    let started = |inner: &Arc<Inner>| {
        super::lock(&inner.unavailable).as_deref().is_some_and(|r| r.contains("macOS only"))
    };
    let inner = Arc::new(Inner::default());
    *super::lock(&inner.paths) = Some(paths.clone());
    super::lock(&inner.config).computer_use = true;
    let running = Inner::install_running(&inner, connection(json!({}))).unwrap();

    // The host announces the quit and keeps its link open while it ends its workers.
    let (reader, mut host) = std::os::unix::net::UnixStream::pair().unwrap();
    host.write_all(b"{\"type\":\"event\",\"event\":\"quit\"}\n").unwrap();
    let weak = Arc::downgrade(&inner);
    let link = Arc::clone(&running);
    let reading = std::thread::spawn(move || {
        Inner::read(&weak, &link, std::io::BufReader::new(reader));
    });
    let deadline = Instant::now() + Duration::from_secs(5);
    while !running.quit.load(std::sync::atomic::Ordering::Relaxed) {
        assert!(Instant::now() < deadline, "the quit event was never read");
        std::thread::sleep(Duration::from_millis(5));
    }
    // It exits 300 ms into the restart.
    let exiting = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(300));
        drop(host);
    });

    let supervisor = super::RemoteHostSupervisor { inner: Arc::clone(&inner) };
    let _ = supervisor.call("restart", json!({"worker": "computer-use", "force": false}));
    exiting.join().unwrap();
    reading.join().unwrap();

    assert!(started(&inner), "a restart during the quit's drain never started a new host");
    assert!(!paths.state.join("stop-intent.json").exists(), "the restart clears the stop intent");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn saved_switches_read_back_and_a_bad_file_reads_as_the_defaults() {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_nanos());
    let root =
        std::env::temp_dir().join(format!("cmux-rh-read-config-{}-{nanos}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("config.json");
    assert_eq!(super::read_config(&path), super::RemoteConfig::default(), "no file");
    std::fs::write(&path, br#"{"computer_use": true}"#).unwrap();
    let on = super::read_config(&path);
    assert!(on.computer_use && !on.screen_sharing && on.headless, "{on:?}");
    std::fs::write(&path, b"{not json").unwrap();
    assert_eq!(super::read_config(&path), super::RemoteConfig::default(), "corrupt");
    let _ = std::fs::remove_dir_all(&root);
}
