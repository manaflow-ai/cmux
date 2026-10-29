//! `SetThreadQos`: the daemon tells a terminal's host the
//! class its PTY reader and parser threads run at, utility while no view
//! shows the terminal. The host stores it in [`HostShared::thread_qos`];
//! each thread applies it itself after its next wake, so the message wakes
//! neither thread.

use cmux_threads::ThreadQos;

use super::super::*;
use super::host_shared::HostShared;

/// One byte: the class's place in [`ThreadQos::ALL`] (its `repr(u8)`).
pub(crate) fn encode_thread_qos(qos: ThreadQos) -> [u8; 1] {
    [qos as u8]
}

/// The class of a `SetThreadQos` payload; `None` for any other length or
/// an unknown class.
pub(crate) fn decode_thread_qos(payload: &[u8]) -> Option<ThreadQos> {
    match payload {
        [raw] => ThreadQos::ALL.get(usize::from(*raw)).copied(),
        _ => None,
    }
}

impl HostShared {
    /// The daemon's `SetThreadQos`: the PTY reader and parser threads run
    /// at `qos` from their next wake.
    pub(crate) fn set_thread_qos(&self, qos: ThreadQos) {
        self.thread_qos.request(qos);
    }
}

impl HostAttachment {
    /// Sends the class the host's per-terminal threads run at. `Ok(false)`
    /// without a write when the record does not advertise `SetThreadQos`:
    /// an older host would end the connection on the unknown message.
    pub(crate) fn send_thread_qos(&self, qos: ThreadQos) -> std::io::Result<bool> {
        if !self.record.supports_thread_qos {
            return Ok(false);
        }
        self.send(MessageKind::SetThreadQos, &encode_thread_qos(qos))?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_class_round_trips_and_other_payloads_are_refused() {
        for qos in ThreadQos::ALL {
            assert_eq!(decode_thread_qos(&encode_thread_qos(qos)), Some(qos));
        }
        assert_eq!(decode_thread_qos(&[]), None);
        assert_eq!(decode_thread_qos(&[5]), None);
        assert_eq!(decode_thread_qos(&[1, 0]), None);
    }
}
