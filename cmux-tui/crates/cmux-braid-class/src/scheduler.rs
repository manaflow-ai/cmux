//! One class scheduler: strict priority across classes, each class bounded by bytes and
//! full by its own [`DropRule`].

use std::collections::VecDeque;

use crate::{Class, DropRule};

/// What [`Scheduler::offer`] did with an item.
#[derive(Debug, PartialEq, Eq)]
pub enum Offer<T> {
    /// Queued.
    Queued,
    /// Queued; it replaced the older state for its stream, returned here (latest wins).
    Replaced(T),
    /// Queued; the oldest bulk item made room and is returned here.
    DroppedOldest(T),
    /// The class is full: the item is handed back, nothing was queued.
    Refused(T),
}

struct Queue<T> {
    items: VecDeque<(u64, usize, T)>,
    bytes: usize,
    limit: usize,
}

/// Items of type `T` queued by [`Class`]. `stream` keys latest-wins for [`Class::State`];
/// other classes ignore it.
pub struct Scheduler<T> {
    queues: [Queue<T>; 4],
}

impl<T> Scheduler<T> {
    /// `limits` are the byte bounds per class, in [`Class::ALL`] order.
    pub fn new(limits: [usize; 4]) -> Self {
        Self { queues: limits.map(|limit| Queue { items: VecDeque::new(), bytes: 0, limit }) }
    }

    pub fn offer(&mut self, class: Class, stream: u64, len: usize, item: T) -> Offer<T> {
        let queue = &mut self.queues[class.rank() as usize];
        match class.drop_rule() {
            DropRule::LatestWins => {
                if let Some(slot) = queue.items.iter_mut().find(|(s, _, _)| *s == stream) {
                    let (_, old_len, old) = std::mem::replace(slot, (stream, len, item));
                    queue.bytes = queue.bytes - old_len + len;
                    return Offer::Replaced(old);
                }
                if queue.bytes + len > queue.limit && !queue.items.is_empty() {
                    return Offer::Refused(item);
                }
            }
            DropRule::RefuseNewest => {
                if queue.bytes + len > queue.limit && !queue.items.is_empty() {
                    return Offer::Refused(item);
                }
            }
            DropRule::DropOldest => {
                if queue.bytes + len > queue.limit
                    && let Some((_, old_len, old)) = queue.items.pop_front()
                {
                    queue.bytes -= old_len;
                    queue.bytes += len;
                    queue.items.push_back((stream, len, item));
                    return Offer::DroppedOldest(old);
                }
            }
        }
        queue.bytes += len;
        queue.items.push_back((stream, len, item));
        Offer::Queued
    }

    /// The next item to send: the highest class with anything queued, oldest first.
    pub fn next(&mut self) -> Option<(Class, T)> {
        Class::ALL.into_iter().find_map(|class| {
            let queue = &mut self.queues[class.rank() as usize];
            let (_, len, item) = queue.items.pop_front()?;
            queue.bytes -= len;
            Some((class, item))
        })
    }

    pub fn queued_bytes(&self, class: Class) -> usize {
        self.queues[class.rank() as usize].bytes
    }

    pub fn is_empty(&self) -> bool {
        self.queues.iter().all(|q| q.items.is_empty())
    }
}

#[cfg(test)]
#[path = "scheduler_tests.rs"]
mod tests;
