//! The owner level on real processes (a `sleep` child stands in for the
//! app): `cargo test -p cmux-owner-liveness`.

use std::process::{Child, Command};
use std::sync::mpsc::{Receiver, channel};

use super::*;

fn app() -> Child {
    Command::new("sleep").arg("600").spawn().expect("a stand-in app")
}

fn quit(mut app: Child) {
    app.kill().expect("the stand-in app ends");
    app.wait().expect("reaped");
}

fn named(app: &Child) -> OwnerApp {
    OwnerApp::from_pid(i32::try_from(app.id()).expect("pid"))
}

/// A liveness that reports each change on the returned channel.
fn observed(file: Option<PathBuf>) -> (Arc<OwnerLiveness>, Receiver<()>) {
    let liveness = OwnerLiveness::new(file);
    let (tx, rx) = channel();
    assert!(liveness.observe(move || {
        let _ = tx.send(());
    }));
    (liveness, rx)
}

/// Waits for the observer until `liveness` says `want`.
fn until(liveness: &OwnerLiveness, changes: &Receiver<()>, want: OwnerState) {
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while liveness.state() != want {
        let left = deadline.saturating_duration_since(std::time::Instant::now());
        assert!(!left.is_zero(), "the owner never became {want:?}: {:?}", liveness.state());
        let _ = changes.recv_timeout(left);
    }
}

#[test]
fn owner_liveness_unnamed_follows_nothing() {
    let (liveness, watch) = OwnerLiveness::following(OwnerApp::parse(None), None);
    assert!(matches!(watch, Watch::Unnamed));
    assert_eq!(liveness.state(), OwnerState::Unnamed);
    assert_eq!(OwnerApp::parse(Some("1")), OwnerApp::default());
    assert_eq!(OwnerApp::parse(Some("abc")), OwnerApp::default());
    assert_eq!(OwnerApp::parse(Some(" 42\n")).pid(), Some(42));
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn owner_liveness_the_kernel_reports_the_app_exit() {
    let app = app();
    let (liveness, changes) = observed(None);
    assert!(matches!(liveness.follow(named(&app)), Watch::Kernel));
    // The follow itself is a change.
    changes.recv_timeout(Duration::from_secs(5)).expect("the follow was not reported");
    assert_eq!(liveness.state(), OwnerState::Alive);
    assert!(
        changes.recv_timeout(Duration::from_millis(200)).is_err(),
        "a change while the app runs"
    );
    quit(app);
    changes.recv_timeout(Duration::from_secs(10)).expect("the exit was never reported");
    assert_eq!(liveness.state(), OwnerState::Gone);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn owner_liveness_an_app_gone_before_the_follow_is_gone() {
    let app = app();
    let pid = named(&app);
    quit(app);
    let (liveness, watch) = OwnerLiveness::following(pid, None);
    assert!(matches!(watch, Watch::Gone), "{watch:?}");
    assert_eq!(liveness.state(), OwnerState::Gone);
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn owner_liveness_follows_the_newer_app_the_pid_file_names() {
    let dir = std::env::temp_dir().join(format!("owner-liveness-next-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("dir");
    let file = dir.join("owner-app.pid");
    let (first, second) = (app(), app());
    std::fs::write(&file, format!("{}\n", second.id())).expect("pid file");
    let (liveness, changes) = observed(Some(file));
    liveness.follow(named(&first));
    quit(first);
    changes.recv_timeout(Duration::from_secs(10)).expect("the first exit was never reported");
    assert_eq!(liveness.state(), OwnerState::Alive, "the newer app runs");
    quit(second);
    until(&liveness, &changes, OwnerState::Gone);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The level, not an edge: an app that starts after the quit and reuses the
/// helper (it writes the pid file) is followed again.
#[cfg(any(target_os = "linux", target_os = "macos"))]
#[test]
fn owner_liveness_an_app_after_the_quit_is_alive_again() {
    let dir = std::env::temp_dir().join(format!("owner-liveness-again-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("dir");
    let file = dir.join("owner-app.pid");
    let first = app();
    let (liveness, changes) = observed(Some(file.clone()));
    liveness.follow(named(&first));
    quit(first);
    until(&liveness, &changes, OwnerState::Gone);
    let second = app();
    std::fs::write(&file, format!("{}\n", second.id())).expect("pid file");
    assert_eq!(liveness.state(), OwnerState::Alive, "the newer app does not keep the helper");
    quit(second);
    until(&liveness, &changes, OwnerState::Gone);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn owner_liveness_the_stop_rule() {
    let keeps = |clients, owner, live_work| Keeps { clients, owner, live_work };
    for owner in [OwnerState::Unnamed, OwnerState::Alive, OwnerState::Gone] {
        assert!(!keeps(true, owner, false).exits(false), "a client keeps it");
        assert!(!keeps(false, owner, true).exits(false), "live work keeps it");
    }
    assert!(!keeps(false, OwnerState::Alive, false).exits(false));
    assert!(keeps(false, OwnerState::Gone, false).exits(true));
    assert!(keeps(false, OwnerState::Unnamed, false).exits(false));
    assert!(!keeps(false, OwnerState::Unnamed, false).exits(true));
}

#[cfg(debug_assertions)]
#[test]
#[should_panic(expected = "the stop rule says")]
fn owner_liveness_check_refuses_an_exit_the_rule_does_not_say() {
    let keeps = Keeps { clients: false, owner: OwnerState::Alive, live_work: false };
    check("test helper", true, keeps, false);
}

#[cfg(unix)]
#[test]
fn owner_liveness_a_socket_peer_is_named_by_the_kernel() {
    let (one, _two) = std::os::unix::net::UnixStream::pair().expect("pair");
    assert_eq!(peer_app(&one).pid(), i32::try_from(std::process::id()).ok());
}
