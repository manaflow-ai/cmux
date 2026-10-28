//! Priority-inheriting locks for the daemon's ranked locks (p05-ipc-138).
//!
//! A request thread at user-initiated that blocks on a lock a utility or
//! background thread holds must not wait while the scheduler runs other
//! low-class work: the owner has to run at the waiter's class until it
//! releases. [`PiRawMutex`] is that lock:
//!
//! - macOS: an `os_unfair_lock`. A blocked waiter parks on a kernel
//!   turnstile that pushes its priority to the owner, as Chromium's
//!   `base::Lock` does on Apple platforms with priority inheritance
//!   (base/synchronization/lock_impl_posix.cc, `PTHREAD_PRIO_INHERIT`, and
//!   the `os_unfair_lock` path of base/synchronization/lock_impl.h). The
//!   lock is boxed so its address never changes, even when a leaked guard
//!   leaves it locked while the mutex value moves.
//! - Elsewhere: parking_lot's raw mutex, unchanged. Linux has no
//!   priority-inheriting futex parking_lot uses, so the daemon's lock-holder
//!   boost (`qos::LockBoost`, `cmux_threads::OwnerBoost`) remains the only
//!   raise there.
//!
//! [`PiMutex`] has `std::sync::Mutex`'s API, poisoning included, so a site
//! swaps the type and nothing else. [`PiReentrantMutex`] is the reentrant
//! lock of the registry connection. Every ranked lock in cmux-tui-core uses
//! one of them (`lock_rank::RankedLock`, `lock_rank::RankedReentrantLock`;
//! its `pi_mutex_backs_every_rank` test enumerates the ranks).
//!
//! A deadline wait ([`lock_api::RawMutexTimed`], the journal writer's
//! `try_lock_until`) parks on parking_lot_core keyed by the boxed lock and
//! donates nothing: only the blocking `lock` reaches the turnstile. An
//! unlock wakes one deadline waiter when one is parked.

use std::marker::PhantomData;
use std::ops::{Deref, DerefMut};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LockResult, PoisonError, TryLockError, TryLockResult};
use std::time::{Duration, Instant};

use lock_api::RawMutex as _;
use parking_lot::RawThreadId;

/// True where a blocked [`PiRawMutex::lock`] raises the owner to the
/// waiter's priority (macOS); false where the lock is parking_lot's.
pub const DONATES_PRIORITY: bool = cfg!(target_vendor = "apple");

/// The raw lock of [`PiMutex`] and [`PiReentrantMutex`]: `os_unfair_lock`
/// on Apple platforms, parking_lot's raw mutex elsewhere (module docs).
pub struct PiRawMutex(imp::Raw);

impl PiRawMutex {
    /// A new unlocked raw lock (on macOS its box is allocated now, not on
    /// the first lock).
    pub fn new() -> Self {
        Self(imp::Raw::new())
    }
}

impl Default for PiRawMutex {
    fn default() -> Self {
        Self::new()
    }
}

// SAFETY: `lock` blocks until this thread owns the lock, `try_lock` takes
// it only when it is free, and `unlock` is called only by the owner (the
// guards are `GuardNoSend`, so they release on the thread that locked).
unsafe impl lock_api::RawMutex for PiRawMutex {
    #[allow(clippy::declare_interior_mutable_const)]
    const INIT: Self = Self(imp::Raw::INIT);

    // An os_unfair_lock aborts when another thread unlocks it.
    type GuardMarker = lock_api::GuardNoSend;

    #[inline]
    fn lock(&self) {
        self.0.lock();
    }

    #[inline]
    fn try_lock(&self) -> bool {
        self.0.try_lock()
    }

    #[inline]
    unsafe fn unlock(&self) {
        // SAFETY: the caller owns the lock (the trait's contract).
        unsafe { self.0.unlock() }
    }
}

// SAFETY: a deadline wait returns true only once this thread owns the lock.
unsafe impl lock_api::RawMutexTimed for PiRawMutex {
    type Duration = Duration;
    type Instant = Instant;

    fn try_lock_for(&self, timeout: Duration) -> bool {
        match Instant::now().checked_add(timeout) {
            Some(deadline) => self.try_lock_until(deadline),
            None => {
                self.lock();
                true
            }
        }
    }

    fn try_lock_until(&self, deadline: Instant) -> bool {
        self.0.try_lock_until(deadline)
    }
}

/// A lock whose blocking waits go through [`PiRawMutex`]. Only the
/// priority-inheriting types implement it, so a function bounded by it
/// accepts a field only when that field is one of them.
pub trait PriorityInheriting {
    /// The raw lock behind the type.
    type Raw: lock_api::RawMutex;
}

/// The reentrant priority-inheriting lock (the registry connection's).
pub type PiReentrantMutex<T> = lock_api::ReentrantMutex<PiRawMutex, RawThreadId, T>;
/// A held [`PiReentrantMutex`].
pub type PiReentrantMutexGuard<'a, T> =
    lock_api::ReentrantMutexGuard<'a, PiRawMutex, RawThreadId, T>;
/// An owned hold of an `Arc<PiReentrantMutex>`.
pub type ArcPiReentrantMutexGuard<T> = lock_api::ArcReentrantMutexGuard<PiRawMutex, RawThreadId, T>;

/// A [`PiReentrantMutex`] holding `value`.
pub fn reentrant_mutex<T>(value: T) -> PiReentrantMutex<T> {
    lock_api::ReentrantMutex::from_raw(
        PiRawMutex::new(),
        <RawThreadId as lock_api::GetThreadId>::INIT,
        value,
    )
}

impl<T: ?Sized> PriorityInheriting for PiReentrantMutex<T> {
    type Raw = PiRawMutex;
}

/// `std::sync::Mutex` over [`PiRawMutex`]: the same `lock`, `try_lock`,
/// poisoning and `into_inner`, with a priority-inheriting wait on macOS.
pub struct PiMutex<T: ?Sized> {
    poison: Poison,
    inner: lock_api::Mutex<PiRawMutex, T>,
}

impl<T: ?Sized> PriorityInheriting for PiMutex<T> {
    type Raw = PiRawMutex;
}

/// Set when a holder panicked, as std's mutex is.
struct Poison(AtomicBool);

impl Poison {
    fn get(&self) -> bool {
        self.0.load(Ordering::Relaxed)
    }
}

impl<T> PiMutex<T> {
    /// `Mutex::new`.
    pub fn new(value: T) -> Self {
        Self {
            poison: Poison(AtomicBool::new(false)),
            inner: lock_api::Mutex::from_raw(PiRawMutex::new(), value),
        }
    }

    /// `Mutex::into_inner`.
    pub fn into_inner(self) -> LockResult<T> {
        let poisoned = self.poison.get();
        let value = self.inner.into_inner();
        if poisoned { Err(PoisonError::new(value)) } else { Ok(value) }
    }
}

impl<T: ?Sized> PiMutex<T> {
    /// `Mutex::lock`: blocks until this thread holds the lock; on macOS the
    /// holder runs at this thread's priority meanwhile.
    #[inline]
    pub fn lock(&self) -> LockResult<PiMutexGuard<'_, T>> {
        // SAFETY: the raw lock is only locked here and in `try_lock`, and
        // the guard below unlocks it once.
        unsafe { self.inner.raw() }.lock();
        self.guard()
    }

    /// `Mutex::try_lock`: never waits.
    #[inline]
    pub fn try_lock(&self) -> TryLockResult<PiMutexGuard<'_, T>> {
        // SAFETY: as in `lock`.
        if unsafe { self.inner.raw() }.try_lock() {
            self.guard().map_err(TryLockError::Poisoned)
        } else {
            Err(TryLockError::WouldBlock)
        }
    }

    /// `Mutex::is_poisoned`.
    pub fn is_poisoned(&self) -> bool {
        self.poison.get()
    }

    /// `Mutex::clear_poison`.
    pub fn clear_poison(&self) {
        self.poison.0.store(false, Ordering::Relaxed);
    }

    /// `Mutex::get_mut`.
    pub fn get_mut(&mut self) -> LockResult<&mut T> {
        let poisoned = self.poison.get();
        let value = self.inner.get_mut();
        if poisoned { Err(PoisonError::new(value)) } else { Ok(value) }
    }

    /// The guard of the lock this thread just took.
    #[inline]
    fn guard(&self) -> LockResult<PiMutexGuard<'_, T>> {
        let guard = PiMutexGuard {
            mutex: self,
            panicking: std::thread::panicking(),
            _not_send: PhantomData,
        };
        if self.poison.get() { Err(PoisonError::new(guard)) } else { Ok(guard) }
    }
}

impl<T: Default> Default for PiMutex<T> {
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T> From<T> for PiMutex<T> {
    fn from(value: T) -> Self {
        Self::new(value)
    }
}

impl<T: ?Sized> std::fmt::Debug for PiMutex<T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PiMutex").field("poisoned", &self.poison.get()).finish_non_exhaustive()
    }
}

/// A held [`PiMutex`]. Dropping it during a panic that started while it was
/// held poisons the mutex, then unlocks.
#[must_use = "the lock is released when the guard drops"]
///
/// It is two words, as std's guard is: the mutex and the panic flag.
pub struct PiMutexGuard<'a, T: ?Sized> {
    mutex: &'a PiMutex<T>,
    /// Whether this thread was already panicking when it took the lock.
    panicking: bool,
    /// Unlocked on the thread that locked (an `os_unfair_lock` aborts
    /// otherwise).
    _not_send: PhantomData<*const ()>,
}

// SAFETY: a shared guard hands out only `&T`, as std's `MutexGuard` does.
unsafe impl<T: ?Sized + Sync> Sync for PiMutexGuard<'_, T> {}

impl<T: ?Sized> Deref for PiMutexGuard<'_, T> {
    type Target = T;

    #[inline]
    fn deref(&self) -> &T {
        // SAFETY: this guard holds the lock, so no other reference to the
        // value is live.
        unsafe { &*self.mutex.inner.data_ptr() }
    }
}

impl<T: ?Sized> DerefMut for PiMutexGuard<'_, T> {
    #[inline]
    fn deref_mut(&mut self) -> &mut T {
        // SAFETY: as in `deref`, and `&mut self` makes this the only one.
        unsafe { &mut *self.mutex.inner.data_ptr() }
    }
}

impl<T: ?Sized + std::fmt::Debug> std::fmt::Debug for PiMutexGuard<'_, T> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        (**self).fmt(f)
    }
}

impl<T: ?Sized> Drop for PiMutexGuard<'_, T> {
    #[inline]
    fn drop(&mut self) {
        // Poisoned before it unlocks, as std does.
        if !self.panicking && std::thread::panicking() {
            self.mutex.poison.0.store(true, Ordering::Relaxed);
        }
        // SAFETY: this guard took the lock on this thread and unlocks it
        // once.
        unsafe { self.mutex.inner.force_unlock() };
    }
}

#[cfg(target_vendor = "apple")]
mod imp {
    use std::ptr;
    use std::sync::atomic::{AtomicPtr, AtomicU32, Ordering, fence};
    use std::time::Instant;

    use parking_lot_core::{DEFAULT_PARK_TOKEN, DEFAULT_UNPARK_TOKEN, ParkResult};

    /// A boxed `os_unfair_lock` and the count of deadline waiters parked
    /// on it.
    pub(super) struct Raw {
        /// Allocated by `new`, or by the first use of an `INIT` value;
        /// freed on drop. Its address never changes once set.
        lock: AtomicPtr<libc::os_unfair_lock>,
        /// Deadline waiters past their first failed try; an unlock wakes
        /// one while any is counted.
        deadline_waiters: AtomicU32,
    }

    fn boxed() -> *mut libc::os_unfair_lock {
        Box::into_raw(Box::new(libc::OS_UNFAIR_LOCK_INIT))
    }

    impl Raw {
        #[allow(clippy::declare_interior_mutable_const)]
        pub(super) const INIT: Self =
            Self { lock: AtomicPtr::new(ptr::null_mut()), deadline_waiters: AtomicU32::new(0) };

        pub(super) fn new() -> Self {
            Self { lock: AtomicPtr::new(boxed()), deadline_waiters: AtomicU32::new(0) }
        }

        #[inline]
        fn lock_ptr(&self) -> *mut libc::os_unfair_lock {
            let lock = self.lock.load(Ordering::Acquire);
            if lock.is_null() { self.allocate() } else { lock }
        }

        /// The first use of an `INIT` value: install a box, or take the one
        /// another thread installed first.
        #[cold]
        fn allocate(&self) -> *mut libc::os_unfair_lock {
            let fresh = boxed();
            match self.lock.compare_exchange(
                ptr::null_mut(),
                fresh,
                Ordering::AcqRel,
                Ordering::Acquire,
            ) {
                Ok(_) => fresh,
                Err(installed) => {
                    // SAFETY: `fresh` came from `Box::into_raw` above and was
                    // never shared.
                    drop(unsafe { Box::from_raw(fresh) });
                    installed
                }
            }
        }

        /// The parking_lot_core key of this lock's deadline waiters: the
        /// boxed lock's address, which nothing else parks on.
        fn key(&self) -> usize {
            self.lock_ptr() as usize
        }

        #[inline]
        pub(super) fn lock(&self) {
            // SAFETY: the pointer is a live boxed os_unfair_lock.
            unsafe { libc::os_unfair_lock_lock(self.lock_ptr()) }
        }

        #[inline]
        pub(super) fn try_lock(&self) -> bool {
            // SAFETY: the pointer is a live boxed os_unfair_lock.
            unsafe { libc::os_unfair_lock_trylock(self.lock_ptr()) }
        }

        /// # Safety
        /// The calling thread owns the lock.
        #[inline]
        pub(super) unsafe fn unlock(&self) {
            // SAFETY: the caller owns the lock, so the box exists and this
            // thread already read its address.
            unsafe { libc::os_unfair_lock_unlock(self.lock.load(Ordering::Relaxed)) };
            // Pairs with the fence in `try_lock_until`: a waiter counted
            // after this load sees the lock free on its next try.
            fence(Ordering::SeqCst);
            if self.deadline_waiters.load(Ordering::Relaxed) != 0 {
                // SAFETY: the key is this lock's own; the callback does not
                // call into parking_lot_core.
                unsafe { parking_lot_core::unpark_one(self.key(), |_| DEFAULT_UNPARK_TOKEN) };
            }
        }

        /// Waits for the lock until `deadline`; true once this thread owns
        /// it. The wait parks on parking_lot_core and is woken by an unlock.
        pub(super) fn try_lock_until(&self, deadline: Instant) -> bool {
            if self.try_lock() {
                return true;
            }
            self.deadline_waiters.fetch_add(1, Ordering::Relaxed);
            fence(Ordering::SeqCst);
            let locked = loop {
                if self.try_lock() {
                    break true;
                }
                let mut won = false;
                // The try runs under the bucket lock an unlock's wake takes,
                // so an unlock after a failed try always finds this waiter.
                // SAFETY: the key is this lock's own, and the callbacks
                // neither panic nor call into parking_lot_core.
                // wakeup-allow: deadline the journal writer's bounded wait for the registry connection lock
                let parked = unsafe {
                    parking_lot_core::park(
                        self.key(),
                        || {
                            won = self.try_lock();
                            !won
                        },
                        || {},
                        |_, _| {},
                        DEFAULT_PARK_TOKEN,
                        Some(deadline),
                    )
                };
                if won {
                    break true;
                }
                if matches!(parked, ParkResult::TimedOut) {
                    break self.try_lock();
                }
            };
            self.deadline_waiters.fetch_sub(1, Ordering::Relaxed);
            locked
        }
    }

    impl Drop for Raw {
        fn drop(&mut self) {
            let lock = *self.lock.get_mut();
            if !lock.is_null() {
                // SAFETY: the box came from `Box::into_raw`, and `&mut self`
                // means no thread holds or waits for the lock.
                drop(unsafe { Box::from_raw(lock) });
            }
        }
    }
}

#[cfg(not(target_vendor = "apple"))]
mod imp {
    use std::time::Instant;

    use lock_api::{RawMutex as _, RawMutexTimed as _};

    /// parking_lot's raw mutex.
    pub(super) struct Raw(parking_lot::RawMutex);

    impl Raw {
        #[allow(clippy::declare_interior_mutable_const)]
        pub(super) const INIT: Self = Self(parking_lot::RawMutex::INIT);

        pub(super) fn new() -> Self {
            Self(parking_lot::RawMutex::INIT)
        }

        #[inline]
        pub(super) fn lock(&self) {
            self.0.lock();
        }

        #[inline]
        pub(super) fn try_lock(&self) -> bool {
            self.0.try_lock()
        }

        /// # Safety
        /// The calling thread owns the lock.
        #[inline]
        pub(super) unsafe fn unlock(&self) {
            // SAFETY: the caller owns the lock.
            unsafe { self.0.unlock() }
        }

        pub(super) fn try_lock_until(&self, deadline: Instant) -> bool {
            self.0.try_lock_until(deadline)
        }
    }
}

#[cfg(test)]
#[path = "pi_mutex_tests.rs"]
mod tests;
