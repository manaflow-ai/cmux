//! The key-press flow of one terminal's input
//! ([`crate::wire::capability::WRITE_FLOW`]): which master read is the echo
//! of a WRITE that carried a flow.
//!
//! A flow is armed only once every input byte up to the end of its WRITE
//! reached the master, so output the PTY held before the input never takes
//! it. An armed flow marks the next read within [`ECHO_WINDOW`]; after
//! that it is dropped, so input that never echoes marks no later output.
//! A flow mark with no input (sent before the daemon writes on its custody
//! master) is armed at once: best effort, as the holder may read that echo
//! before it handles the mark.

use std::time::{Duration, Instant};

use super::{Holder, error_code};
use crate::wire;

/// How long an armed flow waits for its echo.
pub(super) const ECHO_WINDOW: Duration = Duration::from_secs(1);

#[derive(Default)]
pub(super) struct InputFlow {
    /// Input bytes queued for the master so far.
    queued: u64,
    /// Input bytes written to the master so far.
    written: u64,
    /// A flow and the `queued` offset its input ends at, not yet written.
    pending: Option<(u64, u64)>,
    /// A flow whose input reached the master, and when.
    armed: Option<(u64, Instant)>,
}

impl InputFlow {
    /// A WRITE queued `len` input bytes, with `flow` (`None`: none).
    pub(super) fn queued(&mut self, len: usize, flow: Option<u64>) {
        self.queued += len as u64;
        let Some(flow) = flow.filter(|flow| *flow != 0) else { return };
        self.armed = None;
        self.pending = None;
        if len == 0 {
            self.armed = Some((flow, Instant::now()));
        } else {
            self.pending = Some((flow, self.queued));
        }
    }

    /// `n` queued bytes reached the master.
    pub(super) fn written(&mut self, n: usize) {
        self.written += n as u64;
        if let Some((flow, end)) = self.pending
            && self.written >= end
        {
            self.pending = None;
            self.armed = Some((flow, Instant::now()));
        }
    }

    /// The queued input was dropped (nobody reads the PTY): no echo comes.
    pub(super) fn discarded(&mut self) {
        self.written = self.queued;
        self.pending = None;
    }

    /// The flow a master read carries (0: none), once.
    pub(super) fn take(&mut self) -> u64 {
        match self.armed.take() {
            Some((flow, at)) if at.elapsed() <= ECHO_WINDOW => flow,
            _ => 0,
        }
    }
}

impl Holder {
    /// Queue a WRITE's input for the PTY. With [`wire::FLAG_FLOW`] its
    /// trailer is the key press's flow ([`InputFlow`]), never written to
    /// the shell.
    pub(super) fn queue_input(
        &mut self,
        chan: u32,
        flags: u16,
        payload: &[u8],
    ) -> Result<(), (u16, String)> {
        let (bytes, flow) = wire::split_write(flags, payload)
            .map_err(|error| (error_code::BAD_PAYLOAD, error.to_string()))?;
        let terminal = self.terminal(chan)?;
        terminal.input.extend(bytes);
        terminal.flow.queued(bytes.len(), flow);
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_flow_marks_only_a_read_after_its_input_was_written() {
        let mut flow = InputFlow::default();
        flow.queued(3, Some(42));
        assert_eq!(flow.take(), 0, "output read before the input was written");
        flow.written(2);
        assert_eq!(flow.take(), 0, "part of the input is still queued");
        flow.written(1);
        assert_eq!(flow.take(), 42);
        assert_eq!(flow.take(), 0, "once");
    }

    #[test]
    fn a_flow_follows_input_queued_before_it() {
        let mut flow = InputFlow::default();
        flow.queued(4, None);
        flow.queued(1, Some(7));
        flow.written(4);
        assert_eq!(flow.take(), 0);
        flow.written(1);
        assert_eq!(flow.take(), 7);
    }

    #[test]
    fn a_mark_without_input_arms_at_once_and_a_newer_flow_replaces_it() {
        let mut flow = InputFlow::default();
        flow.queued(0, Some(9));
        flow.queued(2, Some(10));
        assert_eq!(flow.take(), 0, "the newer flow waits for its input");
        flow.written(2);
        assert_eq!(flow.take(), 10);
    }

    #[test]
    fn discarded_input_never_arms_and_a_stale_flow_marks_nothing() {
        let mut flow = InputFlow::default();
        flow.queued(5, Some(3));
        flow.discarded();
        flow.written(0);
        assert_eq!(flow.take(), 0);
        flow.queued(1, Some(4));
        flow.written(1);
        let stale = ECHO_WINDOW + Duration::from_millis(1);
        flow.armed = flow.armed.map(|(id, at)| (id, at.checked_sub(stale).unwrap()));
        assert_eq!(flow.take(), 0, "an echo that never came marks no later output");
    }
}
