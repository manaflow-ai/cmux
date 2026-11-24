//! This computer woke from sleep (or its wall clock was set): one event from the OS, so no link
//! polls the clocks to find out.
//!
//! - Linux: a `timerfd` on `CLOCK_REALTIME` armed far in the future with `TFD_TIMER_CANCEL_ON_SET`.
//!   The kernel cancels it when the wall clock is set, which it does on every resume from suspend
//!   (`timekeeping_resume` calls `timerfd_resume`), and on a manual or NTP step. One blocked
//!   thread for the whole process, no wakeups between events.
//! - macOS: `IORegisterForSystemPower` on its own dispatch queue: `kIOMessageSystemHasPoweredOn`
//!   is the wake. A sleep this daemon is asked about is allowed at once (`IOAllowPowerChange`),
//!   so registering never delays one.
//!
//! Before, every peer link checked the clocks each 5 s (`SleepWatch::EVERY`) and every backoff
//! wait did too: 0.2 wakeups/s per link at idle, and up to 5 s from the wake to the redial. The
//! clocks are still compared when a link's keepalive fires (`SleepWatch`), so a wake the OS did
//! not report is noticed within one keepalive. Where no source starts ([`live`] is false) the
//! links keep their 5 s check.

use std::sync::OnceLock;
use tokio::sync::watch;

static WATCH: OnceLock<Option<watch::Sender<u64>>> = OnceLock::new();

/// The process's wake source, started on first use; None where none could start.
fn source() -> &'static Option<watch::Sender<u64>> {
    WATCH.get_or_init(|| {
        let (tx, _) = watch::channel(0u64);
        os::start(tx.clone()).then_some(tx)
    })
}

/// Whether the OS reports wakes here: false means callers poll the clocks as before.
pub fn live() -> bool {
    cfg!(test) || source().is_some()
}

/// A receiver of wakes from now on. Tests get one that never changes (a wake a test signals must
/// not reach other tests' peers); a test that wants wakes gives its peer its own sender.
pub fn changes() -> watch::Receiver<u64> {
    if cfg!(test) {
        return watch::channel(0).1;
    }
    match source() {
        Some(tx) => {
            let mut rx = tx.subscribe();
            rx.borrow_and_update();
            rx
        }
        None => watch::channel(0).1,
    }
}

/// Waits for the next wake `changes` sees; never returns once its sender is gone.
pub async fn woke(changes: &mut watch::Receiver<u64>) {
    if changes.changed().await.is_err() {
        std::future::pending::<()>().await;
    }
    changes.borrow_and_update();
}

fn bump(tx: &watch::Sender<u64>) {
    tx.send_modify(|n| *n = n.wrapping_add(1));
}

#[cfg(target_os = "linux")]
mod os {
    use super::bump;
    use tokio::sync::watch;

    /// One timerfd that the kernel cancels whenever the wall clock is set.
    fn arm(fd: libc::c_int) -> bool {
        let spec = libc::itimerspec {
            it_interval: libc::timespec { tv_sec: 0, tv_nsec: 0 },
            // Far in the future, so it never expires; only a clock set ends a read.
            it_value: libc::timespec { tv_sec: libc::time_t::MAX / 2, tv_nsec: 0 },
        };
        let flags = libc::TFD_TIMER_ABSTIME | libc::TFD_TIMER_CANCEL_ON_SET;
        // SAFETY: `fd` is a timerfd this module opened; `spec` lives for the call.
        unsafe { libc::timerfd_settime(fd, flags, &spec, std::ptr::null_mut()) == 0 }
    }

    pub(super) fn start(tx: watch::Sender<u64>) -> bool {
        // SAFETY: plain syscall; the result is checked.
        let fd = unsafe { libc::timerfd_create(libc::CLOCK_REALTIME, libc::TFD_CLOEXEC) };
        if fd < 0 || !arm(fd) {
            if fd >= 0 {
                // SAFETY: closing the fd this function opened.
                unsafe { libc::close(fd) };
            }
            return false;
        }
        std::thread::Builder::new()
            .name("acpmux-wake".into())
            .spawn(move || {
                let mut buf = [0u8; 8];
                loop {
                    // SAFETY: reads at most 8 bytes into `buf`, which outlives the call.
                    let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
                    if n >= 0 {
                        // The timer expired (it never should): arm it again.
                        if !arm(fd) {
                            return;
                        }
                        continue;
                    }
                    match std::io::Error::last_os_error().raw_os_error() {
                        Some(libc::ECANCELED) => {
                            tracing::debug!("the wall clock was set (a wake or a time step)");
                            bump(&tx);
                            if !arm(fd) {
                                return;
                            }
                        }
                        Some(libc::EINTR) => {}
                        _ => return,
                    }
                }
            })
            .is_ok()
    }
}

#[cfg(target_os = "macos")]
mod os {
    use super::bump;
    use std::ffi::{c_char, c_void};
    use tokio::sync::watch;

    type IoConnect = u32;
    type IoObject = u32;
    type NotifyPort = *mut c_void;
    type Queue = *mut c_void;
    type Callback = extern "C" fn(*mut c_void, IoObject, u32, *mut c_void);

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IORegisterForSystemPower(
            refcon: *mut c_void,
            port: *mut NotifyPort,
            callback: Callback,
            notifier: *mut IoObject,
        ) -> IoConnect;
        fn IONotificationPortSetDispatchQueue(port: NotifyPort, queue: Queue);
        fn IOAllowPowerChange(kernel_port: IoConnect, notification_id: isize) -> i32;
    }

    unsafe extern "C" {
        fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> Queue;
    }

    const CAN_SYSTEM_SLEEP: u32 = 0xE000_0270;
    const SYSTEM_WILL_SLEEP: u32 = 0xE000_0280;
    const SYSTEM_HAS_POWERED_ON: u32 = 0xE000_0300;

    /// What the callback reads: the root power port to answer on, and where wakes go.
    struct Context {
        root: std::sync::atomic::AtomicU32,
        tx: watch::Sender<u64>,
    }

    extern "C" fn on_power(refcon: *mut c_void, _: IoObject, message: u32, argument: *mut c_void) {
        // SAFETY: `refcon` is the leaked `Context` `start` registered; it lives for the process.
        let context = unsafe { &*(refcon as *const Context) };
        match message {
            // Never hold a sleep up: answered at once.
            CAN_SYSTEM_SLEEP | SYSTEM_WILL_SLEEP => {
                let root = context.root.load(std::sync::atomic::Ordering::SeqCst);
                // SAFETY: `root` is the connection `IORegisterForSystemPower` returned.
                unsafe { IOAllowPowerChange(root, argument as isize) };
            }
            SYSTEM_HAS_POWERED_ON => {
                tracing::debug!("this computer woke");
                bump(&context.tx);
            }
            _ => {}
        }
    }

    pub(super) fn start(tx: watch::Sender<u64>) -> bool {
        let context: &'static Context =
            Box::leak(Box::new(Context { root: std::sync::atomic::AtomicU32::new(0), tx }));
        let mut port: NotifyPort = std::ptr::null_mut();
        let mut notifier: IoObject = 0;
        // SAFETY: the out-pointers live for the call; `context` lives for the process.
        let root = unsafe {
            IORegisterForSystemPower(
                context as *const Context as *mut c_void,
                &mut port,
                on_power,
                &mut notifier,
            )
        };
        if root == 0 || port.is_null() {
            return false;
        }
        context.root.store(root, std::sync::atomic::Ordering::SeqCst);
        // SAFETY: a serial queue of our own, kept for the process; the label is NUL-terminated.
        let queue = unsafe { dispatch_queue_create(c"dev.cmux.acpmux.wake".as_ptr(), std::ptr::null()) };
        if queue.is_null() {
            return false;
        }
        // SAFETY: `port` came from `IORegisterForSystemPower`; `queue` is live.
        unsafe { IONotificationPortSetDispatchQueue(port, queue) };
        true
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod os {
    pub(super) fn start(_: tokio::sync::watch::Sender<u64>) -> bool {
        false
    }
}

#[cfg(all(test, target_os = "linux"))]
mod tests {
    /// The Linux source starts here (a timerfd with `TFD_TIMER_CANCEL_ON_SET` is allowed in an
    /// unprivileged process), so links on Linux take wakes from it, not a clock poll.
    #[test]
    fn the_linux_wake_source_starts() {
        assert!(super::os::start(tokio::sync::watch::channel(0).0));
    }
}
