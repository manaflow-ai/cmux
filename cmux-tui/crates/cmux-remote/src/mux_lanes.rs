use std::borrow::Cow;
use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

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
                "overflow" if envelope.scope.as_ref().map(MuxName::as_str) == Some("surface") => {
                    Lane::Bulk
                }
                _ => Lane::Control,
            });
        }
        match envelope
            .id
            .and_then(|id| self.state.lock().unwrap().requests.remove(&id))
            .map(|tracked| tracked.disposition)
        {
            Some(ResponseDisposition::Forward(lane)) => Some(lane),
            Some(ResponseDisposition::Suppress) => None,
            None => Some(Lane::Control),
        }
    }

    fn track(&self, id: u64, disposition: ResponseDisposition) {
        let mut state = self.state.lock().unwrap();
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
        Some("attach-surface" | "read-screen" | "read-scrollback" | "vt-state") => Lane::Bulk,
        Some("copy") if envelope.mode.as_ref().map(MuxName::as_str) == Some("scrollback") => {
            Lane::Bulk
        }
        Some(
            "identify" | "ping" | "list-clients" | "list-workspaces" | "export-layout" | "wait-for"
            | "ids" | "list-agents" | "pane-neighbor" | "process-info" | "subscribe",
        ) => Lane::Control,
        // Mutations default to one ordered lane with compact PTY input. This
        // keeps a later close, move, focus, resize, or configuration change
        // from overtaking input already accepted from the local mux client.
        Some(_) => Lane::Interactive,
        None => Lane::Control,
    }
}

#[cfg(test)]
mod tests {
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

    fn allocation_count<T>(operation: impl FnOnce() -> T) -> (T, usize) {
        COUNT_ALLOCATIONS.with(|enabled| enabled.set(false));
        ALLOCATION_COUNT.with(|count| count.set(0));
        COUNT_ALLOCATIONS.with(|enabled| enabled.set(true));
        let result = operation();
        COUNT_ALLOCATIONS.with(|enabled| enabled.set(false));
        let allocations = ALLOCATION_COUNT.with(Cell::get);
        (result, allocations)
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

    #[test]
    fn surface_stream_state_events_use_the_bulk_lane() {
        let tracker = MuxLaneTracker::default();
        for event in [
            "render-state",
            "render-delta",
            "resized",
            "colors-changed",
            "scroll-changed",
            "detached",
        ] {
            let line = format!(r#"{{"event":"{event}","surface":1}}"#);
            assert_eq!(
                tracker.classify_server_line(line.as_bytes()),
                Some(Lane::Bulk),
                "{event} must stay ordered with surface output"
            );
        }
    }

    #[test]
    fn surface_stream_terminal_cannot_overtake_its_bulk_tail() {
        let tracker = MuxLaneTracker::default();
        let render_lane =
            tracker.classify_server_line(br#"{"event":"render-delta","surface":1}"#).unwrap();

        for terminal in [
            br#"{"event":"detached","surface":1}"#.as_slice(),
            br#"{"event":"overflow","scope":"surface","surface":1}"#.as_slice(),
        ] {
            assert_eq!(
                tracker.classify_server_line(terminal),
                Some(render_lane),
                "surface stream termination must stay ordered behind its bulk tail"
            );
        }
    }

    #[test]
    fn one_way_input_response_is_drained_once() {
        let tracker = MuxLaneTracker::default();
        tracker.suppress_response(9);
        assert_eq!(tracker.classify_server_line(br#"{"id":9,"ok":true}"#), None);
        assert_eq!(tracker.classify_server_line(br#"{"id":9,"ok":true}"#), Some(Lane::Control));
    }

    #[test]
    fn response_tracking_is_bounded() {
        let tracker = MuxLaneTracker::default();
        for id in 0..=MAX_TRACKED_REQUESTS as u64 {
            tracker.suppress_response(id);
        }

        let state = tracker.state.lock().unwrap();
        assert_eq!(state.order.len(), MAX_TRACKED_REQUESTS);
        assert_eq!(state.requests.len(), MAX_TRACKED_REQUESTS);
        drop(state);
        assert_eq!(tracker.classify_server_line(br#"{"id":0,"ok":true}"#), Some(Lane::Control));
    }

    #[test]
    fn stale_tracking_entry_does_not_evict_reused_request_id() {
        let tracker = MuxLaneTracker::default();
        tracker.suppress_response(1);
        tracker.suppress_response(1);
        for id in 2..=MAX_TRACKED_REQUESTS as u64 {
            tracker.suppress_response(id);
        }

        assert_eq!(tracker.classify_server_line(br#"{"id":1,"ok":true}"#), None);
    }

    #[test]
    fn large_snapshot_requests_use_bulk_lane() {
        assert_eq!(classify_client_line(br#"{"id":2,"cmd":"vt-state"}"#), Lane::Bulk);
        assert_eq!(
            classify_client_line(br#"{"id":2,"cmd":"copy","mode":"scrollback"}"#),
            Lane::Bulk
        );
        assert_eq!(classify_client_line(br#"{"id":3,"cmd":"list-workspaces"}"#), Lane::Control);
    }

    #[test]
    fn escaped_protocol_names_retain_lane_semantics() {
        let tracker = MuxLaneTracker::default();
        assert_eq!(classify_client_line(br#"{"id":2,"cmd":"vt\u002dstate"}"#), Lane::Bulk);
        assert_eq!(
            tracker.classify_server_line(br#"{"event":"out\u0070ut","data":"YQ=="}"#),
            Some(Lane::Bulk)
        );
    }

    #[test]
    fn mux_mutations_share_input_ordering_lane() {
        for command in ["close-surface", "run", "new-workspace", "set-client-sizing"] {
            let line = format!(r#"{{"id":2,"cmd":"{command}"}}"#);
            assert_eq!(classify_client_line(line.as_bytes()), Lane::Interactive);
        }
    }

    #[test]
    fn large_mux_payload_classification_does_not_allocate() {
        let tracker = MuxLaneTracker::default();
        let mut line = br#"{"event":"output","surface":1,"data":""#.to_vec();
        line.resize(line.len() + 1024 * 1024, b'e');
        line.extend_from_slice(br#""}"#);

        let (lane, allocations) =
            allocation_count(|| tracker.classify_server_line(std::hint::black_box(&line)));

        assert_eq!(lane, Some(Lane::Bulk));
        // This assertion also relies on serde_json skipping the unescaped data
        // string in place. A serde_json parser change may legitimately add a
        // scratch allocation even if lane classification remains bounded.
        assert_eq!(
            allocations, 0,
            "mux classification allocated while skipping a large output payload"
        );
    }
}
