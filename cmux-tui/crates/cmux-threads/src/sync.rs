//! Channels that know their producer's QoS, so a thread that waits on work
//! sent from a lower-QoS thread is a recorded `priority-inversion` site
//! (plans/cmux-next/chrome-parity/p02-threads.md, 3D, task 206).
//!
//! [`mpsc`] wraps `std::sync::mpsc` and `crossbeam` (feature `crossbeam`)
//! wraps `crossbeam_channel`, with the same calls, so a site swaps the import
//! and nothing else.
//!
//! - Debug: each message carries the QoS of the registered thread that sent
//!   it. A blocking receive (`recv`, `recv_timeout`, the blocking iterators)
//!   on a registered thread of higher QoS records a
//!   [`BlockingKind::PriorityInversion`] site at the receive's caller, read
//!   with [`crate::blocking::snapshot`]. It never panics: the receive is
//!   allowed, the QoS pairing is what a review fixes (task 238 adds the
//!   producer boost). A non-blocking receive records nothing: it never waits
//!   on the producer. Unregistered threads have no QoS and record nothing.
//! - Release: a message is the plain value on the plain channel; no QoS is
//!   read or recorded.
//!
//! Every blocking receive is also a checked [`BlockingKind::Recv`] wait, as
//! [`crate::checked::sync::recv`] is.
//!
//! [`Mutex`], [`RwLock`] and [`Condvar`] are std's with their waits timed: a
//! wait of 2 ms or more on a thread that may not wait records its site
//! (task 227, see the `locks` module). A thread that waits for its own next
//! work takes [`Condvar::idle`], which records nothing.
//!
//! Chromium makes a waiter run ahead of a lower-priority lock owner with
//! priority-inheritance mutexes (base/synchronization/lock_impl_posix.cc);
//! a channel has no owner the kernel can see, so the message names its
//! producer.

use std::panic::Location;

use crate::blocking::{BlockingKind, assert_blocking_allowed_at};

#[path = "sync_locks.rs"]
mod locks;

pub use locks::{Condvar, IdleWait, Mutex, RwLock};
/// std's guard and result types, named here so a site imports them beside
/// the timed locks.
pub use std::sync::{
    LockResult, MutexGuard, PoisonError, RwLockReadGuard, RwLockWriteGuard, TryLockError,
    TryLockResult, WaitTimeoutResult,
};

/// A value with the QoS of the thread that sent it.
#[cfg(debug_assertions)]
struct Tagged<T> {
    value: T,
    producer: Option<crate::ThreadQos>,
}

#[cfg(debug_assertions)]
type Payload<T> = Tagged<T>;

#[cfg(not(debug_assertions))]
type Payload<T> = T;

#[inline]
fn tag<T>(value: T) -> Payload<T> {
    #[cfg(debug_assertions)]
    {
        Tagged { value, producer: crate::registry::current_qos() }
    }
    #[cfg(not(debug_assertions))]
    {
        value
    }
}

/// The value of a message taken without waiting, or handed back by a failed
/// send.
#[inline]
fn untag<T>(payload: Payload<T>) -> T {
    #[cfg(debug_assertions)]
    {
        payload.value
    }
    #[cfg(not(debug_assertions))]
    {
        payload
    }
}

/// The value of a message a blocking receive at `site` waited for. Debug
/// records an inversion when the producer's QoS is below the receiver's.
#[inline]
#[cfg_attr(not(debug_assertions), allow(unused_variables))]
fn received<T>(payload: Payload<T>, site: &'static Location<'static>) -> T {
    #[cfg(debug_assertions)]
    if let Some(producer) = payload.producer
        && crate::registry::current_qos().is_some_and(|consumer| consumer > producer)
    {
        crate::blocking::note_priority_inversion(site);
    }
    untag(payload)
}

/// Wrapped `std::sync::mpsc` channels.
pub mod mpsc {
    use super::{
        BlockingKind, Location, Payload, assert_blocking_allowed_at, received, tag, untag,
    };
    use std::sync::mpsc as std_mpsc;
    use std::time::Duration;

    pub use std::sync::mpsc::{RecvError, RecvTimeoutError, SendError, TryRecvError, TrySendError};

    /// `std::sync::mpsc::channel`.
    pub fn channel<T>() -> (Sender<T>, Receiver<T>) {
        let (sender, receiver) = std_mpsc::channel();
        (Sender(sender), Receiver(receiver))
    }

    /// `std::sync::mpsc::sync_channel`.
    pub fn sync_channel<T>(bound: usize) -> (SyncSender<T>, Receiver<T>) {
        let (sender, receiver) = std_mpsc::sync_channel(bound);
        (SyncSender(sender), Receiver(receiver))
    }

    /// `std::sync::mpsc::Sender`.
    pub struct Sender<T>(std_mpsc::Sender<Payload<T>>);

    impl<T> Sender<T> {
        /// `Sender::send`.
        pub fn send(&self, value: T) -> Result<(), SendError<T>> {
            self.0.send(tag(value)).map_err(|SendError(payload)| SendError(untag(payload)))
        }
    }

    impl<T> Clone for Sender<T> {
        fn clone(&self) -> Self {
            Self(self.0.clone())
        }
    }

    impl<T> std::fmt::Debug for Sender<T> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("Sender { .. }")
        }
    }

    /// `std::sync::mpsc::SyncSender`.
    pub struct SyncSender<T>(std_mpsc::SyncSender<Payload<T>>);

    impl<T> SyncSender<T> {
        /// `SyncSender::send`.
        pub fn send(&self, value: T) -> Result<(), SendError<T>> {
            self.0.send(tag(value)).map_err(|SendError(payload)| SendError(untag(payload)))
        }

        /// `SyncSender::try_send`.
        pub fn try_send(&self, value: T) -> Result<(), TrySendError<T>> {
            self.0.try_send(tag(value)).map_err(|error| match error {
                TrySendError::Full(payload) => TrySendError::Full(untag(payload)),
                TrySendError::Disconnected(payload) => TrySendError::Disconnected(untag(payload)),
            })
        }
    }

    impl<T> Clone for SyncSender<T> {
        fn clone(&self) -> Self {
            Self(self.0.clone())
        }
    }

    impl<T> std::fmt::Debug for SyncSender<T> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("SyncSender { .. }")
        }
    }

    /// `std::sync::mpsc::Receiver`.
    pub struct Receiver<T>(std_mpsc::Receiver<Payload<T>>);

    impl<T> Receiver<T> {
        /// `Receiver::recv`, a checked wait that records an inversion.
        #[track_caller]
        pub fn recv(&self) -> Result<T, RecvError> {
            self.recv_at(Location::caller())
        }

        /// `Receiver::recv_timeout`, a checked wait that records an inversion.
        #[track_caller]
        pub fn recv_timeout(&self, timeout: Duration) -> Result<T, RecvTimeoutError> {
            let site = Location::caller();
            assert_blocking_allowed_at(BlockingKind::Recv, site);
            // wakeup-allow: deadline the caller's own timeout, forwarded unchanged
            self.0.recv_timeout(timeout).map(|payload| received(payload, site))
        }

        /// `Receiver::try_recv`: no wait, nothing checked or recorded.
        pub fn try_recv(&self) -> Result<T, TryRecvError> {
            self.0.try_recv().map(untag)
        }

        /// `Receiver::iter`: each step is a [`Receiver::recv`] at this call.
        #[track_caller]
        pub fn iter(&self) -> Iter<'_, T> {
            Iter { receiver: self, site: Location::caller() }
        }

        /// `Receiver::try_iter`: each step is a [`Receiver::try_recv`].
        pub fn try_iter(&self) -> TryIter<'_, T> {
            TryIter { receiver: self }
        }

        fn recv_at(&self, site: &'static Location<'static>) -> Result<T, RecvError> {
            assert_blocking_allowed_at(BlockingKind::Recv, site);
            self.0.recv().map(|payload| received(payload, site))
        }
    }

    impl<T> std::fmt::Debug for Receiver<T> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("Receiver { .. }")
        }
    }

    /// `std::sync::mpsc::Iter`.
    #[derive(Debug)]
    pub struct Iter<'a, T> {
        receiver: &'a Receiver<T>,
        site: &'static Location<'static>,
    }

    impl<T> Iterator for Iter<'_, T> {
        type Item = T;

        fn next(&mut self) -> Option<T> {
            self.receiver.recv_at(self.site).ok()
        }
    }

    /// `std::sync::mpsc::TryIter`.
    #[derive(Debug)]
    pub struct TryIter<'a, T> {
        receiver: &'a Receiver<T>,
    }

    impl<T> Iterator for TryIter<'_, T> {
        type Item = T;

        fn next(&mut self) -> Option<T> {
            self.receiver.try_recv().ok()
        }
    }

    /// `std::sync::mpsc::IntoIter`.
    #[derive(Debug)]
    pub struct IntoIter<T> {
        receiver: Receiver<T>,
        site: &'static Location<'static>,
    }

    impl<T> Iterator for IntoIter<T> {
        type Item = T;

        fn next(&mut self) -> Option<T> {
            self.receiver.recv_at(self.site).ok()
        }
    }

    impl<'a, T> IntoIterator for &'a Receiver<T> {
        type Item = T;
        type IntoIter = Iter<'a, T>;

        #[track_caller]
        fn into_iter(self) -> Iter<'a, T> {
            Iter { receiver: self, site: Location::caller() }
        }
    }

    impl<T> IntoIterator for Receiver<T> {
        type Item = T;
        type IntoIter = IntoIter<T>;

        #[track_caller]
        fn into_iter(self) -> IntoIter<T> {
            IntoIter { receiver: self, site: Location::caller() }
        }
    }
}

/// Wrapped `crossbeam_channel` channels. `select!` takes crossbeam's own
/// receivers, so a site that selects keeps `crossbeam_channel` unrecorded.
#[cfg(feature = "crossbeam")]
pub mod crossbeam {
    use super::{
        BlockingKind, Location, Payload, assert_blocking_allowed_at, received, tag, untag,
    };
    use crossbeam_channel as cb;
    use std::time::Duration;

    pub use crossbeam_channel::{
        RecvError, RecvTimeoutError, SendError, TryRecvError, TrySendError,
    };

    /// `crossbeam_channel::unbounded`.
    pub fn unbounded<T>() -> (Sender<T>, Receiver<T>) {
        let (sender, receiver) = cb::unbounded();
        (Sender(sender), Receiver(receiver))
    }

    /// `crossbeam_channel::bounded`.
    pub fn bounded<T>(capacity: usize) -> (Sender<T>, Receiver<T>) {
        let (sender, receiver) = cb::bounded(capacity);
        (Sender(sender), Receiver(receiver))
    }

    /// `crossbeam_channel::Sender`.
    pub struct Sender<T>(cb::Sender<Payload<T>>);

    impl<T> Sender<T> {
        /// `Sender::send`.
        pub fn send(&self, value: T) -> Result<(), SendError<T>> {
            self.0.send(tag(value)).map_err(|SendError(payload)| SendError(untag(payload)))
        }

        /// `Sender::try_send`.
        pub fn try_send(&self, value: T) -> Result<(), TrySendError<T>> {
            self.0.try_send(tag(value)).map_err(|error| match error {
                TrySendError::Full(payload) => TrySendError::Full(untag(payload)),
                TrySendError::Disconnected(payload) => TrySendError::Disconnected(untag(payload)),
            })
        }

        /// `Sender::len`.
        pub fn len(&self) -> usize {
            self.0.len()
        }

        /// `Sender::is_empty`.
        pub fn is_empty(&self) -> bool {
            self.0.is_empty()
        }
    }

    impl<T> Clone for Sender<T> {
        fn clone(&self) -> Self {
            Self(self.0.clone())
        }
    }

    impl<T> std::fmt::Debug for Sender<T> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("Sender { .. }")
        }
    }

    /// `crossbeam_channel::Receiver`.
    pub struct Receiver<T>(cb::Receiver<Payload<T>>);

    impl<T> Receiver<T> {
        /// `Receiver::recv`, a checked wait that records an inversion.
        #[track_caller]
        pub fn recv(&self) -> Result<T, RecvError> {
            self.recv_at(Location::caller())
        }

        /// `Receiver::recv_timeout`, a checked wait that records an inversion.
        #[track_caller]
        pub fn recv_timeout(&self, timeout: Duration) -> Result<T, RecvTimeoutError> {
            let site = Location::caller();
            assert_blocking_allowed_at(BlockingKind::Recv, site);
            // wakeup-allow: deadline the caller's own timeout, forwarded unchanged
            self.0.recv_timeout(timeout).map(|payload| received(payload, site))
        }

        /// `Receiver::try_recv`: no wait, nothing checked or recorded.
        pub fn try_recv(&self) -> Result<T, TryRecvError> {
            self.0.try_recv().map(untag)
        }

        /// `Receiver::iter`: each step is a [`Receiver::recv`] at this call.
        #[track_caller]
        pub fn iter(&self) -> Iter<'_, T> {
            Iter { receiver: self, site: Location::caller() }
        }

        /// `Receiver::try_iter`: each step is a [`Receiver::try_recv`].
        pub fn try_iter(&self) -> TryIter<'_, T> {
            TryIter { receiver: self }
        }

        /// `Receiver::len`.
        pub fn len(&self) -> usize {
            self.0.len()
        }

        /// `Receiver::is_empty`.
        pub fn is_empty(&self) -> bool {
            self.0.is_empty()
        }

        fn recv_at(&self, site: &'static Location<'static>) -> Result<T, RecvError> {
            assert_blocking_allowed_at(BlockingKind::Recv, site);
            self.0.recv().map(|payload| received(payload, site))
        }
    }

    impl<T> Clone for Receiver<T> {
        fn clone(&self) -> Self {
            Self(self.0.clone())
        }
    }

    impl<T> std::fmt::Debug for Receiver<T> {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.write_str("Receiver { .. }")
        }
    }

    /// `crossbeam_channel::Iter`.
    #[derive(Debug)]
    pub struct Iter<'a, T> {
        receiver: &'a Receiver<T>,
        site: &'static Location<'static>,
    }

    impl<T> Iterator for Iter<'_, T> {
        type Item = T;

        fn next(&mut self) -> Option<T> {
            self.receiver.recv_at(self.site).ok()
        }
    }

    /// `crossbeam_channel::TryIter`.
    #[derive(Debug)]
    pub struct TryIter<'a, T> {
        receiver: &'a Receiver<T>,
    }

    impl<T> Iterator for TryIter<'_, T> {
        type Item = T;

        fn next(&mut self) -> Option<T> {
            self.receiver.try_recv().ok()
        }
    }

    /// `crossbeam_channel::IntoIter`.
    #[derive(Debug)]
    pub struct IntoIter<T> {
        receiver: Receiver<T>,
        site: &'static Location<'static>,
    }

    impl<T> Iterator for IntoIter<T> {
        type Item = T;

        fn next(&mut self) -> Option<T> {
            self.receiver.recv_at(self.site).ok()
        }
    }

    impl<'a, T> IntoIterator for &'a Receiver<T> {
        type Item = T;
        type IntoIter = Iter<'a, T>;

        #[track_caller]
        fn into_iter(self) -> Iter<'a, T> {
            Iter { receiver: self, site: Location::caller() }
        }
    }

    impl<T> IntoIterator for Receiver<T> {
        type Item = T;
        type IntoIter = IntoIter<T>;

        #[track_caller]
        fn into_iter(self) -> IntoIter<T> {
            IntoIter { receiver: self, site: Location::caller() }
        }
    }
}

/// Release carries the plain value: this only compiles when it does.
#[cfg(not(debug_assertions))]
const _: fn(Payload<u8>) -> u8 = |payload| payload;

#[cfg(test)]
#[path = "sync_tests.rs"]
mod tests;
