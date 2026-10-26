//! `std::sync` waits through [`scoped_blocking_call`].

use std::sync::mpsc::{Receiver, RecvError, RecvTimeoutError};
use std::sync::{Condvar, LockResult, MutexGuard, WaitTimeoutResult};
use std::time::Duration;

use crate::{BlockingType, scoped_blocking_call};

/// `Receiver::recv`.
#[track_caller]
pub fn recv<T>(receiver: &Receiver<T>) -> Result<T, RecvError> {
    scoped_blocking_call("sync::recv", BlockingType::WillBlock, || receiver.recv())
}

/// `Receiver::recv_timeout`.
#[track_caller]
pub fn recv_timeout<T>(receiver: &Receiver<T>, timeout: Duration) -> Result<T, RecvTimeoutError> {
    scoped_blocking_call("sync::recv_timeout", BlockingType::WillBlock, || {
        receiver.recv_timeout(timeout)
    })
}

/// `Condvar::wait`.
#[track_caller]
pub fn condvar_wait<'a, T>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
) -> LockResult<MutexGuard<'a, T>> {
    scoped_blocking_call("sync::condvar_wait", BlockingType::WillBlock, || condvar.wait(guard))
}

/// `Condvar::wait_while`.
#[track_caller]
pub fn condvar_wait_while<'a, T>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
    condition: impl FnMut(&mut T) -> bool,
) -> LockResult<MutexGuard<'a, T>> {
    scoped_blocking_call("sync::condvar_wait_while", BlockingType::WillBlock, || {
        condvar.wait_while(guard, condition)
    })
}

/// `Condvar::wait_timeout`.
#[track_caller]
pub fn condvar_wait_timeout<'a, T>(
    condvar: &Condvar,
    guard: MutexGuard<'a, T>,
    timeout: Duration,
) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
    scoped_blocking_call("sync::condvar_wait_timeout", BlockingType::WillBlock, || {
        condvar.wait_timeout(guard, timeout)
    })
}
