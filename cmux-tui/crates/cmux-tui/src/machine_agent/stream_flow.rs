//! Per-stream send credit shared by a stream's local reader thread and the
//! generation worker, and the payload bounds both rely on.

use std::sync::Mutex;

use cmux_threads::sync::Condvar;
use cmux_tui_machine_agent_protocol::{self as protocol, DataPayload};

use super::error_code::AgentErrorCode;

pub(super) struct StreamFlow {
    state: Mutex<StreamFlowState>,
    available: Condvar,
}

struct StreamFlowState {
    credit: u32,
    closed: bool,
    reader_result: Option<AgentErrorCode>,
}

impl StreamFlow {
    pub(super) fn new(credit: u32) -> Self {
        Self {
            state: Mutex::new(StreamFlowState { credit, closed: false, reader_result: None }),
            available: Condvar::new(),
        }
    }

    pub(super) fn reserve(&self) -> Option<usize> {
        let mut state = self.state.lock().ok()?;
        while state.credit == 0 && !state.closed {
            state = self.available.wait(state).ok()?;
        }
        if state.closed {
            return None;
        }
        let reserved = state.credit.min(protocol::MAX_DATA_BYTES as u32);
        state.credit -= reserved;
        Some(reserved as usize)
    }

    pub(super) fn return_credit(&self, bytes: u32) {
        if let Ok(mut state) = self.state.lock() {
            state.credit =
                state.credit.saturating_add(bytes).min(protocol::MAX_STREAM_WINDOW_BYTES);
            self.available.notify_all();
        }
    }

    pub(super) fn add_credit(&self, bytes: u32) -> bool {
        let Ok(mut state) = self.state.lock() else { return false };
        let Some(total) = state.credit.checked_add(bytes) else { return false };
        if total > protocol::MAX_STREAM_WINDOW_BYTES || state.closed {
            return false;
        }
        state.credit = total;
        self.available.notify_all();
        true
    }

    pub(super) fn mark_reader_done(&self, code: AgentErrorCode) {
        if let Ok(mut state) = self.state.lock() {
            state.closed = true;
            state.reader_result.get_or_insert(code);
            self.available.notify_all();
        }
    }

    pub(super) fn close(&self, code: AgentErrorCode) {
        self.mark_reader_done(code);
    }

    pub(super) fn reader_result(&self) -> Option<AgentErrorCode> {
        self.state.lock().ok()?.reader_result
    }
}

const _: () = assert!(protocol::MAX_DATA_BYTES <= u32::MAX as usize);

#[allow(
    clippy::expect_used,
    reason = "INVARIANT: DataPayload holds at most MAX_DATA_BYTES, asserted above to fit u32"
)]
pub(super) fn payload_len(payload: &DataPayload) -> u32 {
    u32::try_from(payload.as_bytes().len()).expect("protocol payload length fits u32")
}

#[allow(
    clippy::expect_used,
    reason = "INVARIANT: the local reader reads into a buffer of StreamFlow::reserve bytes, \
              which is at most MAX_DATA_BYTES"
)]
pub(super) fn bounded_local_read(payload: Vec<u8>) -> DataPayload {
    DataPayload::new(payload).expect("bounded local read")
}
