//! The site table behind [`super::snapshot`]: a fixed number of call sites
//! with their kinds and counts, and an overflow count once it is full.

use std::panic::Location;
use std::sync::atomic::{AtomicBool, AtomicPtr, AtomicU16, AtomicU64, Ordering};

use super::report::SiteReport;
use super::{BlockingKind, BlockingKinds, BlockingSite, BlockingSnapshot};

/// Records a violation in `table` and, when a report is open, reports it
/// once per (site, kind, thread), whether or not the table had room. True
/// when it is the first violation the table recorded at this site.
/// `lane_sync` marks a work item's wait for other work.
pub(super) fn note_violation<const N: usize>(
    table: &SiteTable<N>,
    report: Option<&SiteReport>,
    kind: BlockingKind,
    location: &'static Location<'static>,
    lane_sync: bool,
) -> bool {
    let recorded = table.record(location, kind, lane_sync);
    if let Some(report) = report {
        report.first_sighting(location, kind, super::mode(), recorded == Recorded::Overflow);
    }
    recorded == Recorded::Stored { first_at_site: true }
}

struct SiteSlot {
    location: AtomicPtr<Location<'static>>,
    kinds: AtomicU16,
    count: AtomicU64,
    lane_sync: AtomicBool,
}

impl SiteSlot {
    const fn new() -> Self {
        Self {
            location: AtomicPtr::new(std::ptr::null_mut()),
            kinds: AtomicU16::new(0),
            count: AtomicU64::new(0),
            lane_sync: AtomicBool::new(false),
        }
    }
}

/// A fixed open-addressed table of call sites. A slot is claimed once by a
/// compare-exchange of its location and never freed, so recording takes no
/// lock and allocates nothing.
pub(super) struct SiteTable<const N: usize> {
    slots: [SiteSlot; N],
    overflow: AtomicU64,
}

impl<const N: usize> SiteTable<N> {
    pub(super) const fn new() -> Self {
        Self { slots: [const { SiteSlot::new() }; N], overflow: AtomicU64::new(0) }
    }

    fn record(
        &self,
        location: &'static Location<'static>,
        kind: BlockingKind,
        lane_sync: bool,
    ) -> Recorded {
        let wanted = std::ptr::from_ref(location).cast_mut();
        let start = site_hash(location) % N;
        for probe in 0..N {
            let slot = &self.slots[(start + probe) % N];
            let mut current = slot.location.load(Ordering::Acquire);
            if current.is_null() {
                current = match slot.location.compare_exchange(
                    std::ptr::null_mut(),
                    wanted,
                    Ordering::AcqRel,
                    Ordering::Acquire,
                ) {
                    Ok(_) => wanted,
                    Err(winner) => winner,
                };
            }
            // SAFETY: a non-null slot location is a `&'static Location` stored above.
            if same_site(unsafe { &*current }, location) {
                slot.kinds.fetch_or(kind.bit(), Ordering::Relaxed);
                if lane_sync {
                    slot.lane_sync.store(true, Ordering::Relaxed);
                }
                let first_at_site = slot.count.fetch_add(1, Ordering::Relaxed) == 0;
                return Recorded::Stored { first_at_site };
            }
        }
        self.overflow.fetch_add(1, Ordering::Relaxed);
        Recorded::Overflow
    }

    pub(super) fn snapshot(&self) -> BlockingSnapshot {
        let mut sites: Vec<BlockingSite> = self
            .slots
            .iter()
            .filter_map(|slot| {
                let location = slot.location.load(Ordering::Acquire);
                if location.is_null() {
                    return None;
                }
                // SAFETY: a non-null slot location is a `&'static Location`.
                let location = unsafe { &*location };
                Some(BlockingSite {
                    file: location.file(),
                    line: location.line(),
                    column: location.column(),
                    kinds: BlockingKinds(slot.kinds.load(Ordering::Relaxed)),
                    count: slot.count.load(Ordering::Relaxed),
                    lane_sync: slot.lane_sync.load(Ordering::Relaxed),
                })
            })
            .collect();
        sites.sort_by(|a, b| {
            b.count.cmp(&a.count).then_with(|| (a.file, a.line).cmp(&(b.file, b.line)))
        });
        BlockingSnapshot { sites, overflow: self.overflow.load(Ordering::Relaxed) }
    }
}

/// Where one [`SiteTable::record`] call counted the violation.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Recorded {
    /// In the site's slot; `first_at_site` when it is the slot's first count.
    Stored { first_at_site: bool },
    /// The table was full: only in the overflow count.
    Overflow,
}

/// Locations of one call site can be distinct statics (inlined generics), so
/// sites compare and hash by content.
pub(super) fn same_site(a: &Location<'_>, b: &Location<'_>) -> bool {
    a.line() == b.line() && a.column() == b.column() && a.file() == b.file()
}

fn site_hash(location: &Location<'_>) -> usize {
    // FNV-1a over file, line and column.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let line_column = (u64::from(location.line()) << 32) | u64::from(location.column());
    for byte in location.file().bytes().chain(line_column.to_le_bytes()) {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[track_caller]
    fn here() -> &'static Location<'static> {
        Location::caller()
    }

    #[test]
    fn site_table_merges_kinds_and_counts_overflow() {
        let table = SiteTable::<2>::new();
        let first = here();
        let second = here();
        let third = here();
        let first_count = Recorded::Stored { first_at_site: true };
        let later_count = Recorded::Stored { first_at_site: false };
        assert_eq!(table.record(first, BlockingKind::Fs, false), first_count, "the site's first");
        assert_eq!(table.record(first, BlockingKind::Sleep, false), later_count);
        assert_eq!(table.record(first, BlockingKind::Sleep, false), later_count);
        assert_eq!(table.record(second, BlockingKind::Recv, true), first_count);
        assert_eq!(table.record(third, BlockingKind::Join, false), Recorded::Overflow);
        assert_eq!(table.record(third, BlockingKind::Join, false), Recorded::Overflow);
        let snapshot = table.snapshot();
        assert_eq!(snapshot.sites.len(), 2);
        assert_eq!(snapshot.overflow, 2);
        let first_site = snapshot.site(first.file(), first.line()).expect("first");
        assert_eq!(first_site.count, 3);
        assert_eq!(
            first_site.kinds.iter().collect::<Vec<_>>(),
            vec![BlockingKind::Fs, BlockingKind::Sleep]
        );
        assert_eq!(snapshot.sites[0], *first_site);
        assert!(!first_site.lane_sync);
        assert!(snapshot.site(second.file(), second.line()).expect("second").lane_sync);
    }

    /// Every (site, kind, thread) gets one line, the sites past a full table
    /// included: they are the ones only the report can name.
    #[test]
    fn the_report_has_each_site_kind_and_thread_once_past_a_full_table() {
        let dir =
            std::env::temp_dir().join(format!("cmux-threads-sites-report-{}", std::process::id()));
        let report = SiteReport::open(&dir).expect("open a report");
        let table = SiteTable::<2>::new();
        let [first, second, third, fourth] = [here(), here(), here(), here()];
        let note = |kind, location| note_violation(&table, Some(&report), kind, location, false);
        std::thread::scope(|scope| {
            std::thread::Builder::new()
                .name("sites-report-a".into())
                .spawn_scoped(scope, || {
                    for location in [first, first, second, third, third, fourth] {
                        note(BlockingKind::Fs, location);
                    }
                    note(BlockingKind::Sleep, first);
                })
                .expect("spawn a")
                .join()
                .expect("thread a");
            std::thread::Builder::new()
                .name("sites-report-b".into())
                .spawn_scoped(scope, || {
                    note(BlockingKind::Fs, first);
                    note(BlockingKind::Fs, fourth);
                    note(BlockingKind::Fs, fourth);
                })
                .expect("spawn b")
                .join()
                .expect("thread b");
        });
        let path = dir.join(format!("blocking-{}.jsonl", std::process::id()));
        let text = std::fs::read_to_string(&path).expect("read the report");
        let _ = std::fs::remove_dir_all(&dir);
        let key = |thread: &str, location: &Location<'_>, kind: &str, overflow: bool| {
            format!(
                "\"thread\":\"{thread}\",\"file\":\"{}\",\"line\":{},\"column\":{},\"kind\":\"{kind}\",\
                 \"mode\":\"{}\",\"overflow\":{overflow}}}",
                location.file().replace('\\', "\\\\"),
                location.line(),
                location.column(),
                match super::super::mode() {
                    super::super::BlockingMode::Record => "record",
                    super::super::BlockingMode::Panic => "panic",
                },
            )
        };
        let expected = [
            key("sites-report-a", first, "fs", false),
            key("sites-report-a", second, "fs", false),
            key("sites-report-a", third, "fs", true),
            key("sites-report-a", fourth, "fs", true),
            key("sites-report-a", first, "sleep", false),
            key("sites-report-b", first, "fs", false),
            key("sites-report-b", fourth, "fs", true),
        ];
        let lines: Vec<&str> = text.lines().collect();
        assert_eq!(lines.len(), expected.len(), "{text}");
        for (line, expected) in lines.iter().zip(&expected) {
            assert!(line.ends_with(expected.as_str()), "{line}\nwanted {expected}");
        }
        assert_eq!(table.snapshot().overflow, 5);
    }
}
