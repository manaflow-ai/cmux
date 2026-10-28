//! The Perfetto exporter: its output read back with a protobuf parser of
//! this test's own, field numbers from Perfetto's protos (v58):
//!
//! - every packet is a TracePacket of the kinds the exporter writes, and the golden dump of a fixed
//!   recording (`tests/fixtures/export-golden.txt`) does not drift;
//! - two overlapping `create.tab` intervals on main get two async tracks, each with one slice;
//! - descriptors carry role, thread name and QoS; names are interned per sequence; flows join two
//!   threads and end where they arrive; counters; one ClockSnapshot per machine, the remote one
//!   tied by its offset; a remote machine's processes and threads are named tracks, apart from
//!   local ones with the same pid and tid;
//! - Chromium's JSON merges on the local clock after its offset, zero-length slices included;
//! - the `#[ignore]`d `trace_processor` tests import the output with Perfetto's
//!   `trace_processor_shell` (`CMUX_TRACE_PROCESSOR`, else `PATH`, else the Perfetto Python
//!   package's `~/.local/share/perfetto/prebuilts`) and fail when it is missing:
//!   `cargo test -p cmux-trace --test export -- --include-ignored`.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

use cmux_trace::clock::ClockDomain;
use cmux_trace::{
    ChromiumInput, Decoded, ExportInput, ExportStats, FLAG_ESTIMATE, FLAG_ID, Machine, Phase,
    ProcessIdentity, Record, RemoteMachine, RingInput, RingSizes, Role, StartClocks,
    ThreadIdentity, Tracer, TracerConfig, Writer, decode, export, names::catalog_id,
};

// ---- An in-test protobuf reader -------------------------------------------------------------

#[derive(Clone, Debug, PartialEq)]
enum Wire {
    Varint(u64),
    Fixed64(u64),
    Bytes(Vec<u8>),
    Fixed32(u32),
}

fn varint(bytes: &[u8], at: &mut usize) -> u64 {
    let mut value = 0u64;
    for shift in (0..64).step_by(7) {
        let byte = bytes[*at];
        *at += 1;
        value |= u64::from(byte & 0x7F) << shift;
        if byte & 0x80 == 0 {
            return value;
        }
    }
    panic!("varint longer than 10 bytes");
}

/// The fields of one message, in order. Panics on bytes that are not protobuf.
fn fields(bytes: &[u8]) -> Vec<(u32, Wire)> {
    let mut out = Vec::new();
    let mut at = 0;
    while at < bytes.len() {
        let key = varint(bytes, &mut at);
        let field = (key >> 3) as u32;
        assert!(field > 0, "field 0 at byte {at}");
        let value = match key & 7 {
            0 => Wire::Varint(varint(bytes, &mut at)),
            1 => {
                let word = u64::from_le_bytes(bytes[at..at + 8].try_into().unwrap());
                at += 8;
                Wire::Fixed64(word)
            }
            2 => {
                let len = varint(bytes, &mut at) as usize;
                let body = bytes[at..at + len].to_vec();
                at += len;
                Wire::Bytes(body)
            }
            5 => {
                let word = u32::from_le_bytes(bytes[at..at + 4].try_into().unwrap());
                at += 4;
                Wire::Fixed32(word)
            }
            wire => panic!("wire type {wire} at byte {at}"),
        };
        out.push((field, value));
    }
    assert_eq!(at, bytes.len(), "a field runs past the message");
    out
}

/// A decoded message with lookups by field number.
#[derive(Clone, Debug)]
struct Msg(Vec<(u32, Wire)>);

impl Msg {
    fn parse(bytes: &[u8]) -> Msg {
        Msg(fields(bytes))
    }
    fn all(&self, field: u32) -> impl Iterator<Item = &Wire> {
        self.0.iter().filter(move |(number, _)| *number == field).map(|(_, value)| value)
    }
    fn uint(&self, field: u32) -> Option<u64> {
        self.all(field).find_map(|value| match value {
            Wire::Varint(value) => Some(*value),
            _ => None,
        })
    }
    fn fixed(&self, field: u32) -> Vec<u64> {
        self.all(field)
            .filter_map(|value| match value {
                Wire::Fixed64(value) => Some(*value),
                _ => None,
            })
            .collect()
    }
    fn msg(&self, field: u32) -> Option<Msg> {
        self.msgs(field).into_iter().next()
    }
    fn msgs(&self, field: u32) -> Vec<Msg> {
        self.all(field)
            .filter_map(|value| match value {
                Wire::Bytes(bytes) => Some(Msg::parse(bytes)),
                _ => None,
            })
            .collect()
    }
    fn text(&self, field: u32) -> Option<String> {
        self.texts(field).into_iter().next()
    }
    fn texts(&self, field: u32) -> Vec<String> {
        self.all(field)
            .filter_map(|value| match value {
                Wire::Bytes(bytes) => Some(String::from_utf8(bytes.clone()).expect("UTF-8")),
                _ => None,
            })
            .collect()
    }
}

// Field numbers (protos/perfetto/trace/...).
const TRACE_PACKET: u32 = 1;
const P_TIMESTAMP: u32 = 8;
const P_CLOCK_SNAPSHOT: u32 = 6;
const P_TRACK_EVENT: u32 = 11;
const P_SEQUENCE_ID: u32 = 10;
const P_INTERNED_DATA: u32 = 12;
const P_SEQUENCE_FLAGS: u32 = 13;
const P_TIMESTAMP_CLOCK_ID: u32 = 58;
const P_TRACK_DESCRIPTOR: u32 = 60;
const TD_UUID: u32 = 1;
const TD_NAME: u32 = 2;
const TD_PROCESS: u32 = 3;
const TD_THREAD: u32 = 4;
const TD_PARENT: u32 = 5;
const TD_COUNTER: u32 = 8;
const TD_DESCRIPTION: u32 = 14;
const TE_CATEGORY_IIDS: u32 = 3;
const TE_ANNOTATIONS: u32 = 4;
const TE_TYPE: u32 = 9;
const TE_NAME_IID: u32 = 10;
const TE_TRACK: u32 = 11;
const TE_CATEGORIES: u32 = 22;
const TE_NAME: u32 = 23;
const TE_COUNTER: u32 = 30;
const TE_DOUBLE_COUNTER: u32 = 44;
const TE_FLOWS: u32 = 47;
const TE_TERMINATING_FLOWS: u32 = 48;
const BEGIN: u64 = 1;
const END: u64 = 2;
const INSTANT: u64 = 3;
const COUNTER: u64 = 4;
const MONOTONIC_RAW: u64 = 5;

fn packets(trace: &[u8]) -> Vec<Msg> {
    let top = Msg::parse(trace);
    assert!(top.0.iter().all(|(field, _)| *field == TRACE_PACKET), "a Trace holds only packets");
    top.msgs(TRACE_PACKET)
}

/// Every TrackEvent with its packet's time, clock, sequence and the sequence's interned names.
struct Event {
    t: u64,
    clock: u64,
    sequence: u64,
    kind: u64,
    track: u64,
    name: String,
    categories: Vec<String>,
    flows: Vec<u64>,
    terminating: Vec<u64>,
    counter: Option<f64>,
    args: Vec<(String, String)>,
}

struct Parsed {
    packets: Vec<Msg>,
    tracks: BTreeMap<u64, Msg>,
    snapshots: Vec<Msg>,
    events: Vec<Event>,
}

fn annotation_value(annotation: &Msg) -> String {
    if let Some(value) = annotation.uint(2) {
        return format!("bool {value}");
    }
    if let Some(value) = annotation.uint(3) {
        return format!("uint {value}");
    }
    if let Some(value) = annotation.uint(4) {
        return format!("int {}", value as i64);
    }
    if let Some(value) = annotation.fixed(5).first() {
        return format!("double {}", f64::from_bits(*value));
    }
    if let Some(value) = annotation.text(6) {
        return format!("string {value}");
    }
    if let Some(value) = annotation.text(9) {
        return format!("json {value}");
    }
    panic!("an annotation with no value: {annotation:?}");
}

/// One sequence's interned tables, by iid.
#[derive(Default)]
struct Interned {
    names: HashMap<u64, String>,
    categories: HashMap<u64, String>,
    annotations: HashMap<u64, String>,
}

fn parse(trace: &[u8]) -> Parsed {
    let packets = packets(trace);
    let mut tracks = BTreeMap::new();
    let mut snapshots = Vec::new();
    let mut events = Vec::new();
    let mut interned: HashMap<u64, Interned> = HashMap::new();
    for packet in &packets {
        let sequence = packet.uint(P_SEQUENCE_ID).expect("every packet names its sequence");
        if let Some(descriptor) = packet.msg(P_TRACK_DESCRIPTOR) {
            let uuid = descriptor.uint(TD_UUID).expect("a track has a uuid");
            assert!(tracks.insert(uuid, descriptor).is_none(), "track {uuid} described twice");
            continue;
        }
        if let Some(snapshot) = packet.msg(P_CLOCK_SNAPSHOT) {
            snapshots.push(snapshot);
            continue;
        }
        let event =
            packet.msg(P_TRACK_EVENT).expect("a packet is a descriptor, a snapshot or an event");
        let flags = packet.uint(P_SEQUENCE_FLAGS).unwrap_or(0);
        if flags & 1 != 0 {
            interned.insert(sequence, Interned::default());
        }
        let tables =
            interned.get_mut(&sequence).expect("a sequence clears its state before an event");
        if let Some(data) = packet.msg(P_INTERNED_DATA) {
            assert!(flags & 1 != 0, "interned data comes with a cleared state");
            let tables = &mut *tables;
            for (field, table) in
                [(1, &mut tables.categories), (2, &mut tables.names), (3, &mut tables.annotations)]
            {
                for entry in data.msgs(field) {
                    table.insert(entry.uint(1).expect("iid"), entry.text(2).expect("name"));
                }
            }
        }
        let name = match event.uint(TE_NAME_IID) {
            Some(iid) => tables
                .names
                .get(&iid)
                .cloned()
                .unwrap_or_else(|| panic!("name iid {iid} is not interned")),
            None => event.text(TE_NAME).unwrap_or_default(),
        };
        let mut categories: Vec<String> = event
            .all(TE_CATEGORY_IIDS)
            .map(|value| match value {
                Wire::Varint(iid) => {
                    tables.categories.get(iid).cloned().expect("category interned")
                }
                _ => panic!("category iid is a varint"),
            })
            .collect();
        categories.extend(event.texts(TE_CATEGORIES));
        let counter = event
            .uint(TE_COUNTER)
            .map(|value| value as i64 as f64)
            .or_else(|| event.fixed(TE_DOUBLE_COUNTER).first().map(|bits| f64::from_bits(*bits)));
        let args = event
            .msgs(TE_ANNOTATIONS)
            .iter()
            .map(|annotation| {
                let name = match annotation.uint(1) {
                    Some(iid) => {
                        tables.annotations.get(&iid).cloned().expect("annotation name interned")
                    }
                    None => annotation.text(10).expect("an inline annotation name"),
                };
                (name, annotation_value(annotation))
            })
            .collect();
        events.push(Event {
            t: packet.uint(P_TIMESTAMP).expect("an event has a time"),
            clock: packet.uint(P_TIMESTAMP_CLOCK_ID).expect("an event names its clock"),
            sequence,
            kind: event.uint(TE_TYPE).expect("an event has a type"),
            track: event.uint(TE_TRACK).expect("an event names its track"),
            name,
            categories,
            flows: event.fixed(TE_FLOWS),
            terminating: event.fixed(TE_TERMINATING_FLOWS),
            counter,
            args,
        });
    }
    for event in &events {
        assert!(tracks.contains_key(&event.track), "event {} on an undescribed track", event.name);
    }
    for descriptor in tracks.values() {
        if let Some(parent) = descriptor.uint(TD_PARENT) {
            assert!(tracks.contains_key(&parent), "a track's parent is described");
        }
    }
    Parsed { packets, tracks, snapshots, events }
}

/// A readable line per track and event, uuids replaced by their first-use index.
fn dump(parsed: &Parsed) -> String {
    let index: HashMap<u64, usize> =
        parsed.tracks.keys().copied().enumerate().map(|(at, uuid)| (uuid, at)).collect();
    let mut out = String::new();
    for snapshot in &parsed.snapshots {
        let clocks: Vec<String> = snapshot
            .msgs(1)
            .iter()
            .map(|clock| format!("{}@{}", clock.uint(1).unwrap(), clock.uint(2).unwrap()))
            .collect();
        out.push_str(&format!(
            "clock_snapshot primary={} {}\n",
            snapshot.uint(2).unwrap_or(0),
            clocks.join(" ")
        ));
    }
    let mut tracks: Vec<(usize, String)> = parsed
        .tracks
        .iter()
        .map(|(uuid, descriptor)| {
            let parent = descriptor
                .uint(TD_PARENT)
                .map_or("-".to_owned(), |parent| index[&parent].to_string());
            let what = if let Some(process) = descriptor.msg(TD_PROCESS) {
                format!(
                    "process pid={} name={:?} labels={:?}",
                    process.uint(1).unwrap(),
                    process.text(6),
                    process.texts(8)
                )
            } else if let Some(thread) = descriptor.msg(TD_THREAD) {
                format!(
                    "thread pid={} tid={} name={:?} description={:?}",
                    thread.uint(1).unwrap(),
                    thread.uint(2).unwrap(),
                    thread.text(5),
                    descriptor.text(TD_DESCRIPTION)
                )
            } else if descriptor.msg(TD_COUNTER).is_some() {
                format!("counter name={:?}", descriptor.text(TD_NAME))
            } else {
                format!("named name={:?}", descriptor.text(TD_NAME))
            };
            (index[uuid], format!("track {} parent={parent} {what}\n", index[uuid]))
        })
        .collect();
    tracks.sort();
    out.extend(tracks.into_iter().map(|(_, line)| line));
    for event in &parsed.events {
        out.push_str(&format!(
            "event seq={} t={} clock={} type={} track={} name={:?} cat={:?} flows={:?} end_flows={:?} counter={:?} args={:?}\n",
            event.sequence,
            event.t,
            event.clock,
            event.kind,
            index[&event.track],
            event.name,
            event.categories,
            event.flows,
            event.terminating,
            event.counter,
            event.args
        ));
    }
    out
}

// ---- A fixed recording ----------------------------------------------------------------------

fn zero() -> u64 {
    0
}
fn unix() -> u64 {
    1_700_000_000_000_000_000
}
fn continuous() -> u64 {
    5_000
}

fn tracer(role: Role, pid: u32) -> Tracer {
    Tracer::new(TracerConfig {
        blackbox: RingSizes { name_capacity: 256, thread_capacity: 256, chunk_count: 16 },
        recording: RingSizes { name_capacity: 256, thread_capacity: 256, chunk_count: 16 },
        clocks: StartClocks {
            uptime_ns: zero,
            unix_ns: unix,
            continuous_ns: continuous,
            domain: ClockDomain::UptimeRaw,
        },
        identity: ProcessIdentity {
            pid,
            process_start_unix_us: 1_699_999_999_000_000,
            boot_session_uuid: [7; 16],
            build_uuid: [9; 16],
            build_version: *b"1.2.3 (45)\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        },
        read_slow_identity: |_| {},
        ..TracerConfig::for_process("/nonexistent", role)
    })
}

fn id(text: &str) -> u16 {
    let id = catalog_id(text);
    assert_ne!(id, 0, "{text} is a catalog name");
    id
}

fn record(t_ns: u64, name: &str, phase: Phase, flags: u8, arg0: u64, arg1: u64) -> Record {
    Record { t_ns, name: id(name), phase, flags, arg0, arg1 }
}

const FLOW: u64 = 0x0000_1234_0000_0001;

/// The app: two overlapping create.tab intervals on main, a nested slice, a key flow from main to
/// the IO thread, an estimated present, a counter and an end whose begin the black box lost.
fn app_ring() -> Decoded {
    let tracer = tracer(Role::App, 1234);
    let mut main = Writer::new(&tracer, ThreadIdentity::new(101, 0x21, "main"));
    let mut io = Writer::new(&tracer, ThreadIdentity::new(202, 0x19, "cmux-io"));
    main.write(record(900, "action.perform", Phase::End, 0, 0, 0));
    main.write(record(1_000, "create.tab", Phase::AsyncBegin, FLAG_ID, 3, 1));
    main.write(record(1_100, "create.tab", Phase::AsyncBegin, FLAG_ID, 4, 2));
    main.write(record(1_150, "action.perform", Phase::Begin, 0, 17, 0));
    main.write(record(1_160, "key.flow", Phase::FlowOut, 0, 0, FLOW));
    main.write(record(1_170, "action.perform", Phase::End, 0, 0, 0));
    io.write(record(1_180, "key.flow", Phase::FlowIn, 0, 0, FLOW));
    io.write(record(1_190, "key.flow", Phase::FlowOut, 0, 1, FLOW));
    main.write(record(1_200, "create.tab", Phase::AsyncEnd, FLAG_ID, 0, 1));
    io.write(record(1_250, "frame.present_estimate", Phase::Instant, FLAG_ESTIMATE, 60, 0));
    main.write(record(1_300, "create.tab", Phase::AsyncEnd, FLAG_ID, 0, 2));
    io.write(record(1_350, "frame.sequence", Phase::Counter, FLAG_ID, (-5i64) as u64, 4));
    drop(main);
    drop(io);
    decode(&tracer.snapshot_active()).expect("the app ring decodes")
}

/// A remote daemon whose clock is 37 ms ahead: the key flow arrives there.
fn remote_ring() -> Decoded {
    daemon_ring(4321, 303)
}

/// The remote daemon's recording, as process `pid` with its dispatch thread `tid`.
fn daemon_ring(pid: u32, tid: u64) -> Decoded {
    let tracer = tracer(Role::Daemon, pid);
    let mut dispatch = Writer::new(&tracer, ThreadIdentity::new(tid, 0, "mux-control-dispatch"));
    dispatch.write(record(37_000_000 + 1_400, "key.flow", Phase::FlowIn, 0, 2, FLOW));
    dispatch.write(record(37_000_000 + 1_450, "daemon.request", Phase::Begin, 0, 1, 0));
    dispatch.write(record(37_000_000 + 1_500, "daemon.request", Phase::End, 0, 0, 0));
    drop(dispatch);
    decode(&tracer.snapshot_active()).expect("the remote ring decodes")
}

const CHROMIUM: &str = r#"{"traceEvents":[
 {"ph":"M","pid":77,"tid":77,"name":"process_name","args":{"name":"Browser"}},
 {"ph":"M","pid":77,"tid":5,"name":"thread_name","args":{"name":"CrBrowserMain"}},
 {"ph":"X","pid":77,"tid":5,"ts":2.5,"dur":1,"cat":"toplevel","name":"RunTask","args":{"src":"a.cc","n":3}},
 {"ph":"X","pid":77,"tid":5,"ts":2,"dur":3,"cat":"toplevel","name":"ThreadControllerImpl::RunTask","bind_id":"0x9","flow_out":true},
 {"ph":"X","pid":77,"tid":6,"ts":4,"dur":0.5,"cat":"ipc","name":"Receive","bind_id":"0x9","flow_in":true},
 {"ph":"b","pid":77,"tid":5,"ts":2,"cat":"latency","name":"EventLatency","id":"0x1"},
 {"ph":"b","pid":77,"tid":5,"ts":2.2,"cat":"latency","name":"EventLatency","id":"0x2"},
 {"ph":"e","pid":77,"tid":5,"ts":3,"cat":"latency","name":"EventLatency","id":"0x1"},
 {"ph":"e","pid":77,"tid":5,"ts":3.5,"cat":"latency","name":"EventLatency","id":"0x2","args":{"nested":{"a":[1]}}},
 {"ph":"C","pid":77,"tid":5,"ts":2,"cat":"memory","name":"Heap","args":{"used":10.5,"total":20}},
 {"ph":"i","pid":77,"tid":5,"ts":2.1,"cat":"input","name":"Mark","s":"g"},
 {"ph":"E","pid":77,"tid":5,"ts":9,"cat":"x","name":"lost begin"},
 {"ph":"O","pid":77,"tid":5,"ts":9,"cat":"x","name":"object","id":"0x5"}
]}"#;

const CHROMIUM_OFFSET_NS: i64 = -500;

fn export_fixture() -> (Vec<u8>, ExportStats) {
    let app = app_ring();
    let remote = remote_ring();
    let remotes = [RemoteMachine {
        name: "linux-lane".into(),
        offset_ns: 37_000_000,
        error_bound_ns: 2_000_000,
    }];
    let rings = [
        RingInput { ring: &app, machine: Machine::Local },
        RingInput { ring: &remote, machine: Machine::Remote(0) },
    ];
    let chromium = [ChromiumInput { json: CHROMIUM.as_bytes(), offset_ns: CHROMIUM_OFFSET_NS }];
    let input = ExportInput { remotes: &remotes, rings: &rings, chromium: &chromium };
    let mut out = Vec::new();
    let stats = export(&input, &mut out).expect("exports");
    (out, stats)
}

fn track_name(parsed: &Parsed, uuid: u64) -> Option<String> {
    parsed.tracks[&uuid].text(TD_NAME)
}

// ---- Tests -----------------------------------------------------------------------------------

#[test]
fn export_two_overlapping_create_tab_intervals_get_their_own_tracks() {
    let (trace, stats) = export_fixture();
    let parsed = parse(&trace);
    let create: Vec<&Event> = parsed
        .events
        .iter()
        .filter(|event| {
            event.name == "create.tab" || {
                event.kind == END
                    && track_name(&parsed, event.track).as_deref() == Some("create.tab")
            }
        })
        .collect();
    assert_eq!(create.len(), 4, "two begins and two ends");
    let begins: Vec<&&Event> = create.iter().filter(|event| event.kind == BEGIN).collect();
    assert_eq!(begins.len(), 2);
    assert_ne!(begins[0].track, begins[1].track, "overlapping intervals never share a track");
    for begin in &begins {
        let ends: Vec<&&Event> =
            create.iter().filter(|event| event.kind == END && event.track == begin.track).collect();
        assert_eq!(ends.len(), 1, "each interval ends once, on its own track");
        assert!(ends[0].t > begin.t);
        assert_eq!(begin.categories, ["create"]);
        let parent = parsed.tracks[&begin.track]
            .uint(TD_PARENT)
            .expect("an async track is under its process");
        assert_eq!(
            parsed.tracks[&parent].msg(TD_PROCESS).and_then(|p| p.text(6)).as_deref(),
            Some("app")
        );
    }
    let ids: Vec<&String> = begins
        .iter()
        .flat_map(|event| &event.args)
        .filter(|(name, _)| name == "id")
        .map(|(_, value)| value)
        .collect();
    assert_eq!(ids, ["uint 1", "uint 2"]);
    assert_eq!(stats.unmatched_ends, 2, "the app's lost begin and Chromium's");
    assert_eq!(stats.invalid_records, 0);
}

#[test]
fn export_descriptors_name_roles_threads_and_qos() {
    let (trace, _) = export_fixture();
    let parsed = parse(&trace);
    let threads: Vec<(String, Option<String>)> = parsed
        .tracks
        .values()
        .filter_map(|descriptor| {
            let thread = descriptor.msg(TD_THREAD)?;
            Some((thread.text(5).unwrap_or_default(), descriptor.text(TD_DESCRIPTION)))
        })
        .collect();
    assert!(threads.contains(&("main".into(), Some("QoS: user-interactive".into()))));
    assert!(threads.contains(&("cmux-io".into(), Some("QoS: user-initiated".into()))));
    assert!(threads.contains(&("CrBrowserMain".into(), None)));
    let processes: Vec<(u64, Option<String>, Vec<String>)> = parsed
        .tracks
        .values()
        .filter_map(|descriptor| descriptor.msg(TD_PROCESS))
        .map(|process| (process.uint(1).unwrap(), process.text(6), process.texts(8)))
        .collect();
    assert!(processes.contains(&(
        1234,
        Some("app".into()),
        vec!["build 1.2.3 (45)".into(), "black box".into()]
    )));
    assert!(processes.contains(&(77, Some("Browser".into()), vec![])));
    let named = |name: &str| -> Option<String> {
        let descriptor = parsed
            .tracks
            .values()
            .find(|descriptor| descriptor.text(TD_NAME).as_deref() == Some(name))
            .unwrap_or_else(|| panic!("a track named {name}"));
        descriptor.text(TD_DESCRIPTION)
    };
    assert_eq!(
        named("daemon 4321 on linux-lane").as_deref(),
        Some("build 1.2.3 (45); black box; clock offset 37000000 ns, error bound 2000000 ns"),
        "a remote process is a named track with its labels"
    );
    assert_eq!(named("mux-control-dispatch 303"), None);
}

#[test]
fn export_names_are_interned_once_per_sequence() {
    let (trace, _) = export_fixture();
    let parsed = parse(&trace);
    let ring_sequences: Vec<u64> = {
        let mut sequences: Vec<u64> = parsed
            .events
            .iter()
            .filter(|e| e.categories.iter().any(|c| c == "create" || c == "daemon"))
            .map(|e| e.sequence)
            .collect();
        sequences.dedup();
        sequences
    };
    assert_eq!(ring_sequences.len(), 2, "one sequence per ring");
    for sequence in ring_sequences {
        let with_names: Vec<&Msg> = parsed
            .packets
            .iter()
            .filter(|packet| {
                packet.uint(P_SEQUENCE_ID) == Some(sequence)
                    && packet.msg(P_INTERNED_DATA).is_some()
            })
            .collect();
        assert_eq!(with_names.len(), 1, "the first packet interns, the rest refer");
        let names = with_names[0].msg(P_INTERNED_DATA).unwrap().msgs(2);
        let create = names
            .iter()
            .find(|name| name.text(2).as_deref() == Some("create.tab"))
            .expect("create.tab interned");
        assert_eq!(create.uint(1), Some(u64::from(id("create.tab"))), "iid is the ring's name id");
    }
}

#[test]
fn export_flows_join_threads_and_machines() {
    let (trace, stats) = export_fixture();
    let parsed = parse(&trace);
    let key: Vec<&Event> = parsed
        .events
        .iter()
        .filter(|event| event.flows == [FLOW] || event.terminating == [FLOW])
        .collect();
    assert_eq!(key.len(), 4, "out on main, in and out on io, in on the remote daemon");
    let tracks: std::collections::HashSet<u64> = key.iter().map(|event| event.track).collect();
    assert_eq!(tracks.len(), 3);
    assert!(key.iter().all(|event| event.kind == INSTANT));
    let shape: Vec<(bool, bool)> =
        key.iter().map(|event| (event.flows.is_empty(), event.terminating.is_empty())).collect();
    assert_eq!(
        shape,
        [(false, true), (true, false), (false, true), (true, false)],
        "s carries flow_ids, f terminating_flow_ids (Perfetto's TerminatingFlow)"
    );
    let chromium_out =
        parsed.events.iter().find(|event| event.name == "ThreadControllerImpl::RunTask").unwrap();
    let chromium_in = parsed.events.iter().find(|event| event.name == "Receive").unwrap();
    assert_eq!(chromium_out.flows.len(), 1);
    assert_eq!(chromium_in.terminating, chromium_out.flows, "flow v2 ends where flow_in is");
    assert!(stats.flow_events >= 6);
}

/// One id used for two flows (ids keyed by a pane or a request number repeat): the arrival ends
/// the first, so the second never chains from it.
fn reused_flow_ring() -> Decoded {
    let tracer = tracer(Role::App, 1234);
    let mut main = Writer::new(&tracer, ThreadIdentity::new(101, 0x21, "main"));
    let mut io = Writer::new(&tracer, ThreadIdentity::new(202, 0x19, "cmux-io"));
    main.write(record(1_000, "key.flow", Phase::FlowOut, 0, 0, FLOW));
    io.write(record(1_100, "key.flow", Phase::FlowIn, 0, 0, FLOW));
    main.write(record(2_000, "key.flow", Phase::FlowOut, 0, 0, FLOW));
    io.write(record(2_100, "key.flow", Phase::FlowIn, 0, 0, FLOW));
    drop(main);
    drop(io);
    decode(&tracer.snapshot_active()).expect("decodes")
}

fn export_rings(rings: &[RingInput<'_>], remotes: &[RemoteMachine]) -> (Vec<u8>, ExportStats) {
    let mut trace = Vec::new();
    let stats =
        export(&ExportInput { remotes, rings, chromium: &[] }, &mut trace).expect("exports");
    (trace, stats)
}

#[test]
fn export_a_flow_ends_where_it_arrives() {
    let ring = reused_flow_ring();
    let (trace, _) = export_rings(&[RingInput { ring: &ring, machine: Machine::Local }], &[]);
    let parsed = parse(&trace);
    let arrivals: Vec<&Event> =
        parsed.events.iter().filter(|event| event.terminating == [FLOW]).collect();
    assert_eq!(arrivals.len(), 2);
    assert!(arrivals.iter().all(|event| event.flows.is_empty()), "an arrival starts no flow");
}

/// A remote ring and a local one with the same pid and tid.
fn same_pid_rings() -> (Decoded, Decoded) {
    let local = {
        let tracer = tracer(Role::App, 4321);
        let mut main = Writer::new(&tracer, ThreadIdentity::new(303, 0x21, "main"));
        main.write(record(1_000, "action.perform", Phase::Begin, 0, 1, 0));
        main.write(record(1_100, "action.perform", Phase::End, 0, 0, 0));
        drop(main);
        decode(&tracer.snapshot_active()).expect("decodes")
    };
    (local, daemon_ring(4321, 303))
}

fn lane() -> RemoteMachine {
    RemoteMachine { name: "linux-lane".into(), offset_ns: 37_000_000, error_bound_ns: 2_000_000 }
}

#[test]
fn export_a_remote_machine_keeps_its_own_processes() {
    let (local, remote) = same_pid_rings();
    let rings = [
        RingInput { ring: &local, machine: Machine::Local },
        RingInput { ring: &remote, machine: Machine::Remote(0) },
    ];
    let (trace, _) = export_rings(&rings, &[lane()]);
    let parsed = parse(&trace);
    let processes: Vec<(u64, Option<String>)> = parsed
        .tracks
        .values()
        .filter_map(|descriptor| descriptor.msg(TD_PROCESS))
        .map(|process| (process.uint(1).unwrap(), process.text(6)))
        .collect();
    assert_eq!(processes, [(4321, Some("app".into()))], "only the local process has a pid");
    let threads = parsed.tracks.values().filter(|descriptor| descriptor.msg(TD_THREAD).is_some());
    assert_eq!(threads.count(), 1, "only the local thread has a tid");
    let daemon = parsed.events.iter().find(|event| event.name == "daemon.request").unwrap();
    let thread = &parsed.tracks[&daemon.track];
    assert_eq!(thread.text(TD_NAME).as_deref(), Some("mux-control-dispatch 303"));
    let process = &parsed.tracks[&thread.uint(TD_PARENT).expect("under its process")];
    assert_eq!(process.text(TD_NAME).as_deref(), Some("daemon 4321 on linux-lane"));
    assert_eq!(process.uint(TD_PARENT), None);
}

#[test]
fn export_one_clock_snapshot_per_machine() {
    let (trace, _) = export_fixture();
    let parsed = parse(&trace);
    assert_eq!(parsed.snapshots.len(), 2, "the local machine and the remote one");
    let local = &parsed.snapshots[0];
    assert_eq!(local.uint(2), Some(MONOTONIC_RAW), "UPTIME_RAW is the primary trace clock");
    let clocks: Vec<(u64, u64)> = local
        .msgs(1)
        .iter()
        .map(|clock| (clock.uint(1).unwrap(), clock.uint(2).unwrap()))
        .collect();
    assert_eq!(clocks, [(MONOTONIC_RAW, 0), (6, 5_000), (1, 1_700_000_000_000_000_000)]);
    let remote = &parsed.snapshots[1];
    let clocks: Vec<(u64, u64)> = remote
        .msgs(1)
        .iter()
        .map(|clock| (clock.uint(1).unwrap(), clock.uint(2).unwrap()))
        .collect();
    assert_eq!(clocks.len(), 2);
    let (remote_id, remote_t) = clocks[0];
    assert_eq!(clocks[1].0, MONOTONIC_RAW);
    assert_eq!(remote_t as i64 - clocks[1].1 as i64, 37_000_000, "tied by the measured offset");
    let daemon =
        parsed.events.iter().filter(|event| event.name == "daemon.request").collect::<Vec<_>>();
    assert!(
        daemon.iter().all(|event| event.clock == remote_id),
        "remote rings stay on their clock"
    );
    let app = parsed.events.iter().find(|event| event.name == "create.tab").unwrap();
    assert_eq!(app.clock, MONOTONIC_RAW);
}

#[test]
fn export_chromium_merges_on_the_local_clock_after_its_offset() {
    let (trace, stats) = export_fixture();
    let parsed = parse(&trace);
    let outer =
        parsed.events.iter().find(|event| event.name == "ThreadControllerImpl::RunTask").unwrap();
    assert_eq!(outer.t, (2_000i64 + CHROMIUM_OFFSET_NS) as u64);
    assert_eq!(outer.clock, MONOTONIC_RAW);
    let main: Vec<&Event> =
        parsed.events.iter().filter(|event| event.track == outer.track).collect();
    let order: Vec<(u64, &str)> =
        main.iter().map(|event| (event.kind, event.name.as_str())).collect();
    assert_eq!(
        order,
        [(BEGIN, "ThreadControllerImpl::RunTask"), (BEGIN, "RunTask"), (END, ""), (END, "")],
        "a complete event written after its child still opens first"
    );
    let run = main[1];
    assert_eq!(
        run.args,
        [("src".to_owned(), "string a.cc".to_owned()), ("n".to_owned(), "int 3".to_owned())]
    );
    let latency: Vec<&Event> =
        parsed.events.iter().filter(|event| event.categories == ["latency"]).collect();
    let begin_tracks: Vec<u64> =
        latency.iter().filter(|event| event.kind == BEGIN).map(|event| event.track).collect();
    assert_eq!(begin_tracks.len(), 2);
    assert_ne!(
        begin_tracks[0], begin_tracks[1],
        "EventLatency ids 1 and 2 overlap on their own tracks"
    );
    let nested = latency.iter().find(|event| !event.args.is_empty()).expect("the end with args");
    assert_eq!(nested.args, [("nested".to_owned(), r#"json {"a":[1]}"#.to_owned())]);
    let counters: Vec<(String, f64)> = parsed
        .events
        .iter()
        .filter(|event| event.kind == COUNTER)
        .map(|event| (track_name(&parsed, event.track).unwrap(), event.counter.unwrap()))
        .collect();
    assert!(counters.contains(&("Heap.used".into(), 10.5)));
    assert!(counters.contains(&("Heap.total".into(), 20.0)));
    assert!(counters.contains(&("frame.sequence 4".into(), -5.0)), "a ring counter keeps its sign");
    let global = parsed.events.iter().find(|event| event.name == "Mark").unwrap();
    assert_eq!(
        parsed.tracks[&global.track].uint(TD_PARENT),
        None,
        "a global instant has no process"
    );
    assert_eq!(stats.chromium_events, 13);
    assert_eq!(stats.chromium_skipped, 1, "the object event");
}

/// Zero-length Chromium slices: a `dur: 0` X inside a parent, one at the top level, and a B/E pair
/// at one timestamp, each followed by a slice that must stay at depth 0; an instant at a slice's
/// begin is inside it.
const CHROMIUM_ZERO_LENGTH: &str = r#"[
 {"ph":"X","pid":7,"tid":1,"ts":0,"dur":10,"name":"Parent"},
 {"ph":"X","pid":7,"tid":1,"ts":5,"dur":0,"name":"Child"},
 {"ph":"X","pid":7,"tid":1,"ts":20,"dur":0,"name":"Top"},
 {"ph":"B","pid":7,"tid":1,"ts":30,"name":"Pair"},
 {"ph":"E","pid":7,"tid":1,"ts":30},
 {"ph":"i","pid":7,"tid":1,"ts":40,"name":"AtBegin","s":"t"},
 {"ph":"X","pid":7,"tid":1,"ts":40,"dur":5,"name":"Later"}
]"#;

/// `json` merged with the app's ring, whose header ties the trace clock to BOOTTIME and REALTIME.
fn export_chromium(json: &str) -> (Vec<u8>, ExportStats) {
    let app = app_ring();
    let rings = [RingInput { ring: &app, machine: Machine::Local }];
    let chromium = [ChromiumInput { json: json.as_bytes(), offset_ns: 0 }];
    let mut trace = Vec::new();
    let input = ExportInput { remotes: &[], rings: &rings, chromium: &chromium };
    let stats = export(&input, &mut trace).expect("exports");
    (trace, stats)
}

/// Each slice of one track as (name, begin, end, depth), from its begin and end events in order.
fn slices(events: &[&Event]) -> Vec<(String, u64, u64, usize)> {
    let mut open: Vec<usize> = Vec::new();
    let mut out: Vec<(String, u64, u64, usize)> = Vec::new();
    for event in events {
        match event.kind {
            BEGIN => {
                open.push(out.len());
                out.push((event.name.clone(), event.t, u64::MAX, open.len() - 1));
            }
            END => out[open.pop().expect("every end has its begin")].2 = event.t,
            _ => {}
        }
    }
    assert!(open.is_empty(), "every begin has its end");
    out
}

#[test]
fn export_chromium_zero_length_slices_close_themselves() {
    let (trace, stats) = export_chromium(CHROMIUM_ZERO_LENGTH);
    assert_eq!(stats.unmatched_ends, 1, "only the app ring's lost begin");
    let parsed = parse(&trace);
    let chromium = parsed.events.iter().find(|event| event.name == "Parent").unwrap().track;
    let events: Vec<&Event> =
        parsed.events.iter().filter(|event| event.track == chromium).collect();
    assert_eq!(
        slices(&events),
        [
            ("Parent".to_owned(), 0, 10_000, 0),
            ("Child".to_owned(), 5_000, 5_000, 1),
            ("Top".to_owned(), 20_000, 20_000, 0),
            ("Pair".to_owned(), 30_000, 30_000, 0),
            ("Later".to_owned(), 40_000, 45_000, 0),
        ]
    );
    let order: Vec<&str> =
        events.iter().filter(|event| event.t == 40_000).map(|event| event.name.as_str()).collect();
    assert_eq!(order, ["Later", "AtBegin"], "an instant at a slice's begin is inside it");
}

#[test]
fn export_estimated_instant_is_marked() {
    let (trace, _) = export_fixture();
    let parsed = parse(&trace);
    let present =
        parsed.events.iter().find(|event| event.name == "frame.present_estimate").unwrap();
    assert!(present.args.contains(&("estimated".to_owned(), "bool 1".to_owned())));
    assert!(present.args.contains(&("arg0".to_owned(), "uint 60".to_owned())));
}

#[test]
fn export_bad_chromium_json_is_an_error() {
    let app = app_ring();
    let rings = [RingInput { ring: &app, machine: Machine::Local }];
    let chromium = [ChromiumInput { json: b"{\"traceEvents\": [", offset_ns: 0 }];
    let input = ExportInput { remotes: &[], rings: &rings, chromium: &chromium };
    let error = export(&input, &mut Vec::new()).expect_err("truncated JSON");
    assert!(error.to_string().starts_with("Chromium trace 0 is not a JSON trace"), "{error}");
    let input = ExportInput {
        remotes: &[],
        rings: &[RingInput { ring: &app, machine: Machine::Remote(3) }],
        chromium: &[],
    };
    assert!(matches!(
        export(&input, &mut Vec::new()),
        Err(cmux_trace::ExportError::UnknownRemote(3))
    ));
}

#[test]
fn export_golden_dump_does_not_drift() {
    let (trace, _) = export_fixture();
    let text = dump(&parse(&trace));
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/export-golden.txt");
    if std::env::var_os("CMUX_TRACE_UPDATE_GOLDEN").is_some() {
        std::fs::write(&path, &text).expect("writes the golden dump");
    }
    let golden = std::fs::read_to_string(&path)
        .expect("the golden dump (CMUX_TRACE_UPDATE_GOLDEN=1 writes it)");
    assert_eq!(
        text, golden,
        "the export changed: review the diff, then CMUX_TRACE_UPDATE_GOLDEN=1"
    );
}

/// Perfetto's `trace_processor_shell`: `CMUX_TRACE_PROCESSOR`, else `trace_processor_shell` on
/// `PATH`, else the newest one the Perfetto Python package downloaded. Panics when there is none:
/// the tests that need it are `#[ignore]`d, so running them means checking the import.
fn trace_processor_shell() -> PathBuf {
    if let Some(shell) = std::env::var_os("CMUX_TRACE_PROCESSOR") {
        return PathBuf::from(shell);
    }
    let on_path = std::env::var_os("PATH").into_iter().flat_map(|path| {
        std::env::split_paths(&path)
            .map(|dir| dir.join("trace_processor_shell"))
            .collect::<Vec<_>>()
    });
    let prebuilts = std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(".local/share/perfetto/prebuilts"))
        .and_then(|dir| std::fs::read_dir(dir).ok())
        .into_iter()
        .flatten()
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("trace_processor_shell"))
        })
        .max_by_key(|path| std::fs::metadata(path).and_then(|meta| meta.modified()).ok());
    on_path.chain(prebuilts).find(|path| path.is_file()).unwrap_or_else(|| {
        panic!(
            "no trace_processor_shell: set CMUX_TRACE_PROCESSOR, put it on PATH, or run \
             `python3 -m pip install perfetto` and load a trace once"
        )
    })
}

/// Runs `sql` queries on `trace` with [`trace_processor_shell`]. Asserts the import had no error
/// or data loss.
fn trace_processor(name: &str, trace: &[u8], queries: &[&str]) -> Vec<String> {
    let shell = trace_processor_shell();
    let dir = std::env::temp_dir().join(format!("cmux-trace-export-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("scratch dir");
    let file = dir.join("export.perfetto-trace");
    std::fs::write(&file, trace).expect("writes the trace");
    let query = |sql: &str| -> String {
        let output = std::process::Command::new(&shell)
            .arg("-Q")
            .arg(sql)
            .arg(&file)
            .output()
            .expect("runs trace_processor_shell");
        assert!(
            output.status.success(),
            "trace_processor failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        String::from_utf8_lossy(&output.stdout).into_owned()
    };
    let errors = query(
        "select 'stat:' || name || '=' || value as e from stats \
         where (severity = 'error' or severity = 'data_loss') and value > 0",
    );
    assert!(!errors.lines().any(|line| line.contains("stat:")), "import errors:\n{errors}");
    let answers = queries.iter().map(|sql| query(sql)).collect();
    let _ = std::fs::remove_dir_all(dir);
    answers
}

/// The one number a `select ... as n` query printed.
fn number(answer: &str) -> u64 {
    answer.lines().filter_map(|line| line.trim().trim_matches('"').parse().ok()).next().unwrap_or(0)
}

/// The import check: 0 import errors, the two create.tab slices on two tracks, the flows (into
/// the remote daemon too), and the remote daemon's slice on the local clock.
#[test]
#[ignore = "needs Perfetto's trace_processor_shell: cargo test -p cmux-trace --test export -- --include-ignored"]
fn trace_processor_imports_the_export_with_no_errors() {
    let (trace, _) = export_fixture();
    let queries = [
        "select count(*) || ' ' || count(distinct track_id) as n from slice where name = 'create.tab'",
        "select so.name || '@' || so.ts || ' -> ' || si.name || '@' || si.ts as hop from flow f \
         join slice so on so.id = f.slice_out join slice si on si.id = f.slice_in order by so.ts",
        "select ts as n from slice where name = 'daemon.request'",
    ];
    let answers = trace_processor("fixture", &trace, &queries);
    assert!(answers[0].contains("\"2 2\""), "two create.tab slices on two tracks:\n{}", answers[0]);
    let hops: Vec<&str> = answers[1].lines().skip(1).map(|line| line.trim_matches('"')).collect();
    assert_eq!(
        hops,
        [
            "key.flow@1160 -> key.flow@1180",
            "key.flow@1190 -> key.flow@1400",
            "ThreadControllerImpl::RunTask@1500 -> Receive@3500"
        ],
        "main to io, io to the remote daemon, Chromium's"
    );
    assert_eq!(number(&answers[2]), 1_450, "the remote daemon's slice, on the local clock");
}

/// Flows that reuse an id: two arrows, not a chain through the first arrival.
#[test]
#[ignore = "needs Perfetto's trace_processor_shell: cargo test -p cmux-trace --test export -- --include-ignored"]
fn trace_processor_ends_a_flow_where_it_arrives() {
    let ring = reused_flow_ring();
    let (trace, _) = export_rings(&[RingInput { ring: &ring, machine: Machine::Local }], &[]);
    let answers = trace_processor(
        "reused-flow",
        &trace,
        &[
            "select count(*) as n from flow",
            "select count(*) as n from flow f \
           join slice s on f.slice_out = s.id where s.ts = 1100",
        ],
    );
    assert_eq!(number(&answers[0]), 2);
    assert_eq!(number(&answers[1]), 0, "the first arrival starts no flow");
}

/// A remote process and thread with a local one's pid and tid stay apart.
#[test]
#[ignore = "needs Perfetto's trace_processor_shell: cargo test -p cmux-trace --test export -- --include-ignored"]
fn trace_processor_keeps_a_remote_machine_apart() {
    let (local, remote) = same_pid_rings();
    let rings = [
        RingInput { ring: &local, machine: Machine::Local },
        RingInput { ring: &remote, machine: Machine::Remote(0) },
    ];
    let (trace, _) = export_rings(&rings, &[lane()]);
    let answers = trace_processor(
        "same-pid",
        &trace,
        &[
            "select group_concat(name, ',') as n from process where pid = 4321",
            "select group_concat(name, ',') as n from thread where tid = 303",
            "select coalesce(t.name, '-') || ' ' || s.ts as n from slice s \
             join track t on t.id = s.track_id where s.name = 'daemon.request'",
        ],
    );
    assert!(answers[0].lines().any(|line| line == "\"app\""), "{}", answers[0]);
    assert!(answers[1].lines().any(|line| line == "\"main\""), "{}", answers[1]);
    assert!(
        answers[2].contains("\"mux-control-dispatch 303 1450\""),
        "the remote slice on its own track, on the local clock:\n{}",
        answers[2]
    );
}

/// The Chromium zero-length slices: no slice left open (dur = -1), each later slice at depth 0.
#[test]
#[ignore = "needs Perfetto's trace_processor_shell: cargo test -p cmux-trace --test export -- --include-ignored"]
fn trace_processor_reads_zero_length_chromium_slices() {
    let (trace, _) = export_chromium(CHROMIUM_ZERO_LENGTH);
    let answers = trace_processor(
        "zero-length",
        &trace,
        &[
            "select count(*) as n from slice where dur < 0",
            "select group_concat(name || ':' || depth || ':' || dur, ',') as n from \
             (select s.* from slice s join thread_track tt on s.track_id = tt.id \
              join thread t using(utid) where t.tid = 1 order by s.ts, s.depth)",
        ],
    );
    assert_eq!(number(&answers[0]), 0, "no slice left open");
    assert!(
        answers[1].contains("Parent:0:10000,Child:1:0,Top:0:0,Pair:0:0,Later:0:5000"),
        "{}",
        answers[1]
    );
}

/// A black box that wrapped many times under four writers: begins lost to the overwrite, ends
/// still open, overlapping async intervals. The export drops the ends it cannot match.
fn wrapped_black_box_export() -> Vec<u8> {
    let tracer = tracer(Role::App, 2222);
    std::thread::scope(|scope| {
        for thread in 1..=4u64 {
            let tracer = &tracer;
            scope.spawn(move || {
                let mut writer = Writer::new(
                    tracer,
                    ThreadIdentity::new(100 + thread, 0x19, &format!("w{thread}")),
                );
                for index in 0..20_000u64 {
                    let t = index * 10 + thread;
                    let async_id = thread << 32 | index;
                    writer.write(record(t, "action.perform", Phase::Begin, 0, index, 0));
                    writer.write(record(
                        t + 1,
                        "create.tab",
                        Phase::AsyncBegin,
                        FLAG_ID,
                        0,
                        async_id,
                    ));
                    writer.write(record(t + 2, "key.flow", Phase::FlowOut, 0, 0, async_id));
                    writer.write(record(t + 3, "action.perform", Phase::End, 0, 0, 0));
                    writer.write(record(
                        t + 15,
                        "create.tab",
                        Phase::AsyncEnd,
                        FLAG_ID,
                        0,
                        async_id,
                    ));
                }
            });
        }
    });
    let ring = decode(&tracer.snapshot_active()).expect("decodes");
    assert!(ring.header.chunks_overwritten > 0, "the black box wrapped");
    let rings = [RingInput { ring: &ring, machine: Machine::Local }];
    let mut trace = Vec::new();
    let stats = export(&ExportInput { remotes: &[], rings: &rings, chromium: &[] }, &mut trace)
        .expect("exports");
    let parsed = parse(&trace);
    assert_eq!(stats.invalid_records, 0);
    let begins = parsed.events.iter().filter(|event| event.kind == BEGIN).count() as u64;
    let ends = parsed.events.iter().filter(|event| event.kind == END).count() as u64;
    assert!(ends <= begins, "every end written has its begin");
    assert_eq!(begins, stats.slices);
    trace
}

#[test]
fn export_a_wrapped_black_box_drops_the_ends_it_cannot_match() {
    wrapped_black_box_export();
}

#[test]
#[ignore = "needs Perfetto's trace_processor_shell: cargo test -p cmux-trace --test export -- --include-ignored"]
fn trace_processor_imports_a_wrapped_black_box_cleanly() {
    let trace = wrapped_black_box_export();
    let answers =
        trace_processor("wrapped", &trace, &["select count(*) as n from slice where dur < -1"]);
    assert_eq!(number(&answers[0]), 0, "no slice with a negative duration");
}
