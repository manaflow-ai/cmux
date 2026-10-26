//! Chromium's JSON trace (the Trace Event Format, `base/trace_event/trace_event_impl.cc`'s
//! `AppendAsJSON`) merged into the Perfetto trace on the local trace clock, the way
//! trace_processor's JSON importer reads it (`src/trace_processor/importers/json/`):
//!
//! - `B`/`E` and `X` (complete) are slices on the thread track; `I`/`i`/`R` are instants on the
//!   thread, process or global track by their scope `s`.
//! - `b`/`e`/`n` (nestable async) and `S`/`T`/`F` (legacy async) go on an async track per
//!   (process or global id scope, category, id).
//! - `s`/`t`/`f` (flow v1) and `bind_id` with `flow_in`/`flow_out` (flow v2) carry flow ids.
//! - `C` writes one counter track per (process, name, series).
//! - `M` names processes and threads.
//!
//! Other phases (objects `N`/`O`/`D`, samples `P`, marks) are counted and skipped.
//!
//! Every slice end is paired with its begin before the events are sorted: an `X` is both, and a
//! `B`/`E` (or async begin and end) pair is matched per track in time order, input order breaking
//! ties, as trace_processor's JSON importer reads them. At one time the order is then the ends of
//! slices begun earlier (innermost first), the begins of slices that last (longest first), and the
//! rest in input order: instants, counters, flows and zero-length slices, each zero-length begin
//! right before its own end. So a complete event that Chromium wrote after its children (it writes
//! `X` at the slice's end) still opens before them, an instant at a slice's begin is inside it, and
//! a `dur: 0` slice never closes its parent.

use super::tracks::{Track, TrackKind, uuid_of};
use super::{Builder, ChromiumInput, CounterValue, Event, Machine, field};
use crate::json::{self, JsonError, Value};
use crate::proto::Message;

/// One event to write. `partner_ns` pairs a slice's ends: a begin's end time (`u64::MAX` while
/// none is known) or an end's begin time. `order` is the input event's index, `sub` the end of an
/// `X` (1) after its begin (0).
#[derive(Clone, Copy)]
struct Pending<'a> {
    t_ns: u64,
    partner_ns: u64,
    order: u32,
    sub: u8,
    /// A `B`/`E` (or async) begin or end, paired by [`pair_slices`]; an `X` is paired already.
    explicit: bool,
    track: u64,
    kind: u64,
    name: &'a str,
    category: &'a str,
    counter: Option<CounterValue>,
    flow: Option<u64>,
    terminating: Option<u64>,
    args: Option<&'a Value<'a>>,
}

const CLASS_END: u8 = 0;
const CLASS_BEGIN: u8 = 1;
const CLASS_POINT: u8 = 2;

impl Pending<'_> {
    /// Where the event goes among the events at its time.
    fn sort_key(&self) -> (u64, u8, u64, u32, u8) {
        let (class, tie) = match self.kind {
            field::TYPE_SLICE_END if self.partner_ns < self.t_ns => {
                (CLASS_END, u64::MAX - self.partner_ns)
            }
            field::TYPE_SLICE_BEGIN if self.partner_ns > self.t_ns => {
                (CLASS_BEGIN, u64::MAX - self.partner_ns)
            }
            _ => (CLASS_POINT, 0),
        };
        (self.t_ns, class, tie, self.order, self.sub)
    }
}

/// Reads `input` and adds its events to `builder` as sequence `sequence_id`.
pub(super) fn merge(
    builder: &mut Builder,
    input: &ChromiumInput<'_>,
    sequence_id: u32,
) -> Result<(), JsonError> {
    let text = String::from_utf8_lossy(input.json);
    let document = json::parse(&text)?;
    let events = match document.get("traceEvents").unwrap_or(&document).as_array() {
        Some(events) => events,
        None => return Err(JsonError { offset: 0, what: "no traceEvents array" }),
    };
    let mut pending = Vec::with_capacity(events.len());
    for (order, event) in events.iter().enumerate() {
        builder.stats.chromium_events += 1;
        if !convert(builder, event, input.offset_ns, order as u32, &mut pending) {
            builder.stats.chromium_skipped += 1;
        }
    }
    pair_slices(builder, &mut pending);
    pending.sort_by_key(Pending::sort_key);
    let sequence = builder.sequence(sequence_id, Machine::Local);
    for event in &pending {
        let proto = Event {
            kind: event.kind,
            track: event.track,
            name: (event.kind != field::TYPE_SLICE_END && event.kind != field::TYPE_COUNTER)
                .then_some(event.name),
            categories: (event.kind != field::TYPE_COUNTER).then_some(event.category),
            counter: event.counter,
            flow_ids: event.flow,
            terminating_flow_ids: event.terminating,
            ..Event::default()
        };
        let args = event.args;
        builder.emit(sequence, event.t_ns, &proto, None, &|message| write_args(message, args));
    }
    Ok(())
}

/// Matches each `B`/`E` (and async begin/end) end with the latest open begin on its track, in time
/// order and then input order; an end with nothing open is dropped and counted.
fn pair_slices(builder: &mut Builder, pending: &mut Vec<Pending<'_>>) {
    let mut explicit: Vec<usize> = (0..pending.len()).filter(|&at| pending[at].explicit).collect();
    explicit.sort_unstable_by_key(|&at| (pending[at].t_ns, pending[at].order));
    let mut open = std::collections::HashMap::<u64, Vec<usize>>::new();
    let mut unmatched = vec![false; pending.len()];
    for at in explicit {
        let event = pending[at];
        if event.kind == field::TYPE_SLICE_BEGIN {
            open.entry(event.track).or_default().push(at);
            continue;
        }
        match open.get_mut(&event.track).and_then(Vec::pop) {
            Some(begin) => {
                pending[begin].partner_ns = event.t_ns;
                pending[at].partner_ns = pending[begin].t_ns;
            }
            None => {
                builder.stats.unmatched_ends += 1;
                unmatched[at] = true;
            }
        }
    }
    let mut at = 0;
    pending.retain(|_| {
        at += 1;
        !unmatched[at - 1]
    });
}

fn text<'a>(event: &'a Value<'a>, key: &str) -> &'a str {
    event.get(key).and_then(Value::as_str).unwrap_or("")
}

/// The trace-clock time of a µs timestamp, after the measured offset.
fn shifted(ts_ns: u64, offset_ns: i64) -> u64 {
    (i128::from(ts_ns) + i128::from(offset_ns)).clamp(0, i128::from(u64::MAX)) as u64
}

fn thread_track(builder: &mut Builder, pid: i64, tid: i64) -> u64 {
    let process = process_track(builder, pid);
    let uuid = uuid_of(&[b"chromium-thread", &pid.to_le_bytes(), &tid.to_le_bytes()]);
    builder.tracks.insert(uuid, || Track {
        parent: Some(process),
        kind: TrackKind::Thread { pid: pid as i32, tid, name: None, description: None },
    })
}

/// The process track Chromium's pid shares with that process's own ring (the Chromium host).
fn process_track(builder: &mut Builder, pid: i64) -> u64 {
    builder.tracks.process(0, pid as u32, || TrackKind::Process {
        pid: pid as i32,
        name: None,
        labels: Vec::new(),
    })
}

fn named_track(builder: &mut Builder, parent: Option<u64>, parts: &[&[u8]], name: String) -> u64 {
    builder.tracks.insert(uuid_of(parts), || Track { parent, kind: TrackKind::Named { name } })
}

/// The async id of an event and whether it is global: `id2.global`, `id2.local` or `id`.
fn async_id(event: &Value<'_>) -> Option<(u64, bool)> {
    if let Some(id2) = event.get("id2") {
        if let Some(id) = id2.get("global").and_then(Value::as_u64) {
            return Some((id, true));
        }
        return id2.get("local").and_then(Value::as_u64).map(|id| (id, false));
    }
    event.get("id").and_then(Value::as_u64).map(|id| (id, false))
}

/// One event to `out`: false when it is skipped.
fn convert<'a>(
    builder: &mut Builder,
    event: &'a Value<'a>,
    offset_ns: i64,
    order: u32,
    out: &mut Vec<Pending<'a>>,
) -> bool {
    let phase = text(event, "ph");
    let pid = event.get("pid").and_then(Value::as_i64).unwrap_or(0);
    let tid = event.get("tid").and_then(Value::as_i64).unwrap_or(pid);
    if phase == "M" {
        return metadata(builder, event, pid, tid);
    }
    let Some(ts) = event.get("ts").and_then(Value::as_micros_in_ns) else { return false };
    let t_ns = shifted(ts, offset_ns);
    let name = text(event, "name");
    let category = text(event, "cat");
    let args = event.get("args");
    let pending = Pending {
        t_ns,
        partner_ns: t_ns,
        order,
        sub: 0,
        explicit: false,
        track: 0,
        kind: field::TYPE_INSTANT,
        name,
        category,
        counter: None,
        flow: None,
        terminating: None,
        args,
    };
    match phase {
        "B" | "E" | "X" | "I" | "i" | "R" => {
            thread_event(builder, event, phase, (pid, tid), pending, out);
            true
        }
        "b" | "e" | "n" | "S" | "T" | "F" => async_event(builder, event, phase, pid, pending, out),
        "s" | "t" | "f" => {
            let Some((id, _)) = async_id(event) else { return false };
            let mut pending = pending;
            pending.track = thread_track(builder, pid, tid);
            let parts: [&[u8]; 4] =
                [b"chromium-flow1", category.as_bytes(), name.as_bytes(), &id.to_le_bytes()];
            let flow = uuid_of(&parts);
            if phase == "f" {
                pending.terminating = Some(flow);
            } else {
                pending.flow = Some(flow);
            }
            out.push(pending);
            true
        }
        "C" => counters(builder, event, pid, &pending, out),
        _ => false,
    }
}

/// `B`, `E`, `X` and the instants: a complete event is a begin and an end.
fn thread_event<'a>(
    builder: &mut Builder,
    event: &'a Value<'a>,
    phase: &str,
    (pid, tid): (i64, i64),
    mut pending: Pending<'a>,
    out: &mut Vec<Pending<'a>>,
) {
    pending.track = match (phase, text(event, "s")) {
        ("I" | "i" | "R", "g") => {
            named_track(builder, None, &[b"chromium-global"], "Global".into())
        }
        ("I" | "i" | "R", "p") => process_track(builder, pid),
        _ => thread_track(builder, pid, tid),
    };
    bind_flows(event, &mut pending);
    match phase {
        "B" => explicit_begin(&mut pending),
        "E" => explicit_end(&mut pending),
        "X" => {
            let dur = event.get("dur").and_then(Value::as_micros_in_ns).unwrap_or(0);
            let (begin_ns, end_ns) = (pending.t_ns, pending.t_ns.saturating_add(dur));
            pending.kind = field::TYPE_SLICE_BEGIN;
            pending.partner_ns = end_ns;
            out.push(pending);
            pending = Pending {
                t_ns: end_ns,
                partner_ns: begin_ns,
                sub: 1,
                kind: field::TYPE_SLICE_END,
                flow: None,
                terminating: None,
                args: None,
                ..pending
            };
        }
        _ => {}
    }
    out.push(pending);
}

/// Nestable (`b`/`e`/`n`) and legacy (`S`/`T`/`F`) async events, on the track of their id: false
/// for one with no id.
fn async_event<'a>(
    builder: &mut Builder,
    event: &'a Value<'a>,
    phase: &str,
    pid: i64,
    mut pending: Pending<'a>,
    out: &mut Vec<Pending<'a>>,
) -> bool {
    let Some((id, global)) = async_id(event) else { return false };
    let scope = text(event, "scope");
    let process = process_track(builder, pid);
    let pid_key = if global { -1 } else { pid };
    let parts: [&[u8]; 5] = [
        b"chromium-async",
        &pid_key.to_le_bytes(),
        scope.as_bytes(),
        pending.category.as_bytes(),
        &id.to_le_bytes(),
    ];
    let name = pending.name.to_owned();
    pending.track = named_track(builder, (!global).then_some(process), &parts, name);
    match phase {
        "b" | "S" => explicit_begin(&mut pending),
        "e" | "F" => explicit_end(&mut pending),
        _ => {}
    }
    out.push(pending);
    true
}

/// A begin [`pair_slices`] pairs: open-ended until its end is found.
fn explicit_begin(pending: &mut Pending<'_>) {
    pending.kind = field::TYPE_SLICE_BEGIN;
    pending.partner_ns = u64::MAX;
    pending.explicit = true;
}

fn explicit_end(pending: &mut Pending<'_>) {
    pending.kind = field::TYPE_SLICE_END;
    pending.explicit = true;
}

/// Flow v2: `bind_id` with `flow_out` (and maybe `flow_in`) passes the flow on; `flow_in` alone ends it.
fn bind_flows(event: &Value<'_>, pending: &mut Pending<'_>) {
    let Some(bind) = event.get("bind_id").and_then(Value::as_u64) else { return };
    let flow = uuid_of(&[b"chromium-flow2", &bind.to_le_bytes()]);
    let flow_in = event.get("flow_in").and_then(Value::as_bool).unwrap_or(false);
    let flow_out = event.get("flow_out").and_then(Value::as_bool).unwrap_or(false);
    if flow_out {
        pending.flow = Some(flow);
    } else if flow_in {
        pending.terminating = Some(flow);
    }
}

/// A `C` event: one sample per numeric series of `args`.
fn counters<'a>(
    builder: &mut Builder,
    event: &'a Value<'a>,
    pid: i64,
    template: &Pending<'a>,
    out: &mut Vec<Pending<'a>>,
) -> bool {
    let Some(series) = event.get("args").and_then(Value::as_object) else { return false };
    let process = process_track(builder, pid);
    let id = event.get("id").and_then(Value::as_u64);
    let mut any = false;
    for (key, value) in series {
        let counter = match (value.as_i64(), value.as_f64()) {
            (Some(int), _) => CounterValue::Int(int),
            (None, Some(double)) => CounterValue::Double(double),
            _ => continue,
        };
        let mut name = template.name.to_owned();
        if let Some(id) = id {
            name.push_str(&format!(" {id}"));
        }
        if series.len() > 1 || key != "value" {
            name.push('.');
            name.push_str(key);
        }
        let parts: [&[u8]; 3] = [b"chromium-counter", &pid.to_le_bytes(), name.as_bytes()];
        let track = builder.tracks.insert(uuid_of(&parts), || Track {
            parent: Some(process),
            kind: TrackKind::Counter { name },
        });
        out.push(Pending {
            track,
            kind: field::TYPE_COUNTER,
            counter: Some(counter),
            args: None,
            ..*template
        });
        any = true;
    }
    any
}

/// `M`: `process_name`, `process_labels` and `thread_name` name the tracks; the rest are skipped.
fn metadata(builder: &mut Builder, event: &Value<'_>, pid: i64, tid: i64) -> bool {
    let value = event.get("args").and_then(|args| args.get("name").or_else(|| args.get("labels")));
    let Some(value) = value.and_then(Value::as_str).map(str::to_owned) else { return false };
    let track = match text(event, "name") {
        "process_name" | "process_labels" => process_track(builder, pid),
        "thread_name" => thread_track(builder, pid, tid),
        _ => return false,
    };
    let is_labels = text(event, "name") == "process_labels";
    match builder.tracks.get_mut(track).map(|track| &mut track.kind) {
        Some(TrackKind::Process { labels, .. }) if is_labels => labels.push(value),
        // A ring's role names its process first; Chromium's name is kept as a label.
        Some(TrackKind::Process { name: Some(_), labels, .. }) => labels.push(value),
        Some(TrackKind::Process { name, .. }) => *name = Some(value),
        Some(TrackKind::Thread { name, .. }) => *name = Some(value),
        _ => return false,
    }
    true
}

/// `args` as debug annotations with inline names: numbers, booleans and strings as themselves,
/// nested values as their JSON.
fn write_args(message: &mut Message, args: Option<&Value<'_>>) {
    let Some(entries) = args.and_then(Value::as_object) else { return };
    for (key, value) in entries {
        message.message(field::EVENT_DEBUG_ANNOTATIONS, |annotation| {
            annotation.string(field::ANNOTATION_NAME, key);
            match value {
                Value::Null => {
                    annotation.string(field::ANNOTATION_LEGACY_JSON, "null");
                }
                Value::Bool(flag) => {
                    annotation.bool(field::ANNOTATION_BOOL, *flag);
                }
                Value::String(text) => {
                    annotation.string(field::ANNOTATION_STRING, text);
                }
                Value::Number(_) => {
                    if let Some(int) = value.as_i64() {
                        annotation.int(field::ANNOTATION_INT, int);
                    } else if let Some(uint) = value.as_u64() {
                        annotation.uint(field::ANNOTATION_UINT, uint);
                    } else {
                        annotation.double(field::ANNOTATION_DOUBLE, value.as_f64().unwrap_or(0.0));
                    }
                }
                Value::Array(..) | Value::Object(..) => {
                    annotation.string(field::ANNOTATION_LEGACY_JSON, value.raw().unwrap_or("null"));
                }
            }
        });
    }
}
