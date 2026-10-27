//! The native Perfetto exporter: decoded rings (and Chromium's JSON trace) to one `.perfetto-trace`
//! file, the protobuf `Trace` that ui.perfetto.dev and `trace_processor` read.
//!
//! The output follows what the Perfetto SDK's track-event data source writes
//! (`include/perfetto/tracing/track_event.h`, `src/tracing/track_event_state_tracker.cc`):
//!
//! - One `TrackDescriptor` per process (its role, build and machine), per thread (its name, and its
//!   QoS in the description), per async track and per counter track, each once.
//! - One packet sequence per ring. Its first packet clears the incremental state and interns the
//!   ring's name table (`InternedData.event_names`, iid = the ring's name id), its categories and
//!   the argument names; every event refers to them by iid, as the SDK's `TrackEventInternedDataIndex`.
//! - `B`/`E` are slices on the thread's track; an `E` with no open slice (its `B` was overwritten in
//!   the black box) is dropped and counted. `I` is an instant. `b`/`e` (AB/AE) go on an async track
//!   whose uuid is a hash of (machine, pid, name, async id): Chrome's
//!   `TRACE_EVENT_NESTABLE_ASYNC_*` over `perfetto::Track(uuid)`, so overlapping intervals of one
//!   name never misnest. `s` is an instant carrying `flow_ids` and `f` one carrying
//!   `terminating_flow_ids` (Perfetto's `Flow` and `TerminatingFlow`), joined across threads,
//!   processes and machines by the flow id; an id used again after its `f` is a new flow. `C` is
//!   a counter sample on a track per (name, track id).
//! - One `ClockSnapshot` per machine. The local machine's trace clock (`CLOCK_UPTIME_RAW` on macOS)
//!   is the primary trace clock; its snapshot ties it to `BOOTTIME` (the ring's
//!   `start_continuous_ns`, read with `start_uptime_ns`) and `REALTIME` (`start_unix_ns`). A remote
//!   machine (task 116) gets its own clock id, tied to the local clock by its measured offset.
//! - A remote machine's processes and threads are named tracks (`"daemon 4321 on linux-lane"`,
//!   `"<thread> <tid>"`), not pid and tid descriptors: trace_processor resolves those on one
//!   machine, so a remote pid or tid equal to a local one would join the local process or thread.
//!   `TracePacket.machine_id` would keep them apart too, but trace_processor (v58) joins flows
//!   only within one machine, and a key's flow crosses into the remote daemon.
//! - Chromium's JSON trace ([`ChromiumInput`]) is merged on the local clock after its measured
//!   offset ([`chromium`]).
//!
//! It reads only the decoded rings: no clock, file or process of its own.

mod chromium;
mod ring;
mod tracks;

use std::io::{self, Write};

use crate::clock::ClockDomain;
use crate::decode::Decoded;
use crate::json::JsonError;
use crate::proto::Message;
use ring::RingExport;
use tracks::Tracks;

/// Field numbers and enum values, from Perfetto's protos (`protos/perfetto/trace/...`, v58).
pub(crate) mod field {
    // trace.proto: Trace.
    pub const TRACE_PACKET: u32 = 1;
    // trace_packet.proto: TracePacket.
    pub const TIMESTAMP: u32 = 8;
    pub const TIMESTAMP_CLOCK_ID: u32 = 58;
    pub const CLOCK_SNAPSHOT: u32 = 6;
    pub const TRACK_EVENT: u32 = 11;
    pub const TRACK_DESCRIPTOR: u32 = 60;
    pub const TRUSTED_PACKET_SEQUENCE_ID: u32 = 10;
    pub const INTERNED_DATA: u32 = 12;
    pub const SEQUENCE_FLAGS: u32 = 13;
    pub const SEQ_INCREMENTAL_STATE_CLEARED: u64 = 1;
    pub const SEQ_NEEDS_INCREMENTAL_STATE: u64 = 2;
    // clock_snapshot.proto: ClockSnapshot, ClockSnapshot.Clock; builtin_clock.proto.
    pub const SNAPSHOT_CLOCKS: u32 = 1;
    pub const SNAPSHOT_PRIMARY_TRACE_CLOCK: u32 = 2;
    pub const CLOCK_ID: u32 = 1;
    pub const CLOCK_TIMESTAMP: u32 = 2;
    pub const BUILTIN_CLOCK_REALTIME: u32 = 1;
    pub const BUILTIN_CLOCK_MONOTONIC: u32 = 3;
    pub const BUILTIN_CLOCK_MONOTONIC_RAW: u32 = 5;
    pub const BUILTIN_CLOCK_BOOTTIME: u32 = 6;
    // track_descriptor.proto: TrackDescriptor.
    pub const TRACK_UUID: u32 = 1;
    pub const TRACK_NAME: u32 = 2;
    pub const TRACK_PROCESS: u32 = 3;
    pub const TRACK_THREAD: u32 = 4;
    pub const TRACK_PARENT_UUID: u32 = 5;
    pub const TRACK_COUNTER: u32 = 8;
    pub const TRACK_DESCRIPTION: u32 = 14;
    // process_descriptor.proto: ProcessDescriptor.
    pub const PROCESS_PID: u32 = 1;
    pub const PROCESS_NAME: u32 = 6;
    pub const PROCESS_LABELS: u32 = 8;
    // thread_descriptor.proto: ThreadDescriptor.
    pub const THREAD_PID: u32 = 1;
    pub const THREAD_TID: u32 = 2;
    pub const THREAD_NAME: u32 = 5;
    // track_event.proto: TrackEvent.
    pub const EVENT_CATEGORY_IIDS: u32 = 3;
    pub const EVENT_DEBUG_ANNOTATIONS: u32 = 4;
    pub const EVENT_TYPE: u32 = 9;
    pub const EVENT_NAME_IID: u32 = 10;
    pub const EVENT_TRACK_UUID: u32 = 11;
    pub const EVENT_CATEGORIES: u32 = 22;
    pub const EVENT_NAME: u32 = 23;
    pub const EVENT_COUNTER_VALUE: u32 = 30;
    pub const EVENT_DOUBLE_COUNTER_VALUE: u32 = 44;
    pub const EVENT_FLOW_IDS: u32 = 47;
    pub const EVENT_TERMINATING_FLOW_IDS: u32 = 48;
    pub const TYPE_SLICE_BEGIN: u64 = 1;
    pub const TYPE_SLICE_END: u64 = 2;
    pub const TYPE_INSTANT: u64 = 3;
    pub const TYPE_COUNTER: u64 = 4;
    // interned_data.proto: InternedData; EventName, EventCategory, DebugAnnotationName.
    pub const INTERNED_EVENT_CATEGORIES: u32 = 1;
    pub const INTERNED_EVENT_NAMES: u32 = 2;
    pub const INTERNED_DEBUG_ANNOTATION_NAMES: u32 = 3;
    pub const INTERNED_IID: u32 = 1;
    pub const INTERNED_NAME: u32 = 2;
    // debug_annotation.proto: DebugAnnotation.
    pub const ANNOTATION_NAME_IID: u32 = 1;
    pub const ANNOTATION_BOOL: u32 = 2;
    pub const ANNOTATION_UINT: u32 = 3;
    pub const ANNOTATION_INT: u32 = 4;
    pub const ANNOTATION_DOUBLE: u32 = 5;
    pub const ANNOTATION_STRING: u32 = 6;
    pub const ANNOTATION_LEGACY_JSON: u32 = 9;
    pub const ANNOTATION_NAME: u32 = 10;
}

/// A machine other than the one the recording ran on (task 116): its rings are on its own clock.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RemoteMachine {
    /// How the machine is shown (a host name).
    pub name: String,
    /// Its trace clock minus the local trace clock at the same instant, in ns (the min-RTT estimate).
    pub offset_ns: i64,
    /// The offset's error bound, in ns.
    pub error_bound_ns: u64,
}

/// Which machine a ring was recorded on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Machine {
    Local,
    /// An index into [`ExportInput::remotes`].
    Remote(usize),
}

/// One decoded ring and the machine it came from.
#[derive(Clone, Copy, Debug)]
pub struct RingInput<'a> {
    pub ring: &'a Decoded,
    pub machine: Machine,
}

/// A Chromium JSON trace (`{"traceEvents": [...]}` or a bare array) from the local machine.
#[derive(Clone, Copy, Debug)]
pub struct ChromiumInput<'a> {
    pub json: &'a [u8],
    /// Added to Chromium's timestamps (µs as ns) to put them on the local trace clock, in ns: the
    /// offset the CEF shim measured (task 050). 0 when Chromium's clock is the trace clock
    /// (`base::TimeTicks` is `mach_absolute_time` on macOS).
    pub offset_ns: i64,
}

/// Everything one export reads.
#[derive(Clone, Copy, Debug, Default)]
pub struct ExportInput<'a> {
    pub remotes: &'a [RemoteMachine],
    pub rings: &'a [RingInput<'a>],
    pub chromium: &'a [ChromiumInput<'a>],
}

/// What an export wrote and what it left out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ExportStats {
    pub packets: u64,
    pub tracks: u64,
    pub slices: u64,
    pub instants: u64,
    pub counters: u64,
    /// Events that carry a flow id.
    pub flow_events: u64,
    /// `E`/`AE` records (or Chromium `E`/`e` events) with no open slice on their track: dropped.
    pub unmatched_ends: u64,
    /// Records with a phase this exporter does not know: dropped.
    pub invalid_records: u64,
    pub chromium_events: u64,
    /// Chromium events of a phase this exporter does not convert (objects, samples, marks).
    pub chromium_skipped: u64,
}

/// Why an export failed.
#[derive(Debug)]
pub enum ExportError {
    Io(io::Error),
    /// A Chromium trace that is not JSON, or has no event array.
    ChromiumJson {
        input: usize,
        error: JsonError,
    },
    /// A ring names a remote machine that [`ExportInput::remotes`] does not have.
    UnknownRemote(usize),
    /// Local rings on two clock domains (rings from two machines both passed as local).
    MixedLocalClocks {
        first: u8,
        other: u8,
    },
}

impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExportError::Io(error) => write!(f, "writing the Perfetto trace failed: {error}"),
            ExportError::ChromiumJson { input, error } => {
                write!(f, "Chromium trace {input} is not a JSON trace: {error}")
            }
            ExportError::UnknownRemote(index) => {
                write!(f, "a ring names remote machine {index}, which is not given")
            }
            ExportError::MixedLocalClocks { first, other } => {
                write!(
                    f,
                    "local rings use clock domains {first} and {other}: pass one machine's rings as local"
                )
            }
        }
    }
}

impl std::error::Error for ExportError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            ExportError::Io(error) => Some(error),
            ExportError::ChromiumJson { error, .. } => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for ExportError {
    fn from(error: io::Error) -> ExportError {
        ExportError::Io(error)
    }
}

/// The sequence the clock snapshots and track descriptors go on; rings and Chromium traces follow.
const EXPORTER_SEQUENCE: u32 = 1;

/// Writes the Perfetto trace of `input` to `out`.
pub fn export(input: &ExportInput<'_>, out: &mut impl Write) -> Result<ExportStats, ExportError> {
    let clocks = Clocks::of(input)?;
    let mut builder = Builder::new(clocks);
    for (index, ring) in input.rings.iter().enumerate() {
        let remote = match ring.machine {
            Machine::Local => None,
            Machine::Remote(remote) => input.remotes.get(remote),
        };
        RingExport::new(&mut builder, ring, remote)
            .run(&mut builder, EXPORTER_SEQUENCE + 1 + index as u32);
    }
    for (index, trace) in input.chromium.iter().enumerate() {
        let sequence = EXPORTER_SEQUENCE + 1 + (input.rings.len() + index) as u32;
        chromium::merge(&mut builder, trace, sequence)
            .map_err(|error| ExportError::ChromiumJson { input: index, error })?;
    }
    builder.finish(out)
}

/// Each machine's clock id, and what its snapshot ties together.
#[derive(Clone, Debug)]
pub(crate) struct Clocks {
    /// The local trace clock's builtin id: the primary trace clock.
    local: u32,
    /// Index by remote machine: (clock id, snapshot time on its clock, the same instant locally).
    remotes: Vec<Option<(u32, u64, u64)>>,
    /// The local snapshot: the ring header the local clock is tied to BOOTTIME and REALTIME by.
    local_start: Option<(u64, u64, u64)>,
}

impl Clocks {
    fn of(input: &ExportInput<'_>) -> Result<Clocks, ExportError> {
        let mut domain: Option<u8> = None;
        let mut local_start: Option<(u64, u64, u64)> = None;
        let mut remotes = vec![None; input.remotes.len()];
        for ring in input.rings {
            let header = &ring.ring.header;
            match ring.machine {
                Machine::Local => {
                    match domain {
                        Some(first) if first != header.clock_domain => {
                            return Err(ExportError::MixedLocalClocks {
                                first,
                                other: header.clock_domain,
                            });
                        }
                        _ => domain = Some(header.clock_domain),
                    }
                    // The latest start: the pair read nearest the recording, past any sleep before it.
                    if local_start.is_none_or(|(uptime, _, _)| header.start_uptime_ns > uptime) {
                        local_start = Some((
                            header.start_uptime_ns,
                            header.start_continuous_ns,
                            header.start_unix_ns,
                        ));
                    }
                }
                Machine::Remote(index) => {
                    let remote =
                        input.remotes.get(index).ok_or(ExportError::UnknownRemote(index))?;
                    if remotes[index].is_none() {
                        remotes[index] =
                            Some(remote_snapshot(index, remote, header.start_uptime_ns));
                    }
                }
            }
        }
        let domain = domain.and_then(ClockDomain::from_raw).unwrap_or(ClockDomain::CURRENT);
        Ok(Clocks { local: builtin_clock(domain), remotes, local_start })
    }

    fn of_machine(&self, machine: Machine) -> u32 {
        match machine {
            Machine::Local => self.local,
            Machine::Remote(index) => self.remotes[index].map_or(self.local, |(id, _, _)| id),
        }
    }
}

/// The builtin clock a local domain is: macOS `CLOCK_UPTIME_RAW` (`mach_absolute_time`) and the
/// Windows performance counter are raw monotonic clocks; Linux records `CLOCK_MONOTONIC`.
fn builtin_clock(domain: ClockDomain) -> u32 {
    match domain {
        ClockDomain::UptimeRaw | ClockDomain::Qpc => field::BUILTIN_CLOCK_MONOTONIC_RAW,
        ClockDomain::Monotonic => field::BUILTIN_CLOCK_MONOTONIC,
    }
}

/// A remote machine's clock id and one instant on both clocks. Ids at or above 128 are global
/// (`clock_snapshot.proto`); the reserved scheme is a multiple of 128, so remote `k` is `128 * (k + 1)`.
fn remote_snapshot(index: usize, remote: &RemoteMachine, start_ns: u64) -> (u32, u64, u64) {
    let id = 128 * (index as u32 + 1);
    // remote = local + offset; keep both instants at or after 0.
    let remote_ns = start_ns.max(u64::try_from(remote.offset_ns).unwrap_or(0));
    let local_ns = (i128::from(remote_ns) - i128::from(remote.offset_ns)).max(0) as u64;
    (id, remote_ns, local_ns)
}

/// One packet sequence's buffered packets.
pub(crate) struct Sequence {
    id: u32,
    clock: u32,
    bytes: Vec<u8>,
    first: bool,
}

/// Collects tracks and events; [`Builder::finish`] writes them in order: clocks, tracks, events.
pub(crate) struct Builder {
    clocks: Clocks,
    pub(crate) tracks: Tracks,
    pub(crate) stats: ExportStats,
    sequences: Vec<Sequence>,
    packet: Message,
    event: Message,
}

/// One TrackEvent, before it is encoded.
#[derive(Default)]
pub(crate) struct Event<'a> {
    pub kind: u64,
    pub track: u64,
    pub name_iid: Option<u64>,
    pub name: Option<&'a str>,
    pub category_iid: Option<u64>,
    pub categories: Option<&'a str>,
    pub counter: Option<CounterValue>,
    pub flow_ids: Option<u64>,
    pub terminating_flow_ids: Option<u64>,
}

#[derive(Clone, Copy)]
pub(crate) enum CounterValue {
    Int(i64),
    Double(f64),
}

impl Builder {
    fn new(clocks: Clocks) -> Builder {
        Builder {
            clocks,
            tracks: Tracks::default(),
            stats: ExportStats::default(),
            sequences: Vec::new(),
            packet: Message::new(),
            event: Message::new(),
        }
    }

    pub(crate) fn sequence(&mut self, id: u32, machine: Machine) -> usize {
        let clock = self.clocks.of_machine(machine);
        self.sequences.push(Sequence { id, clock, bytes: Vec::new(), first: true });
        self.sequences.len() - 1
    }

    /// Appends one TrackEvent packet at `t_ns` to `sequence`. `interned` writes the sequence's
    /// interned data into its first packet; `args` writes the event's debug annotations.
    pub(crate) fn emit(
        &mut self,
        sequence: usize,
        t_ns: u64,
        event: &Event<'_>,
        interned: Option<&dyn Fn(&mut Message)>,
        args: &dyn Fn(&mut Message),
    ) {
        match event.kind {
            field::TYPE_SLICE_BEGIN => self.stats.slices += 1,
            field::TYPE_INSTANT => self.stats.instants += 1,
            field::TYPE_COUNTER => self.stats.counters += 1,
            _ => {}
        }
        if event.flow_ids.is_some() || event.terminating_flow_ids.is_some() {
            self.stats.flow_events += 1;
        }
        let seq = &mut self.sequences[sequence];
        let (first, id, clock) = (seq.first, seq.id, seq.clock);
        seq.first = false;
        self.event.clear();
        encode_event(&mut self.event, event, args);
        self.packet.clear();
        self.packet
            .uint(field::TIMESTAMP, t_ns)
            .uint(field::TIMESTAMP_CLOCK_ID, u64::from(clock))
            .uint(field::TRUSTED_PACKET_SEQUENCE_ID, u64::from(id));
        let flags = if first { field::SEQ_INCREMENTAL_STATE_CLEARED } else { 0 };
        self.packet.uint(field::SEQUENCE_FLAGS, flags | field::SEQ_NEEDS_INCREMENTAL_STATE);
        if let (true, Some(interned)) = (first, interned) {
            self.packet.message(field::INTERNED_DATA, |data| interned(data));
        }
        self.packet.bytes(field::TRACK_EVENT, self.event.as_bytes());
        let bytes = &mut self.sequences[sequence].bytes;
        push_packet(bytes, self.packet.as_bytes());
        self.stats.packets += 1;
    }

    fn finish(mut self, out: &mut impl Write) -> Result<ExportStats, ExportError> {
        let mut packet = Message::new();
        let mut header = Vec::new();
        self.clock_snapshots(&mut packet, &mut header);
        for (uuid, track) in self.tracks.iter() {
            packet.clear();
            packet.uint(field::TRUSTED_PACKET_SEQUENCE_ID, u64::from(EXPORTER_SEQUENCE));
            packet.message(field::TRACK_DESCRIPTOR, |descriptor| {
                tracks::encode(descriptor, uuid, track);
            });
            push_packet(&mut header, packet.as_bytes());
            self.stats.packets += 1;
            self.stats.tracks += 1;
        }
        out.write_all(&header)?;
        for sequence in &self.sequences {
            out.write_all(&sequence.bytes)?;
        }
        out.flush()?;
        Ok(self.stats)
    }

    fn clock_snapshots(&mut self, packet: &mut Message, out: &mut Vec<u8>) {
        let local = self.clocks.local;
        let (uptime, continuous, unix) = self.clocks.local_start.unwrap_or((0, 0, 0));
        packet.clear();
        packet.uint(field::TRUSTED_PACKET_SEQUENCE_ID, u64::from(EXPORTER_SEQUENCE));
        packet.message(field::CLOCK_SNAPSHOT, |snapshot| {
            clock(snapshot, local, uptime);
            if self.clocks.local_start.is_some() {
                if continuous != 0 && local != field::BUILTIN_CLOCK_BOOTTIME {
                    clock(snapshot, field::BUILTIN_CLOCK_BOOTTIME, continuous);
                }
                if unix != 0 {
                    clock(snapshot, field::BUILTIN_CLOCK_REALTIME, unix);
                }
            }
            snapshot.uint(field::SNAPSHOT_PRIMARY_TRACE_CLOCK, u64::from(local));
        });
        push_packet(out, packet.as_bytes());
        self.stats.packets += 1;
        for &(id, remote_ns, local_ns) in self.clocks.remotes.iter().flatten() {
            packet.clear();
            packet.uint(field::TRUSTED_PACKET_SEQUENCE_ID, u64::from(EXPORTER_SEQUENCE));
            packet.message(field::CLOCK_SNAPSHOT, |snapshot| {
                clock(snapshot, id, remote_ns);
                clock(snapshot, local, local_ns);
                snapshot.uint(field::SNAPSHOT_PRIMARY_TRACE_CLOCK, u64::from(local));
            });
            push_packet(out, packet.as_bytes());
            self.stats.packets += 1;
        }
    }
}

fn clock(snapshot: &mut Message, id: u32, timestamp: u64) {
    snapshot.message(field::SNAPSHOT_CLOCKS, |clock| {
        clock.uint(field::CLOCK_ID, u64::from(id)).uint(field::CLOCK_TIMESTAMP, timestamp);
    });
}

/// Appends `packet` as `Trace.packet`.
fn push_packet(out: &mut Vec<u8>, packet: &[u8]) {
    crate::proto::push_varint(out, u64::from(field::TRACE_PACKET) << 3 | 2);
    crate::proto::push_varint(out, packet.len() as u64);
    out.extend_from_slice(packet);
}

fn encode_event(message: &mut Message, event: &Event<'_>, args: &dyn Fn(&mut Message)) {
    message.uint(field::EVENT_TYPE, event.kind).uint(field::EVENT_TRACK_UUID, event.track);
    if let Some(iid) = event.category_iid {
        message.uint(field::EVENT_CATEGORY_IIDS, iid);
    }
    for category in event.categories.into_iter().flat_map(|text| text.split(',')) {
        if !category.is_empty() {
            message.string(field::EVENT_CATEGORIES, category);
        }
    }
    if let Some(iid) = event.name_iid {
        message.uint(field::EVENT_NAME_IID, iid);
    } else if let Some(name) = event.name {
        message.string(field::EVENT_NAME, name);
    }
    match event.counter {
        Some(CounterValue::Int(value)) => {
            message.int(field::EVENT_COUNTER_VALUE, value);
        }
        Some(CounterValue::Double(value)) => {
            message.double(field::EVENT_DOUBLE_COUNTER_VALUE, value);
        }
        None => {}
    }
    if let Some(id) = event.flow_ids {
        message.fixed64(field::EVENT_FLOW_IDS, id);
    }
    if let Some(id) = event.terminating_flow_ids {
        message.fixed64(field::EVENT_TERMINATING_FLOW_IDS, id);
    }
    args(message);
}
