//! Read a session journal in bounded pages and prepare a replay plan.
//!
//! The durable event log is the source of truth for a replay. Consumers provide the page
//! operation, so this adapter works with the local store and with the cursor-paged
//! `_acpmux/events` route. Every request is capped at [`PAGE_SIZE`], repeated boundary records are
//! removed by sequence number, and the reducer runs once for each unique record. The resulting
//! [`ReplayPlan`] stores timestamped states, allowing a frame renderer to seek by replay time
//! without reading or reducing the journal again.

use anyhow::{Result, anyhow};
use std::collections::BTreeMap;

use crate::store::EventRecord;

/// The maximum number of records requested from one journal page.
pub const PAGE_SIZE: usize = 400;

/// A page returned by a cursor-based journal reader.
#[derive(Debug, Clone, PartialEq)]
pub struct JournalPage {
    /// Records after the requested cursor, oldest first. A server may repeat the cursor boundary
    /// when a retry races a page cache, so callers must not assume every record is new.
    pub events: Vec<EventRecord>,
    /// Whether another page remains after this one.
    pub has_more: bool,
    /// The server's cursor watermark for this page. It can advance past the last returned event
    /// when a filter omits records.
    pub page_through: u64,
}

/// The unique, ordered records collected from a journal and the work spent collecting them.
#[derive(Debug, Clone, PartialEq)]
pub struct JournalReplay {
    pub events: Vec<EventRecord>,
    pub pages: usize,
    pub fetched: usize,
    pub duplicates: usize,
}

/// Read all pages after cursor zero, advancing only through the server watermark or a returned
/// record. A page that claims more data without advancing is rejected instead of looping forever.
pub fn read<F>(mut fetch: F) -> Result<JournalReplay>
where
    F: FnMut(u64, usize) -> Result<JournalPage>,
{
    let mut cursor = 0;
    let mut pages = 0;
    let mut fetched = 0;
    let mut duplicates = 0;
    let mut by_seq = BTreeMap::new();

    loop {
        let page = fetch(cursor, PAGE_SIZE)?;
        if page.events.len() > PAGE_SIZE {
            return Err(anyhow!(
                "journal replay page has {} records, exceeds bound {}",
                page.events.len(),
                PAGE_SIZE
            ));
        }
        pages += 1;
        fetched += page.events.len();
        let mut next = page.page_through.max(cursor);
        for event in page.events {
            if event.seq == 0 {
                continue;
            }
            next = next.max(event.seq);
            if by_seq.insert(event.seq, event).is_some() {
                duplicates += 1;
            }
        }
        if !page.has_more {
            break;
        }
        if next <= cursor {
            return Err(anyhow!("journal replay cursor did not advance past {cursor}"));
        }
        cursor = next;
    }

    Ok(JournalReplay { events: by_seq.into_values().collect(), pages, fetched, duplicates })
}

/// The state reached after one journal record at a replay timestamp.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplayTransition<S> {
    /// The journal sequence that produced this state.
    pub seq: u64,
    /// The record's wall-clock timestamp.
    pub at: u64,
    /// Milliseconds from the first record after long idle gaps are shortened.
    pub time: u64,
    pub state: S,
}

/// A replay reduced once into scheduled state transitions.
#[derive(Debug, Clone, PartialEq)]
pub struct ReplayPlan<S> {
    pub initial: S,
    pub transitions: Vec<ReplayTransition<S>>,
    pub duration: u64,
}

impl<S: Clone> ReplayPlan<S> {
    /// The state visible at replay time `time`. This is a binary search over stored transitions,
    /// so seeking and animation do not reread the journal or invoke the reducer.
    pub fn state_at(&self, time: u64) -> S {
        let mut low = 0;
        let mut high = self.transitions.len();
        while low < high {
            let middle = (low + high) / 2;
            if self.transitions[middle].time <= time {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        low.checked_sub(1)
            .map_or_else(|| self.initial.clone(), |index| self.transitions[index].state.clone())
    }
}

/// Fold ordered journal records into timestamped states. The reducer is called exactly once per
/// record in `events`, and every state is retained for scheduled frame lookup.
pub fn reduce<S, F>(events: &[EventRecord], initial: S, mut reducer: F) -> ReplayPlan<S>
where
    S: Clone,
    F: FnMut(&mut S, &EventRecord),
{
    const IDLE_GAP_MS: u64 = 2_000;
    let mut state = initial.clone();
    let mut transitions = Vec::with_capacity(events.len());
    let mut previous_at = None;
    let mut time = 0;
    for event in events {
        if let Some(previous) = previous_at {
            time += event.at.saturating_sub(previous).min(IDLE_GAP_MS);
        }
        previous_at = Some(event.at);
        reducer(&mut state, event);
        transitions.push(ReplayTransition {
            seq: event.seq,
            at: event.at,
            time,
            state: state.clone(),
        });
    }
    ReplayPlan { initial, transitions, duration: time }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::cell::{Cell, RefCell};

    fn event(seq: u64, at: u64) -> EventRecord {
        EventRecord {
            seq,
            at,
            dir: "mux".into(),
            kind: "status".into(),
            msg: json!({"seq": seq}),
            host_seq: None,
        }
    }

    fn page(events: &[u64], has_more: bool, page_through: u64) -> JournalPage {
        JournalPage {
            events: events.iter().map(|seq| event(*seq, *seq * 100)).collect(),
            has_more,
            page_through,
        }
    }

    #[test]
    fn reads_bounded_pages_and_deduplicates_the_boundary() {
        let asks = RefCell::new(Vec::new());
        let replay = read(|after, limit| {
            asks.borrow_mut().push((after, limit));
            match after {
                0 => Ok(page(&[1, 2], true, 2)),
                2 => Ok(page(&[2, 3], false, 3)),
                _ => unreachable!("unexpected cursor {after}"),
            }
        })
        .unwrap();
        assert_eq!(replay.events.iter().map(|event| event.seq).collect::<Vec<_>>(), [1, 2, 3]);
        assert_eq!(replay.pages, 2);
        assert_eq!(replay.fetched, 4);
        assert_eq!(replay.duplicates, 1);
        assert_eq!(*asks.borrow(), [(0, PAGE_SIZE), (2, PAGE_SIZE)]);
    }

    #[test]
    fn rejects_a_page_that_cannot_advance_its_cursor() {
        let error = read(|after, _| Ok(page(&[after], true, after))).unwrap_err();
        assert!(error.to_string().contains("did not advance"));
    }

    #[test]
    fn reducer_runs_once_and_state_lookup_is_scheduled() {
        let events = [event(1, 10), event(2, 5), event(3, 5), event(4, 10_000)];
        let calls = Cell::new(0);
        let plan = reduce(&events, 0_u64, |state, event| {
            calls.set(calls.get() + 1);
            *state = event.seq;
        });
        assert_eq!(calls.get(), events.len());
        assert_eq!(
            plan.transitions.iter().map(|step| step.time).collect::<Vec<_>>(),
            [0, 0, 0, 2_000]
        );
        assert_eq!(plan.duration, 2_000);
        assert_eq!(plan.state_at(0), 3);
        assert_eq!(plan.state_at(1_999), 3);
        assert_eq!(plan.state_at(2_000), 4);
        assert_eq!(plan.state_at(u64::MAX), 4);
    }
}
