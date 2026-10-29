//! The holder's part of a daemon trace recording and of an exact echo flow,
//! through its capability bits ([`cmux_holder::wire::capability`]):
//! only a holder that granted TRACE_CONTROL gets
//! TRACE_START and TRACE_STOP, only one that granted WRITE_FLOW a flow
//! trailer. Any other holder is `holder_untraced`. The daemon's
//! `trace.start`, `trace.stop` and `trace.status`
//! and the exact echo flow call these.

use std::io;

use cmux_holder::link::{HolderLink, TraceForward};
use cmux_holder::wire::TraceStart;

use super::HolderService;
use crate::panic_free::RecoverPoison;

/// What the holder does for a daemon trace recording (`trace.status`). The
/// holder is told only through [`cmux_holder::wire::capability::TRACE_CONTROL`]
/// and answers with its refusal, never through a guess from its version or
/// its timing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum HolderTrace {
    /// The holder granted the capability and refused no control frame.
    Traced,
    /// It refused the last TRACE_START or TRACE_STOP (its tracer did not
    /// start, the recording ring is over the budget, one already runs):
    /// the holder's message.
    Refused(String),
    /// It did not grant the capability (a holder of an older build, or one
    /// whose tracer does not run): it got nothing.
    Untraced,
    /// No holder link is open (none runs, or one is restarting): a holder
    /// that starts meanwhile gets the recording when its link is published.
    NotLinked,
}

impl HolderTrace {
    /// The `trace.status` word (the holder's `reason` in
    /// `server/trace_control.rs`, whose tests hold the two equal).
    #[cfg_attr(not(test), expect(dead_code, reason = "the reply words; tests compare them"))]
    pub(crate) fn as_str(&self) -> &'static str {
        match self {
            HolderTrace::Traced => "holder_traced",
            HolderTrace::Refused(_) => "holder_trace_failed",
            HolderTrace::Untraced => "holder_untraced",
            HolderTrace::NotLinked => "holder_not_linked",
        }
    }

    fn of(link: Option<&HolderLink>) -> Self {
        match link {
            Some(link) if link.traced() => {
                link.trace_refusal().map_or(HolderTrace::Traced, HolderTrace::Refused)
            }
            Some(_) => HolderTrace::Untraced,
            None => HolderTrace::NotLinked,
        }
    }
}

impl HolderService {
    /// Start the holder's trace recording of `categories` within
    /// `budget_bytes` ring bytes (0: no limit), and every later holder's
    /// while it runs. Only a holder that granted TRACE_CONTROL gets the
    /// frame; its refusal comes back later ([`Self::trace_state`]). Never
    /// connects or starts a holder.
    pub(crate) fn trace_start(&self, categories: u64, budget_bytes: u64) -> HolderTrace {
        self.change_recording(Some(TraceStart { categories, budget_bytes }))
    }

    /// Stop the holder's trace recording. Never connects.
    pub(crate) fn trace_stop(&self) -> HolderTrace {
        self.change_recording(None)
    }

    /// What the holder does for the recording now (`trace.status`).
    pub(crate) fn trace_state(&self) -> HolderTrace {
        HolderTrace::of(self.open_link().as_deref())
    }

    /// Record `recording` and send it to the open link, both under
    /// `trace_control`: a publish in between cannot reorder them.
    fn change_recording(&self, recording: Option<TraceStart>) -> HolderTrace {
        let _trace = self.trace_control.lock().recover_poison();
        let link = {
            let mut slot = self.link.lock().recover_poison();
            slot.trace = recording;
            slot.link.clone().filter(|link| link.is_open())
        };
        let Some(link) = link else { return HolderTrace::NotLinked };
        let sent = match recording {
            Some(start) => link.trace_start(start.categories, start.budget_bytes),
            None => link.trace_stop(),
        };
        forwarded(sent)
    }

    /// Send a just-published link the running recording, if one runs
    /// (`trace_control` held by the publish).
    pub(super) fn send_recording(&self, link: &HolderLink) {
        let Some(start) = self.link.lock().recover_poison().trace else { return };
        if let Err(error) = link.trace_start(start.categories, start.budget_bytes) {
            eprintln!("cmux-tui: start the terminal holder's trace: {error}");
        }
    }

    /// Tell the holder the next output of `chan` answers key press `flow`,
    /// for input the daemon writes on its custody master: call it before
    /// that write. Only an empty WRITE carries the flow, and only to a
    /// holder that granted WRITE_FLOW. Best effort: the holder may read the
    /// echo before it handles the mark. False when nothing was sent (no
    /// flow, no open link, or a holder without the capability). Never
    /// connects.
    pub(crate) fn mark_input_flow(&self, chan: u32, flow: u64) -> bool {
        if flow == 0 {
            return false;
        }
        self.open_link()
            .filter(|link| link.takes_write_flow())
            .is_some_and(|link| link.write_flow(chan, &[], flow).is_ok())
    }
}

/// The state a trace control send leaves.
fn forwarded(sent: io::Result<TraceForward>) -> HolderTrace {
    match sent {
        // A refusal comes back later: trace_state reads it.
        Ok(TraceForward::Sent) => HolderTrace::Traced,
        Ok(TraceForward::Untraced) => HolderTrace::Untraced,
        // The link broke: the next one gets the recording on publish.
        Err(_) => HolderTrace::NotLinked,
    }
}

#[cfg(test)]
mod tests {
    use std::os::fd::AsRawFd;
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    use cmux_holder::holder::error_code;
    use cmux_holder::wire::{self, Frame, Kind, Out, capability};

    use super::super::tests::{next_frame, stand_in_service, welcome_granting};
    use super::*;

    /// A recording budget with room for a holder's ring.
    const BUDGET: u64 = 16 << 20;

    fn temp_socket(prefix: &str) -> (PathBuf, PathBuf) {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |elapsed| elapsed.subsec_nanos());
        let dir = std::env::temp_dir().join(format!("{prefix}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("h.sock");
        (dir, socket)
    }

    /// Every frame on `stream` up to the test's SIGNAL on channel 999.
    fn frames_until_sentinel(stream: &UnixStream, reader: &mut wire::Reader) -> Vec<Frame> {
        let mut frames = Vec::new();
        loop {
            let frame = next_frame(stream, reader, "the test's SIGNAL");
            if frame.kind == Kind::Signal as u16 && frame.chan == 999 {
                return frames;
            }
            frames.push(frame);
        }
    }

    /// A holder that granted TRACE_CONTROL and
    /// WRITE_FLOW gets the recording and the flow mark; a holder that
    /// restarts while the recording runs gets it when its link is
    /// published, without another `trace.start`.
    #[test]
    fn a_granted_holder_gets_the_recording_and_the_flow_mark() {
        let (dir, socket) = temp_socket("cht");
        let listener = UnixListener::bind(&socket).unwrap();
        let granted = capability::TRACE_CONTROL | capability::WRITE_FLOW;
        let stand_in = std::thread::spawn(move || {
            let (first, _) = listener.accept().unwrap();
            first.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut reader = wire::Reader::default();
            welcome_granting(&first, &mut reader, &[], Some(granted));
            let seen = frames_until_sentinel(&first, &mut reader);
            // The holder dies: the restarted link gets the running recording.
            first.shutdown(std::net::Shutdown::Both).unwrap();
            drop(first);
            let (second, _) = listener.accept().unwrap();
            second.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut reader = wire::Reader::default();
            welcome_granting(&second, &mut reader, &[], Some(granted));
            let restarted = frames_until_sentinel(&second, &mut reader);
            (seen, restarted, second)
        });

        let service = stand_in_service(socket);
        let link = service.link().unwrap();
        assert_eq!(service.trace_start(0x4400, BUDGET), HolderTrace::Traced);
        assert_eq!(service.trace_state().as_str(), "holder_traced");
        assert!(service.mark_input_flow(5, 42), "a granted holder takes the flow mark");
        assert!(!service.mark_input_flow(5, 0), "no flow, no frame");
        link.signal(999, 0).unwrap();
        wait_for_relink(&service, &link);
        service.link().unwrap().signal(999, 0).unwrap();
        let (seen, restarted, second) = stand_in.join().expect("the stand-in saw both SIGNALs");

        let start = TraceStart { categories: 0x4400, budget_bytes: BUDGET };
        assert_eq!(seen.len(), 2, "TRACE_START and one WRITE: {seen:?}");
        assert_eq!((seen[0].kind, seen[0].chan), (Kind::TraceStart as u16, 0));
        assert_eq!(TraceStart::decode(&seen[0].payload).unwrap(), start);
        assert_eq!(
            (seen[1].kind, seen[1].flags, seen[1].chan),
            (Kind::Write as u16, wire::FLAG_FLOW, 5)
        );
        assert_eq!(
            wire::split_write(seen[1].flags, &seen[1].payload).unwrap(),
            (&[][..], Some(42))
        );
        assert_eq!(restarted.len(), 1, "the new holder gets the recording: {restarted:?}");
        assert_eq!(TraceStart::decode(&restarted[0].payload).unwrap(), start);

        service.superseded.store(true, Ordering::Release);
        drop(service);
        drop(second);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Wait until the service published a link other than `old`.
    fn wait_for_relink(service: &Arc<HolderService>, old: &Arc<HolderLink>) {
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(link) = service.open_link()
                && !Arc::ptr_eq(&link, old)
            {
                return;
            }
            assert!(std::time::Instant::now() < deadline, "no new link");
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    /// A holder older than the capability bits (its
    /// WELCOME has no grant: the v3 and v5 holders already shipped) is
    /// `holder_untraced` and gets neither TRACE_START, TRACE_STOP nor a
    /// WRITE flow trailer. No guess from its version or timing.
    #[test]
    fn an_older_holder_is_untraced_and_gets_no_new_frame() {
        let (dir, socket) = temp_socket("chu");
        let listener = UnixListener::bind(&socket).unwrap();
        let stand_in = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut reader = wire::Reader::default();
            welcome_granting(&stream, &mut reader, &[], None);
            (frames_until_sentinel(&stream, &mut reader), stream)
        });

        let service = stand_in_service(socket);
        assert_eq!(service.trace_state(), HolderTrace::NotLinked);
        let link = service.link().unwrap();
        assert_eq!(link.capabilities(), 0);
        assert_eq!(service.trace_start(u64::MAX, 0), HolderTrace::Untraced);
        assert_eq!(service.trace_state().as_str(), "holder_untraced");
        assert!(!service.mark_input_flow(5, 42), "no WRITE_FLOW, no flow mark");
        assert_eq!(service.trace_stop(), HolderTrace::Untraced);
        link.signal(999, 0).unwrap();
        let (seen, stream) = stand_in.join().expect("the stand-in saw the test's SIGNAL");
        assert!(seen.is_empty(), "an older holder got a frame: {seen:?}");

        service.superseded.store(true, Ordering::Release);
        drop(link);
        drop(service);
        drop(stream);
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A holder that granted TRACE_CONTROL but
    /// refused the recording (here: its tracer never started) is
    /// `holder_trace_failed` with its message, never `holder_traced`.
    #[test]
    fn a_refused_recording_is_reported_failed() {
        let (dir, socket) = temp_socket("chr");
        let listener = UnixListener::bind(&socket).unwrap();
        let stand_in = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            stream.set_read_timeout(Some(Duration::from_secs(20))).unwrap();
            let mut reader = wire::Reader::default();
            welcome_granting(&stream, &mut reader, &[], Some(capability::TRACE_CONTROL));
            let start = next_frame(&stream, &mut reader, "TRACE_START");
            assert_eq!(start.kind, Kind::TraceStart as u16);
            let refusal = Out::default()
                .u16(Kind::TraceStart as u16)
                .u16(error_code::TRACE_FAILED)
                .bytes(b"tracing is not initialised in this process")
                .0;
            let error = wire::encode(Kind::Error, 0, &refusal);
            wire::send_all(stream.as_raw_fd(), &error, &[]).unwrap();
            frames_until_sentinel(&stream, &mut reader);
            stream
        });

        let service = stand_in_service(socket);
        let link = service.link().unwrap();
        assert_eq!(service.trace_start(0x4400, BUDGET), HolderTrace::Traced, "sent");
        let deadline = std::time::Instant::now() + Duration::from_secs(20);
        while service.trace_state() == HolderTrace::Traced {
            assert!(std::time::Instant::now() < deadline, "no refusal");
            std::thread::sleep(Duration::from_millis(10));
        }
        let state = service.trace_state();
        assert_eq!(
            state,
            HolderTrace::Refused("tracing is not initialised in this process".to_string())
        );
        assert_eq!(state.as_str(), "holder_trace_failed");
        link.signal(999, 0).unwrap();
        let stream = stand_in.join().expect("the stand-in saw the test's SIGNAL");

        service.superseded.store(true, Ordering::Release);
        drop(link);
        drop(service);
        drop(stream);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
