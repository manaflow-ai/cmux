//! Daemon-side attachment pieces that do not touch the OS (cx-ko2e): the
//! receipt a durable input write waits on. `HostAttachment` itself follows
//! once its stream calls go through `sys::HostStream`.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::Duration;

use super::super::sys::HostStream;
use super::super::*;
use super::control_responses::ControlResponses;

pub(crate) struct InputAckReceipt {
    pub(crate) request_id: u64,
    pub(crate) receiver: Receiver<Frame>,
    pub(crate) control_responses: Arc<ControlResponses>,
    pub(crate) shutdown: Arc<HostStream>,
    pub(crate) bytes: usize,
}

impl InputAckReceipt {
    pub(crate) fn abort_connection(&self) {
        let _ = self.shutdown.shutdown(std::net::Shutdown::Both);
    }

    pub(crate) fn wait(self) -> std::io::Result<()> {
        self.wait_for(CONTROL_RESPONSE_TIMEOUT)
    }

    pub(crate) fn wait_for(self, timeout: Duration) -> std::io::Result<()> {
        match self.receiver.recv_timeout(timeout) {
            Ok(frame) => {
                if !frame.payload.is_empty() {
                    self.abort_connection();
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "terminal host returned a malformed input acknowledgement",
                    ));
                }
                Ok(())
            }
            Err(error) => {
                self.control_responses.waiters.lock().unwrap().remove(&self.request_id);
                // Shutdown uses a separately cloned socket handle. A timed-out
                // receipt therefore does not wait behind another frame writer
                // before it can abort the broken attachment.
                self.abort_connection();
                let kind = match error {
                    RecvTimeoutError::Timeout => std::io::ErrorKind::TimedOut,
                    RecvTimeoutError::Disconnected => std::io::ErrorKind::ConnectionAborted,
                };
                Err(std::io::Error::new(
                    kind,
                    format!("terminal host did not acknowledge receipted input: {error}"),
                ))
            }
        }
    }
}

impl Drop for InputAckReceipt {
    fn drop(&mut self) {
        let abandoned =
            self.control_responses.waiters.lock().unwrap().remove(&self.request_id).is_some();
        self.control_responses.release_input_ack(self.bytes);
        if abandoned {
            // A submitted request whose confirmation is abandoned can still
            // produce a late targeted ACK. Close this attachment now rather
            // than letting that late frame fail the production reader later.
            self.abort_connection();
        }
    }
}
