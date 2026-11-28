//! Priority lanes over one link. Frames are bounded (a chunk is at most four
//! times the CDC average), so a faulted read waits at most one frame per
//! stream behind the background fill, never behind a whole file.

use std::collections::VecDeque;
use std::io;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Lane {
    Manifest = 0,
    Fault = 1,
    Hot = 2,
    Fill = 3,
}

pub const LANES: [Lane; 4] = [Lane::Manifest, Lane::Fault, Lane::Hot, Lane::Fill];

/// Where a lane's frames go. Today's carrier is the daemon's mux (manifest, fault and hot as
/// interactive traffic, fill as `frame::Lane::Bulk`); Braid's paced bulk class (RFD 0164 class 3)
/// implements this when it lands, with no change to the scheduler.
pub trait LaneSink<T> {
    fn send(&mut self, lane: Lane, item: T) -> io::Result<()>;
}

/// Sends everything queued, in scheduler order, stopping at the first carrier error (the
/// item that failed is the caller's to resume from its manifest).
pub fn drain<T>(s: &mut Scheduler<T>, sink: &mut impl LaneSink<T>) -> io::Result<usize> {
    let mut sent = 0;
    while let Some((lane, item)) = s.pop() {
        sink.send(lane, item)?;
        sent += 1;
    }
    Ok(sent)
}

/// Strict priority, except the fill keeps one frame in `fill_every` so a
/// stream of faults cannot starve it forever.
pub struct Scheduler<T> {
    queues: [VecDeque<T>; 4],
    fill_every: u32,
    since_fill: u32,
}

impl<T> Scheduler<T> {
    pub fn new(fill_every: u32) -> Self {
        Self { queues: Default::default(), fill_every: fill_every.max(1), since_fill: 0 }
    }

    fn queue(&mut self, lane: Lane) -> &mut VecDeque<T> {
        let [manifest, fault, hot, fill] = &mut self.queues;
        match lane {
            Lane::Manifest => manifest,
            Lane::Fault => fault,
            Lane::Hot => hot,
            Lane::Fill => fill,
        }
    }

    pub fn push(&mut self, lane: Lane, item: T) {
        self.queue(lane).push_back(item);
    }

    /// Moves a queued item to the fault lane (an agent read a file the fill had not sent yet).
    pub fn promote(&mut self, from: Lane, pick: impl Fn(&T) -> bool) -> bool {
        let q = self.queue(from);
        if let Some(item) = q.iter().position(pick).and_then(|i| q.remove(i)) {
            self.queue(Lane::Fault).push_back(item);
            return true;
        }
        false
    }

    pub fn pop(&mut self) -> Option<(Lane, T)> {
        if self.since_fill + 1 >= self.fill_every && !self.queue(Lane::Fill).is_empty() {
            self.since_fill = 0;
            return self.queue(Lane::Fill).pop_front().map(|t| (Lane::Fill, t));
        }
        for lane in LANES {
            if let Some(t) = self.queue(lane).pop_front() {
                self.since_fill = if lane == Lane::Fill { 0 } else { self.since_fill + 1 };
                return Some((lane, t));
            }
        }
        None
    }

    pub fn is_empty(&self) -> bool {
        self.queues.iter().all(VecDeque::is_empty)
    }
}

#[cfg(test)]
#[path = "lanes_tests.rs"]
mod tests;
