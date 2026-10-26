//! The holder's part of a daemon trace recording and of an exact echo flow,
//! through its capability bits ([`cmux_holder::wire::capability`],
//! p09-observability-096): only a holder that granted TRACE_CONTROL gets
//! TRACE_START and TRACE_STOP, only one that granted WRITE_FLOW a flow
//! trailer. Any other holder is `holder_untraced`.

// The daemon's trace.start, trace.stop and trace.status (p09-observability-015) and the exact
// echo flow (p09-observability-018) call these.
#![cfg_attr(not(test), expect(dead_code, reason = "called by p09-observability-015 and -018"))]

use std::io;
use std::sync::Arc;

use cmux_holder::link::{HolderLink, TraceForward};
use cmux_holder::wire::TraceStart;

use super::HolderService;
use crate::panic_free::RecoverPoison;

/// What the holder does for a daemon trace recording (`trace.status`). The
/// holder is told only through [`cmux_holder::wire::capability::TRACE_CONTROL`],
/// never through a guess from its version or its timing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum HolderTrace {
    /// The holder granted the capability: it got the frame.
    Traced,
    /// It did not (a holder of an older build): it got nothing.
    Untraced,
    /// No holder link is open (none runs, or one is restarting): a holder
    /// that starts meanwhile gets the recording when its link is published.
    NotLinked,
}

impl HolderTrace {
    /// The `trace.status` word.
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            HolderTrace::Traced => "holder_traced",
            HolderTrace::Untraced => "holder_untraced",
            HolderTrace::NotLinked => "holder_not_linked",
        }
    }

    fn of(link: Option<&HolderLink>) -> Self {
        match link {
            Some(link) if link.traced() => HolderTrace::Traced,
            Some(_) => HolderTrace::Untraced,
            None => HolderTrace::NotLinked,
        }
    }
}

impl HolderService {
    /// Start the holder's trace recording of `categories` within `records`
    /// (0: its role's default), and every later holder's while it runs.
    /// Only a holder that granted TRACE_CONTROL gets the frame. Never
    /// connects or starts a holder.
    pub(crate) fn trace_start(&self, categories: u64, records: u32) -> HolderTrace {
        let link = {
            let mut slot = self.link.lock().recover_poison();
            slot.trace = Some(TraceStart { categories, records });
            slot.link.clone().filter(|link| link.is_open())
        };
        self.forward_trace(link, |link| link.trace_start(categories, records))
    }

    /// Stop the holder's trace recording. Never connects.
    pub(crate) fn trace_stop(&self) -> HolderTrace {
        let link = {
            let mut slot = self.link.lock().recover_poison();
            slot.trace = None;
            slot.link.clone().filter(|link| link.is_open())
        };
        self.forward_trace(link, HolderLink::trace_stop)
    }

    /// Whether the holder takes trace control now (`trace.status`).
    pub(crate) fn trace_state(&self) -> HolderTrace {
        HolderTrace::of(self.open_link().as_deref())
    }

    fn forward_trace(
        &self,
        link: Option<Arc<HolderLink>>,
        send: impl FnOnce(&HolderLink) -> io::Result<TraceForward>,
    ) -> HolderTrace {
        let Some(link) = link else { return HolderTrace::NotLinked };
        match send(&link) {
            Ok(TraceForward::Sent) => HolderTrace::Traced,
            Ok(TraceForward::Untraced) => HolderTrace::Untraced,
            // The link broke: the next one gets the recording on publish.
            Err(_) => HolderTrace::NotLinked,
        }
    }

    /// Tell the holder the next output of `chan` answers key press `flow`:
    /// the daemon wrote its input on its custody master, so only an empty
    /// WRITE carries the flow, and only to a holder that granted
    /// WRITE_FLOW. False when nothing was sent (no flow, no open link, or
    /// a holder without the capability). Never connects.
    pub(crate) fn mark_input_flow(&self, chan: u32, flow: u64) -> bool {
        if flow == 0 {
            return false;
        }
        self.open_link()
            .filter(|link| link.takes_write_flow())
            .is_some_and(|link| link.write_flow(chan, &[], flow).is_ok())
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::{UnixListener, UnixStream};
    use std::path::PathBuf;
    use std::sync::atomic::Ordering;
    use std::time::Duration;

    use cmux_holder::wire::{self, Frame, Kind, capability};

    use super::super::tests::{next_frame, stand_in_service, welcome_granting};
    use super::*;

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

    /// p09-observability-096: a holder that granted TRACE_CONTROL and
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
        assert_eq!(service.trace_start(0x4400, 8192), HolderTrace::Traced);
        assert_eq!(service.trace_state().as_str(), "holder_traced");
        assert!(service.mark_input_flow(5, 42), "a granted holder takes the flow mark");
        assert!(!service.mark_input_flow(5, 0), "no flow, no frame");
        link.signal(999, 0).unwrap();
        wait_for_relink(&service, &link);
        service.link().unwrap().signal(999, 0).unwrap();
        let (seen, restarted, second) = stand_in.join().expect("the stand-in saw both SIGNALs");

        let start = TraceStart { categories: 0x4400, records: 8192 };
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

    /// p09-observability-096: a holder older than the capability bits (its
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
}
