//! The holder loop's hang watch ([`wire::capability::HANG_REPORT`]): each
//! pass of the loop's work, after `poll` returns and never the wait itself,
//! is one 100 ms [`HangScope`](cmux_threads::HangScope) of the process's
//! `mux-hang-watch` thread, as Chrome watches each task a thread runs and
//! not its idle wait (base/threading/hang_watcher.h, `WatchHangsInScope`
//! around `ThreadControllerWithMessagePumpImpl::DoWork`). The holder has no
//! hang log of its own: a pass seen past its deadline becomes one
//! [`Kind::Hang`] frame to the daemon, which writes it to its hang log.
//!
//! The watcher thread hands each record to the loop through a bounded
//! channel and wakes the loop (its self-pipe); the loop queues the frames on
//! its next pass. No lock is taken on the loop: the channel's `try_recv` is
//! one atomic load while nothing waits.

use std::io;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, SyncSender, TryRecvError, sync_channel};
use std::time::Duration;

use cmux_threads::{HangRecord, HangSite, HangWatcher};

use super::Holder;
use crate::wire::{self, Kind};

/// One pass of the holder loop's work: every terminal's echo waits behind it.
pub static HOLDER_LOOP: HangSite = HangSite::new("holder-loop", Duration::from_millis(100));

/// Records waiting for the loop; a watcher that finds it full drops the
/// record (the loop is stuck, and the ones queued already say so).
const REPORT_QUEUE: usize = 16;

/// The loop's hang watcher and the records it saw.
pub struct HangWatch {
    watcher: Arc<HangWatcher>,
    reports: Receiver<HangRecord>,
}

impl HangWatch {
    /// Starts the process's `mux-hang-watch` thread; each record wakes the
    /// loop.
    pub fn start() -> io::Result<Self> {
        Self::start_with(super::wake_loop)
    }

    fn start_with(wake: fn()) -> io::Result<Self> {
        let (sender, reports) = sync_channel(REPORT_QUEUE);
        let watcher = HangWatcher::start(Box::new(move |record| forward(&sender, record, wake)))?;
        Ok(Self { watcher: Arc::new(watcher), reports })
    }

    /// The watcher, for its [`HangWatcher::snapshot`].
    pub fn watcher(&self) -> Arc<HangWatcher> {
        Arc::clone(&self.watcher)
    }
}

fn forward(sender: &SyncSender<HangRecord>, record: &HangRecord, wake: fn()) {
    if sender.try_send(record.clone()).is_ok() {
        wake();
    }
}

impl Holder {
    /// Watch every pass of the loop with `watch` and report its hangs to a
    /// link granted [`wire::capability::HANG_REPORT`].
    pub fn set_hang_watch(&mut self, watch: HangWatch) {
        self.hangs = Some(watch);
    }

    /// The watcher a pass opens its scope on, `None` with no hang watch.
    pub(super) fn pass_watcher(&self) -> Option<Arc<HangWatcher>> {
        self.hangs.as_ref().map(|hangs| Arc::clone(&hangs.watcher))
    }

    /// Queue one [`Kind::Hang`] per record the watcher saw, on a link
    /// granted [`wire::capability::HANG_REPORT`]; with no such link the
    /// records are dropped (no daemon hang log to write them to).
    pub(super) fn send_hang_reports(&mut self) {
        loop {
            let record = match self.hangs.as_ref().map(|hangs| hangs.reports.try_recv()) {
                Some(Ok(record)) => record,
                None | Some(Err(TryRecvError::Empty | TryRecvError::Disconnected)) => return,
            };
            if !self.granted(wire::capability::HANG_REPORT) {
                continue;
            }
            let report = wire::HangReport {
                deadline_ms: record.deadline_ms,
                busy_ms: record.busy_ms,
                site: record.site.to_owned(),
            };
            self.queue(Kind::Hang, 0, &report.encode(), Vec::new());
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::Instant;

    use super::*;

    static WAKES: AtomicU32 = AtomicU32::new(0);

    fn count_wake() {
        WAKES.fetch_add(1, Ordering::SeqCst);
    }

    /// A pass that stalls 150 ms is one record naming `holder-loop`, and it
    /// wakes the loop; a 10 ms pass is none.
    #[test]
    fn a_stalled_pass_is_one_record_that_wakes_the_loop() {
        let watch = HangWatch::start_with(count_wake).unwrap();
        {
            let _pass = watch.watcher.scope(&HOLDER_LOOP);
            std::thread::sleep(Duration::from_millis(10));
        }
        {
            let _pass = watch.watcher.scope(&HOLDER_LOOP);
            std::thread::sleep(Duration::from_millis(150));
        }
        let deadline = Instant::now() + Duration::from_secs(5);
        let record = loop {
            match watch.reports.try_recv() {
                Ok(record) => break record,
                Err(_) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("no hang record: {error}"),
            }
        };
        assert_eq!((record.site, record.deadline_ms), ("holder-loop", 100));
        assert!(record.busy_ms >= 100, "{record:?}");
        assert!(WAKES.load(Ordering::SeqCst) >= 1);
        std::thread::sleep(Duration::from_millis(250));
        assert!(watch.reports.try_recv().is_err(), "one record per stalled pass");
        assert_eq!(watch.watcher.snapshot().total, 1);
    }

    #[test]
    fn a_hang_report_round_trips() {
        let report =
            wire::HangReport { deadline_ms: 100, busy_ms: 153, site: "holder-loop".into() };
        assert_eq!(wire::HangReport::decode(&report.encode()).unwrap(), report);
        assert!(wire::HangReport::decode(&[0; 8]).is_err());
    }
}
