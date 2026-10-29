//! Whether the app a helper process serves still runs, and the one rule by
//! which every app helper stops (principled audit lagQuitHelpers,
//! 2026-10-29; first fixed by cp/lag-quit-helpers and cp/quit-chief-idle).
//!
//! The helpers an app starts (acpmux, cmux-browser-host, the Chief's
//! `optchat-chief host` and its `cmux-chief-*` conversation owner) follow
//! one rule, recomputed from current truth at every change:
//!
//! > a helper exits when it has no client, no live owner app and no live
//! > work ([`Keeps::exits`]).
//!
//! Chromium ends a child process when the browser process goes
//! (`ChildProcessHost` channel error) and a utility process when its last
//! client goes; this is the same rule with the owner as a level.
//!
//! [`OwnerLiveness`] is that level. It follows one app at a time through one
//! kernel handle (a pidfd on Linux, a kqueue `EVFILT_PROC` `NOTE_EXIT`
//! registration on macOS), opened when the app is named, so the identity is
//! the handle, not a pid read later. One thread per followed app blocks in
//! the kernel for its exit and then tells the helper ([`OwnerLiveness::observe`]);
//! nothing polls. When the followed app has exited, [`OwnerLiveness::state`]
//! reads the owner-app.pid file (a newer app that reused the helper names
//! itself there) and follows that app when it runs. The answer is never a
//! latched event: an app that starts after a quit and writes the file keeps
//! the helper again.
//!
//! Where no kernel handle can be opened, the follow thread checks the app
//! with `kill(pid, 0)` every [`POLL_FALLBACK`] instead, and [`Watch::Polled`]
//! says so: the helper still stops after its app quits.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock, PoisonError, Weak};
use std::time::Duration;

use cmux_threads::sync::Mutex;

mod handle;

#[cfg(unix)]
mod peer;
#[cfg(unix)]
pub use peer::peer_app;

/// How long a helper whose owner app exited waits, with no client and no
/// live work, before it stops: an app that restarts (an update) reconnects
/// within it. It decides when a helper stops, never whether.
pub const OWNER_EXIT_GRACE: Duration = Duration::from_secs(2);

/// How often a follow with no kernel handle checks the app.
pub const POLL_FALLBACK: Duration = Duration::from_secs(1);

/// An app named by its process id (a launcher's environment variable, an
/// owner-app.pid file or a socket peer).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub struct OwnerApp {
    pid: Option<i32>,
}

impl OwnerApp {
    /// The app named in environment variable `variable`.
    pub fn from_env(variable: &str) -> Self {
        Self::parse(std::env::var(variable).ok().as_deref())
    }

    /// A pid above 1; anything else names no app.
    pub fn parse(value: Option<&str>) -> Self {
        let pid = value.and_then(|v| v.trim().parse::<i32>().ok()).filter(|pid| *pid > 1);
        Self { pid }
    }

    /// The app with process id `pid` (none for 1 or less).
    pub fn from_pid(pid: i32) -> Self {
        Self { pid: Some(pid).filter(|pid| *pid > 1) }
    }

    /// Whether an app was named.
    pub fn is_named(&self) -> bool {
        self.pid.is_some()
    }

    /// Its process id.
    pub fn pid(&self) -> Option<i32> {
        self.pid
    }

    /// Whether a process with this pid exists now (a recycled pid counts:
    /// it fails toward keeping the helper). Only for an app no handle
    /// follows yet (the pid file's) and for the fallback follow.
    fn exists(self) -> bool {
        let Some(pid) = self.pid else { return false };
        #[cfg(unix)]
        {
            // SAFETY: signal 0 delivers nothing; it checks existence and permission.
            let rc = unsafe { libc::kill(pid, 0) };
            rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
        }
        #[cfg(not(unix))]
        {
            let _ = pid;
            true
        }
    }
}

/// The owner app as a level.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum OwnerState {
    /// No app named this helper (a CLI started it): each helper says
    /// whether that keeps it ([`Keeps::exits`]'s `unowned_keeps`).
    Unnamed,
    /// The followed app runs.
    Alive,
    /// The followed app exited and no newer app took the helper over.
    Gone,
}

/// What can keep a helper running, read from current truth.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Keeps {
    /// A client is connected.
    pub clients: bool,
    pub owner: OwnerState,
    /// Work runs that a stop would cut (an agent turn, a session, a
    /// terminal, a child at work).
    pub live_work: bool,
}

impl Keeps {
    /// The rule: exit when there is no client, no live owner and no live
    /// work. `unowned_keeps` says whether a helper no app named stays for
    /// good (the CLI's acpmux) or stops by the same rule.
    pub fn exits(&self, unowned_keeps: bool) -> bool {
        let owner_keeps = match self.owner {
            OwnerState::Alive => true,
            OwnerState::Gone => false,
            OwnerState::Unnamed => unowned_keeps,
        };
        !(self.clients || owner_keeps || self.live_work)
    }
}

/// The R3 invariant, checked in debug builds where a helper acts on its
/// decision to exit (after its fence, when it has one). `keeps` must be read
/// again there, not the facts the decision used, so a helper that acts on a
/// stale or latched answer fails it:
/// `exiting == !(clients || owner alive || live work)`. Unit tests also check
/// the other side (a helper that stays while the rule says exit).
#[track_caller]
pub fn check(helper: &str, exiting: bool, keeps: Keeps, unowned_keeps: bool) {
    debug_assert_eq!(
        exiting,
        keeps.exits(unowned_keeps),
        "{helper}: exiting is {exiting}, but the stop rule says {} for {keeps:?}",
        keeps.exits(unowned_keeps)
    );
    let _ = (helper, exiting, keeps, unowned_keeps);
}

/// How an app is followed.
#[derive(Debug)]
pub enum Watch {
    /// No app: nothing to follow.
    Unnamed,
    /// A kernel handle; one thread blocks for the exit.
    Kernel,
    /// It had exited already.
    Gone,
    /// No kernel handle (this error): checked every [`POLL_FALLBACK`].
    Polled(std::io::Error),
    /// No thread could start (this error): [`OwnerLiveness::state`] checks
    /// the app when it is read, and nothing tells the helper of its exit.
    Unwatched(std::io::Error),
}

/// How a followed app is watched (a [`Watch`] without its error).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Kernel,
    Gone,
    Polled,
    Unwatched,
}

/// One followed app.
struct Followed {
    app: OwnerApp,
    exited: Arc<AtomicBool>,
    kind: Kind,
}

impl Followed {
    fn exited(&self) -> bool {
        self.exited.load(Ordering::Acquire) || (self.kind == Kind::Unwatched && !self.app.exists())
    }
}

type Observer = Box<dyn Fn() + Send + Sync>;

/// The owner app a helper follows, as a level ([`OwnerLiveness::state`]).
pub struct OwnerLiveness {
    /// The owner-app.pid file a newer app writes when it reuses the helper.
    file: Option<PathBuf>,
    followed: Mutex<Option<Followed>>,
    observer: OnceLock<Observer>,
    me: Weak<OwnerLiveness>,
}

impl std::fmt::Debug for OwnerLiveness {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OwnerLiveness").field("file", &self.file).finish_non_exhaustive()
    }
}

impl OwnerLiveness {
    /// Follows no app yet ([`OwnerState::Unnamed`]); `file` is the
    /// owner-app.pid file a newer app writes, if the helper has one.
    pub fn new(file: Option<PathBuf>) -> Arc<Self> {
        Arc::new_cyclic(|me| Self {
            file,
            followed: Mutex::new(None),
            observer: OnceLock::new(),
            me: me.clone(),
        })
    }

    /// [`OwnerLiveness::new`] following `app` (nothing for an unnamed one).
    pub fn following(app: OwnerApp, file: Option<PathBuf>) -> (Arc<Self>, Watch) {
        let liveness = Self::new(file);
        let watch = liveness.follow(app);
        (liveness, watch)
    }

    /// `observer` runs (on the follow thread) after each change of
    /// [`OwnerLiveness::state`] it can see: the followed app exited, or a
    /// newer app is followed. The helper then reads the state again. Once
    /// per liveness; false when one was installed before.
    pub fn observe(&self, observer: impl Fn() + Send + Sync + 'static) -> bool {
        self.observer.set(Box::new(observer)).is_ok()
    }

    /// Follows `app` from now (the newest app that serves the helper, such
    /// as a provider that connected), replacing the app followed before.
    /// The observer hears it.
    pub fn follow(&self, app: OwnerApp) -> Watch {
        let watch = {
            let mut followed = self.lock();
            self.follow_locked(&mut followed, app)
        };
        self.notify();
        watch
    }

    /// The owner now: the followed app runs, else a newer app the pid file
    /// names runs (it is followed from here), else gone; unnamed when no
    /// app was ever named.
    pub fn state(&self) -> OwnerState {
        let mut followed = self.lock();
        let Some(current) = followed.as_ref() else { return OwnerState::Unnamed };
        if !current.exited() {
            return OwnerState::Alive;
        }
        let gone = current.app;
        let Some(next) = self.file.as_deref().and_then(|file| next_owner(gone, file)) else {
            return OwnerState::Gone;
        };
        match self.follow_locked(&mut followed, next) {
            Watch::Gone => OwnerState::Gone,
            _ => OwnerState::Alive,
        }
    }

    /// Whether the owner app runs ([`OwnerState::Alive`]).
    pub fn owner_alive(&self) -> bool {
        self.state() == OwnerState::Alive
    }

    /// Whether a change of [`OwnerLiveness::state`] reaches the observer:
    /// false when the follow thread could not start ([`Watch::Unwatched`]).
    /// A helper whose owner does not report its changes reads the state
    /// again on a deadline of its own.
    pub fn reports_changes(&self) -> bool {
        self.lock().as_ref().is_none_or(|followed| followed.kind != Kind::Unwatched)
    }

    fn lock(&self) -> cmux_threads::sync::MutexGuard<'_, Option<Followed>> {
        self.followed.lock().unwrap_or_else(PoisonError::into_inner)
    }

    fn notify(&self) {
        if let Some(observer) = self.observer.get() {
            observer();
        }
    }

    /// Follows `app` in place of what `followed` holds (the caller holds the
    /// lock, so two readers never follow the same newer app twice).
    fn follow_locked(&self, followed: &mut Option<Followed>, app: OwnerApp) -> Watch {
        let Some(pid) = app.pid() else {
            *followed = None;
            return Watch::Unnamed;
        };
        if let Some(current) = followed.as_ref().filter(|f| f.app == app && !f.exited()) {
            // The same running process (its handle has not fired, so the pid
            // was not reused): one follow is enough (a provider reconnects).
            return match current.kind {
                Kind::Kernel => Watch::Kernel,
                Kind::Gone => Watch::Gone,
                Kind::Polled => Watch::Polled(already()),
                Kind::Unwatched => Watch::Unwatched(already()),
            };
        }
        let exited = Arc::new(AtomicBool::new(false));
        let (watch, kind) = match handle::Handle::open(pid) {
            Ok(None) => {
                exited.store(true, Ordering::Release);
                (Watch::Gone, Kind::Gone)
            }
            Ok(Some(handle)) => match self.spawn_wait(app, Some(handle), exited.clone()) {
                Ok(()) => (Watch::Kernel, Kind::Kernel),
                Err(error) => (Watch::Unwatched(error), Kind::Unwatched),
            },
            Err(open_error) => match self.spawn_wait(app, None, exited.clone()) {
                Ok(()) => (Watch::Polled(open_error), Kind::Polled),
                Err(error) => (Watch::Unwatched(error), Kind::Unwatched),
            },
        };
        *followed = Some(Followed { app, exited, kind });
        watch
    }

    /// One thread waits for `app`'s exit (in the kernel on `handle`, else
    /// by [`POLL_FALLBACK`] checks), marks it and tells the observer.
    fn spawn_wait(
        &self,
        app: OwnerApp,
        handle: Option<handle::Handle>,
        exited: Arc<AtomicBool>,
    ) -> std::io::Result<()> {
        let me = self.me.clone();
        // supervise-allow: one follow; a panic leaves the app's exit unseen by this helper, which then keeps running as it would with its app (fails toward staying).
        cmux_threads::spawn("owner-app-exit", cmux_threads::ThreadQos::Utility, move || {
            let waited = handle.map(handle::Handle::wait);
            if !matches!(waited, Some(Ok(()))) {
                while app.exists() {
                    cmux_threads::checked::sync::sleep(POLL_FALLBACK);
                }
            }
            exited.store(true, Ordering::Release);
            if let Some(liveness) = me.upgrade() {
                liveness.notify();
            }
        })
        .map(drop)
    }
}

/// The error of a follow that found the app already followed (the first
/// follow's error is in its own [`Watch`]).
fn already() -> std::io::Error {
    std::io::Error::other("followed already")
}

/// The app `file` names, when it is another process than `gone` and runs.
pub fn next_owner(gone: OwnerApp, file: &Path) -> Option<OwnerApp> {
    let text = std::fs::read_to_string(file).ok()?;
    let next = OwnerApp::parse(Some(&text));
    (next.is_named() && next != gone && next.exists()).then_some(next)
}

#[cfg(test)]
mod tests;
