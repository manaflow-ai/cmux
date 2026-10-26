//! The Linux kernel pressure source: PSI triggers on `/proc/pressure/memory`
//! (Documentation/accounting/psi.rst, "Monitoring for pressure thresholds";
//! Android's lmkd uses the same triggers).
//!
//! Two triggers: `some` stall time over the threshold means warning, `full`
//! stall time over it means critical. The kernel signals a trigger with
//! POLLPRI at most once per window, so a level holds while its trigger keeps
//! firing and falls back one window after the last event. One thread per
//! process waits in `poll`: with no pressure it has no deadline (no idle
//! wakeup); under pressure its one deadline is the end of the current window.

use std::ffi::CStr;
use std::fs::File;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::time::{Duration, Instant};

use crate::{PressureLevel, WatchError, WeakRegistry};

const PSI_MEMORY: &CStr = c"/proc/pressure/memory";

/// One PSI trigger: `kind` (`some` or `full`) stalled for `stall` within
/// `window`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct TriggerSpec {
    kind: &'static str,
    stall: Duration,
    window: Duration,
}

impl TriggerSpec {
    /// The design's trigger: 150 ms of stall in 1 s.
    const fn new(kind: &'static str) -> Self {
        Self { kind, stall: Duration::from_millis(150), window: Duration::from_secs(1) }
    }

    /// The same ratio over the window an unprivileged process may use (the
    /// kernel takes only multiples of 2 s from a process without
    /// CAP_SYS_RESOURCE).
    fn unprivileged(self) -> Self {
        Self { stall: self.stall * 2, window: self.window * 2, ..self }
    }

    fn text(self) -> String {
        format!("{} {} {}\0", self.kind, self.stall.as_micros(), self.window.as_micros())
    }
}

/// A file descriptor the watch thread waits on, and the poll bit that means
/// "the trigger fired" (POLLPRI for PSI; tests use POLLIN on a pipe).
struct Trigger {
    fd: OwnedFd,
    ready: libc::c_short,
    window: Duration,
    level: PressureLevel,
}

fn open_trigger(spec: TriggerSpec, level: PressureLevel) -> io::Result<Trigger> {
    let try_spec = |spec: TriggerSpec| -> io::Result<Trigger> {
        // SAFETY: a NUL-terminated path; the result is checked.
        let raw = unsafe {
            libc::open(PSI_MEMORY.as_ptr(), libc::O_RDWR | libc::O_NONBLOCK | libc::O_CLOEXEC)
        };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: `raw` is a descriptor this function just opened.
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        let text = spec.text();
        // SAFETY: writes `text`'s bytes (the trigger with its NUL) to `fd`.
        let written = unsafe { libc::write(fd.as_raw_fd(), text.as_ptr().cast(), text.len()) };
        if written < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Trigger { fd, ready: libc::POLLPRI, window: spec.window, level })
    };
    try_spec(spec).or_else(|error| match error.raw_os_error() {
        Some(libc::EINVAL | libc::EPERM) => try_spec(spec.unprivileged()),
        _ => Err(error),
    })
}

/// The level the triggers say now: the worst trigger that fired within its
/// window before `now`.
fn level_at(triggers: &[Trigger], fired: &[Option<Instant>], now: Instant) -> PressureLevel {
    triggers
        .iter()
        .zip(fired)
        .filter(|(trigger, fired)| fired.is_some_and(|at| now.duration_since(at) < trigger.window))
        .map(|(trigger, _)| trigger.level)
        .max()
        .unwrap_or(PressureLevel::Normal)
}

/// The poll timeout: none while no trigger is in its window, else the time
/// until the first window ends.
fn timeout_ms(triggers: &[Trigger], fired: &[Option<Instant>], now: Instant) -> libc::c_int {
    triggers
        .iter()
        .zip(fired)
        .filter_map(|(trigger, fired)| {
            let end = (*fired)? + trigger.window;
            (end > now).then(|| end - now)
        })
        .min()
        .map_or(-1, |left| libc::c_int::try_from(left.as_millis() + 1).unwrap_or(libc::c_int::MAX))
}

/// Waits on `triggers` and tells `registry` each level change, until `stop`
/// hangs up or a trigger fails.
fn run(triggers: &[Trigger], stop: &OwnedFd, registry: &WeakRegistry) {
    let mut fired: Vec<Option<Instant>> = vec![None; triggers.len()];
    let mut level = PressureLevel::Normal;
    let mut fds: Vec<libc::pollfd> = triggers
        .iter()
        .map(|trigger| libc::pollfd {
            fd: trigger.fd.as_raw_fd(),
            events: trigger.ready,
            revents: 0,
        })
        .chain([libc::pollfd { fd: stop.as_raw_fd(), events: libc::POLLIN, revents: 0 }])
        .collect();
    loop {
        // wakeup-allow: deadline the end of a pressure window; none while there is no pressure
        let timeout = timeout_ms(triggers, &fired, Instant::now());
        // SAFETY: `fds` is a live array of `fds.len()` pollfds.
        let ready = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
        if ready < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return;
        }
        let now = Instant::now();
        let Some((stop_fd, trigger_fds)) = fds.split_last_mut() else { return };
        if stop_fd.revents != 0 {
            return;
        }
        for ((pollfd, trigger), fired) in trigger_fds.iter_mut().zip(triggers).zip(&mut fired) {
            if pollfd.revents & (libc::POLLERR | libc::POLLHUP | libc::POLLNVAL) != 0 {
                // The trigger is gone (its cgroup was removed): no more events.
                return;
            }
            if pollfd.revents & trigger.ready != 0 {
                *fired = Some(now);
                drain(&trigger.fd, trigger.ready);
            }
            pollfd.revents = 0;
        }
        let next = level_at(triggers, &fired, now);
        if next != level {
            level = next;
            registry.set_level(level);
        }
    }
}

/// Empties a readable stand-in (tests' pipes). A PSI trigger needs no read:
/// POLLPRI clears when the kernel rearms it.
fn drain(fd: &OwnedFd, ready: libc::c_short) {
    if ready & libc::POLLIN == 0 {
        return;
    }
    let mut buffer = [0u8; 64];
    // SAFETY: reads into a local buffer of its length; the fd is non-blocking.
    while unsafe { libc::read(fd.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len()) } > 0 {}
}

/// A pipe with both ends close-on-exec; the read end is non-blocking.
fn pipe() -> io::Result<(OwnedFd, OwnedFd)> {
    let mut ends = [0; 2];
    // SAFETY: `ends` holds the two descriptors pipe2 writes.
    if unsafe { libc::pipe2(ends.as_mut_ptr(), libc::O_CLOEXEC | libc::O_NONBLOCK) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: pipe2 just opened both descriptors.
    Ok(unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) })
}

/// The running watch thread; dropping it hangs up the stop pipe and the
/// thread ends at its next wake (it holds only a weak registry).
pub(crate) struct Watch {
    _stop: File,
}

impl Watch {
    pub(crate) fn start(registry: WeakRegistry) -> Result<Self, WatchError> {
        let triggers = [
            open_trigger(TriggerSpec::new("some"), PressureLevel::Warning),
            open_trigger(TriggerSpec::new("full"), PressureLevel::Critical),
        ];
        let triggers = triggers.into_iter().collect::<io::Result<Vec<_>>>().map_err(|error| {
            match error.kind() {
                // No PSI in this kernel, or it is turned off (psi=0).
                io::ErrorKind::NotFound | io::ErrorKind::Unsupported => WatchError::Unsupported,
                _ => WatchError::Io(error),
            }
        })?;
        Self::spawn(triggers, registry).map_err(WatchError::Io)
    }

    fn spawn(triggers: Vec<Trigger>, registry: WeakRegistry) -> io::Result<Self> {
        let (stop_read, stop_write) = pipe()?;
        std::thread::Builder::new()
            .name("cmux-memory-pressure".into())
            .spawn(move || run(&triggers, &stop_read, &registry))?;
        Ok(Self { _stop: File::from(stop_write) })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::MemoryRegistry;
    use std::sync::Arc;

    #[test]
    fn trigger_text_is_the_designs_and_falls_back_to_a_two_second_window() {
        let some = TriggerSpec::new("some");
        assert_eq!(some.text(), "some 150000 1000000\0");
        assert_eq!(some.unprivileged().text(), "some 300000 2000000\0");
        assert_eq!(TriggerSpec::new("full").text(), "full 150000 1000000\0");
    }

    /// A pipe stands in for each PSI trigger: a written byte is one POLLPRI.
    fn fake(level: PressureLevel, window: Duration) -> (Trigger, File) {
        let (read, write) = pipe().unwrap();
        (Trigger { fd: read, ready: libc::POLLIN, window, level }, File::from(write))
    }

    fn fire(end: &mut File) {
        use std::io::Write;
        end.write_all(b"!").unwrap();
    }

    /// Test harness wait for the watch thread (not product code).
    fn wait_for(registry: &MemoryRegistry, level: PressureLevel) -> bool {
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if registry.level() == level {
                return true;
            }
            std::thread::sleep(Duration::from_millis(2));
        }
        false
    }

    #[test]
    fn fake_triggers_raise_the_level_and_it_falls_back_one_window_after_the_last_event() {
        let registry = MemoryRegistry::new();
        let heard = Arc::new(std::sync::Mutex::new(Vec::new()));
        let _consumer = registry.register(crate::MemoryConsumer::new(
            "probe",
            crate::Retention::Lossless,
            || None,
            {
                let heard = heard.clone();
                move |level| heard.lock().unwrap().push(level)
            },
        ));
        let window = Duration::from_millis(150);
        let (some, mut some_end) = fake(PressureLevel::Warning, window);
        let (full, mut full_end) = fake(PressureLevel::Critical, window);
        let watch =
            Watch::spawn(vec![some, full], WeakRegistry(Arc::downgrade(&registry.shared))).unwrap();

        fire(&mut some_end);
        assert!(wait_for(&registry, PressureLevel::Warning));
        fire(&mut full_end);
        assert!(wait_for(&registry, PressureLevel::Critical));
        assert!(wait_for(&registry, PressureLevel::Normal), "no event for a window: normal");
        // Critical's window may end before or after warning's (both fired
        // within one window); the changes always end at normal, change-only.
        let heard = heard.lock().unwrap().clone();
        assert_eq!(heard.first(), Some(&PressureLevel::Warning));
        assert_eq!(heard.last(), Some(&PressureLevel::Normal));
        assert!(heard.windows(2).all(|pair| pair[0] != pair[1]), "change-only: {heard:?}");
        drop(watch);
    }

    #[test]
    fn with_no_pressure_the_thread_waits_with_no_deadline() {
        let (some, _end) = fake(PressureLevel::Warning, Duration::from_secs(1));
        let triggers = [some];
        let now = Instant::now();
        assert_eq!(timeout_ms(&triggers, &[None], now), -1);
        assert_eq!(level_at(&triggers, &[None], now), PressureLevel::Normal);
        assert_eq!(level_at(&triggers, &[Some(now)], now), PressureLevel::Warning);
        let left = timeout_ms(&triggers, &[Some(now)], now + Duration::from_millis(400));
        assert!((590..=610).contains(&left), "the deadline is the window's end: {left}");
        assert_eq!(
            level_at(&triggers, &[Some(now)], now + Duration::from_secs(1)),
            PressureLevel::Normal
        );
    }

    #[test]
    fn dropping_the_watch_ends_its_thread() {
        let registry = MemoryRegistry::new();
        let (some, mut some_end) = fake(PressureLevel::Warning, Duration::from_secs(60));
        let watch =
            Watch::spawn(vec![some], WeakRegistry(Arc::downgrade(&registry.shared))).unwrap();
        drop(watch);
        // The thread owns the trigger's read end: once it ends, a write to
        // the stand-in fails with a broken pipe (test harness wait).
        let deadline = Instant::now() + Duration::from_secs(10);
        let ended = loop {
            match io::Write::write_all(&mut some_end, b"!") {
                Err(error) if error.kind() == io::ErrorKind::BrokenPipe => break true,
                _ if Instant::now() > deadline => break false,
                _ => std::thread::sleep(Duration::from_millis(2)),
            }
        };
        assert!(ended, "the watch thread ends when its watch drops");
        assert_eq!(registry.level(), PressureLevel::Normal);
    }

    #[test]
    fn a_real_psi_trigger_opens_where_the_kernel_has_psi() {
        if !std::path::Path::new("/proc/pressure/memory").exists() {
            return;
        }
        let registry = MemoryRegistry::new();
        match registry.watch_system_pressure() {
            Ok(watch) => drop(watch),
            // Containers often mount /proc/pressure read-only.
            Err(WatchError::Io(error)) if error.kind() == io::ErrorKind::PermissionDenied => {}
            Err(error) => panic!("PSI trigger did not open: {error}"),
        }
    }
}
