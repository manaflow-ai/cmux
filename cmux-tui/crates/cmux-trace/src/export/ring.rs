//! One decoded ring as one packet sequence: its process and thread tracks, its interned names, and
//! each record as a TrackEvent (the phase mapping is in the [`super`] module doc).

use std::collections::{HashMap, HashSet};

use super::tracks::{Track, TrackKind, uuid_of};
use super::{Builder, CounterValue, Event, Machine, RemoteMachine, RingInput, field};
use crate::Role;
use crate::decode::{Decoded, DecodedRecord};
use crate::layout::{FLAG_ESTIMATE, FLAG_ID, Phase, RingKind, THREAD_NONE};
use crate::proto::Message;

/// The argument names a ring sequence interns (`DebugAnnotationName` iids).
mod arg {
    pub const ARG0: u64 = 1;
    pub const ARG1: u64 = 2;
    pub const ESTIMATED: u64 = 3;
    pub const ID: u64 = 4;
    pub const NAMES: [(u64, &str); 4] =
        [(ARG0, "arg0"), (ARG1, "arg1"), (ESTIMATED, "estimated"), (ID, "id")];
}

/// A record's debug annotations: up to two numbers and the estimate flag. No allocation.
#[derive(Default)]
struct Args {
    numbers: [(u64, u64); 2],
    len: usize,
    estimated: bool,
}

impl Args {
    fn push(&mut self, name_iid: u64, value: u64) {
        self.numbers[self.len] = (name_iid, value);
        self.len += 1;
    }

    fn write(&self, event: &mut Message) {
        for &(name_iid, value) in &self.numbers[..self.len] {
            event.message(field::EVENT_DEBUG_ANNOTATIONS, |annotation| {
                annotation
                    .uint(field::ANNOTATION_NAME_IID, name_iid)
                    .uint(field::ANNOTATION_UINT, value);
            });
        }
        if self.estimated {
            event.message(field::EVENT_DEBUG_ANNOTATIONS, |annotation| {
                annotation
                    .uint(field::ANNOTATION_NAME_IID, arg::ESTIMATED)
                    .bool(field::ANNOTATION_BOOL, true);
            });
        }
    }
}

/// One ring's export: its tracks resolved once, then its records in order.
pub(super) struct RingExport<'a> {
    ring: &'a Decoded,
    machine: Machine,
    machine_key: u64,
    pid: u32,
    process: u64,
    /// A remote machine's ring: its process and threads are [`TrackKind::Remote`].
    remote: bool,
    /// (thread index, generation) to its track.
    threads: HashMap<(u32, u32), u64>,
    /// Name id to (text, category bit; `u8::MAX` for a name the table lacks).
    names: HashMap<u16, (String, u8)>,
    /// Open slices per track (thread and async tracks).
    open: HashMap<u64, u32>,
}

impl<'a> RingExport<'a> {
    pub(super) fn new(
        builder: &mut Builder,
        input: &RingInput<'a>,
        remote: Option<&RemoteMachine>,
    ) -> RingExport<'a> {
        let ring = input.ring;
        let machine_key = match input.machine {
            Machine::Local => 0,
            Machine::Remote(index) => index as u64 + 1,
        };
        let pid = ring.header.pid;
        let process = builder.tracks.process(machine_key, pid, || process_track(ring, remote));
        let mut names: HashMap<u16, (String, u8)> = ring
            .names
            .iter()
            .map(|entry| (entry.id, (entry.text.clone(), entry.category)))
            .collect();
        for record in &ring.records {
            names.entry(record.name).or_insert_with(|| (format!("name {}", record.name), u8::MAX));
        }
        RingExport {
            ring,
            machine: input.machine,
            machine_key,
            pid,
            process,
            remote: remote.is_some(),
            threads: HashMap::new(),
            names,
            open: HashMap::new(),
        }
    }

    pub(super) fn run(mut self, builder: &mut Builder, sequence_id: u32) {
        let sequence = builder.sequence(sequence_id, self.machine);
        let interned = self.interned();
        for record in &self.ring.records {
            self.record(builder, sequence, record, &interned);
        }
    }

    /// The sequence's interned data: every name, the categories they name and the argument names.
    fn interned(&self) -> impl Fn(&mut Message) + use<> {
        let mut names: Vec<(u16, String)> =
            self.names.iter().map(|(id, (text, _))| (*id, text.clone())).collect();
        names.sort_unstable();
        let bits: HashSet<u8> = self.names.values().map(|(_, category)| *category).collect();
        let mut categories: Vec<(u64, &'static str)> = bits
            .into_iter()
            .filter_map(|bit| category_name(bit).map(|name| (u64::from(bit) + 1, name)))
            .collect();
        categories.sort_unstable();
        move |data: &mut Message| {
            for (iid, name) in &categories {
                interned_entry(data, field::INTERNED_EVENT_CATEGORIES, *iid, name);
            }
            for (id, text) in &names {
                interned_entry(data, field::INTERNED_EVENT_NAMES, u64::from(*id), text);
            }
            for (iid, name) in arg::NAMES {
                interned_entry(data, field::INTERNED_DEBUG_ANNOTATION_NAMES, iid, name);
            }
        }
    }

    fn thread_track(&mut self, builder: &mut Builder, record: &DecodedRecord) -> u64 {
        let key = (record.thread_index, record.thread_generation);
        if let Some(&track) = self.threads.get(&key) {
            return track;
        }
        let track = match self.ring.thread_of(record) {
            Some(thread) => {
                let (pid, process, remote) = (self.pid, self.process, self.remote);
                let parts: [&[u8]; 4] = [
                    b"thread",
                    &self.machine_key.to_le_bytes(),
                    &pid.to_le_bytes(),
                    &thread.tid.to_le_bytes(),
                ];
                let description = qos_name(thread.qos).map(|qos| format!("QoS: {qos}"));
                let kind = if remote {
                    let name = match thread.name.as_str() {
                        "" => format!("thread {}", thread.tid),
                        name => format!("{name} {}", thread.tid),
                    };
                    TrackKind::Remote { name, description }
                } else {
                    TrackKind::Thread {
                        pid: pid as i32,
                        tid: thread.tid as i64,
                        name: (!thread.name.is_empty()).then(|| thread.name.clone()),
                        description,
                    }
                };
                builder.tracks.insert(uuid_of(&parts), || Track { parent: Some(process), kind })
            }
            None => self.unregistered_thread_track(builder, record),
        };
        self.threads.insert(key, track);
        track
    }

    /// A chunk whose thread entry is gone (an earlier occupant) or was never taken (a full table):
    /// a named track, as the decoder names it.
    fn unregistered_thread_track(&self, builder: &mut Builder, record: &DecodedRecord) -> u64 {
        let name = if record.thread_index == THREAD_NONE {
            "unregistered threads".to_owned()
        } else {
            format!("thread {} (generation {})", record.thread_index, record.thread_generation)
        };
        let parts: [&[u8]; 5] = [
            b"thread-slot",
            &self.machine_key.to_le_bytes(),
            &self.pid.to_le_bytes(),
            &record.thread_index.to_le_bytes(),
            &record.thread_generation.to_le_bytes(),
        ];
        let process = self.process;
        builder.tracks.insert(uuid_of(&parts), || Track {
            parent: Some(process),
            kind: TrackKind::Named { name },
        })
    }

    /// The async (or counter) track of (name, id) in this process: `perfetto::Track(uuid)`.
    fn keyed_track(&self, builder: &mut Builder, record: &DecodedRecord, counter: bool) -> u64 {
        let (text, _) = &self.names[&record.name];
        let id = if record.flags & FLAG_ID != 0 { record.arg1 } else { 0 };
        let kind: &[u8] = if counter { b"counter" } else { b"async" };
        let parts: [&[u8]; 5] = [
            kind,
            &self.machine_key.to_le_bytes(),
            &self.pid.to_le_bytes(),
            text.as_bytes(),
            &id.to_le_bytes(),
        ];
        let process = self.process;
        builder.tracks.insert(uuid_of(&parts), || {
            let name = if counter && id != 0 { format!("{text} {id}") } else { text.clone() };
            let kind =
                if counter { TrackKind::Counter { name } } else { TrackKind::Named { name } };
            Track { parent: Some(process), kind }
        })
    }

    /// Opens or closes a slice on `track`: false for an end with nothing open.
    fn nest(&mut self, builder: &mut Builder, track: u64, begin: bool) -> bool {
        let depth = self.open.entry(track).or_insert(0);
        if begin {
            *depth += 1;
        } else if *depth == 0 {
            builder.stats.unmatched_ends += 1;
            return false;
        } else {
            *depth -= 1;
        }
        true
    }

    fn record(
        &mut self,
        builder: &mut Builder,
        sequence: usize,
        record: &DecodedRecord,
        interned: &dyn Fn(&mut Message),
    ) {
        let Some(phase) = Phase::from_raw(record.phase) else {
            builder.stats.invalid_records += 1;
            return;
        };
        let category = self.names[&record.name].1;
        let mut event = Event {
            name_iid: Some(u64::from(record.name)),
            category_iid: category_name(category).map(|_| u64::from(category) + 1),
            ..Event::default()
        };
        let mut args = Args { estimated: record.flags & FLAG_ESTIMATE != 0, ..Args::default() };
        let keep = match phase {
            Phase::Begin | Phase::End | Phase::Instant => {
                self.thread_event(builder, record, phase, &mut event, &mut args)
            }
            Phase::AsyncBegin | Phase::AsyncEnd => {
                self.async_event(builder, record, phase == Phase::AsyncBegin, &mut event, &mut args)
            }
            Phase::FlowOut | Phase::FlowIn => {
                event.track = self.thread_track(builder, record);
                event.kind = field::TYPE_INSTANT;
                // `f` ends the flow (Perfetto's `TerminatingFlow`): an id used again starts a new one.
                if phase == Phase::FlowIn {
                    event.terminating_flow_ids = Some(record.arg1);
                } else {
                    event.flow_ids = Some(record.arg1);
                }
                args.push(arg::ARG0, record.arg0);
                true
            }
            Phase::Counter => {
                event.track = self.keyed_track(builder, record, true);
                event.kind = field::TYPE_COUNTER;
                event.counter = Some(CounterValue::Int(record.arg0 as i64));
                event.name_iid = None;
                event.category_iid = None;
                true
            }
        };
        if keep {
            builder.emit(sequence, record.t_ns, &event, Some(interned), &|message| {
                args.write(message);
            });
        }
    }

    /// `B`, `E` and `I` on the writing thread's track.
    fn thread_event(
        &mut self,
        builder: &mut Builder,
        record: &DecodedRecord,
        phase: Phase,
        event: &mut Event<'_>,
        args: &mut Args,
    ) -> bool {
        event.track = self.thread_track(builder, record);
        event.kind = match phase {
            Phase::Begin => field::TYPE_SLICE_BEGIN,
            Phase::End => field::TYPE_SLICE_END,
            _ => field::TYPE_INSTANT,
        };
        if phase != Phase::Instant && !self.nest(builder, event.track, phase == Phase::Begin) {
            return false;
        }
        if phase != Phase::End {
            args.push(arg::ARG0, record.arg0);
            args.push(if record.flags & FLAG_ID != 0 { arg::ID } else { arg::ARG1 }, record.arg1);
        }
        true
    }

    /// AB and AE on the (name, async id) track.
    fn async_event(
        &mut self,
        builder: &mut Builder,
        record: &DecodedRecord,
        begin: bool,
        event: &mut Event<'_>,
        args: &mut Args,
    ) -> bool {
        event.track = self.keyed_track(builder, record, false);
        event.kind = if begin { field::TYPE_SLICE_BEGIN } else { field::TYPE_SLICE_END };
        if !self.nest(builder, event.track, begin) {
            return false;
        }
        if begin {
            args.push(arg::ARG0, record.arg0);
            args.push(arg::ID, record.arg1);
        }
        true
    }
}

/// A category's name by its bit, if the bit names one.
fn category_name(bit: u8) -> Option<&'static str> {
    crate::category::NAMES.get(usize::from(bit)).copied().filter(|name| !name.is_empty())
}

fn interned_entry(data: &mut Message, field_number: u32, iid: u64, name: &str) {
    data.message(field_number, |entry| {
        entry.uint(field::INTERNED_IID, iid).string(field::INTERNED_NAME, name);
    });
}

/// The QoS a thread registered with (`qos_class_t`), as the thread track's description says it.
fn qos_name(qos: u8) -> Option<&'static str> {
    Some(match qos {
        0x21 => "user-interactive",
        0x19 => "user-initiated",
        0x15 => "default",
        0x11 => "utility",
        0x09 => "background",
        0x05 => "maintenance",
        _ => return None,
    })
}

/// The text of a ring's build version (NUL padded).
fn build_text(bytes: &[u8; 32]) -> String {
    let end = bytes.iter().position(|&byte| byte == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

/// The process track of a ring: its role, with its build, ring kind and machine as labels. A
/// remote machine's is a [`TrackKind::Remote`] named for its role, pid and machine, the labels in
/// its description.
fn process_track(ring: &Decoded, remote: Option<&RemoteMachine>) -> TrackKind {
    let header = &ring.header;
    let role = Role::from_raw(header.role).map_or("unknown role", Role::as_str);
    let mut labels = Vec::new();
    let build = build_text(&header.build_version);
    if !build.is_empty() {
        labels.push(format!("build {build}"));
    }
    if header.ring_kind == RingKind::BlackBox as u8 {
        labels.push("black box".to_owned());
    }
    let Some(remote) = remote else {
        return TrackKind::Process { pid: header.pid as i32, name: Some(role.to_owned()), labels };
    };
    labels.push(format!(
        "clock offset {} ns, error bound {} ns",
        remote.offset_ns, remote.error_bound_ns
    ));
    TrackKind::Remote {
        name: format!("{role} {} on {}", header.pid, remote.name),
        description: Some(labels.join("; ")),
    }
}
