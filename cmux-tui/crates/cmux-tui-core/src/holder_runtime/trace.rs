//! Trace control of the holder (p09-observability-015): the daemon forwards
//! `trace-start` and `trace-stop` only on a link whose WELCOME granted
//! TRACE_CONTROL (task 096). A holder without the grant gets no frame and is
//! reported `holder_untraced`: an older holder would end the link on a kind
//! it does not know. The frames carry a category mask and a record count,
//! never a path; the holder records into its holder-lifetime directory.

use std::io;

use cmux_holder::link::HolderLink;
use cmux_trace::{ControlOp, RECORDS_PER_CHUNK, Role};

/// What the holder side of one link offers trace control.
pub(crate) trait HolderTraceLink {
    /// The holder granted TRACE_CONTROL in its WELCOME.
    fn grants_trace_control(&self) -> bool;
    /// Writes TRACE_START (`categories`, `records`) or TRACE_STOP.
    fn send_trace(&self, op: HolderTraceFrame) -> io::Result<()>;
}

/// The two holder frames of TRACE_CONTROL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HolderTraceFrame {
    Start { categories: u64, records: u32 },
    Stop,
}

/// What forwarding one control call to the holder did.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum HolderTrace {
    /// No grant: no frame went out.
    Untraced,
    /// The frame went out (a status sends none: the holder records while
    /// the daemon's recording runs).
    Traced,
    Failed(String),
}

impl HolderTrace {
    /// Forwards `op` on `link`.
    pub(crate) fn forward(link: &dyn HolderTraceLink, op: ControlOp) -> HolderTrace {
        if !link.grants_trace_control() {
            return HolderTrace::Untraced;
        }
        let frame = match op {
            ControlOp::Start { categories } => HolderTraceFrame::Start {
                categories,
                records: Role::Holder.recording_sizes().chunk_count * RECORDS_PER_CHUNK,
            },
            ControlOp::Stop => HolderTraceFrame::Stop,
            ControlOp::Status => return HolderTrace::Traced,
        };
        match link.send_trace(frame) {
            Ok(()) => HolderTrace::Traced,
            Err(error) => HolderTrace::Failed(error.to_string()),
        }
    }
}

/// A holder of this build grants no TRACE_CONTROL yet: the grant and its
/// two frames arrive with task 096's WELCOME capability bits.
impl HolderTraceLink for HolderLink {
    fn grants_trace_control(&self) -> bool {
        false
    }

    fn send_trace(&self, _: HolderTraceFrame) -> io::Result<()> {
        Err(io::ErrorKind::Unsupported.into())
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use super::*;

    struct FakeLink {
        granted: bool,
        frames: Mutex<Vec<HolderTraceFrame>>,
    }

    impl HolderTraceLink for FakeLink {
        fn grants_trace_control(&self) -> bool {
            self.granted
        }

        fn send_trace(&self, frame: HolderTraceFrame) -> io::Result<()> {
            self.frames.lock().unwrap().push(frame);
            Ok(())
        }
    }

    fn link(granted: bool) -> FakeLink {
        FakeLink { granted, frames: Mutex::default() }
    }

    #[test]
    fn trace_control_sends_a_holder_without_the_grant_no_frame() {
        let holder = link(false);
        for op in [ControlOp::Start { categories: 1 }, ControlOp::Status, ControlOp::Stop] {
            assert_eq!(HolderTrace::forward(&holder, op), HolderTrace::Untraced);
        }
        assert!(holder.frames.lock().unwrap().is_empty());
    }

    #[test]
    fn trace_control_sends_a_granted_holder_its_mask_and_record_count() {
        let holder = link(true);
        let start = HolderTrace::forward(&holder, ControlOp::Start { categories: 0x40 });
        assert_eq!(start, HolderTrace::Traced);
        assert_eq!(HolderTrace::forward(&holder, ControlOp::Status), HolderTrace::Traced);
        assert_eq!(HolderTrace::forward(&holder, ControlOp::Stop), HolderTrace::Traced);
        assert_eq!(
            *holder.frames.lock().unwrap(),
            [
                HolderTraceFrame::Start { categories: 0x40, records: 8192 * RECORDS_PER_CHUNK },
                HolderTraceFrame::Stop,
            ]
        );
    }
}
