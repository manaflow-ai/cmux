//! Checked forms of the blocking std primitives. Each one checks the current
//! thread with [`assert_blocking_allowed`] at the caller's location, then makes
//! the std call unchanged, so call sites swap `std::fs::read` for
//! `checked::fs::read` and nothing else. As in Chrome, the blocking API makes
//! its own `ScopedBlockingCall`; callers do not wrap it.

use crate::blocking::{BlockingKind, assert_blocking_allowed};
use std::future::Future;

/// File-system calls ([`BlockingKind::Fs`]).
pub mod fs {
    use super::{BlockingKind, assert_blocking_allowed};
    use std::fs;
    use std::io;
    use std::path::{Path, PathBuf};

    /// The std file types, named here so daemon code imports them beside the
    /// checked calls. Their disk calls are the checked functions below.
    pub use std::fs::{
        DirBuilder, DirEntry, File, FileType, Metadata, OpenOptions, Permissions, ReadDir,
    };

    macro_rules! checked_fs {
        ($( $(#[$doc:meta])* fn $name:ident($($arg:ident: $ty:ty),*) -> $ret:ty = $call:path; )*) => {
            $(
                $(#[$doc])*
                #[track_caller]
                pub fn $name($($arg: $ty),*) -> $ret {
                    assert_blocking_allowed(BlockingKind::Fs);
                    $call($($arg),*)
                }
            )*
        };
    }

    checked_fs! {
        /// `std::fs::read`.
        fn read(path: impl AsRef<Path>) -> io::Result<Vec<u8>> = fs::read;
        /// `std::fs::read_to_string`.
        fn read_to_string(path: impl AsRef<Path>) -> io::Result<String> = fs::read_to_string;
        /// `std::fs::write`.
        fn write(path: impl AsRef<Path>, contents: impl AsRef<[u8]>) -> io::Result<()> = fs::write;
        /// `std::fs::create_dir`.
        fn create_dir(path: impl AsRef<Path>) -> io::Result<()> = fs::create_dir;
        /// `std::fs::create_dir_all`.
        fn create_dir_all(path: impl AsRef<Path>) -> io::Result<()> = fs::create_dir_all;
        /// `std::fs::remove_file`.
        fn remove_file(path: impl AsRef<Path>) -> io::Result<()> = fs::remove_file;
        /// `std::fs::remove_dir`.
        fn remove_dir(path: impl AsRef<Path>) -> io::Result<()> = fs::remove_dir;
        /// `std::fs::remove_dir_all`.
        fn remove_dir_all(path: impl AsRef<Path>) -> io::Result<()> = fs::remove_dir_all;
        /// `std::fs::rename`.
        fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> = fs::rename;
        /// `std::fs::copy`.
        fn copy(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<u64> = fs::copy;
        /// `std::fs::hard_link`.
        fn hard_link(original: impl AsRef<Path>, link: impl AsRef<Path>) -> io::Result<()> = fs::hard_link;
        /// `std::fs::metadata`.
        fn metadata(path: impl AsRef<Path>) -> io::Result<Metadata> = fs::metadata;
        /// `std::fs::symlink_metadata`.
        fn symlink_metadata(path: impl AsRef<Path>) -> io::Result<Metadata> = fs::symlink_metadata;
        /// `std::fs::exists`.
        fn exists(path: impl AsRef<Path>) -> io::Result<bool> = fs::exists;
        /// `std::fs::read_dir`.
        fn read_dir(path: impl AsRef<Path>) -> io::Result<ReadDir> = fs::read_dir;
        /// `std::fs::read_link`.
        fn read_link(path: impl AsRef<Path>) -> io::Result<PathBuf> = fs::read_link;
        /// `std::fs::canonicalize`.
        fn canonicalize(path: impl AsRef<Path>) -> io::Result<PathBuf> = fs::canonicalize;
        /// `std::fs::set_permissions`.
        fn set_permissions(path: impl AsRef<Path>, permissions: Permissions) -> io::Result<()> = fs::set_permissions;
        /// `File::open`.
        fn open(path: impl AsRef<Path>) -> io::Result<File> = File::open;
        /// `File::create`.
        fn create(path: impl AsRef<Path>) -> io::Result<File> = File::create;
        /// `File::sync_all`.
        fn sync_all(file: &File) -> io::Result<()> = File::sync_all;
        /// `File::sync_data`.
        fn sync_data(file: &File) -> io::Result<()> = File::sync_data;
    }

    /// `OpenOptions::open`.
    #[track_caller]
    pub fn open_with(options: &OpenOptions, path: impl AsRef<Path>) -> io::Result<File> {
        assert_blocking_allowed(BlockingKind::Fs);
        options.open(path)
    }

    /// `DirBuilder::create`.
    #[track_caller]
    pub fn create_dir_with(builder: &DirBuilder, path: impl AsRef<Path>) -> io::Result<()> {
        assert_blocking_allowed(BlockingKind::Fs);
        builder.create(path)
    }

    /// `flock(2)` on `file`'s descriptor. `LOCK_SH` and `LOCK_EX` wait for
    /// the lock unless `operation` has `LOCK_NB`, and only that wait is
    /// checked: `LOCK_UN` and a `LOCK_NB` try return at once, so a lock
    /// guard's drop may unlock on any thread.
    #[cfg(unix)]
    #[track_caller]
    pub fn advisory_lock(file: &impl std::os::fd::AsFd, operation: libc::c_int) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        if operation & (libc::LOCK_UN | libc::LOCK_NB) == 0 {
            assert_blocking_allowed(BlockingKind::Fs);
        }
        // SAFETY: flock reads or changes only the advisory lock of a
        // descriptor the borrow keeps open.
        if unsafe { libc::flock(file.as_fd().as_raw_fd(), operation) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        }
    }
}

/// Child processes ([`BlockingKind::ProcessSpawn`], [`BlockingKind::ProcessWait`]).
pub mod process {
    use super::{BlockingKind, assert_blocking_allowed};
    use std::io;
    use std::process::{Child, Command, ExitStatus, Output};

    /// `Command::spawn`.
    #[track_caller]
    pub fn spawn(command: &mut Command) -> io::Result<Child> {
        assert_blocking_allowed(BlockingKind::ProcessSpawn);
        command.spawn()
    }

    /// `Command::output`: spawns and waits.
    #[track_caller]
    pub fn output(command: &mut Command) -> io::Result<Output> {
        assert_blocking_allowed(BlockingKind::ProcessWait);
        command.output()
    }

    /// `Command::status`: spawns and waits.
    #[track_caller]
    pub fn status(command: &mut Command) -> io::Result<ExitStatus> {
        assert_blocking_allowed(BlockingKind::ProcessWait);
        command.status()
    }

    /// `Child::wait`.
    #[track_caller]
    pub fn wait(child: &mut Child) -> io::Result<ExitStatus> {
        assert_blocking_allowed(BlockingKind::ProcessWait);
        child.wait()
    }

    /// `Child::wait_with_output`.
    #[track_caller]
    pub fn wait_with_output(child: Child) -> io::Result<Output> {
        assert_blocking_allowed(BlockingKind::ProcessWait);
        child.wait_with_output()
    }
}

/// Channel, thread and condition-variable waits, and sleep.
pub mod sync {
    use super::{BlockingKind, assert_blocking_allowed};
    use std::sync::mpsc::{Receiver, RecvError, RecvTimeoutError};
    use std::sync::{Condvar, LockResult, MutexGuard, WaitTimeoutResult};
    use std::thread::JoinHandle;
    use std::time::Duration;

    /// `Receiver::recv` ([`BlockingKind::Recv`]).
    #[track_caller]
    pub fn recv<T>(receiver: &Receiver<T>) -> Result<T, RecvError> {
        assert_blocking_allowed(BlockingKind::Recv);
        receiver.recv()
    }

    /// `Receiver::recv` for a thread that is idle: it waits at the top of
    /// its loop for its own next command and holds no one else's work (a
    /// parser's or writer's queue). The wait is never checked or recorded,
    /// at any length, as [`crate::sync::Condvar::idle`]'s are. Chromium
    /// declares the same with `WaitableEvent::declare_only_used_while_idle`
    /// (base/synchronization/waitable_event.h), which `MessagePumpDefault`'s
    /// event uses: a thread idle at the bottom of its stack is not a
    /// `ScopedBlockingCall`. A wait for another thread's reply or result is
    /// not idle; it takes [`recv`] (p02-threads 308).
    pub fn idle_recv<T>(receiver: &Receiver<T>) -> Result<T, RecvError> {
        receiver.recv()
    }

    /// `Receiver::recv_timeout` ([`BlockingKind::Recv`]).
    #[track_caller]
    pub fn recv_timeout<T>(
        receiver: &Receiver<T>,
        timeout: Duration,
    ) -> Result<T, RecvTimeoutError> {
        assert_blocking_allowed(BlockingKind::Recv);
        receiver.recv_timeout(timeout)
    }

    /// `JoinHandle::join` ([`BlockingKind::Join`]).
    #[track_caller]
    pub fn join<T>(handle: JoinHandle<T>) -> std::thread::Result<T> {
        assert_blocking_allowed(BlockingKind::Join);
        handle.join()
    }

    /// A condition variable the checked waits take: std's or the timed
    /// [`crate::sync::Condvar`]. A checked wait is judged at any length, so
    /// it waits on the std condition variable directly.
    pub trait AnyCondvar: sealed::Sealed {
        /// The std condition variable to wait on.
        fn std_condvar(&self) -> &Condvar;
    }

    mod sealed {
        pub trait Sealed {}
        impl Sealed for std::sync::Condvar {}
        impl Sealed for crate::sync::Condvar {}
    }

    impl AnyCondvar for Condvar {
        fn std_condvar(&self) -> &Condvar {
            self
        }
    }

    impl AnyCondvar for crate::sync::Condvar {
        fn std_condvar(&self) -> &Condvar {
            self.as_std()
        }
    }

    /// `Condvar::wait` ([`BlockingKind::CondvarWait`]).
    #[track_caller]
    pub fn wait<'a, T>(
        condvar: &impl AnyCondvar,
        guard: MutexGuard<'a, T>,
    ) -> LockResult<MutexGuard<'a, T>> {
        assert_blocking_allowed(BlockingKind::CondvarWait);
        condvar.std_condvar().wait(guard)
    }

    /// `Condvar::wait_while` ([`BlockingKind::CondvarWait`]).
    #[track_caller]
    pub fn wait_while<'a, T>(
        condvar: &impl AnyCondvar,
        guard: MutexGuard<'a, T>,
        condition: impl FnMut(&mut T) -> bool,
    ) -> LockResult<MutexGuard<'a, T>> {
        assert_blocking_allowed(BlockingKind::CondvarWait);
        condvar.std_condvar().wait_while(guard, condition)
    }

    /// `Condvar::wait_timeout` ([`BlockingKind::CondvarWait`]).
    #[track_caller]
    pub fn wait_timeout<'a, T>(
        condvar: &impl AnyCondvar,
        guard: MutexGuard<'a, T>,
        timeout: Duration,
    ) -> LockResult<(MutexGuard<'a, T>, WaitTimeoutResult)> {
        assert_blocking_allowed(BlockingKind::CondvarWait);
        condvar.std_condvar().wait_timeout(guard, timeout)
    }

    /// `std::thread::sleep` ([`BlockingKind::Sleep`]).
    #[track_caller]
    pub fn sleep(duration: Duration) {
        assert_blocking_allowed(BlockingKind::Sleep);
        std::thread::sleep(duration);
    }
}

/// Runs `future` to completion on this thread, parking between polls
/// ([`BlockingKind::BlockOn`]). Runtime-specific forms (tokio) wrap their own
/// `block_on` in [`crate::blocking::scoped_blocking_call`] with the same kind.
#[track_caller]
pub fn block_on<F: Future>(future: F) -> F::Output {
    use std::sync::Arc;
    use std::task::{Context, Poll, Wake, Waker};

    struct ParkedThread(std::thread::Thread);

    impl Wake for ParkedThread {
        fn wake(self: Arc<Self>) {
            self.0.unpark();
        }

        fn wake_by_ref(self: &Arc<Self>) {
            self.0.unpark();
        }
    }

    assert_blocking_allowed(BlockingKind::BlockOn);
    let waker = Waker::from(Arc::new(ParkedThread(std::thread::current())));
    let mut context = Context::from_waker(&waker);
    let mut future = std::pin::pin!(future);
    loop {
        match future.as_mut().poll(&mut context) {
            Poll::Ready(output) => return output,
            Poll::Pending => std::thread::park(),
        }
    }
}

/// A cross-process round trip: a request to the holder, terminal host or
/// browser host and the wait for its reply ([`BlockingKind::IpcReply`]). No
/// allowance permits it on a disallowed thread.
#[track_caller]
pub fn ipc_reply<R>(round_trip: impl FnOnce() -> R) -> R {
    assert_blocking_allowed(BlockingKind::IpcReply);
    round_trip()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blocking::{
        AllowReason, BlockingMode, allow_blocking, disallow_blocking, set_mode, snapshot,
    };
    use std::sync::{Arc, Condvar, Mutex, mpsc};
    use std::time::Duration;

    fn manifest() -> std::path::PathBuf {
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml")
    }

    fn count_at(line: u32) -> u64 {
        snapshot().site(file!(), line).map_or(0, |site| site.count)
    }

    fn kinds_at(line: u32) -> Vec<BlockingKind> {
        snapshot().site(file!(), line).map(|site| site.kinds.iter().collect()).unwrap_or_default()
    }

    fn run_on<R: Send + 'static>(disallowed: bool, f: impl FnOnce() -> R + Send + 'static) -> R {
        set_mode(BlockingMode::Record);
        std::thread::spawn(move || {
            if disallowed {
                disallow_blocking();
            }
            f()
        })
        .join()
        .expect("test thread")
    }

    /// A thread idle for its own next command waits in `idle_recv` on a
    /// disallowed thread in panic mode: no panic and no site.
    #[test]
    fn idle_recv_on_a_disallowed_thread_is_not_a_violation() {
        let (commands, queue) = mpsc::channel::<u32>();
        let waiter = std::thread::spawn(move || {
            disallow_blocking();
            crate::blocking::with_mode(BlockingMode::Panic, || {
                let line = line!() + 1;
                let first = sync::idle_recv(&queue);
                (line, first, sync::idle_recv(&queue).is_err())
            })
        });
        std::thread::sleep(Duration::from_millis(50));
        commands.send(7).expect("the waiter is alive");
        drop(commands);
        let (line, first, closed) = waiter.join().expect("an idle wait does not panic");
        assert_eq!((first, closed), (Ok(7), true));
        assert_eq!(count_at(line), 0, "an idle wait records no site");
    }

    #[test]
    fn checked_read_records_one_site_on_a_disallowed_thread() {
        let path = manifest();
        let (line, bytes) = run_on(true, move || {
            let line = line!() + 1;
            let bytes = fs::read(&path).expect("read manifest");
            (line, bytes)
        });
        assert!(!bytes.is_empty(), "the checked read still reads");
        assert_eq!(count_at(line), 1);
        assert_eq!(kinds_at(line), vec![BlockingKind::Fs]);
    }

    #[test]
    fn assert_at_reports_the_first_violation_at_a_site_once() {
        use crate::blocking::{BlockingCheck, assert_blocking_allowed_at};
        let site = std::panic::Location::caller();
        let checks = run_on(true, move || {
            [
                assert_blocking_allowed_at(BlockingKind::Fs, site),
                assert_blocking_allowed_at(BlockingKind::Fs, site),
            ]
        });
        assert_eq!(
            checks,
            [
                BlockingCheck::Violation { first_at_site: true },
                BlockingCheck::Violation { first_at_site: false }
            ]
        );
        let allowed = run_on(false, move || assert_blocking_allowed_at(BlockingKind::Fs, site));
        assert_eq!(allowed, BlockingCheck::Allowed);
    }

    #[test]
    fn checked_dir_builder_records_one_site_and_creates_the_folder() {
        let dir = std::env::temp_dir().join(format!("cmux-threads-dir-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let nested = dir.join("a/b");
        let (line, created) = run_on(true, move || {
            let line = line!() + 1;
            let created = fs::create_dir_with(std::fs::DirBuilder::new().recursive(true), &nested);
            (line, created.map(|()| nested.is_dir()))
        });
        let _ = std::fs::remove_dir_all(&dir);
        assert!(created.expect("create"), "the checked builder still creates");
        assert_eq!(count_at(line), 1);
        assert_eq!(kinds_at(line), vec![BlockingKind::Fs]);
    }

    #[cfg(unix)]
    #[test]
    fn advisory_lock_records_only_a_waiting_lock() {
        let path = std::env::temp_dir().join(format!("cmux-threads-lock-{}", std::process::id()));
        let lock_path = path.clone();
        let (lines, held, free_again) = run_on(true, move || {
            let first = fs::create(&lock_path).expect("lock file");
            let second = fs::open(&lock_path).expect("second descriptor");
            let waiting = line!() + 1;
            fs::advisory_lock(&first, libc::LOCK_EX).expect("lock");
            let trying = line!() + 1;
            let held = fs::advisory_lock(&second, libc::LOCK_EX | libc::LOCK_NB).is_err();
            let unlocking = line!() + 1;
            fs::advisory_lock(&first, libc::LOCK_UN).expect("unlock");
            let free_again = fs::advisory_lock(&second, libc::LOCK_EX | libc::LOCK_NB).is_ok();
            ([waiting, trying, unlocking], held, free_again)
        });
        let _ = std::fs::remove_file(&path);
        let [waiting, trying, unlocking] = lines;
        assert!(held, "a second descriptor sees the lock");
        assert!(free_again, "unlocking frees it");
        assert_eq!(count_at(waiting), 1);
        assert_eq!(kinds_at(waiting), vec![BlockingKind::Fs]);
        assert_eq!(count_at(trying), 0, "a LOCK_NB try never waits");
        assert_eq!(count_at(unlocking), 0, "an unlock never waits");
    }

    #[test]
    fn checked_read_records_nothing_on_an_ordinary_thread() {
        let path = manifest();
        let line = run_on(false, move || {
            let line = line!() + 1;
            fs::read(&path).expect("read manifest");
            line
        });
        assert_eq!(count_at(line), 0);
    }

    #[test]
    fn checked_read_under_shutdown_allowance_records_nothing() {
        let path = manifest();
        let line = run_on(true, move || {
            allow_blocking(AllowReason::Shutdown, || {
                let line = line!() + 1;
                fs::read_to_string(&path).expect("read manifest");
                line
            })
        });
        assert_eq!(count_at(line), 0);
    }

    #[test]
    fn sync_waits_record_their_kinds() {
        let lines = run_on(true, || {
            let (tx, rx) = mpsc::channel();
            tx.send(1).expect("send");
            let recv_line = line!() + 1;
            assert_eq!(sync::recv(&rx), Ok(1));
            let timeout_line = line!() + 1;
            assert!(sync::recv_timeout(&rx, Duration::from_millis(1)).is_err());

            let handle = std::thread::spawn(|| 7);
            let join_line = line!() + 1;
            assert_eq!(sync::join(handle).expect("join"), 7);

            let pair = Arc::new((Mutex::new(false), Condvar::new()));
            let notifier = Arc::clone(&pair);
            std::thread::spawn(move || {
                *notifier.0.lock().expect("lock") = true;
                notifier.1.notify_all();
            });
            let guard = pair.0.lock().expect("lock");
            let wait_line = line!() + 1;
            let guard = sync::wait_while(&pair.1, guard, |ready| !*ready).expect("wait");
            assert!(*guard);
            drop(guard);

            let sleep_line = line!() + 1;
            sync::sleep(Duration::from_millis(1));
            [recv_line, timeout_line, join_line, wait_line, sleep_line]
        });
        let expected = [
            BlockingKind::Recv,
            BlockingKind::Recv,
            BlockingKind::Join,
            BlockingKind::CondvarWait,
            BlockingKind::Sleep,
        ];
        for (line, kind) in lines.into_iter().zip(expected) {
            assert_eq!(count_at(line), 1, "{kind:?} at line {line}");
            assert_eq!(kinds_at(line), vec![kind], "line {line}");
        }
    }

    #[cfg(unix)]
    #[test]
    fn process_wait_records_process_wait() {
        let (line, ok) = run_on(true, || {
            let line = line!() + 1;
            let status = process::status(
                std::process::Command::new("true").stdout(std::process::Stdio::null()),
            );
            (line, status.map(|status| status.success()).unwrap_or(false))
        });
        assert!(ok);
        assert_eq!(kinds_at(line), vec![BlockingKind::ProcessWait]);
    }

    #[test]
    fn block_on_drives_a_future_woken_from_another_thread() {
        struct Flag {
            ready: Arc<Mutex<Option<std::task::Waker>>>,
            done: Arc<std::sync::atomic::AtomicBool>,
        }
        impl Future for Flag {
            type Output = u32;
            fn poll(
                self: std::pin::Pin<&mut Self>,
                cx: &mut std::task::Context<'_>,
            ) -> std::task::Poll<u32> {
                // Store the waker before reading the flag, so a wake can never be lost.
                *self.ready.lock().expect("lock") = Some(cx.waker().clone());
                if self.done.load(std::sync::atomic::Ordering::Acquire) {
                    return std::task::Poll::Ready(42);
                }
                std::task::Poll::Pending
            }
        }

        let (line, value) = run_on(true, || {
            let ready = Arc::new(Mutex::new(None::<std::task::Waker>));
            let done = Arc::new(std::sync::atomic::AtomicBool::new(false));
            let (waker_slot, done_flag) = (Arc::clone(&ready), Arc::clone(&done));
            let (tx, rx) = mpsc::channel::<()>();
            std::thread::spawn(move || {
                rx.recv().expect("first poll happened");
                done_flag.store(true, std::sync::atomic::Ordering::Release);
                if let Some(waker) = waker_slot.lock().expect("lock").take() {
                    waker.wake();
                }
            });
            let started = async move {
                tx.send(()).expect("signal");
                Flag { ready, done }.await
            };
            let line = line!() + 1;
            let value = block_on(started);
            (line, value)
        });
        assert_eq!(value, 42);
        assert_eq!(kinds_at(line), vec![BlockingKind::BlockOn]);
    }

    #[test]
    fn ipc_reply_has_no_allowance() {
        let line = run_on(true, || {
            allow_blocking(AllowReason::Shutdown, || {
                let line = line!() + 1;
                ipc_reply(|| ());
                line
            })
        });
        assert_eq!(count_at(line), 1);
        assert_eq!(kinds_at(line), vec![BlockingKind::IpcReply]);
    }
}
