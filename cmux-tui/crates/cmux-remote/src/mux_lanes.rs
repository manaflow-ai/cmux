use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, PoisonError};

use cmux_ipc::{
    CallAux, CallFlags, Durability, FrameHeader, FrameKind, MethodId, MethodTables, Ordering,
    PriorityHint,
};
use cmux_remote_protocol::Lane;
use serde::Deserialize;

use crate::mux_codec::MuxCodecError;

const MAX_TRACKED_REQUESTS: usize = 4096;

#[derive(Default)]
pub(crate) struct MuxLaneTracker {
    state: Mutex<MuxLaneState>,
}

#[derive(Default)]
struct MuxLaneState {
    requests: HashMap<u64, TrackedResponse>,
    order: VecDeque<(u64, u64)>,
    next_token: u64,
}

#[derive(Clone, Copy)]
struct TrackedResponse {
    disposition: ResponseDisposition,
    token: u64,
}

#[derive(Clone, Copy)]
enum ResponseDisposition {
    Forward(Lane),
    Suppress,
}

struct MuxName<'a>(Cow<'a, str>);

impl MuxName<'_> {
    fn as_str(&self) -> &str {
        self.0.as_ref()
    }
}

impl<'de: 'a, 'a> Deserialize<'de> for MuxName<'a> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct MuxNameVisitor<'a>(std::marker::PhantomData<&'a ()>);

        impl<'de: 'a, 'a> serde::de::Visitor<'de> for MuxNameVisitor<'a> {
            type Value = MuxName<'a>;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a mux protocol name")
            }

            fn visit_borrowed_str<E>(self, value: &'de str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(MuxName(Cow::Borrowed(value)))
            }

            fn visit_str<E>(self, value: &str) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(MuxName(Cow::Owned(value.to_owned())))
            }

            fn visit_string<E>(self, value: String) -> Result<Self::Value, E>
            where
                E: serde::de::Error,
            {
                Ok(MuxName(Cow::Owned(value)))
            }
        }

        deserializer.deserialize_str(MuxNameVisitor(std::marker::PhantomData))
    }
}

#[derive(Deserialize)]
struct MuxEnvelope<'a> {
    id: Option<u64>,
    #[serde(borrow)]
    cmd: Option<MuxName<'a>>,
    #[serde(borrow)]
    event: Option<MuxName<'a>>,
    #[serde(borrow)]
    scope: Option<MuxName<'a>>,
    #[serde(borrow)]
    mode: Option<MuxName<'a>>,
    #[serde(borrow)]
    op: Option<MuxName<'a>>,
    #[serde(default)]
    stream: StreamMember,
}

/// A line's `stream` member when it names a client-minted stream (a nonzero
/// integer). Any other value (`"stream": true` of an `fs.read`) names none.
#[derive(Default)]
struct StreamMember(Option<u64>);

impl<'de> Deserialize<'de> for StreamMember {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(StreamMemberVisitor)
    }
}

/// Reads a `stream` member without buffering it: an integer is kept, any
/// other value is skipped.
struct StreamMemberVisitor;

impl<'de> serde::de::Visitor<'de> for StreamMemberVisitor {
    type Value = StreamMember;

    fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("any JSON value")
    }

    fn visit_u64<E>(self, value: u64) -> Result<StreamMember, E> {
        Ok(StreamMember((value != 0).then_some(value)))
    }

    fn visit_i64<E>(self, _: i64) -> Result<StreamMember, E> {
        Ok(StreamMember(None))
    }

    fn visit_f64<E>(self, _: f64) -> Result<StreamMember, E> {
        Ok(StreamMember(None))
    }

    fn visit_bool<E>(self, _: bool) -> Result<StreamMember, E> {
        Ok(StreamMember(None))
    }

    fn visit_str<E>(self, _: &str) -> Result<StreamMember, E> {
        Ok(StreamMember(None))
    }

    fn visit_unit<E>(self) -> Result<StreamMember, E> {
        Ok(StreamMember(None))
    }

    fn visit_seq<A>(self, mut items: A) -> Result<StreamMember, A::Error>
    where
        A: serde::de::SeqAccess<'de>,
    {
        while items.next_element::<serde::de::IgnoredAny>()?.is_some() {}
        Ok(StreamMember(None))
    }

    fn visit_map<A>(self, mut entries: A) -> Result<StreamMember, A::Error>
    where
        A: serde::de::MapAccess<'de>,
    {
        while entries.next_entry::<serde::de::IgnoredAny, serde::de::IgnoredAny>()?.is_some() {}
        Ok(StreamMember(None))
    }
}

fn parse_envelope(line: &[u8]) -> Result<MuxEnvelope<'_>, serde_json::Error> {
    serde_json::from_slice(line)
}

impl MuxLaneTracker {
    pub(crate) fn observe_request(&self, line: &[u8], lane: Lane) {
        let Ok(envelope) = parse_envelope(line) else { return };
        if let Some(id) = envelope.id {
            self.track(id, ResponseDisposition::Forward(lane));
        }
    }

    pub(crate) fn suppress_response(&self, id: u64) {
        self.track(id, ResponseDisposition::Suppress);
    }

    pub(crate) fn classify_server_line(&self, line: &[u8]) -> Option<Lane> {
        let Ok(envelope) = parse_envelope(line) else {
            return Some(Lane::Control);
        };
        if let Some(event) = envelope.event.as_ref().map(MuxName::as_str) {
            // An event of a client-minted stream (its items, `stream-end`,
            // `input-failed`) rides the lane of that stream's frames
            // ([`classify_frame`] toward the client), so its end never passes
            // its last items and the opener's reply that follows the end.
            if envelope.stream.0.is_some() {
                return Some(Lane::Bulk);
            }
            return Some(match event {
                "output" | "vt-state" | "render-state" | "render-delta" | "frame"
                | "browser-state" | "resized" | "colors-changed" | "scroll-changed"
                | "detached" => Lane::Bulk,
                // Forwarded loopback bytes and their stream lifecycle stay in
                // one ordered lane, away from keystrokes and control replies.
                name if name.starts_with("loopback-") => Lane::Bulk,
                // Agent session records and the attachment's close follow
                // the attach reply in one ordered lane (they can be large).
                name if name.starts_with("agent-session-") => Lane::Bulk,
                "overflow" if envelope.scope.as_ref().map(MuxName::as_str) == Some("surface") => {
                    Lane::Bulk
                }
                _ => Lane::Control,
            });
        }
        match envelope
            .id
            .and_then(|id| {
                self.state.lock().unwrap_or_else(PoisonError::into_inner).requests.remove(&id)
            })
            .map(|tracked| tracked.disposition)
        {
            Some(ResponseDisposition::Forward(lane)) => Some(lane),
            Some(ResponseDisposition::Suppress) => None,
            None => Some(Lane::Control),
        }
    }

    fn track(&self, id: u64, disposition: ResponseDisposition) {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        if state.next_token == u64::MAX {
            state.requests.clear();
            state.order.clear();
            state.next_token = 0;
        }
        state.next_token += 1;
        let token = state.next_token;
        state.requests.insert(id, TrackedResponse { disposition, token });
        state.order.push_back((id, token));

        while state.order.len() > MAX_TRACKED_REQUESTS {
            let Some((old_id, old_token)) = state.order.pop_front() else { break };
            if state.requests.get(&old_id).is_some_and(|tracked| tracked.token == old_token) {
                state.requests.remove(&old_id);
            }
        }
    }
}

pub(crate) fn classify_client_line(line: &[u8]) -> Lane {
    let Ok(envelope) = parse_envelope(line) else { return Lane::Control };
    match envelope.cmd.as_ref().map(MuxName::as_str) {
        Some("paste-image") if envelope.op.as_ref().map(MuxName::as_str) == Some("commit") => {
            Lane::Interactive
        }
        // Image transactions acknowledge every chunk before commit, so they can
        // use bulk backpressure without delaying interactive keys or reordering paste.
        Some("attach-surface" | "read-screen" | "read-scrollback" | "vt-state" | "paste-image") => {
            Lane::Bulk
        }
        Some("copy") if envelope.mode.as_ref().map(MuxName::as_str) == Some("scrollback") => {
            Lane::Bulk
        }
        // `loopback-forward-v1`: open, data, credit and close of one stream
        // must stay ordered, and forwarded bytes must never queue ahead of
        // PTY input, so every loopback command uses the bulk lane.
        Some(name) if name.starts_with("loopback-") => Lane::Bulk,
        // `agent-session-attach-v1`: the attach reply, the replay pages and
        // the live records of one attachment stay in one ordered lane, so a
        // record never overtakes the reply it follows.
        Some(name) if name.starts_with("agent-session-") => Lane::Bulk,
        // `agent-transfer-v1`: bundle pages of up to 4 MiB never queue ahead
        // of PTY input.
        Some(name) if name.starts_with("agent-transfer-") => Lane::Bulk,
        // Read-only lookups never wait behind PTY input or a slow mutation
        // commit; a stalled Interactive lane must not make a live terminal
        // look missing to the client resolving it.
        Some(
            "identify" | "ping" | "list-clients" | "list-workspaces" | "export-layout" | "wait-for"
            | "ids" | "list-agents" | "pane-neighbor" | "process-info" | "terminal-ports"
            | "terminal-resources" | "subscribe" | "resolve-terminal",
        ) => Lane::Control,
        // Mutations default to one ordered lane with compact PTY input. This
        // keeps a later close, move, focus, resize, or configuration change
        // from overtaking input already accepted from the local mux client.
        Some(_) => Lane::Interactive,
        None => Lane::Control,
    }
}

/// Which way a frame crosses the mux bridge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum FrameDirection {
    /// From the local client to the remote daemon.
    ToDaemon,
    /// From the remote daemon to the local client.
    ToClient,
}

/// The lane of one `bridge-frames-v1` frame, read from its header and the
/// schema's method table only.
///
/// A data stream (stream != 0) is one sequence (p05-ipc.md 3.4), so every
/// frame of it rides one lane per direction and keeps its order: toward the
/// daemon the lane of keystrokes (INPUT and the stream's own calls), toward
/// the client the bulk lane, where terminal `output` events and the stream's
/// JSON lifecycle events go. This is Mojo's rule that a port delivers its
/// messages in sequence order (mojo/core/ports/message_queue.cc), whatever
/// channel carried them.
///
/// Stream 0 is the connection's control sequence. A call on it keeps the
/// interactive lane, the one PTY input rides, unless the method table says it
/// is a read-only `independent` read: a framed `close-surface` must not pass
/// INPUT already sent on a stream it closes, as a JSON mutation line does not
/// ([`classify_client_line`]). An independent read goes by its priority hint
/// (the daemon refuses a hint that differs from its table). REPLY, ERROR and
/// CANCEL carry their request's method, so each takes its request's lane.
///
/// RING, RING_ADVANCE, RING_ACK, SHARED_BUFFER and calls with descriptors are
/// refused: a byte bridge passes no descriptor and no shared memory.
pub(crate) fn classify_frame(
    header: &FrameHeader,
    direction: FrameDirection,
) -> Result<Lane, MuxCodecError> {
    refuse_unbridged(header)?;
    if header.stream() != 0 {
        return Ok(stream_lane(direction));
    }
    // Only call kinds may use stream 0 once the header is valid.
    let Some(call) = header.call() else { return Ok(Lane::Interactive) };
    Ok(if leaves_the_sequence(header.kind(), call) {
        hint_lane(call.priority)
    } else {
        Lane::Interactive
    })
}

/// Admits a frame the far end of the bridge sent, before a byte of it reaches
/// the local socket. The receiving end applies the same rules as the sender
/// ([`classify_frame`]) and does not trust it to: without `bridge-frames-v1`
/// a frame is `frames_not_negotiated`, a descriptor or shared-memory frame
/// never crosses, and a frame must arrive on a lane its sender may use. A
/// stream-0 call may use the interactive lane or the lane of its hint, so a
/// peer built from another schema (a method that became independent) still
/// passes; ordering is the sender's own, so this admits no foreign effect.
pub(crate) fn admit_bridged_frame(
    header: &FrameHeader,
    lane: Lane,
    direction: FrameDirection,
    frames_negotiated: bool,
) -> Result<(), MuxCodecError> {
    if !frames_negotiated {
        return Err(MuxCodecError::Frame(cmux_ipc::BadMessage::FramesNotNegotiated));
    }
    refuse_unbridged(header)?;
    let allowed = match (header.stream(), header.call()) {
        (0, Some(call)) => lane == Lane::Interactive || lane == hint_lane(call.priority),
        (0, None) => lane == Lane::Interactive,
        _ => lane == stream_lane(direction),
    };
    if allowed {
        Ok(())
    } else {
        Err(MuxCodecError::FrameOffLane { kind: header.kind(), stream: header.stream(), lane })
    }
}

fn refuse_unbridged(header: &FrameHeader) -> Result<(), MuxCodecError> {
    let kind = header.kind();
    let descriptors = header.call().is_some_and(|call| call.flags.contains(CallFlags::FDS));
    if descriptors
        || matches!(
            kind,
            FrameKind::Ring | FrameKind::RingAdvance | FrameKind::RingAck | FrameKind::SharedBuffer
        )
    {
        return Err(MuxCodecError::FrameNotBridged(kind));
    }
    Ok(())
}

/// The one lane of every frame of a data stream in `direction`.
fn stream_lane(direction: FrameDirection) -> Lane {
    match direction {
        FrameDirection::ToDaemon => Lane::Interactive,
        FrameDirection::ToClient => Lane::Bulk,
    }
}

fn hint_lane(priority: PriorityHint) -> Lane {
    match priority {
        PriorityHint::Input => Lane::Interactive,
        PriorityHint::Control => Lane::Control,
        PriorityHint::Bulk | PriorityHint::Background => Lane::Bulk,
    }
}

/// Whether a stream-0 call may leave the connection's sequence lane: a typed
/// event (it answers no request), or a call of a read-only method the schema
/// marks `ordering: independent`. An unknown method stays in sequence; the
/// daemon answers it with an error there.
fn leaves_the_sequence(kind: FrameKind, call: CallAux) -> bool {
    if kind == FrameKind::TypedEvent {
        return true;
    }
    MethodTables::schema().method(MethodId::new(call.method_id)).is_some_and(|method| {
        method.ordering == Ordering::Independent && method.durability == Durability::ReadOnly
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn loopback_forward_lines_use_the_bulk_lane_in_both_directions() {
        for line in [
            &br#"{"id":1,"cmd":"loopback-open","stream":1,"host":"localhost","port":3000}"#[..],
            br#"{"cmd":"loopback-data","stream":1,"data":"eA=="}"#,
            br#"{"cmd":"loopback-credit","stream":1,"bytes":65536}"#,
            br#"{"cmd":"loopback-shutdown","stream":1}"#,
            br#"{"cmd":"loopback-close","stream":1}"#,
        ] {
            assert_eq!(classify_client_line(line), Lane::Bulk);
        }
        let tracker = MuxLaneTracker::default();
        for line in [
            &br#"{"event":"loopback-data","stream":1,"data":"eA=="}"#[..],
            br#"{"event":"loopback-credit","stream":1,"bytes":65536}"#,
            br#"{"event":"loopback-eof","stream":1}"#,
            br#"{"event":"loopback-closed","stream":1}"#,
        ] {
            assert_eq!(tracker.classify_server_line(line), Some(Lane::Bulk));
        }
        tracker.observe_request(br#"{"id":7,"cmd":"loopback-open"}"#, Lane::Bulk);
        assert_eq!(tracker.classify_server_line(br#"{"id":7,"ok":true}"#), Some(Lane::Bulk));
    }

    #[test]
    fn agent_transfer_pages_use_the_bulk_lane() {
        for line in [
            &br#"{"id":1,"cmd":"agent-transfer-write","receive_id":"r","path":"a","offset":0,"data":""}"#[..],
            br#"{"id":2,"cmd":"agent-transfer-read","transfer_id":"t","path":"a","offset":0}"#,
        ] {
            assert_eq!(classify_client_line(line), Lane::Bulk);
        }
    }

    #[test]
    fn agent_session_attach_lines_use_the_bulk_lane_in_both_directions() {
        for line in [
            &br#"{"id":1,"cmd":"agent-session-attach","surface":3}"#[..],
            br#"{"id":2,"cmd":"agent-session-events","surface":3,"after_seq":9}"#,
            br#"{"id":3,"cmd":"agent-session-prompt","surface":3,"prompt_id":"p","text":"hi"}"#,
            br#"{"id":4,"cmd":"agent-session-detach","surface":3}"#,
        ] {
            assert_eq!(classify_client_line(line), Lane::Bulk);
        }
        let tracker = MuxLaneTracker::default();
        for line in [
            &br#"{"event":"agent-session-record","surface":3,"record":{"seq":2}}"#[..],
            br#"{"event":"agent-session-permission","surface":3,"request":{}}"#,
            br#"{"event":"agent-session-closed","surface":3,"reason":"lagged"}"#,
        ] {
            assert_eq!(tracker.classify_server_line(line), Some(Lane::Bulk));
        }
        tracker.observe_request(br#"{"id":1,"cmd":"agent-session-attach"}"#, Lane::Bulk);
        assert_eq!(tracker.classify_server_line(br#"{"id":1,"ok":true}"#), Some(Lane::Bulk));
    }

    use std::alloc::{GlobalAlloc, Layout, System};
    use std::cell::Cell;

    use super::*;

    struct CountingAllocator;

    std::thread_local! {
        static COUNT_ALLOCATIONS: Cell<bool> = const { Cell::new(false) };
        static ALLOCATION_COUNT: Cell<usize> = const { Cell::new(0) };
    }

    // Rust installs this allocator for the whole cmux-remote unit-test binary;
    // thread-local counting keeps unrelated test threads out of each sample.
    #[global_allocator]
    static TEST_ALLOCATOR: CountingAllocator = CountingAllocator;

    unsafe impl GlobalAlloc for CountingAllocator {
        unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
            COUNT_ALLOCATIONS
                .try_with(|enabled| {
                    if enabled.get() {
                        ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                    }
                })
                .ok();
            unsafe { System.alloc(layout) }
        }

        unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
            COUNT_ALLOCATIONS
                .try_with(|enabled| {
                    if enabled.get() {
                        ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                    }
                })
                .ok();
            unsafe { System.alloc_zeroed(layout) }
        }

        unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
            unsafe { System.dealloc(pointer, layout) };
        }

        unsafe fn realloc(&self, pointer: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
            COUNT_ALLOCATIONS
                .try_with(|enabled| {
                    if enabled.get() {
                        ALLOCATION_COUNT.with(|count| count.set(count.get().saturating_add(1)));
                    }
                })
                .ok();
            unsafe { System.realloc(pointer, layout, new_size) }
        }
    }

    fn call(kind: FrameKind, stream: u16, priority: PriorityHint, flags: CallFlags) -> FrameHeader {
        let call = CallAux { request_id: 1, method_id: 0x0101, priority, flags };
        FrameHeader::new(kind, stream, 0, cmux_ipc::Aux::Call(call)).unwrap()
    }

    #[test]
    fn every_frame_of_a_stream_rides_one_lane_per_direction() {
        for stream in [1, 2, 0xffff] {
            for kind in [
                FrameKind::Output,
                FrameKind::Grid,
                FrameKind::Event,
                FrameKind::Snapshot,
                FrameKind::SnapshotMore,
                FrameKind::Replay,
            ] {
                let header = FrameHeader::new(kind, stream, 0, cmux_ipc::Aux::Offset(9)).unwrap();
                assert_eq!(classify_frame(&header, FrameDirection::ToClient), Ok(Lane::Bulk));
            }
            let input = FrameHeader::new(FrameKind::Input, stream, 0, cmux_ipc::Aux::FlowId(3));
            let input = input.unwrap();
            assert_eq!(classify_frame(&input, FrameDirection::ToDaemon), Ok(Lane::Interactive));
            for priority in PriorityHint::ALL {
                let flags = CallFlags::empty();
                let reply = call(FrameKind::TypedEvent, stream, priority, flags);
                assert_eq!(classify_frame(&reply, FrameDirection::ToClient), Ok(Lane::Bulk));
                let request = call(FrameKind::Request, stream, priority, flags);
                assert_eq!(
                    classify_frame(&request, FrameDirection::ToDaemon),
                    Ok(Lane::Interactive)
                );
            }
        }
    }

    fn method_call(kind: FrameKind, method: &cmux_ipc::MethodAttrs) -> FrameHeader {
        let call = CallAux {
            request_id: 1,
            method_id: method.id.raw(),
            priority: method.priority,
            flags: CallFlags::empty(),
        };
        FrameHeader::new(kind, 0, 0, cmux_ipc::Aux::Call(call)).unwrap()
    }

    #[test]
    fn stream_zero_calls_stay_in_sequence_unless_the_table_marks_them_independent() {
        let tables = MethodTables::schema();
        let mut independent = 0;
        for method in tables.v12_families().chain(tables.v2_families()).flat_map(|f| f.iter()) {
            let free = method.ordering == Ordering::Independent
                && method.durability == Durability::ReadOnly;
            independent += usize::from(free);
            let lane = if free { hint_lane(method.priority) } else { Lane::Interactive };
            // A call, its cancel and its answers take one lane.
            for kind in [FrameKind::Request, FrameKind::Cancel] {
                let header = method_call(kind, method);
                assert_eq!(classify_frame(&header, FrameDirection::ToDaemon), Ok(lane));
            }
            for kind in [FrameKind::Reply, FrameKind::Error] {
                let header = method_call(kind, method);
                assert_eq!(classify_frame(&header, FrameDirection::ToClient), Ok(lane));
            }
        }
        assert!(independent > 0, "the schema has independent reads");
        let close = tables.v12_id("close-surface").and_then(|id| tables.method(id)).unwrap();
        let close = method_call(FrameKind::Request, close);
        assert_eq!(classify_frame(&close, FrameDirection::ToDaemon), Ok(Lane::Interactive));
        let unknown = call(FrameKind::Request, 0, PriorityHint::Control, CallFlags::empty());
        let unknown = FrameHeader::new(
            FrameKind::Request,
            0,
            0,
            cmux_ipc::Aux::Call(CallAux { method_id: 0x5fff, ..unknown.call().unwrap() }),
        )
        .unwrap();
        assert_eq!(classify_frame(&unknown, FrameDirection::ToDaemon), Ok(Lane::Interactive));
        for (priority, lane) in [
            (PriorityHint::Input, Lane::Interactive),
            (PriorityHint::Control, Lane::Control),
            (PriorityHint::Bulk, Lane::Bulk),
            (PriorityHint::Background, Lane::Bulk),
        ] {
            let event = call(FrameKind::TypedEvent, 0, priority, CallFlags::empty());
            assert_eq!(classify_frame(&event, FrameDirection::ToClient), Ok(lane));
        }
    }

    #[test]
    fn a_received_frame_is_admitted_only_as_its_sender_may_send_it() {
        let output = FrameHeader::new(FrameKind::Output, 1, 0, cmux_ipc::Aux::Offset(0)).unwrap();
        let input = FrameHeader::new(FrameKind::Input, 1, 0, cmux_ipc::Aux::FlowId(0)).unwrap();
        let (to_app, to_daemon) = (FrameDirection::ToClient, FrameDirection::ToDaemon);
        assert_eq!(admit_bridged_frame(&output, Lane::Bulk, to_app, true), Ok(()));
        assert_eq!(admit_bridged_frame(&input, Lane::Interactive, to_daemon, true), Ok(()));
        assert_eq!(
            admit_bridged_frame(&output, Lane::Bulk, to_app, false),
            Err(MuxCodecError::Frame(cmux_ipc::BadMessage::FramesNotNegotiated))
        );
        for (header, lane, direction) in
            [(&output, Lane::Control, to_app), (&input, Lane::Bulk, to_daemon)]
        {
            assert_eq!(
                admit_bridged_frame(header, lane, direction, true),
                Err(MuxCodecError::FrameOffLane { kind: header.kind(), stream: 1, lane })
            );
        }
        // A stream-0 call may use the sequence lane or its hint's lane,
        // whichever the sender's schema chose, and no other.
        let read = call(FrameKind::Reply, 0, PriorityHint::Bulk, CallFlags::empty());
        assert_eq!(admit_bridged_frame(&read, Lane::Interactive, to_app, true), Ok(()));
        assert_eq!(admit_bridged_frame(&read, Lane::Bulk, to_app, true), Ok(()));
        assert_eq!(
            admit_bridged_frame(&read, Lane::Control, to_app, true),
            Err(MuxCodecError::FrameOffLane {
                kind: FrameKind::Reply,
                stream: 0,
                lane: Lane::Control
            })
        );
        let ring = FrameHeader::new(FrameKind::Ring, 1, 0, cmux_ipc::Aux::Offset(0)).unwrap();
        let fds = call(FrameKind::Request, 0, PriorityHint::Control, CallFlags::FDS);
        for (header, lane) in [(&ring, Lane::Bulk), (&fds, Lane::Interactive)] {
            for direction in [to_app, to_daemon] {
                assert_eq!(
                    admit_bridged_frame(header, lane, direction, true),
                    Err(MuxCodecError::FrameNotBridged(header.kind()))
                );
            }
        }
    }

    #[test]
    fn events_of_a_client_stream_ride_the_bulk_lane_of_its_frames() {
        let tracker = MuxLaneTracker::default();
        for line in [
            &br#"{"event":"stream-end","stream":3,"reason":"attach_failed"}"#[..],
            br#"{"event":"input-failed","stream":3,"reason":"write_failed","bytes":2}"#,
            br#"{"stream":3,"event":"title-changed","surface":1}"#,
        ] {
            assert_eq!(tracker.classify_server_line(line), Some(Lane::Bulk), "{line:?}");
        }
        for line in [
            &br#"{"event":"title-changed","surface":1}"#[..],
            br#"{"event":"title-changed","stream":0}"#,
            br#"{"event":"title-changed","stream":"named"}"#,
            br#"{"event":"title-changed","stream":{"name":[1,2]}}"#,
            br#"{"event":"title-changed","stream":null}"#,
        ] {
            assert_eq!(tracker.classify_server_line(line), Some(Lane::Control), "{line:?}");
        }
        assert_eq!(
            classify_client_line(br#"{"id":1,"cmd":"fs.read","path":"/a","stream":true}"#),
            Lane::Interactive
        );
    }

    #[test]
    fn descriptors_and_shared_memory_never_cross_the_bridge() {
        for kind in [FrameKind::Ring, FrameKind::RingAdvance, FrameKind::RingAck] {
            let header = FrameHeader::new(kind, 1, 0, cmux_ipc::Aux::Offset(0)).unwrap();
            for direction in [FrameDirection::ToDaemon, FrameDirection::ToClient] {
                assert_eq!(
                    classify_frame(&header, direction),
                    Err(MuxCodecError::FrameNotBridged(kind))
                );
            }
        }
        let shared =
            FrameHeader::new(FrameKind::SharedBuffer, 0, 0, cmux_ipc::Aux::SharedBufferSize(4096))
                .unwrap();
        assert_eq!(
            classify_frame(&shared, FrameDirection::ToDaemon),
            Err(MuxCodecError::FrameNotBridged(FrameKind::SharedBuffer))
        );
        let with_fds = call(FrameKind::Request, 0, PriorityHint::Control, CallFlags::FDS);
        assert_eq!(
            classify_frame(&with_fds, FrameDirection::ToDaemon),
            Err(MuxCodecError::FrameNotBridged(FrameKind::Request))
        );
    }

    #[test]
    fn keystrokes_and_terminal_output_use_distinct_lanes() {
        let tracker = MuxLaneTracker::default();
        let request = br#"{"id":7,"cmd":"send","surface":1,"bytes":"YQ=="}"#;
        let lane = classify_client_line(request);
        assert_eq!(lane, Lane::Interactive);
        tracker.observe_request(request, lane);
        assert_eq!(tracker.classify_server_line(br#"{"id":7,"ok":true}"#), Some(Lane::Interactive));
        assert_eq!(
            tracker.classify_server_line(br#"{"event":"output","surface":1,"data":"Yg=="}"#),
            Some(Lane::Bulk)
        );
    }
}
