use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, PoisonError};

use cmux_ipc::{CallFlags, FrameHeader, FrameKind, PriorityHint};
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

/// The lane of one `bridge-frames-v1` frame, read from its header only.
///
/// A data stream (stream != 0) is one sequence (p05-ipc.md 3.4), so every
/// frame of it rides one lane per direction and keeps its order: toward the
/// daemon the lane of keystrokes (INPUT and the stream's own calls), toward
/// the client the bulk lane, where terminal `output` events already go. This
/// is Mojo's rule that a port delivers its messages in sequence order
/// (mojo/core/ports/message_queue.cc), whatever channel carried them.
/// Stream 0 calls go by their priority hint, as JSON lines go by command: the
/// daemon refuses a hint that differs from its method table, and a REPLY
/// carries its request's hint, so it returns on the request's lane.
///
/// RING, RING_ADVANCE, RING_ACK, SHARED_BUFFER and calls with descriptors are
/// refused: a byte bridge passes no descriptor and no shared memory.
pub(crate) fn classify_frame(
    header: &FrameHeader,
    direction: FrameDirection,
) -> Result<Lane, MuxCodecError> {
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
    if header.stream() != 0 {
        return Ok(match direction {
            FrameDirection::ToDaemon => Lane::Interactive,
            FrameDirection::ToClient => Lane::Bulk,
        });
    }
    // Only call kinds may use stream 0 once the header is valid.
    Ok(match header.call().map(|call| call.priority) {
        Some(PriorityHint::Input) => Lane::Interactive,
        Some(PriorityHint::Control) | None => Lane::Control,
        Some(PriorityHint::Bulk | PriorityHint::Background) => Lane::Bulk,
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
        let call = cmux_ipc::CallAux { request_id: 1, method_id: 0x0101, priority, flags };
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

    #[test]
    fn stream_zero_calls_follow_their_priority_hint_both_ways() {
        for (priority, lane) in [
            (PriorityHint::Input, Lane::Interactive),
            (PriorityHint::Control, Lane::Control),
            (PriorityHint::Bulk, Lane::Bulk),
            (PriorityHint::Background, Lane::Bulk),
        ] {
            let request = call(FrameKind::Request, 0, priority, CallFlags::empty());
            let reply = call(FrameKind::Reply, 0, priority, CallFlags::empty());
            assert_eq!(classify_frame(&request, FrameDirection::ToDaemon), Ok(lane));
            assert_eq!(classify_frame(&reply, FrameDirection::ToClient), Ok(lane));
        }
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
