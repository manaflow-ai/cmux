//! Per-subscriber mux event delivery with bounded coalesced state.

use std::collections::{BTreeMap, HashMap, VecDeque};
use std::sync::mpsc::{RecvError, RecvTimeoutError, TryRecvError};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

use crate::{MuxEvent, SurfaceId, TreeDeltaKind};

// A subscriber may drain accepted events after crossing this limit, then observes a disconnect.
const MAX_PENDING_EVENTS: usize = 4_096;

#[derive(Default)]
pub struct MuxEventBroadcaster {
    subscribers: Mutex<Vec<MuxEventSubscriber>>,
}

struct MuxEventSubscriber {
    mailbox: Weak<MuxEventMailbox>,
    filter: MuxEventFilter,
}

#[derive(Clone, Copy)]
enum MuxEventFilter {
    All,
    AttachedSurface(SurfaceId),
}

pub struct MuxEventReceiver {
    mailbox: Arc<MuxEventMailbox>,
}

#[derive(Default)]
struct MuxEventMailbox {
    state: Mutex<MuxEventMailboxState>,
    changed: Condvar,
}

#[derive(Default)]
struct MuxEventMailboxState {
    next_sequence: u128,
    events: VecDeque<(u128, MuxEvent)>,
    title_sequences: HashMap<SurfaceId, u128>,
    titles: BTreeMap<u128, (SurfaceId, Arc<str>)>,
    surface_output_sequences: HashMap<SurfaceId, u128>,
    surface_outputs: BTreeMap<u128, SurfaceId>,
    closed: bool,
    overflowed: bool,
}

impl MuxEventBroadcaster {
    pub fn subscribe(&self) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::All)
    }

    pub fn subscribe_attached_surface(&self, surface: SurfaceId) -> MuxEventReceiver {
        self.subscribe_with_filter(MuxEventFilter::AttachedSurface(surface))
    }

    fn subscribe_with_filter(&self, filter: MuxEventFilter) -> MuxEventReceiver {
        let mailbox = Arc::new(MuxEventMailbox::default());
        self.subscribers
            .lock()
            .unwrap()
            .push(MuxEventSubscriber { mailbox: Arc::downgrade(&mailbox), filter });
        MuxEventReceiver { mailbox }
    }

    pub fn emit(&self, event: MuxEvent) {
        let mut subscribers = self.subscribers.lock().unwrap();
        subscribers.retain(|subscriber| {
            let Some(mailbox) = subscriber.mailbox.upgrade() else { return false };
            !subscriber.filter.accepts(&event) || mailbox.push(event.clone())
        });
    }
}

impl MuxEventFilter {
    fn accepts(self, event: &MuxEvent) -> bool {
        match self {
            Self::All => true,
            Self::AttachedSurface(surface) => match event {
                MuxEvent::Notification(notification) => notification.surface == Some(surface),
                MuxEvent::ScrollChanged { surface: event_surface, .. } => *event_surface == surface,
                _ => false,
            },
        }
    }
}

impl Drop for MuxEventBroadcaster {
    fn drop(&mut self) {
        for subscriber in self.subscribers.get_mut().unwrap().drain(..) {
            if let Some(mailbox) = subscriber.mailbox.upgrade() {
                mailbox.close();
            }
        }
    }
}

impl MuxEventMailbox {
    fn push(&self, event: MuxEvent) -> bool {
        let mut state = self.state.lock().unwrap();
        if state.closed {
            return false;
        }
        let sequence = state.next_sequence;
        state.next_sequence = state.next_sequence.saturating_add(1);
        match event {
            MuxEvent::TitleChanged { surface, title } => {
                if let Some(previous) = state.title_sequences.get(&surface).copied() {
                    state.titles.remove(&previous);
                } else if !state.reserve_pending_slot() {
                    self.changed.notify_all();
                    return false;
                }
                state.title_sequences.insert(surface, sequence);
                state.titles.insert(sequence, (surface, title));
            }
            MuxEvent::SurfaceOutput(surface) => {
                if let Some(previous) = state.surface_output_sequences.get(&surface).copied() {
                    state.surface_outputs.remove(&previous);
                } else if !state.reserve_pending_slot() {
                    self.changed.notify_all();
                    return false;
                }
                state.surface_output_sequences.insert(surface, sequence);
                state.surface_outputs.insert(sequence, surface);
            }
            MuxEvent::SurfaceExited(surface) => {
                if let Some(previous) = state.title_sequences.remove(&surface) {
                    state.titles.remove(&previous);
                }
                if let Some(previous) = state.surface_output_sequences.remove(&surface) {
                    state.surface_outputs.remove(&previous);
                }
                if !state.reserve_pending_slot() {
                    self.changed.notify_all();
                    return false;
                }
                state.events.push_back((sequence, MuxEvent::SurfaceExited(surface)));
            }
            MuxEvent::Empty => {
                let mut terminal_events = state
                    .events
                    .iter()
                    .filter(|(_, event)| {
                        matches!(event, MuxEvent::SurfaceExited(_))
                            || matches!(
                                event,
                                MuxEvent::TreeDelta(delta)
                                    if delta.kind == TreeDeltaKind::WorkspaceClosed
                            )
                    })
                    .cloned()
                    .collect::<Vec<_>>();
                let keep = MAX_PENDING_EVENTS.saturating_sub(1);
                if terminal_events.len() > keep {
                    terminal_events.drain(..terminal_events.len() - keep);
                }
                state.events.clear();
                state.title_sequences.clear();
                state.titles.clear();
                state.surface_output_sequences.clear();
                state.surface_outputs.clear();
                state.events.extend(terminal_events);
                state.events.push_back((sequence, MuxEvent::Empty));
            }
            event => {
                if !state.reserve_pending_slot() {
                    self.changed.notify_all();
                    return false;
                }
                state.events.push_back((sequence, event));
            }
        }
        self.changed.notify_one();
        true
    }

    fn close(&self) {
        self.state.lock().unwrap().closed = true;
        self.changed.notify_all();
    }
}

impl MuxEventMailboxState {
    fn reserve_pending_slot(&mut self) -> bool {
        if self.events.len() + self.titles.len() + self.surface_outputs.len() < MAX_PENDING_EVENTS {
            true
        } else {
            self.closed = true;
            self.overflowed = true;
            false
        }
    }

    fn pop(&mut self) -> Option<MuxEvent> {
        let event_sequence = self.events.front().map(|(sequence, _)| *sequence);
        let title_sequence = self.titles.first_key_value().map(|(sequence, _)| *sequence);
        let surface_output_sequence =
            self.surface_outputs.first_key_value().map(|(sequence, _)| *sequence);
        let next_sequence = [event_sequence, title_sequence, surface_output_sequence]
            .into_iter()
            .flatten()
            .min()?;
        if event_sequence == Some(next_sequence) {
            self.events.pop_front().map(|(_, event)| event)
        } else if title_sequence == Some(next_sequence) {
            let (_, (surface, title)) = self.titles.pop_first()?;
            self.title_sequences.remove(&surface);
            Some(MuxEvent::TitleChanged { surface, title })
        } else {
            let (_, surface) = self.surface_outputs.pop_first()?;
            self.surface_output_sequences.remove(&surface);
            Some(MuxEvent::SurfaceOutput(surface))
        }
    }
}

impl MuxEventReceiver {
    pub fn overflowed(&self) -> bool {
        self.mailbox.state.lock().unwrap().overflowed
    }

    pub fn recv(&self) -> Result<MuxEvent, RecvError> {
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(event) = state.pop() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvError);
            }
            state = self.mailbox.changed.wait(state).unwrap();
        }
    }

    pub fn try_recv(&self) -> Result<MuxEvent, TryRecvError> {
        let mut state = self.mailbox.state.lock().unwrap();
        if let Some(event) = state.pop() {
            Ok(event)
        } else if state.closed {
            Err(TryRecvError::Disconnected)
        } else {
            Err(TryRecvError::Empty)
        }
    }

    pub fn try_iter(&self) -> impl Iterator<Item = MuxEvent> + '_ {
        std::iter::from_fn(|| self.try_recv().ok())
    }

    pub fn recv_timeout(&self, timeout: Duration) -> Result<MuxEvent, RecvTimeoutError> {
        let started = Instant::now();
        let mut remaining = timeout;
        let mut state = self.mailbox.state.lock().unwrap();
        loop {
            if let Some(event) = state.pop() {
                return Ok(event);
            }
            if state.closed {
                return Err(RecvTimeoutError::Disconnected);
            }
            let (next, waited) = self.mailbox.changed.wait_timeout(state, remaining).unwrap();
            state = next;
            if waited.timed_out() {
                if let Some(event) = state.pop() {
                    return Ok(event);
                }
                if state.closed {
                    return Err(RecvTimeoutError::Disconnected);
                }
                return Err(RecvTimeoutError::Timeout);
            }
            remaining = timeout.saturating_sub(started.elapsed());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_churn_keeps_one_latest_value_per_surface_and_subscriber() {
        let broadcaster = MuxEventBroadcaster::default();
        let fast = broadcaster.subscribe();
        let slow = broadcaster.subscribe();

        broadcaster.emit(MuxEvent::TitleChanged { surface: 1, title: "first".into() });
        assert!(matches!(
            fast.recv().unwrap(),
            MuxEvent::TitleChanged { surface: 1, title } if title.as_ref() == "first"
        ));
        for index in 0..10_000 {
            broadcaster
                .emit(MuxEvent::TitleChanged { surface: 1, title: format!("one-{index}").into() });
            broadcaster
                .emit(MuxEvent::TitleChanged { surface: 2, title: format!("two-{index}").into() });
        }

        for receiver in [&fast, &slow] {
            assert!(matches!(
                receiver.recv().unwrap(),
                MuxEvent::TitleChanged { surface: 1, title } if title.as_ref() == "one-9999"
            ));
            assert!(matches!(
                receiver.recv().unwrap(),
                MuxEvent::TitleChanged { surface: 2, title } if title.as_ref() == "two-9999"
            ));
            assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
        }
    }

    #[test]
    fn title_fanout_shares_the_payload_allocation() {
        let broadcaster = MuxEventBroadcaster::default();
        let first = broadcaster.subscribe();
        let second = broadcaster.subscribe();
        let title = Arc::<str>::from("shared title");

        broadcaster.emit(MuxEvent::TitleChanged { surface: 1, title: title.clone() });

        for events in [first, second] {
            let MuxEvent::TitleChanged { title: received, .. } = events.recv().unwrap() else {
                panic!("expected title event");
            };
            assert!(Arc::ptr_eq(&title, &received));
        }
    }

    #[test]
    fn coalesced_title_keeps_its_latest_position_between_other_events() {
        let broadcaster = MuxEventBroadcaster::default();
        let events = broadcaster.subscribe();

        broadcaster.emit(MuxEvent::TitleChanged { surface: 1, title: "old".into() });
        broadcaster.emit(MuxEvent::Bell(2));
        broadcaster.emit(MuxEvent::TitleChanged { surface: 1, title: "latest".into() });
        broadcaster.emit(MuxEvent::SurfaceExited(3));

        assert!(matches!(events.recv().unwrap(), MuxEvent::Bell(2)));
        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::TitleChanged { surface: 1, title } if title.as_ref() == "latest"
        ));
        assert!(matches!(events.recv().unwrap(), MuxEvent::SurfaceExited(3)));
    }

    #[test]
    fn surface_exit_discards_its_pending_title() {
        let broadcaster = MuxEventBroadcaster::default();
        let events = broadcaster.subscribe();

        broadcaster.emit(MuxEvent::TitleChanged { surface: 4, title: "gone".into() });
        broadcaster.emit(MuxEvent::SurfaceExited(4));

        assert!(matches!(events.recv().unwrap(), MuxEvent::SurfaceExited(4)));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn surface_output_churn_keeps_one_latest_position_per_surface() {
        let broadcaster = MuxEventBroadcaster::default();
        let events = broadcaster.subscribe();

        broadcaster.emit(MuxEvent::SurfaceOutput(1));
        broadcaster.emit(MuxEvent::Bell(2));
        for _ in 0..10_000 {
            broadcaster.emit(MuxEvent::SurfaceOutput(1));
            broadcaster.emit(MuxEvent::SurfaceOutput(3));
        }
        broadcaster.emit(MuxEvent::SurfaceExited(4));

        assert!(matches!(events.recv().unwrap(), MuxEvent::Bell(2)));
        assert!(matches!(events.recv().unwrap(), MuxEvent::SurfaceOutput(1)));
        assert!(matches!(events.recv().unwrap(), MuxEvent::SurfaceOutput(3)));
        assert!(matches!(events.recv().unwrap(), MuxEvent::SurfaceExited(4)));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn surface_exit_discards_its_pending_output() {
        let broadcaster = MuxEventBroadcaster::default();
        let events = broadcaster.subscribe();

        broadcaster.emit(MuxEvent::SurfaceOutput(4));
        broadcaster.emit(MuxEvent::SurfaceExited(4));

        assert!(matches!(events.recv().unwrap(), MuxEvent::SurfaceExited(4)));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn slow_subscriber_disconnects_at_the_hard_bound() {
        let broadcaster = MuxEventBroadcaster::default();
        let fast = broadcaster.subscribe();
        let slow = broadcaster.subscribe();

        for surface in 0..=MAX_PENDING_EVENTS {
            broadcaster.emit(MuxEvent::Bell(surface as SurfaceId));
            assert!(
                matches!(fast.recv().unwrap(), MuxEvent::Bell(id) if id == surface as SurfaceId)
            );
        }

        let slow_events = slow.try_iter().collect::<Vec<_>>();
        assert_eq!(slow_events.len(), MAX_PENDING_EVENTS);
        assert!(slow.overflowed());
        assert!(matches!(slow.try_recv(), Err(TryRecvError::Disconnected)));

        broadcaster.emit(MuxEvent::Bell(9_999));
        assert!(matches!(fast.recv().unwrap(), MuxEvent::Bell(9_999)));
    }

    #[test]
    fn attached_surface_subscription_filters_before_bounded_mailbox() {
        let broadcaster = MuxEventBroadcaster::default();
        let events = broadcaster.subscribe_attached_surface(7);

        for index in 0..=MAX_PENDING_EVENTS {
            broadcaster.emit(MuxEvent::Bell(index as SurfaceId));
            broadcaster.emit(MuxEvent::ScrollChanged {
                surface: 8,
                offset: index as u64,
                at_bottom: false,
            });
        }
        broadcaster.emit(MuxEvent::ScrollChanged { surface: 7, offset: 42, at_bottom: false });

        assert!(matches!(
            events.recv().unwrap(),
            MuxEvent::ScrollChanged { surface: 7, offset: 42, at_bottom: false }
        ));
        assert!(!events.overflowed());
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn empty_preempts_a_full_mailbox() {
        let broadcaster = MuxEventBroadcaster::default();
        let events = broadcaster.subscribe();
        for surface in 0..MAX_PENDING_EVENTS {
            broadcaster.emit(MuxEvent::Bell(surface as SurfaceId));
        }

        broadcaster.emit(MuxEvent::Empty);

        assert!(matches!(events.recv().unwrap(), MuxEvent::Empty));
        assert!(matches!(events.try_recv(), Err(TryRecvError::Empty)));
        assert!(!events.overflowed());
    }
}
