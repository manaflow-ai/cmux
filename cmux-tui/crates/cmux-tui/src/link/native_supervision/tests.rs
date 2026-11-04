use super::*;
use std::io::{BufRead as _, Read as _, Write as _};
use std::os::unix::net::UnixStream as StdStream;
use std::time::Duration;

const FIXTURE: &str = "CMUX_NATIVE_SUPERVISION_TEST";
const SESSION: &str = "CMUX_NATIVE_SUPERVISION_SESSION";
const REPORT: &str = "CMUX_NATIVE_SUPERVISION_REPORT";
const FRAME: &[u8] = b"native-supervision-test-frame";

#[test]
#[ignore = "re-executed only by the owned-child tests"]
fn native_receiver_daemon_fixture() {
    let mode = std::env::var(FIXTURE).unwrap();
    let parent = crate::link::cloud_broker::inherited("0").unwrap();
    parent.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    if mode == "forged" {
        // This inherited endpoint was created by the daemon, not the child.
        cmux_unix_socket::descriptor::send(&parent, &[2], parent.as_raw_fd()).unwrap();
        let _ = (&parent).read(&mut [0]);
        return;
    }
    let (mut control, endpoint) = StdStream::pair().unwrap();
    control.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    cmux_unix_socket::descriptor::send(&parent, &[2], endpoint.as_raw_fd()).unwrap();
    drop(endpoint);
    let mut frame = vec![0; FRAME.len()];
    control.read_exact(&mut frame).unwrap();
    assert_eq!(frame, FRAME);
    let session = std::path::PathBuf::from(std::env::var_os(SESSION).unwrap());
    let entry = cmux_link::entry_path::remote_entry_socket_path(&session);
    let entry = cmux_unix_socket::connect(&entry).unwrap();
    entry.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut greeting = String::new();
    io::BufReader::new(&entry).read_line(&mut greeting).unwrap();
    assert!(greeting.contains("remote_entry"), "the entry refused its actual owned child");
    // The entry's pending stamp is released when this child stops too.
    let mut report =
        std::env::var_os(REPORT).map(|path| cmux_unix_socket::connect(Path::new(&path)).unwrap());
    if mode == "pending" {
        report.as_mut().unwrap().write_all(&std::process::id().to_be_bytes()).unwrap();
    } else {
        control.write_all(&[1]).unwrap();
    }
    assert_eq!(control.read(&mut [0]).unwrap(), 0);
    drop(entry);
    control.write_all(&[2]).unwrap();
    if mode == "hold_exit" {
        let report = report.as_mut().unwrap();
        report.write_all(b"drained").unwrap();
        report.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut release = [0];
        report.read_exact(&mut release).unwrap();
        assert_eq!(release, [1]);
    }
}

fn command(mode: &str, session: &Path, report: Option<&Path>) -> Command {
    let mut command = Command::new(std::env::current_exe().unwrap());
    command
        .args([
            "--ignored",
            "--exact",
            "link::native_supervision::tests::native_receiver_daemon_fixture",
        ])
        .env(FIXTURE, mode)
        .env(SESSION, session);
    if let Some(report) = report {
        command.env(REPORT, report);
    }
    command
}

fn mux() -> Arc<Mux> {
    Mux::new("native-supervision-test", cmux_tui_core::SurfaceOptions::default())
}

async fn within<T>(future: impl Future<Output = T>) -> T {
    tokio::time::timeout(Duration::from_secs(15), future).await.expect("supervision completed")
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_receiver_daemon_entry_accepts_only_its_actual_child() {
    let directory = cmux_unix_socket::short_test_dir("nsv");
    let session = directory.path().join("s");
    let child =
        within(NativeChild::start(command("ready", &session, None), &mux(), &session, FRAME))
            .await
            .expect("the daemon starts its Native receiver");
    let entry = cmux_link::entry_path::remote_entry_socket_path(&session);
    let mut other = UnixStream::connect(&entry).await.unwrap();
    assert_eq!(within(other.read(&mut [0])).await.unwrap(), 0, "same-user caller was admitted");
    let retained = child.child.clone();
    within(child.stop()).await.unwrap();
    assert!(retained.try_wait().unwrap().unwrap().success(), "stop returned before child exit");
    assert!(!entry.exists(), "entry remained after stop");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_receiver_daemon_refuses_an_inherited_creator_instead_of_the_child() {
    let directory = cmux_unix_socket::short_test_dir("nsf");
    let session = directory.path().join("s");
    let result =
        within(NativeChild::start(command("forged", &session, None), &mux(), &session, FRAME))
            .await;
    let error = result.err().expect("inherited creator cannot impersonate the child");
    assert!(error.to_string().contains("caller_refused"), "wrong failure: {error}");
    assert!(!cmux_link::entry_path::remote_entry_socket_path(&session).exists());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_receiver_daemon_waits_for_exit_after_the_child_acknowledges_drain() {
    let directory = cmux_unix_socket::short_test_dir("nsa");
    let session = directory.path().join("s");
    let report = directory.path().join("r");
    let listener = tokio::net::UnixListener::bind(&report).unwrap();
    let child = within(NativeChild::start(
        command("hold_exit", &session, Some(&report)),
        &mux(),
        &session,
        FRAME,
    ))
    .await
    .expect("the daemon starts its Native receiver");
    let retained = child.child.clone();
    let (mut report, _) = within(listener.accept()).await.unwrap();
    let mut stopping = Box::pin(child.stop());
    let mut drained = [0; 7];
    tokio::select! {
        biased;
        result = &mut stopping => panic!("stop completed before the child drained: {result:?}"),
        result = within(report.read_exact(&mut drained)) => { result.unwrap(); }
    }
    assert_eq!(&drained, b"drained");
    assert!(retained.try_wait().unwrap().is_none(), "fixture did not hold the real child alive");
    assert!(
        tokio::time::timeout(Duration::from_millis(30), &mut stopping).await.is_err(),
        "a drain acknowledgement was treated as process exit"
    );
    report.write_all(&[1]).await.unwrap();
    within(stopping).await.unwrap();
    assert!(retained.try_wait().unwrap().unwrap().success());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn native_receiver_daemon_cancellation_during_readiness_reaps_the_owned_child() {
    let directory = cmux_unix_socket::short_test_dir("nsc");
    let session = directory.path().join("s");
    let report = directory.path().join("r");
    let listener = tokio::net::UnixListener::bind(&report).unwrap();
    let mux = mux();
    let mut starting = Box::pin(NativeChild::start(
        command("pending", &session, Some(&report)),
        &mux,
        &session,
        FRAME,
    ));
    let (mut report, _) = tokio::select! {
        biased;
        result = &mut starting => panic!("startup ended before the real child's readiness: {}", result.err().unwrap()),
        report = within(listener.accept()) => report.unwrap(),
    };
    let mut pid = [0; 4];
    within(report.read_exact(&mut pid)).await.unwrap();
    let pid = u32::from_be_bytes(pid) as libc::pid_t;
    drop(starting);
    assert!(!cmux_link::entry_path::remote_entry_socket_path(&session).exists());
    // Cancellation is synchronous ownership cleanup, not a detached waiter.
    // SAFETY: signal zero only queries this test child's continued existence.
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1, "canceled child was left running or unreaped");
    assert_eq!(io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
}

#[test]
fn native_receiver_daemon_original_inherited_parent_check_refuses_a_descriptor_claim() {
    assert!(crate::link::cloud_broker::inherited("not-a-descriptor").is_err());
}

#[tokio::test]
async fn native_receiver_daemon_stop_before_bootstrap_finishes_needs_no_child() {
    let (mut root, daemon) = StdStream::pair().unwrap();
    daemon.set_nonblocking(true).unwrap();
    // The root has delivered a role fd but stops during its four-byte prefix.
    root.write_all(&[0, 0]).unwrap();
    root.shutdown(std::net::Shutdown::Write).unwrap();
    let mut daemon = UnixStream::from_std(daemon).unwrap();
    assert!(within(read_frame(&mut daemon)).await.unwrap().is_none());
}
