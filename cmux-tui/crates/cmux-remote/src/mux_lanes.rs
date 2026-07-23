use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use cmux_remote_protocol::Lane;
use serde_json::Value;

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

impl MuxLaneTracker {
    pub(crate) fn observe_request(&self, line: &[u8], lane: Lane) {
        let Ok(value) = serde_json::from_slice::<Value>(line) else { return };
        if let Some(id) = value.get("id").and_then(Value::as_u64) {
            self.track(id, ResponseDisposition::Forward(lane));
        }
    }

    pub(crate) fn suppress_response(&self, id: u64) {
        self.track(id, ResponseDisposition::Suppress);
    }

    pub(crate) fn classify_server_line(&self, line: &[u8]) -> Option<Lane> {
        let Ok(value) = serde_json::from_slice::<Value>(line) else {
            return Some(Lane::Control);
        };
        if let Some(event) = value.get("event").and_then(Value::as_str) {
            return Some(match event {
                "output" | "vt-state" | "frame" | "browser-state" => Lane::Bulk,
                _ => Lane::Control,
            });
        }
        match value
            .get("id")
            .and_then(Value::as_u64)
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
    let Ok(value) = serde_json::from_slice::<Value>(line) else { return Lane::Control };
    match value.get("cmd").and_then(Value::as_str) {
        Some("attach-surface" | "read-screen" | "read-scrollback" | "vt-state") => Lane::Bulk,
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
    use super::*;

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
        assert_eq!(classify_client_line(br#"{"id":3,"cmd":"list-workspaces"}"#), Lane::Control);
    }

    #[test]
    fn mux_mutations_share_input_ordering_lane() {
        for command in ["close-surface", "run", "new-workspace", "set-client-sizing"] {
            let line = format!(r#"{{"id":2,"cmd":"{command}"}}"#);
            assert_eq!(classify_client_line(line.as_bytes()), Lane::Interactive);
        }
    }
}
