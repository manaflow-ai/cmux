//! The carrier ticket threads' shared state, all of it behind the one lock
//! that [`super::CarrierServer`] keeps it in, and every transition on it.
//!
//! Each method is one transition and runs with that lock held; none blocks,
//! sleeps or makes a request. The fetch thread, the socket thread, the
//! role's resume note and the worker's bind call only these, so no step of
//! one can land between two steps of another. The state does not know about
//! clients or sockets: a bind's payload is `B` and a request's client is `C`,
//! which the model test sets to plain values.

use std::time::{Duration, Instant};

use serde_json::Value;

use super::{HAND_OUT_MARGIN, REFRESH_BEFORE};

/// A ticket asked for ahead and kept for the next ask: the reply line, and
/// its expiry (Unix seconds).
pub(super) struct Warm {
    pub(super) reply: Value,
    expires_at: u64,
}

impl Warm {
    /// The kept reply for a platform reply that is a ticket good past the
    /// refresh point at `now_ms`; `None` for a refusal or a ticket too short
    /// to keep. Only a ticket asked for ahead (prefetched or refreshed in the
    /// background) is held to this; one asked for an ask is good for
    /// [`Warm::handout`].
    pub(super) fn of(reply: &Value, now_ms: u64) -> Option<Warm> {
        Self::handout(reply, now_ms).filter(|warm| {
            warm.expires_at.saturating_mul(1000) > now_ms + REFRESH_BEFORE.as_millis() as u64
        })
    }

    /// The reply for a platform reply that is a ticket that may still be
    /// handed out at `now_ms` ([`HAND_OUT_MARGIN`]); `None` for a refusal or
    /// a ticket too close to its expiry.
    pub(super) fn handout(reply: &Value, now_ms: u64) -> Option<Warm> {
        let expires_at = reply.get("expires_at").and_then(Value::as_u64)?;
        let warm = Warm { reply: reply.clone(), expires_at };
        (reply.get("ok") == Some(&Value::Bool(true)) && warm.usable(now_ms)).then_some(warm)
    }

    /// How long from `now_ms` until it is refreshed (zero when due).
    fn refresh_in(&self, now_ms: u64) -> Duration {
        Duration::from_millis(
            self.expires_at
                .saturating_mul(1000)
                .saturating_sub(REFRESH_BEFORE.as_millis() as u64)
                .saturating_sub(now_ms),
        )
    }

    /// Whether it may still be handed out at `now_ms`.
    pub(super) fn usable(&self, now_ms: u64) -> bool {
        self.expires_at.saturating_mul(1000) > now_ms + HAND_OUT_MARGIN.as_millis() as u64
    }
}

/// One request: the bind's bearer mint, a ticket, or both.
#[derive(Clone, Copy, Debug)]
pub(super) struct Task {
    /// Mint the bearer first (a bind).
    pub(super) mint: bool,
    /// Ask for a ticket: what it is for the journal, and whether an asker
    /// wants it.
    pub(super) ticket: Option<(&'static str, bool)>,
}

impl Task {
    pub(super) fn ticket(what: &'static str, wanted: bool) -> Task {
        Task { mint: false, ticket: Some((what, wanted)) }
    }
}

/// A request that came back: the generation it was started in, the client
/// it ran on and the ticket reply (none for a bearer mint alone or once the
/// role stopped).
pub(super) struct Done<C> {
    pub(super) generation: u64,
    pub(super) client: C,
    pub(super) task: Task,
    pub(super) reply: Option<Value>,
    pub(super) took: Duration,
}

/// What the fetch thread holds, for [`Core::next_job`] to pick by.
#[derive(Clone, Copy, Debug)]
pub(super) struct View {
    /// A client is free (no request on it).
    pub(super) has_client: bool,
    /// A resume can ask now: a free client or a spare one.
    pub(super) can_resume: bool,
    /// The latest bind has a relay carrier: tickets are asked for ahead.
    pub(super) prefetch: bool,
    /// An unused kept ticket may still be refreshed.
    pub(super) may_refresh: bool,
}

/// What the fetch thread does next, with the generation it is of: a request
/// it starts is of that generation, also when a bind or resume comes before
/// the request starts.
pub(super) enum Job<B, C> {
    Stop,
    Bind(Box<B>, u64),
    Resume(u64),
    Wanted(u64),
    Refresh(u64),
    /// A request came back; `current` when it is of this generation.
    Done(Box<Done<C>>, bool, u64),
    /// Nothing to do: wait for a change, at most this long (a kept ticket's
    /// refresh, the only timer).
    Wait(Option<Duration>),
}

/// What an ask got: [`Core::ask`].
pub(super) enum Asked {
    Stopping,
    /// A reply for the asker: a ticket (`kept` when it was asked for ahead)
    /// or a refusal that came after the ask, of `generation`.
    Reply {
        reply: Value,
        kept: bool,
        generation: u64,
    },
    /// Nothing yet: wait. `busy` when a bind or a request is on its way.
    Wait {
        busy: bool,
    },
}

/// The state. A generation starts at each bind and each resume, in the same
/// transition that notes it: nothing asked for in an earlier one is kept,
/// answered or handed out.
pub(super) struct Core<B, C> {
    pub(super) generation: u64,
    pub(super) stopping: bool,
    /// The fetch thread holds a bound client.
    pub(super) bound: bool,
    /// A request of this generation is on its way (or about to start).
    pub(super) fetching: bool,
    /// An asker wants a ticket asked for.
    pub(super) want: bool,
    /// A ticket asked for ahead, for the next ask.
    pub(super) warm: Option<Warm>,
    /// The answer to a ticket an asker wanted, and when it came: for that
    /// asker, or, when it gave up, for the next ask.
    pub(super) answered: Option<(Value, Instant)>,
    /// The latest bind, until the fetch thread takes it.
    pub(super) next: Option<B>,
    /// A resume the fetch thread has not acted on.
    pub(super) resumed: bool,
    /// Requests that came back, for the fetch thread.
    pub(super) done: Vec<Done<C>>,
}

impl<B, C> Default for Core<B, C> {
    fn default() -> Self {
        Core {
            generation: 0,
            stopping: false,
            bound: false,
            fetching: false,
            want: false,
            warm: None,
            answered: None,
            next: None,
            resumed: false,
            done: Vec::new(),
        }
    }
}

impl<B, C> Core<B, C> {
    /// A new generation: whatever was asked for before is stale, and no
    /// request of this one is on its way yet. An asker's want stays.
    fn new_generation(&mut self) {
        self.generation += 1;
        self.warm = None;
        self.answered = None;
        self.fetching = false;
    }

    /// The machine is bound (again): the bind's generation starts now, not
    /// when the fetch thread takes it.
    pub(super) fn bind(&mut self, next: B) {
        self.new_generation();
        self.next = Some(next);
    }

    /// The machine resumed: the kept ticket and anything on its way from
    /// before the pause are stale from this moment.
    pub(super) fn note_resume(&mut self) {
        self.new_generation();
        self.resumed = true;
    }

    /// The server is stopping.
    pub(super) fn stop(&mut self) {
        self.stopping = true;
    }

    /// One look by an asker that came at `started`: the kept ticket, a ticket
    /// asked for an ask (or a refusal that came after the ask), or wait. A
    /// ticket that goes to the asker satisfies its want. Waiting, it wants a
    /// ticket asked for when nothing is on its way.
    pub(super) fn ask(&mut self, now_ms: u64, started: Instant) -> Asked {
        let generation = self.generation;
        if self.stopping {
            return Asked::Stopping;
        }
        if let Some(warm) = self.warm.take()
            && warm.usable(now_ms)
        {
            self.want = false;
            return Asked::Reply { reply: warm.reply, kept: true, generation };
        }
        if let Some((answered, at)) = self.answered.take() {
            let good = Warm::handout(&answered, now_ms).is_some();
            let fresh = answered.get("ok") != Some(&Value::Bool(true)) && at >= started;
            if good || fresh {
                self.want = false;
                return Asked::Reply { reply: answered, kept: false, generation };
            }
        }
        // A bind handed over or in progress counts: its ticket comes within the ask wait.
        let busy = self.bound || self.fetching || self.next.is_some();
        if self.bound && !self.fetching && !self.want {
            self.want = true;
        }
        Asked::Wait { busy }
    }

    /// Whether a reply of `generation` may go to its asker now.
    pub(super) fn may_hand_out(&self, generation: u64) -> bool {
        generation == self.generation
    }

    /// A kept ticket whose asker left before it was written goes back, when
    /// nothing replaced it and its generation still holds.
    pub(super) fn keep_unsent(&mut self, warm: Warm, generation: u64) {
        if self.warm.is_none() && generation == self.generation {
            self.warm = Some(warm);
        }
    }

    /// The fetch thread's next job, picked with the generation read in the
    /// same transition.
    pub(super) fn next_job(&mut self, view: View, now_ms: u64) -> Job<B, C> {
        let generation = self.generation;
        if self.stopping {
            return Job::Stop;
        }
        if let Some(done) = self.done.pop() {
            let current = done.generation == generation;
            if current {
                self.fetching = false;
                if let (Some(reply), Some((_, wanted))) = (&done.reply, done.task.ticket) {
                    if wanted {
                        self.answered = Some((reply.clone(), Instant::now()));
                    } else {
                        self.warm = Warm::of(reply, now_ms);
                    }
                }
            }
            return Job::Done(Box::new(done), current, generation);
        }
        if let Some(next) = self.next.take() {
            // The bind's own request supersedes a resume noted before it.
            self.resumed = false;
            self.bound = true;
            self.fetching = true;
            return Job::Bind(Box::new(next), generation);
        }
        if self.resumed {
            self.resumed = false;
            // A fresh ticket is asked for at once on a carrier machine;
            // otherwise an asker waiting on a request from before the pause
            // asks again.
            self.fetching = view.prefetch && view.can_resume;
            return Job::Resume(generation);
        }
        // A want that a kept or answered ticket already satisfies asks for
        // nothing: the asker takes that ticket.
        let satisfied =
            self.warm.as_ref().is_some_and(|warm| warm.usable(now_ms)) || self.answered.is_some();
        if self.want && !self.fetching && view.has_client && !satisfied {
            self.want = false;
            self.fetching = true;
            return Job::Wanted(generation);
        }
        let refresh = self.warm.as_ref().map(|warm| warm.refresh_in(now_ms));
        if refresh.is_some_and(|left| left.is_zero()) && view.has_client && !self.fetching {
            self.warm = None;
            self.fetching = view.may_refresh;
            return Job::Refresh(generation);
        }
        // A request on its way or no free client: the next change wakes it.
        Job::Wait(refresh.filter(|_| view.has_client && !self.fetching))
    }

    /// A request of `generation` is starting (a resume that waited for its
    /// client): it is on its way when its generation holds.
    pub(super) fn starting(&mut self, generation: u64) {
        if generation == self.generation {
            self.fetching = true;
        }
    }

    /// A request of `generation` could not start.
    pub(super) fn not_started(&mut self, generation: u64) {
        if generation == self.generation {
            self.fetching = false;
        }
    }

    /// A request came back.
    pub(super) fn finished(&mut self, done: Done<C>) {
        self.done.push(done);
    }
}
