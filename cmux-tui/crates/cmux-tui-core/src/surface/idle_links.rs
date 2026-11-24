//! Idle terminal-host links, parked on one poller for the whole daemon.
//!
//! Each hosted terminal's link is read by a thread (`surface-<id>-host-frames`)
//! that blocks in `read` for as long as the terminal is quiet, so a daemon
//! with a thousand hibernated tabs kept a thousand reader threads asleep.
//! A link with nothing to read for [`super::host_frames::LINK_PARK_AFTER`]
//! now hands its socket here instead and the thread ends. One thread
//! (`terminal-idle-links`) waits on every parked socket with epoll (Linux) or
//! kqueue (macOS) through mio; when a socket turns readable (output, a reply,
//! or its end) the link's reader starts again on a new thread with the same
//! state, and reads exactly as it did before it parked.
//!
//! The poller thread starts with the first parked link and ends once no link
//! is parked, so a daemon whose terminals are all busy, or that has none, runs
//! no extra thread. Its cost per wake is the sockets that woke, not the ones
//! parked.

use std::collections::{BTreeSet, HashMap};
use std::os::fd::AsRawFd;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use mio::unix::SourceFd;
use mio::{Events, Interest, Poll, Registry, Token};

use crate::panic_free::RecoverPoison;
use crate::terminal_host_runtime::HostStream;

/// What a parked link runs when its socket turns readable.
type Resume = Box<dyn FnOnce() + Send>;

struct Parked {
    stream: Arc<HostStream>,
    resume: Resume,
    deadline: Option<Instant>,
}

/// A parked link, for [`resume_at`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct ParkedLink(usize);

#[derive(Default)]
struct State {
    parked: HashMap<usize, Parked>,
    /// Links that resume at a deadline even if their socket stays quiet
    /// ([`resume_at`]).
    deadlines: BTreeSet<(Instant, usize)>,
    next_token: usize,
    /// The poll instance while no thread waits on it.
    poll: Option<Poll>,
    running: bool,
}

struct IdleLinks {
    registry: Registry,
    waker: Option<mio::Waker>,
    state: Mutex<State>,
}

fn idle_links() -> Option<&'static IdleLinks> {
    static LINKS: OnceLock<Option<IdleLinks>> = OnceLock::new();
    LINKS
        .get_or_init(|| {
            let poll = Poll::new().ok()?;
            let registry = poll.registry().try_clone().ok()?;
            let waker = mio::Waker::new(&registry, WAKE).ok();
            Some(IdleLinks {
                registry,
                waker,
                state: Mutex::new(State { poll: Some(poll), ..State::default() }),
            })
        })
        .as_ref()
}

/// Park `stream` until it turns readable, then run `resume(work)` on the
/// poller's thread (it starts its own thread, see
/// [`super::host_frames::spawn_or`]). `Err(work)` when it could not be
/// parked; the caller keeps reading itself, as it did before parking
/// existed.
pub(super) fn park<T: Send + 'static>(
    stream: Arc<HostStream>,
    work: T,
    resume: fn(T),
) -> Result<ParkedLink, T> {
    let Some(links) = idle_links() else { return Err(work) };
    let mut state = links.state.lock().recover_poison();
    let token = state.next_token;
    state.next_token = state.next_token.wrapping_add(1) % WAKE.0;
    let fd = stream.as_raw_fd();
    // A socket that already holds bytes reports readable at registration, so
    // nothing that arrived before this call is missed.
    if links.registry.register(&mut SourceFd(&fd), Token(token), Interest::READABLE).is_err() {
        return Err(work);
    }
    if !state.running {
        // The thread takes the poll instance from the state once this lock
        // is released; a failed start leaves it there.
        let started = std::thread::Builder::new()
            .name("terminal-idle-links".into())
            .spawn(move || wait_for_links(links));
        if started.is_err() {
            let _ = links.registry.deregister(&mut SourceFd(&fd));
            return Err(work);
        }
        state.running = true;
    }
    let resume: Resume = Box::new(move || resume(work));
    state.parked.insert(token, Parked { stream, resume, deadline: None });
    Ok(ParkedLink(token))
}

/// Resume `link` by `deadline` even if its socket stays quiet (a link
/// dropped with a reply still owed ends at the reply's deadline). Nothing
/// when it already resumed.
pub(super) fn resume_at(link: ParkedLink, deadline: Instant) {
    let Some(links) = idle_links() else { return };
    let mut state = links.state.lock().recover_poison();
    let Some(parked) = state.parked.get_mut(&link.0) else { return };
    let previous = parked.deadline.replace(deadline);
    if let Some(previous) = previous {
        state.deadlines.remove(&(previous, link.0));
    }
    state.deadlines.insert((deadline, link.0));
    drop(state);
    // The poller sleeps without a timeout; wake it to take the deadline.
    if let Some(waker) = links.waker.as_ref() {
        let _ = waker.wake();
    }
}

/// Remove a parked link and stop watching its socket.
fn take(links: &IdleLinks, state: &mut State, token: usize) -> Option<Parked> {
    let parked = state.parked.remove(&token)?;
    if let Some(deadline) = parked.deadline {
        state.deadlines.remove(&(deadline, token));
    }
    let _ = links.registry.deregister(&mut SourceFd(&parked.stream.as_raw_fd()));
    Some(parked)
}

/// Token of the poller's own waker.
const WAKE: Token = Token(usize::MAX);

/// The poller thread: resume each link whose socket woke; end once none is
/// parked.
fn wait_for_links(links: &'static IdleLinks) {
    let Some(mut poll) = links.state.lock().recover_poison().poll.take() else {
        // Unreachable: one poller thread runs at a time and hands the
        // instance back before it ends. Wake every link so none waits on a
        // poller that does not run.
        let woken: Vec<Parked> = {
            let mut state = links.state.lock().recover_poison();
            state.running = false;
            let tokens: Vec<usize> = state.parked.keys().copied().collect();
            tokens.into_iter().filter_map(|t| take(links, &mut state, t)).collect()
        };
        for parked in woken {
            (parked.resume)();
        }
        return;
    };
    let mut events = Events::with_capacity(64);
    loop {
        let timeout = {
            let state = links.state.lock().recover_poison();
            state
                .deadlines
                .first()
                .map(|(deadline, _)| deadline.saturating_duration_since(Instant::now()))
        };
        if let Err(error) = poll.poll(&mut events, timeout)
            && error.kind() != std::io::ErrorKind::Interrupted
        {
            // A poll that keeps failing must not spin: wake every link so
            // each reads its own socket again, and stop.
            let woken: Vec<Parked> = {
                let mut state = links.state.lock().recover_poison();
                let tokens: Vec<usize> = state.parked.keys().copied().collect();
                let woken = tokens.into_iter().filter_map(|t| take(links, &mut state, t)).collect();
                state.running = false;
                state.poll = Some(poll);
                woken
            };
            for parked in woken {
                (parked.resume)();
            }
            return;
        }
        let mut state = links.state.lock().recover_poison();
        let mut woken = Vec::new();
        for event in events.iter() {
            if let Some(parked) = take(links, &mut state, event.token().0) {
                woken.push(parked);
            }
        }
        let now = Instant::now();
        while let Some(&(deadline, token)) = state.deadlines.first()
            && deadline <= now
        {
            state.deadlines.pop_first();
            if let Some(parked) = take(links, &mut state, token) {
                woken.push(parked);
            }
        }
        if state.parked.is_empty() {
            // Nothing left to wait for: the next park starts the thread
            // again with this poll instance.
            state.running = false;
            state.poll = Some(poll);
            drop(state);
            for parked in woken {
                (parked.resume)();
            }
            return;
        }
        drop(state);
        for parked in woken {
            (parked.resume)();
        }
    }
}

/// Tests: whether the poller thread is running and how many links it holds.
#[cfg(test)]
pub(super) fn parked_for_test() -> (bool, usize) {
    idle_links().map_or((false, 0), |links| {
        let state = links.state.lock().recover_poison();
        (state.running, state.parked.len())
    })
}
