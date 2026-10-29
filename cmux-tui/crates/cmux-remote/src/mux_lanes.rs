use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::{Mutex, PoisonError};

use cmux_ipc::FrameHeader;
use cmux_remote_protocol::Lane;
use serde::Deserialize;

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

/// A line's `stream` member: an `attach-streams-v1` id is an unsigned
/// integer; resource streams name theirs with a string, and other values
/// are not stream ids.
enum StreamMember {
    Attach(u64),
    Other,
}

impl<'de> Deserialize<'de> for StreamMember {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        struct StreamMemberVisitor;

        impl<'de> serde::de::Visitor<'de> for StreamMemberVisitor {
            type Value = StreamMember;

            fn expecting(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str("a stream member")
            }

            fn visit_u64<E>(self, value: u64) -> Result<Self::Value, E> {
                Ok(StreamMember::Attach(value))
            }

            fn visit_i64<E>(self, value: i64) -> Result<Self::Value, E> {
                Ok(u64::try_from(value).map_or(StreamMember::Other, StreamMember::Attach))
            }

            fn visit_f64<E>(self, _: f64) -> Result<Self::Value, E> {
                Ok(StreamMember::Other)
            }

            fn visit_bool<E>(self, _: bool) -> Result<Self::Value, E> {
                Ok(StreamMember::Other)
            }

            fn visit_str<E>(self, _: &str) -> Result<Self::Value, E> {
                Ok(StreamMember::Other)
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: serde::de::SeqAccess<'de>,
            {
                while seq.next_element::<serde::de::IgnoredAny>()?.is_some() {}
                Ok(StreamMember::Other)
            }

            fn visit_map<A>(self, mut map: A) -> Result<Self::Value, A::Error>
            where
                A: serde::de::MapAccess<'de>,
            {
                while map.next_entry::<serde::de::IgnoredAny, serde::de::IgnoredAny>()?.is_some() {}
                Ok(StreamMember::Other)
            }
        }

        deserializer.deserialize_any(StreamMemberVisitor)
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
    stream: Option<StreamMember>,
}

impl MuxEnvelope<'_> {
    /// The `attach-streams-v1` stream the line belongs to; 0 is the
    /// connection's control stream, not an attach stream. `loopback-*`
    /// lines number their own forwarded streams in the same member.
    fn attach_stream(&self) -> Option<u64> {
        let name = self.cmd.as_ref().or(self.event.as_ref()).map(MuxName::as_str);
        if name.is_some_and(|name| name.starts_with("loopback-")) {
            return None;
        }
        match self.stream {
            Some(StreamMember::Attach(stream)) if stream != 0 => Some(stream),
            Some(StreamMember::Attach(_) | StreamMember::Other) | None => None,
        }
    }
}

fn parse_envelope(line: &[u8]) -> Result<MuxEnvelope<'_>, serde_json::Error> {
    serde_json::from_slice(line)
}

/// The lane of every server item of an attach stream: its READY, output,
/// frames, events and `stream-end`, and the replies to the client's requests
/// that name it. One lane keeps them in the daemon's order, as one Mojo
/// endpoint keeps its messages in order (mojo/core/README.md).
const SERVER_STREAM_LANE: Lane = Lane::Bulk;

/// The lane of every client message of an attach stream: the
/// `attach-surface` that opens it, its view commands, `cancel-stream` and
/// its INPUT frames. Keys are person input, so the lane is the interactive
/// one that already carries JSON `send`.
const CLIENT_STREAM_LANE: Lane = Lane::Interactive;

impl MuxLaneTracker {
    pub(crate) fn observe_request(&self, line: &[u8], lane: Lane) {
        let Ok(envelope) = parse_envelope(line) else { return };
        if let Some(id) = envelope.id {
            // A reply to a request that names a stream follows the stream's
            // earlier items (`cancel-stream` answers after `stream-end`).
            let lane = if envelope.attach_stream().is_some() { SERVER_STREAM_LANE } else { lane };
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
                // Every item of an attach stream (`stream-end`, a stream's
                // notification) stays behind its output.
                _ if envelope.attach_stream().is_some() => SERVER_STREAM_LANE,
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
        // Everything of one attach stream, its opening `attach-surface`
        // included, keeps one order with its INPUT frames
        // ([`classify_client_frame`]), so a view command never overtakes
        // the attach that opened its stream.
        Some(_) if envelope.attach_stream().is_some() => CLIENT_STREAM_LANE,
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

/// The lane of a binary frame the local client sent. A frame on an attach
/// stream (INPUT) rides its stream's lane. A call frame on control stream 0
/// may be a mutation, and mutations keep one order with PTY input on the
/// interactive lane (see [`classify_client_line`]).
pub(crate) fn classify_client_frame(_header: &FrameHeader) -> Lane {
    CLIENT_STREAM_LANE
}

/// The lane of a binary frame the daemon sent: every frame of an attach
/// stream (OUTPUT, GRID, EVENT, SNAPSHOT, REPLAY, RING) on the stream's lane,
/// in the daemon's order; a call frame on control stream 0 on the control
/// lane, as a JSON reply without a tracked request.
pub(crate) fn classify_server_frame(header: &FrameHeader) -> Lane {
    if header.stream() == 0 { Lane::Control } else { SERVER_STREAM_LANE }
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
    fn every_item_of_an_attach_stream_rides_one_lane_per_direction() {
        use cmux_ipc::{Aux, FrameKind};

        let tracker = MuxLaneTracker::default();
        // Client to daemon: the attach, view commands and INPUT frames of
        // stream 5 share one lane.
        let attach = br#"{"id":1,"cmd":"attach-surface","surface":3,"stream":5}"#;
        let resize = br#"{"id":2,"cmd":"resize-attached-view","stream":5,"cols":80,"rows":24}"#;
        let cancel = br#"{"id":3,"cmd":"cancel-stream","stream":5}"#;
        let input = FrameHeader::new(FrameKind::Input, 5, 1, Aux::FlowId(0)).unwrap();
        let lanes = [
            classify_client_line(attach),
            classify_client_line(resize),
            classify_client_line(cancel),
            classify_client_frame(&input),
        ];
        assert!(lanes.iter().all(|lane| *lane == CLIENT_STREAM_LANE), "{lanes:?}");
        // Without a stream, attach-surface keeps its bulk lane.
        assert_eq!(classify_client_line(br#"{"id":4,"cmd":"attach-surface"}"#), Lane::Bulk);

        // Daemon to client: READY, replies, frames, notification and
        // stream-end of stream 5 share one lane.
        for (line, lane) in [(&attach[..], lanes[0]), (resize, lanes[1]), (cancel, lanes[2])] {
            tracker.observe_request(line, lane);
        }
        let mut server = vec![
            tracker.classify_server_line(br#"{"stream":5,"event":"vt-state","surface":3}"#),
            tracker.classify_server_line(br#"{"id":1,"ok":true}"#),
            tracker.classify_server_line(br#"{"stream":5,"event":"notification","surface":3}"#),
            tracker.classify_server_line(br#"{"id":2,"ok":true}"#),
            tracker
                .classify_server_line(br#"{"event":"stream-end","stream":5,"reason":"canceled"}"#),
            tracker.classify_server_line(br#"{"id":3,"ok":true,"data":{"stream":5}}"#),
        ];
        for kind in [FrameKind::Output, FrameKind::Grid, FrameKind::Event, FrameKind::Snapshot] {
            let header = FrameHeader::new(kind, 5, 0, Aux::Offset(9)).unwrap();
            server.push(Some(classify_server_frame(&header)));
        }
        assert!(server.iter().all(|lane| *lane == Some(SERVER_STREAM_LANE)), "{server:?}");

        // Resource streams name theirs with a string: not an attach stream.
        assert_eq!(
            tracker.classify_server_line(br#"{"event":"progress","stream":"st_1"}"#),
            Some(Lane::Control)
        );
        // Stream 0 is the control stream.
        assert_eq!(
            tracker.classify_server_line(br#"{"event":"progress","stream":0}"#),
            Some(Lane::Control)
        );
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
