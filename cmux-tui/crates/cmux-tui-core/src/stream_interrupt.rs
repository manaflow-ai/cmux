//! Event-driven stop signals for blocking stream loops.
//!
//! Long-lived stream threads used to wake every 100 ms (and session streams
//! every second) only to re-check whether their connection, stream or
//! attachment had closed. A `StreamInterrupt` makes that close an event: the
//! loop registers one interrupt with every close source it depends on (the
//! connection writer, the outbound stream, the attach lifecycle) and with the
//! queue it blocks on. Firing any source wakes the blocked receive, which
//! then returns so the loop re-checks its conditions and exits.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{RecvTimeoutError, TryRecvError, TrySendError};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::{Duration, Instant};

type Waker = Box<dyn Fn() + Send + Sync>;

/// A one-shot stop signal for one blocking loop.
#[derive(Default)]
pub(crate) struct StreamInterrupt {
    fired: AtomicBool,
    wakers: Mutex<Vec<Waker>>,
}

impl StreamInterrupt {
    pub(crate) fn new() -> Arc<Self> {
        Arc::default()
    }

    pub(crate) fn is_fired(&self) -> bool {
        self.fired.load(Ordering::Acquire)
    }

    pub(crate) fn fire(&self) {
        if self.fired.swap(true, Ordering::AcqRel) {
            return;
        }
        let wakers = std::mem::take(&mut *self.wakers.lock().unwrap());
        for waker in wakers {
            waker();
        }
    }

    /// Runs `waker` when the interrupt fires (now, if it already has). A
    /// waker must take the lock its receiver waits under before notifying,
    /// so a receiver that checked `is_fired` and is about to wait cannot miss
    /// the notification.
    pub(crate) fn on_fire(&self, waker: impl Fn() + Send + Sync + 'static) {
        let mut wakers = self.wakers.lock().unwrap();
        if self.is_fired() {
            drop(wakers);
            waker();
        } else {
            wakers.push(Box::new(waker));
        }
    }
}

/// The interrupts to fire when one close source closes. Clones share the
/// set; it latches, so a registration after the close fires at once.
#[derive(Clone, Default)]
pub(crate) struct InterruptSet {
    inner: Arc<Mutex<InterruptSetState>>,
}

#[derive(Default)]
struct InterruptSetState {
    fired: bool,
    members: Vec<Weak<StreamInterrupt>>,
}

impl InterruptSet {
    pub(crate) fn register(&self, interrupt: &Arc<StreamInterrupt>) {
        let mut state = self.inner.lock().unwrap();
        if state.fired {
            drop(state);
            interrupt.fire();
            return;
        }
        state.members.retain(|member| member.strong_count() > 0);
        state.members.push(Arc::downgrade(interrupt));
    }

    pub(crate) fn fire(&self) {
        let members = {
            let mut state = self.inner.lock().unwrap();
            state.fired = true;
            std::mem::take(&mut state.members)
        };
        for member in members.iter().filter_map(Weak::upgrade) {
            member.fire();
        }
    }
}

/// Wakes `changed` under `lock` when `interrupt` fires, holding both weakly.
pub(crate) fn wake_condvar_on<T: Send + 'static>(
    interrupt: &StreamInterrupt,
    lock: Weak<(Mutex<T>, Condvar)>,
) {
    interrupt.on_fire(move || {
        if let Some(pair) = lock.upgrade() {
            let _guard = pair.0.lock().unwrap_or_else(|error| error.into_inner());
            pair.1.notify_all();
        }
    });
}

/// A capacity-one "something changed" signal (a coalescing wake), like
/// `sync_channel::<()>(1)`, whose receiver can also be woken by a
/// `StreamInterrupt`.
pub(crate) fn signal() -> (SignalSender, SignalReceiver) {
    let state = Arc::new((
        Mutex::new(SignalState { pending: false, sender_alive: true, receiver_alive: true }),
        Condvar::new(),
    ));
    (SignalSender { state: state.clone() }, SignalReceiver { state })
}

struct SignalState {
    pending: bool,
    sender_alive: bool,
    receiver_alive: bool,
}

pub struct SignalSender {
    state: Arc<(Mutex<SignalState>, Condvar)>,
}

impl SignalSender {
    pub fn try_send(&self, (): ()) -> Result<(), TrySendError<()>> {
        let mut state = self.state.0.lock().unwrap();
        if !state.receiver_alive {
            return Err(TrySendError::Disconnected(()));
        }
        if state.pending {
            return Err(TrySendError::Full(()));
        }
        state.pending = true;
        drop(state);
        self.state.1.notify_all();
        Ok(())
    }
}

impl Drop for SignalSender {
    fn drop(&mut self) {
        self.state.0.lock().unwrap().sender_alive = false;
        self.state.1.notify_all();
    }
}

pub struct SignalReceiver {
    state: Arc<(Mutex<SignalState>, Condvar)>,
}

impl SignalReceiver {
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn try_recv(&self) -> Result<(), TryRecvError> {
        let mut state = self.state.0.lock().unwrap();
        if std::mem::take(&mut state.pending) {
            Ok(())
        } else if state.sender_alive {
            Err(TryRecvError::Empty)
        } else {
            Err(TryRecvError::Disconnected)
        }
    }

    #[cfg_attr(not(test), allow(dead_code))]
    pub fn recv_timeout(&self, timeout: Duration) -> Result<(), RecvTimeoutError> {
        let deadline = Instant::now() + timeout;
        let mut state = self.state.0.lock().unwrap();
        loop {
            if std::mem::take(&mut state.pending) {
                return Ok(());
            }
            if !state.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
                return Err(RecvTimeoutError::Timeout);
            };
            state = self.state.1.wait_timeout(state, remaining).unwrap().0;
        }
    }

    /// Wakes a blocked `recv_until_interrupted` when `interrupt` fires.
    pub(crate) fn wake_on(&self, interrupt: &StreamInterrupt) {
        wake_condvar_on(interrupt, Arc::downgrade(&self.state));
    }

    /// Blocks for a signal. Returns `Timeout` once `interrupt` has fired
    /// and no signal is pending, `Disconnected` when the sender is gone.
    pub(crate) fn recv_until_interrupted(
        &self,
        interrupt: &StreamInterrupt,
    ) -> Result<(), RecvTimeoutError> {
        let mut state = self.state.0.lock().unwrap();
        loop {
            if std::mem::take(&mut state.pending) {
                return Ok(());
            }
            if !state.sender_alive {
                return Err(RecvTimeoutError::Disconnected);
            }
            if interrupt.is_fired() {
                return Err(RecvTimeoutError::Timeout);
            }
            state = self.state.1.wait(state).unwrap();
        }
    }
}

impl Drop for SignalReceiver {
    fn drop(&mut self) {
        self.state.0.lock().unwrap().receiver_alive = false;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fired_source_wakes_a_blocked_receiver() {
        let (sender, receiver) = signal();
        let interrupt = StreamInterrupt::new();
        let source = InterruptSet::default();
        source.register(&interrupt);
        receiver.wake_on(&interrupt);
        let waiter = std::thread::spawn(move || receiver.recv_until_interrupted(&interrupt));
        std::thread::sleep(Duration::from_millis(20));
        source.fire();
        assert_eq!(waiter.join().unwrap(), Err(RecvTimeoutError::Timeout));
        drop(sender);
    }

    #[test]
    fn registering_after_the_close_fires_at_once() {
        let source = InterruptSet::default();
        source.fire();
        let interrupt = StreamInterrupt::new();
        source.register(&interrupt);
        assert!(interrupt.is_fired());
    }

    #[test]
    fn signals_coalesce_and_report_a_dropped_sender() {
        let (sender, receiver) = signal();
        assert!(sender.try_send(()).is_ok());
        assert!(matches!(sender.try_send(()), Err(TrySendError::Full(()))));
        assert!(receiver.try_recv().is_ok());
        assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
        drop(sender);
        assert!(matches!(receiver.try_recv(), Err(TryRecvError::Disconnected)));
        assert_eq!(
            receiver.recv_until_interrupted(&StreamInterrupt::default()),
            Err(RecvTimeoutError::Disconnected)
        );
    }
}
