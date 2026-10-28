//! The holder's trace records: one `task.holder_poll` slice per poll
//! turn's work, and a `task.holder_pty_read` / `task.holder_pty_write` instant per PTY read and
//! write with the terminal's hash and the byte count. All of them are `task`, a recording-only
//! category: with no recording the holder writes none.
//!
//! The holder runs in this test process (the ring is per process), so this file holds one test.

#![cfg(unix)]

use std::os::unix::net::UnixListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_holder::link::{HolderLink, TerminalSink};
use cmux_holder::{ExitStatus, SpawnRequest};
use cmux_trace::{Decoded, DecodedRecord, Phase, Role, category, decode};

mod support;

const TOKEN: [u8; 32] = [0x16; 32];

#[derive(Default)]
struct Collect {
    bytes: Mutex<Vec<u8>>,
    exit: Mutex<Option<ExitStatus>>,
}

impl TerminalSink for Collect {
    fn data(&self, _offset: u64, bytes: &[u8]) {
        self.bytes.lock().unwrap().extend_from_slice(bytes);
    }
    fn gap(&self, requested: u64, oldest: u64) {
        panic!("gap {requested}..{oldest}");
    }
    fn exit(&self, status: ExitStatus, _end: u64) {
        *self.exit.lock().unwrap() = Some(status);
    }
}

impl Collect {
    fn count(&self, needle: &str) -> usize {
        String::from_utf8_lossy(&self.bytes.lock().unwrap()).matches(needle).count()
    }
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn ring() -> Decoded {
    decode(&cmux_trace::snapshot_active().expect("tracing started")).expect("the ring decodes")
}

fn named<'a>(decoded: &'a Decoded, name: &str) -> Vec<&'a DecodedRecord> {
    decoded.records.iter().filter(|record| decoded.name(record.name) == Some(name)).collect()
}

#[test]
fn host_spans_holder_records_its_turns_and_pty_bytes_only_while_recording() {
    let dir = support::unique_dir("cmhs");
    let _open = cmux_trace::init_blackbox(dir.join("rings"), Role::Holder);
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let serving = std::thread::spawn(move || {
        cmux_holder::holder::Holder::new(listener, TOKEN).unwrap().run()
    });

    let (link, listed) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();
    assert!(listed.is_empty());
    let id: [u8; 16] = std::array::from_fn(|index| 0x40 + index as u8);
    let request = SpawnRequest {
        id,
        cols: 80,
        rows: 24,
        cwd: b"/tmp".to_vec(),
        argv: vec![b"/bin/cat".to_vec()],
        env: vec![b"PATH=/usr/bin:/bin".to_vec()],
        ..SpawnRequest::default()
    };
    let sink = Arc::new(Collect::default());
    let _spawned = link.spawn(1, &request, sink.clone()).unwrap();

    // Off: the black box does not record `task`, so the echo writes nothing.
    assert!(!cmux_trace::enabled(category::TASK));
    link.write(1, b"before\n").unwrap();
    wait_for("the first echo", || sink.count("before") >= 2);
    let off = ring();
    for name in ["task.holder_poll", "task.holder_pty_read", "task.holder_pty_write"] {
        assert!(named(&off, name).is_empty(), "{name} recorded with its category off");
    }

    cmux_trace::start_recording(category::TASK).expect("a recording starts");
    link.write(1, b"traced\n").unwrap();
    wait_for("the traced echo", || sink.count("traced") >= 2);
    // One more turn after the echo's read, so its slice has ended.
    link.write(1, b"x").unwrap();
    wait_for("the last echo", || sink.count("x") >= 1);
    let on = ring();
    let hash = cmux_trace::terminal_hash(&id);

    let writes = named(&on, "task.holder_pty_write");
    assert!(
        writes.iter().any(|record| record.phase == Phase::Instant as u8
            && record.arg0 == hash
            && record.arg1 == b"traced\n".len() as u64),
        "no pty write of the traced input: {writes:?}"
    );
    let reads = named(&on, "task.holder_pty_read");
    assert!(!reads.is_empty(), "no pty read recorded");
    assert!(reads.iter().all(|record| record.phase == Phase::Instant as u8
        && record.arg0 == hash
        && record.arg1 > 0));
    // The echo: "traced\r\n" from the line discipline and again from cat.
    let read_bytes: u64 = reads.iter().map(|record| record.arg1).sum();
    assert!(read_bytes >= 2 * b"traced\r\n".len() as u64, "{read_bytes} bytes read");

    // One slice per turn: on the holder's thread, begins and ends alternate, never nested, and
    // every pty record lies inside one.
    let mut turns = named(&on, "task.holder_poll");
    turns.sort_by_key(|record| (record.position, record.slot));
    let begins = turns.iter().filter(|record| record.phase == Phase::Begin as u8).count();
    assert!(begins >= 2, "{begins} turns recorded");
    let mut open = None;
    let mut slices = Vec::new();
    for record in &turns {
        match (record.phase, open) {
            (phase, None) if phase == Phase::Begin as u8 => open = Some(record.t_ns),
            (phase, Some(start)) if phase == Phase::End as u8 => {
                slices.push(start..=record.t_ns);
                open = None;
            }
            _ => panic!("turn slices nest or end unopened: {turns:?}"),
        }
    }
    // The turn the snapshot caught still open.
    slices.extend(open.map(|start| start..=u64::MAX));
    for record in reads.iter().chain(&writes) {
        assert!(
            slices.iter().any(|slice| slice.contains(&record.t_ns)),
            "a pty record outside every turn: {record:?}"
        );
    }

    cmux_trace::stop().expect("the recording stops");
    link.close(1, 500).unwrap();
    wait_for("the exit", || sink.exit.lock().unwrap().is_some());
    // The holder keeps serving the link until this process ends.
    assert!(!serving.is_finished(), "the holder stopped: {:?}", serving.join());
    let _ = std::fs::remove_dir_all(&dir);
}

/// The holder links std and libc only: its resolved normal dependency graph, on every target and
/// with the features the workspace turns on, is the holder, libc, the std+libc trace crates and
/// cmux-ipc's descriptor passing with its no-runtime dependencies, and the std+libc
/// cmux-memory budget its ring and link-queue sizes come from, the std+libc
/// cmux-threads QoS and registry row of the daemon-side link reader, the
/// std+libc hang watch of its loop, and cmux-panic-log's std-only
/// writer, without serde_json.
#[test]
fn host_spans_holder_dependencies_stay_std_and_libc() {
    let cargo = std::env::var_os("CARGO").unwrap_or_else(|| "cargo".into());
    let output = std::process::Command::new(cargo)
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .args(["tree", "-p", "cmux-holder", "-e", "normal", "--target", "all"])
        .args(["--prefix", "none", "--format", "{p}", "--offline", "--locked"])
        .output()
        .expect("cargo tree runs");
    assert!(output.status.success(), "cargo tree: {}", String::from_utf8_lossy(&output.stderr));
    let packages: std::collections::BTreeSet<String> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .filter_map(|line| line.split_whitespace().next())
        .map(str::to_owned)
        .collect();
    let expected = [
        "bytes",
        "cmux-flow-trace",
        "cmux-hang-watch",
        "cmux-holder",
        "cmux-ipc",
        "cmux-memory",
        "cmux-panic-log",
        "cmux-threads",
        "cmux-trace",
        "libc",
        "memchr",
        "phf",
        "phf_shared",
        "siphasher",
    ];
    let expected = std::collections::BTreeSet::from(expected.map(str::to_owned));
    assert_eq!(packages, expected, "the holder links more than libc");
}
