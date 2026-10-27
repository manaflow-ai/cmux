//! `std::sync` waits through [`scoped_blocking_call`]. The Condvar waits
//! keep std's names, so the wakeup audit judges `sync::wait_timeout(` at the
//! caller as it judges `.wait_timeout(`.

use std::sync::mpsc::{Receiver, RecvError};
use std::sync::{Condvar, LockResult, MutexGuard, WaitTimeoutResult};
use std::time::Duration;

use crate::{BlockingKind, scoped_blocking_call};

/// `Receiver::recv`.
#[track_caller]
pub fn recv<T>(receiver: &Receiver<T>) -> Result<T, RecvError> {
    scoped_blocking_call("sync::recv", BlockingKind::Recv, || receiver.recv())
}

/// `Condvar::wait`.
#[track_caller]
pub fn wait<'a, T>(condvar: &Condvar, guard: MutexGuard<'a, T>) -> LockResult<MutexGuard<'a, T>> {
    scoped_blocking_call("sync::wait", BlockingKind::CondvarWait, || condvar.wait(guard))
}

/// `Condvar::wait_while`.
#[track_caller]
pub fn wait_while<'a, T>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
    condition: impl FnMut(&mut T) -> bool,
) -> LockResult<MutexGuard<'a, T>> {
    scoped_blocking_call("sync::wait_while", BlockingKind::CondvarWait, || {
        condvar.wait_while(guard, condition)
    })
}

/// `Condvar::wait_timeout`.
#[track_caller]
pub fn wait_timeout<'a, T>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
    timeout: Duration,
) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
    scoped_blocking_call("sync::wait_timeout", BlockingKind::CondvarWait, || {
        // wakeup-allow: deadline the caller's own timed wait, passed through; the audit judges the caller's sync::wait_timeout(
        condvar.wait_timeout(guard, timeout)
    })
}
