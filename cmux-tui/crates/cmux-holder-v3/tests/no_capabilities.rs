//! The version 3 holder grants no capability bit (it predates them): a
//! daemon of this build sends it no TRACE_START, TRACE_STOP or WRITE flow
//! trailer, and the holder is `holder_untraced`.

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_holder::client::launch;
use cmux_holder::link::{HolderLink, TerminalSink, TraceForward};
use cmux_holder::{ExitStatus, SpawnRequest};

#[derive(Default)]
struct Collect {
    bytes: Mutex<Vec<u8>>,
    exit: Mutex<Option<ExitStatus>>,
}

impl TerminalSink for Collect {
    fn data(&self, _offset: u64, bytes: &[u8]) {
        self.bytes.lock().unwrap().extend_from_slice(bytes);
    }
    fn gap(&self, _requested: u64, _oldest: u64) {}
    fn exit(&self, status: ExitStatus, _end: u64) {
        *self.exit.lock().unwrap() = Some(status);
    }
    fn refused(&self, _message: &str) {}
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_v3_holder_is_untraced_and_never_gets_the_new_frames() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!(
        "cmhx3c-{}-{}",
        std::process::id(),
        stamp % 1_000_000_000
    ));
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("h.sock");
    let token = [0x34; 32];
    let mut holder =
        launch(Path::new(env!("CARGO_BIN_EXE_cmux-holder-v3")), &socket, &token).unwrap();
    let (link, _) = HolderLink::connect(&socket, &token, Box::new(|_| {})).unwrap();
    assert_eq!((link.version(), link.capabilities()), (3, 0), "the fixture grants nothing");
    assert!(!link.traced() && !link.takes_write_flow());
    assert_eq!(link.trace_start(u64::MAX, 0).unwrap(), TraceForward::Untraced);
    assert_eq!(link.trace_stop().unwrap(), TraceForward::Untraced);

    let sink = Arc::new(Collect::default());
    let request = SpawnRequest {
        id: [3; 16],
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/sh".to_vec(), b"-c".to_vec(), b"echo up; exec cat".to_vec()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec()],
        ..SpawnRequest::default()
    };
    link.spawn(1, &request, sink.clone()).unwrap();
    let text = || String::from_utf8_lossy(&sink.bytes.lock().unwrap()).into_owned();
    wait_for("the first line", || text().contains("up"));
    // Flow 42 is `*` and seven NULs: a trailer the v3 holder wrote into
    // the shell would echo them. A flow mark with no input sends nothing.
    link.write_flow(1, b"", 42).unwrap();
    link.write_flow(1, b"plain\n", 42).unwrap();
    wait_for("the echo", || text().contains("plain\r\nplain"));
    assert!(
        !text().contains('*') && !text().contains('\0'),
        "a trailer reached the shell: {:?}",
        text()
    );
    // No ERROR came back: the holder got no frame it does not know.
    assert_eq!(link.trace_refusal(), None);

    link.close(1, 200).unwrap();
    wait_for("the exit", || sink.exit.lock().unwrap().is_some());
    drop(link);
    let _ = holder.kill();
    let _ = holder.wait();
    let _ = std::fs::remove_dir_all(&dir);
}
