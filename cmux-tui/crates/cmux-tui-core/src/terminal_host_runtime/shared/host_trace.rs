//! Trace control on a terminal host (p09-observability-015): the daemon's
//! `TraceControl` request, the host's answer and its `TraceControlAck`.
//!
//! Request payload: `op u8` (1 start, 2 stop, 3 status), `categories u64`.
//! It names no path: the host records into `<host root>/trace`, next to its
//! discovery record. Ack payload: `outcome u8` (0 traced, else a
//! [`TraceError`] code), `recording u8`, `pid u32`, `recording_bytes u64`,
//! `records_dropped u64`, then the recording ring's path as UTF-8 (empty when
//! it has none). A host advertises the request in its record
//! (`supports_trace_control`); the daemon never sends it to one that does not.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use cmux_trace::{ControlOp, Role, TraceError};

use super::super::*;
use super::attachment::{HostAttachment, PendingControlResponse};
use super::host_shared::HostShared;
use super::host_state::HostTap;
use crate::panic_free::RecoverPoison;
use crate::process_trace::{TraceReport, TracedState};
use crate::terminal_host_protocol::{wire_u32, wire_u64};

const OP_START: u8 = 1;
const OP_STOP: u8 = 2;
const OP_STATUS: u8 = 3;
const REQUEST_LEN: usize = 9;

const OUTCOME_TRACED: u8 = 0;
const OUTCOME_NOT_INITIALIZED: u8 = 1;
const OUTCOME_ALREADY_RECORDING: u8 = 2;
const OUTCOME_NOT_RECORDING: u8 = 3;
const ACK_HEADER_LEN: usize = 22;
/// A ring path longer than this is not sent (the ack says traced, no path).
const MAX_ACK_PATH_BYTES: usize = 4096;

pub(crate) fn encode_request(op: ControlOp) -> Vec<u8> {
    let (code, categories) = match op {
        ControlOp::Start { categories } => (OP_START, categories),
        ControlOp::Stop => (OP_STOP, 0),
        ControlOp::Status => (OP_STATUS, 0),
    };
    let mut payload = Vec::with_capacity(REQUEST_LEN);
    payload.push(code);
    payload.extend_from_slice(&categories.to_le_bytes());
    payload
}

pub(crate) fn decode_request(payload: &[u8]) -> Option<ControlOp> {
    if payload.len() != REQUEST_LEN {
        return None;
    }
    let categories = wire_u64(payload, 1)?;
    match payload[0] {
        OP_START => Some(ControlOp::Start { categories }),
        OP_STOP if categories == 0 => Some(ControlOp::Stop),
        OP_STATUS if categories == 0 => Some(ControlOp::Status),
        _ => None,
    }
}

pub(crate) fn encode_ack(report: &TraceReport) -> Vec<u8> {
    let (outcome, traced) = match &report.state {
        Ok(traced) => (OUTCOME_TRACED, Some(traced)),
        Err(TraceError::NotInitialized) => (OUTCOME_NOT_INITIALIZED, None),
        Err(TraceError::AlreadyRecording) => (OUTCOME_ALREADY_RECORDING, None),
        Err(TraceError::NotRecording) => (OUTCOME_NOT_RECORDING, None),
    };
    let path = traced
        .and_then(|traced| traced.recording_path.as_deref())
        .and_then(Path::to_str)
        .filter(|path| path.len() <= MAX_ACK_PATH_BYTES)
        .unwrap_or("");
    let mut payload = Vec::with_capacity(ACK_HEADER_LEN + path.len());
    payload.push(outcome);
    payload.push(u8::from(traced.is_some_and(|traced| traced.recording)));
    payload.extend_from_slice(&report.pid.to_le_bytes());
    payload.extend_from_slice(&traced.map_or(0, |traced| traced.recording_bytes).to_le_bytes());
    payload.extend_from_slice(&traced.map_or(0, |traced| traced.records_dropped).to_le_bytes());
    payload.extend_from_slice(path.as_bytes());
    payload
}

pub(crate) fn decode_ack(payload: &[u8]) -> Option<TraceReport> {
    if payload.len() < ACK_HEADER_LEN || payload.len() > ACK_HEADER_LEN + MAX_ACK_PATH_BYTES {
        return None;
    }
    let pid = wire_u32(payload, 2)?;
    let state = match payload[0] {
        OUTCOME_TRACED => {
            let path = std::str::from_utf8(&payload[ACK_HEADER_LEN..]).ok()?;
            Ok(TracedState {
                recording: match payload[1] {
                    0 => false,
                    1 => true,
                    _ => return None,
                },
                recording_path: (!path.is_empty()).then(|| PathBuf::from(path)),
                recording_bytes: wire_u64(payload, 6)?,
                records_dropped: wire_u64(payload, 14)?,
            })
        }
        OUTCOME_NOT_INITIALIZED => Err(TraceError::NotInitialized),
        OUTCOME_ALREADY_RECORDING => Err(TraceError::AlreadyRecording),
        OUTCOME_NOT_RECORDING => Err(TraceError::NotRecording),
        _ => return None,
    };
    Some(TraceReport { pid, state })
}

/// Where a host whose discovery record is at `record_path` records.
pub(crate) fn host_trace_dir(record_path: &Path) -> PathBuf {
    record_path.parent().unwrap_or(record_path).join("trace")
}

/// Answers one `TraceControl` on its own thread, since the first start maps
/// the recording file and the client-input thread carries keystrokes. False
/// when the thread could not start (the connection ends).
pub(crate) fn answer(
    host: Arc<HostShared>,
    sender: HostTap,
    op: ControlOp,
    request_id: u64,
    version: u16,
) -> bool {
    let dir = host_trace_dir(&host.exit_record_path);
    std::thread::Builder::new()
        .name("cmux-host-trace".into())
        .spawn(move || {
            let outcome = cmux_trace::apply_control(op, &dir, Role::TerminalHost);
            let mut response = Frame::new(
                MessageKind::TraceControlAck,
                encode_ack(&TraceReport::of_this_process(outcome)),
            );
            response.version = version;
            response.request_id = request_id;
            // Targeted responses share the writer with live frames: keep an
            // atomic Output/Colors pair whole, as MintCapability does.
            let _broadcast = host.broadcast_lock.lock().recover_poison();
            sender.try_send(response);
        })
        .is_ok()
}

/// A `TraceControl` on the wire whose ack has not been read yet.
pub(crate) struct PendingHostTrace {
    pending: PendingControlResponse,
}

impl HostAttachment {
    /// Sends `op` to the host. Refused without a write when its record does
    /// not advertise trace control: it would end the connection on the
    /// unknown message.
    pub(crate) fn begin_trace_control(
        &self,
        op: ControlOp,
        deadline: Instant,
    ) -> Result<PendingHostTrace, String> {
        if !self.record.supports_trace_control {
            return Err("terminal host does not take trace control".to_owned());
        }
        self.begin_control_request(
            MessageKind::TraceControl,
            MessageKind::TraceControlAck,
            encode_request(op),
            deadline,
        )
        .map(|pending| PendingHostTrace { pending })
        .map_err(|failure| format!("{:#}", failure.into_error()))
    }
}

impl PendingHostTrace {
    /// The host's report, or why there is none. A late ack is dropped on
    /// arrival and keeps the connection (trace control is advisory).
    pub(crate) fn wait(self) -> Result<TraceReport, String> {
        let payload =
            self.pending.wait(false).map_err(|failure| format!("{:#}", failure.into_error()))?;
        decode_ack(&payload).ok_or_else(|| "terminal host sent a malformed trace ack".to_owned())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_control_requests_round_trip_and_carry_no_path() {
        for op in [ControlOp::Start { categories: 0x2_0040 }, ControlOp::Stop, ControlOp::Status] {
            let payload = encode_request(op);
            assert_eq!(payload.len(), REQUEST_LEN);
            assert_eq!(decode_request(&payload), Some(op));
        }
        assert_eq!(decode_request(&[OP_STOP, 1, 0, 0, 0, 0, 0, 0, 0]), None);
        assert_eq!(decode_request(&[9; REQUEST_LEN]), None);
        let mut long = encode_request(ControlOp::Status);
        long.extend_from_slice(b"/tmp/x");
        assert_eq!(decode_request(&long), None);
    }

    #[test]
    fn trace_control_acks_round_trip() {
        let reports = [
            TraceReport {
                pid: 77,
                state: Ok(TracedState {
                    recording: true,
                    recording_path: Some(PathBuf::from(
                        "/s/h/trace/terminal-host-77.recording.cmxtrace",
                    )),
                    recording_bytes: 573_440,
                    records_dropped: 3,
                }),
            },
            TraceReport {
                pid: 78,
                state: Ok(TracedState {
                    recording: false,
                    recording_path: None,
                    recording_bytes: 0,
                    records_dropped: 0,
                }),
            },
            TraceReport { pid: 79, state: Err(TraceError::NotInitialized) },
            TraceReport { pid: 80, state: Err(TraceError::AlreadyRecording) },
            TraceReport { pid: 81, state: Err(TraceError::NotRecording) },
        ];
        for report in reports {
            assert_eq!(decode_ack(&encode_ack(&report)), Some(report));
        }
        assert_eq!(decode_ack(&[0; ACK_HEADER_LEN - 1]), None);
        let mut bad_flag =
            encode_ack(&TraceReport { pid: 1, state: Err(TraceError::NotRecording) });
        bad_flag[0] = OUTCOME_TRACED;
        bad_flag[1] = 2;
        assert_eq!(decode_ack(&bad_flag), None);
    }

    #[test]
    fn a_host_records_next_to_its_discovery_record() {
        assert_eq!(
            host_trace_dir(Path::new("/state/s.terminal-hosts/abc.exit")),
            PathBuf::from("/state/s.terminal-hosts/trace")
        );
    }
}
