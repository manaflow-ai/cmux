//! The forks of one process, counted by the kernel for that process alone
//! (macOS). A kqueue `EVFILT_PROC` knote with `NOTE_FORK` fires in the
//! parent at the end of each `fork` and each `posix_spawn` of a new process
//! (xnu `fork` and `posix_spawn` both `proc_knote(parent, NOTE_FORK)`), so no
//! other process on the host, and no other test of the run, changes the
//! count. The fork-count tests use it in place of the system PID counter,
//! which every process on the host advances.
//!
//! It counts the process's own forks, not its children's: a command
//! substitution whose subshell forks again counts once. Every fork of a
//! descendant starts with a fork of the shell, so a count of 0 is exact.
//! Two forks between two reads of the kqueue merge into one event, so a
//! count above 0 is a lower bound; one thread waits in `kevent` with no
//! timeout and reads each event as it fires, so the forks of one command
//! (each a whole `fork` syscall apart) are read one at a time.

use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::mpsc::{Receiver, channel};
use std::thread::JoinHandle;
use std::time::Duration;

/// `EVFILT_USER` idents: read every pending event and report, or end.
const FLUSH: usize = 1;
const STOP: usize = 2;

fn event(ident: usize, filter: i16, flags: u16, fflags: u32) -> libc::kevent {
    libc::kevent { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() }
}

fn change(kq: RawFd, change: &libc::kevent) {
    // SAFETY: one valid change, no event list.
    let result = unsafe { libc::kevent(kq, change, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
    assert!(result >= 0, "kevent change: {}", std::io::Error::last_os_error());
}

/// The events of `kq` that fire within `timeout` (`None`: until one does).
fn wait(kq: RawFd, timeout: Option<Duration>) -> Vec<libc::kevent> {
    let timeout = timeout.map(|timeout| libc::timespec {
        tv_sec: timeout.as_secs() as libc::time_t,
        tv_nsec: libc::c_long::from(timeout.subsec_nanos()),
    });
    let timeout = timeout.as_ref().map_or(std::ptr::null(), std::ptr::from_ref);
    let mut events = vec![event(0, 0, 0, 0); 16];
    loop {
        // SAFETY: `events` holds `events.len()` entries; `timeout` is null
        // or points at a live timespec.
        let n = unsafe {
            libc::kevent(kq, std::ptr::null(), 0, events.as_mut_ptr(), events.len() as i32, timeout)
        };
        if n >= 0 {
            events.truncate(n as usize);
            return events;
        }
        let error = std::io::Error::last_os_error();
        assert_eq!(error.kind(), std::io::ErrorKind::Interrupted, "kevent: {error}");
    }
}

/// What the watched process did since the watch started.
#[derive(Clone, Copy, Default)]
pub(super) struct Counts {
    pub(super) forks: u32,
    pub(super) execs: u32,
}

impl Counts {
    /// Adds the process events in `events`; returns whether a flush or a stop
    /// was asked.
    fn add(&mut self, events: &[libc::kevent]) -> (bool, bool) {
        let (mut flush, mut stop) = (false, false);
        for event in events {
            match event.filter {
                libc::EVFILT_PROC => {
                    self.forks += u32::from(event.fflags & libc::NOTE_FORK != 0);
                    self.execs += u32::from(event.fflags & libc::NOTE_EXEC != 0);
                }
                libc::EVFILT_USER => {
                    flush |= event.ident == FLUSH;
                    stop |= event.ident == STOP;
                }
                _ => {}
            }
        }
        (flush, stop)
    }
}

/// Counts the forks and execs of one process from now on.
pub(super) struct ForkWatch {
    kq: OwnedFd,
    reports: Receiver<Counts>,
    reader: Option<JoinHandle<()>>,
}

impl ForkWatch {
    /// Starts counting `pid`'s forks and execs. `pid` must be a child of
    /// this process that has not been reaped.
    pub(super) fn new(pid: u32) -> Self {
        // SAFETY: kqueue takes no arguments; the fd is checked below.
        let raw = unsafe { libc::kqueue() };
        assert!(raw >= 0, "kqueue: {}", std::io::Error::last_os_error());
        // SAFETY: `raw` is a new fd that nothing else owns.
        let kq = unsafe { OwnedFd::from_raw_fd(raw) };
        let fflags = libc::NOTE_FORK | libc::NOTE_EXEC;
        change(raw, &event(pid as usize, libc::EVFILT_PROC, libc::EV_ADD | libc::EV_CLEAR, fflags));
        for ident in [FLUSH, STOP] {
            change(raw, &event(ident, libc::EVFILT_USER, libc::EV_ADD | libc::EV_CLEAR, 0));
        }
        let (sender, reports) = channel();
        // The fd outlives the reader: `drop` stops and joins it first.
        let reader = std::thread::spawn(move || {
            let mut counts = Counts::default();
            loop {
                let (mut flush, mut stop) = counts.add(&wait(raw, None));
                // Every fork before the flush was asked is already queued
                // (its knote fires inside the fork, before the shell printed
                // what the caller waited for): read them all before the
                // report, whatever order the queue returns them in.
                while flush && !stop {
                    let pending = wait(raw, Some(Duration::ZERO));
                    if pending.is_empty() {
                        flush = false;
                        stop = sender.send(counts).is_err();
                    } else {
                        stop = counts.add(&pending).1;
                    }
                }
                if stop {
                    return;
                }
            }
        });
        Self { kq, reports, reader: Some(reader) }
    }

    /// The forks and execs of the process so far, every one that happened
    /// before this call included.
    pub(super) fn counts(&self) -> Counts {
        change(self.kq.as_raw_fd(), &event(FLUSH, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER));
        self.reports.recv_timeout(Duration::from_secs(10)).expect("the fork watch did not report")
    }
}

impl Drop for ForkWatch {
    fn drop(&mut self) {
        change(self.kq.as_raw_fd(), &event(STOP, libc::EVFILT_USER, 0, libc::NOTE_TRIGGER));
        if let Some(reader) = self.reader.take() {
            let _ = reader.join();
        }
    }
}

#[test]
fn counts_the_forks_of_its_process_and_not_of_others() {
    use std::io::{BufRead, BufReader, Write};
    // On each line, the child forks once (a `( : )` subshell) and then says
    // so; it forks nothing before the first line, so the watch is in place.
    let mut child = std::process::Command::new("/bin/sh")
        .args(["-c", "while read -r line; do ( : ); echo forked; done"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let watch = ForkWatch::new(child.id());
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    assert_eq!(watch.counts().forks, 0);
    for expected in 1..=3 {
        // Forks of this process are not the child's.
        for _ in 0..3 {
            std::process::Command::new("true").status().unwrap();
        }
        stdin.write_all(b"go\n").unwrap();
        let mut said = String::new();
        stdout.read_line(&mut said).unwrap();
        assert_eq!(said, "forked\n");
        assert_eq!(watch.counts().forks, expected);
    }
    drop(stdin);
    child.wait().unwrap();
}
