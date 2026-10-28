//! The first-sighting feed: each call site the process's site table records
//! for the first time, and each hang a watcher names, sent to the one
//! consumer that took the feed with [`take_first_sites`] (the daemon's
//! diagnostic-site forwarder, cmux-tui-core `server/diagnostic_sites.rs`,
//! which pushes them to the app's hang reports).
//!
//! Event-driven: nothing is sent until a site is new, and nothing waits. The
//! sender is an unbounded `std::sync::mpsc` channel, whose send never blocks
//! and calls nothing of this crate, so a violation inside the consumer's own
//! code cannot re-enter it. Before [`take_first_sites`] runs, nothing is
//! sent: it replays the sites the table already holds.

use std::sync::OnceLock;
use std::sync::mpsc::{Receiver, Sender, channel};

use super::BlockingKind;

/// One first sighting.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FirstSite {
    /// The first violation the site table recorded at a call site: a
    /// blocking call where blocking is disallowed, a work item's wait for
    /// other work (`lane_sync`), or a priority inversion
    /// ([`BlockingKind::PriorityInversion`]).
    Blocking { file: &'static str, line: u32, column: u32, kind: BlockingKind, lane_sync: bool },
    /// A watched run past its deadline, named by its scope (`request`,
    /// `holder-link`, `journal-writer`) and what it ran (a request's method,
    /// a holder frame). The consumer keeps the first of each pair.
    Hang { scope: &'static str, name: &'static str },
}

static FEED: OnceLock<Sender<FirstSite>> = OnceLock::new();

/// Takes the process's feed: `None` once it was taken. The receiver first
/// gets each site the table already holds (with the lowest kind it saw),
/// then every first sighting as it happens. A site recorded while this runs
/// can come twice; the consumer keeps one.
pub fn take_first_sites() -> Option<Receiver<FirstSite>> {
    let (sender, receiver) = channel();
    let replay = sender.clone();
    FEED.set(sender).ok()?;
    for site in super::snapshot().sites {
        let Some(kind) = site.kinds.iter().next() else { continue };
        let _ = replay.send(FirstSite::Blocking {
            file: site.file,
            line: site.line,
            column: site.column,
            kind,
            lane_sync: site.lane_sync,
        });
    }
    Some(receiver)
}

/// Sends `site` when the feed was taken; a consumer that ended drops it.
pub(super) fn send(site: FirstSite) {
    if let Some(feed) = FEED.get() {
        let _ = feed.send(site);
    }
}

/// A watched run of `scope` named `name` ran past its deadline. Every call
/// sends one [`FirstSite::Hang`] (the consumer keeps the first per pair), so
/// call it where the watcher records, never per scope.
pub fn note_hang_site(scope: &'static str, name: &'static str) {
    send(FirstSite::Hang { scope, name });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blocking::{BlockingMode, assert_blocking_allowed, disallow_blocking, set_mode};

    fn on_disallowed_thread(f: fn() -> u32) -> u32 {
        set_mode(BlockingMode::Record);
        std::thread::Builder::new()
            .name("feed-test".into())
            .spawn(move || {
                disallow_blocking();
                f()
            })
            .expect("spawn test thread")
            .join()
            .expect("test thread")
    }

    /// The only test in this binary that takes the feed.
    #[test]
    fn earlier_sites_are_replayed_then_each_new_site_is_sent_once() {
        let early = on_disallowed_thread(|| {
            let line = line!() + 1;
            assert_blocking_allowed(BlockingKind::Sleep);
            line
        });
        let feed = take_first_sites().expect("the first taker gets the feed");
        assert!(take_first_sites().is_none(), "the feed is taken once per process");
        let late = on_disallowed_thread(|| {
            let mut line = 0;
            for _ in 0..3 {
                line = line!() + 1;
                assert_blocking_allowed(BlockingKind::Fs);
            }
            line
        });
        note_hang_site("request", "feed-test-hang");
        note_hang_site("request", "feed-test-hang");
        let ours: Vec<FirstSite> = feed
            .try_iter()
            .filter(|site| match site {
                FirstSite::Blocking { file, .. } => *file == file!(),
                FirstSite::Hang { name, .. } => *name == "feed-test-hang",
            })
            .map(|site| match site {
                // Columns follow formatting; the line names the site.
                FirstSite::Blocking { file, line, kind, lane_sync, .. } => {
                    FirstSite::Blocking { file, line, column: 0, kind, lane_sync }
                }
                hang => hang,
            })
            .collect();
        let blocking = |line, kind| FirstSite::Blocking {
            file: file!(),
            line,
            column: 0,
            kind,
            lane_sync: false,
        };
        assert_eq!(
            ours,
            vec![
                blocking(early, BlockingKind::Sleep),
                blocking(late, BlockingKind::Fs),
                FirstSite::Hang { scope: "request", name: "feed-test-hang" },
                FirstSite::Hang { scope: "request", name: "feed-test-hang" },
            ]
        );
    }
}
