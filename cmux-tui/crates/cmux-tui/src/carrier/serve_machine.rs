//! The lifecycle of one Cloud session's `cmux carrier serve` child as one
//! pure reducer: [`ServeMachine::reduce`] takes an event, commits the next
//! state and returns the effects to run, in order, after that commit.
//! `carrier supervise` ([`super::supervise`]) runs the effects (it spawns,
//! asks the app for tokens, writes token lines and arms timers) and feeds
//! each async result back as an event. No effect writes state, and no
//! transition awaits.
//!
//! The rules, stated once:
//! - Every result event carries the epoch or the child it was started for;
//!   one that no longer matches the state is dropped. The one exception is a
//!   stale successful spawn: its child is closed and terminated after a grace.
//! - [`Event::Stop`] and [`Event::AccountEnded`] are terminal: every parked
//!   connect resumes `closed` in the same turn, the child's stdin closes, and
//!   a later connect fails `closed` with no effect. A new serve is a new
//!   instance (the app makes one per session).
//! - [`Event::Park`] (the machine paused) ends the child and the parked
//!   connects the same way, but is not terminal: the next connect (a resume)
//!   launches a fresh child once the parked one exited.
//! - A child whose stdin this machine closed gets SIGTERM at its stop
//!   deadline unless it exited first, so a relaunch never waits on it for
//!   longer than that grace.
//! - A token is written, and a socket handed out, only as an effect of a
//!   transition out of `ready`.
//! - Connects while a launch is in flight join it: there is never a second
//!   child.
//! - A [`ChildId`] is issued (the epoch the child was spawned in), never read
//!   from a pid, an inode or a path.
//!
//! Ported from the app's Swift reducer (cmux#38309); the tests
//! (`serve_machine_tests.rs`) are its tests, one for one.

use std::collections::BTreeMap;
use std::fmt;

pub(crate) type Epoch = u64;
/// A child's issued id: the epoch it was spawned in (one child per epoch).
pub(crate) type ChildId = u64;
pub(crate) type WaiterId = u64;
pub(crate) type ReadId = u64;
/// A child's environment, as the app's connector read it.
pub(crate) type Env = BTreeMap<String, String>;

/// The environment key of the access token a child gets.
pub(crate) const TOKEN_KEY: &str = "CMUX_CLOUD_ACCESS_TOKEN";

/// Why a Cloud link has no socket: the app's `CloudLinkError` cases this
/// machine produces or passes on (the wire form is
/// [`super::supervise`]'s).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum LinkError {
    Disconnected { reason: String },
    Revoked { reason: String },
    HelperNotRunning { reason: String },
    UnsafeSocket(String),
    OpenDirectory { path: String, parent: bool },
    InvalidAnswer(String),
    NotUp { state: String },
    Failed { code: String, message: String },
    Unsupported,
}

impl LinkError {
    pub(crate) fn disconnected(reason: &str) -> Self {
        Self::Disconnected { reason: reason.to_owned() }
    }

    pub(crate) fn helper_not_running(reason: &str) -> Self {
        Self::HelperNotRunning { reason: reason.to_owned() }
    }

    /// A refused dial as the link wording the sidebar has, step by step:
    /// `relay` dropped, `parked_timeout` not ready yet, any other step a
    /// failed connect naming it.
    pub(crate) fn of_step(code: &str, detail: Option<&str>) -> Self {
        match code {
            "relay" => Self::disconnected(code),
            "parked_timeout" => Self::NotUp { state: code.to_owned() },
            _ => Self::Failed {
                code: code.to_owned(),
                message: detail.map(|detail| format!("{code}: {detail}")).unwrap_or_default(),
            },
        }
    }

    /// `carrier serve`'s refusal before its ready line, after which it exits:
    /// a path it could not claim (`bad_request` naming `socket`) is another
    /// cmux serving the machine; any other step keeps the dial's wording.
    pub(crate) fn serve_start(code: &str, detail: Option<&str>, socket: &str) -> Self {
        if code == "bad_request" && detail.is_some_and(|detail| detail.contains(socket)) {
            return socket_taken();
        }
        Self::of_step(code, detail)
    }

    /// A refusal line of a ready `carrier serve`: a refused connection's
    /// step, or the listener failing for good (`socket`). None for
    /// `bad_request`, which answers a stdin line, not a connection.
    pub(crate) fn serve_refusal(code: &str, detail: Option<&str>) -> Option<Self> {
        match code {
            "bad_request" => None,
            "socket" => Some(Self::helper_not_running(&match detail {
                Some(detail) => format!("cmux carrier serve stopped listening: {detail}"),
                None => "cmux carrier serve stopped listening".to_owned(),
            })),
            _ => Some(Self::of_step(code, detail)),
        }
    }
}

impl fmt::Display for LinkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

/// Another `carrier serve` holds the session's socket.
pub(crate) fn socket_taken() -> LinkError {
    LinkError::Failed {
        code: "socket".to_owned(),
        message: "another cmux is serving this machine's connection socket".to_owned(),
    }
}

/// The serve was stopped (or parked, or its account ended).
pub(crate) fn closed() -> LinkError {
    LinkError::disconnected("closed")
}

/// The child exited.
pub(crate) fn exited() -> LinkError {
    LinkError::helper_not_running("cmux carrier serve exited")
}

/// The longest stderr line [`exited_with`] keeps.
const STDERR_LINE_LIMIT: usize = 300;

/// The child exited with `code` (`supervise`'s: its exit code, 128 + the
/// signal that ended it, or -1 when unknown) after `stderr` (its stderr
/// lines that were not events), so the link's end says which exit it was.
/// Per `carrier serve`'s contract, 0 is its stdin ending (or SIGTERM or
/// SIGINT) and 6 its listener failing for good.
pub(crate) fn exited_with(code: i32, stderr: Option<&str>) -> LinkError {
    let status = if code < 0 { "an unknown status".to_owned() } else { format!("status {code}") };
    let last = stderr
        .and_then(|text| text.lines().rev().map(str::trim).find(|line| !line.is_empty()))
        .map(|line| match line.char_indices().nth(STDERR_LINE_LIMIT) {
            Some((cut, _)) => format!("{}…", line.get(..cut).unwrap_or(line)),
            None => line.to_owned(),
        });
    LinkError::HelperNotRunning {
        reason: match last {
            Some(line) => {
                format!("cmux carrier serve exited with {status}; its last stderr line: {line}")
            }
            None => format!("cmux carrier serve exited with {status}"),
        },
    }
}

/// The child wrote no ready line in time.
pub(crate) fn no_ready_line() -> LinkError {
    LinkError::helper_not_running("cmux carrier serve missed its deadline")
}

/// The person's role on the machine as a connection's grant names it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Caller {
    Owner,
    Team,
    /// A connected line without `vmk`: never owner.
    Unknown,
}

impl Caller {
    pub(crate) fn of_vmk(vmk: Option<&str>) -> Self {
        match vmk {
            Some("owner") => Self::Owner,
            Some("team") => Self::Team,
            _ => Self::Unknown,
        }
    }

    pub(crate) fn word(self) -> &'static str {
        match self {
            Self::Owner => "owner",
            Self::Team => "team",
            Self::Unknown => "unknown",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum StopReason {
    /// The app closed the link: the machine removed, sign-out, quit, Cloud
    /// turned off by policy.
    Closed,
    /// The connector's account ended (an account or team switch, sign-out).
    AccountEnded,
}

/// What a ready child has: the token it got last, its latest connected
/// answer, the last refused dial since the current connect, and the token
/// read in flight (a connect's or the refresh's).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub(crate) struct Ready {
    pub sent_token: Option<String>,
    pub answer: Option<Caller>,
    pub refused: Option<LinkError>,
    pub token_read: Option<ReadId>,
    /// The stderr tail the child ended with (its lines that were not
    /// events); the exit that follows names it.
    pub stderr: Option<String>,
}

impl Ready {
    pub(crate) fn sent(token: Option<&str>) -> Self {
        Self { sent_token: token.map(str::to_owned), ..Self::default() }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum State {
    /// No launch in flight. `last_end`: why the last child or launch ended.
    /// `alive`: a child whose stdin is closed and whose exit has not come
    /// yet; the next launch drains it first.
    Idle {
        last_end: Option<LinkError>,
        alive: Option<ChildId>,
    },
    /// Waiting for the socket lease.
    Claiming(Epoch),
    /// Waiting for this instance's previous child to exit before the relaunch.
    Draining(Epoch, ChildId),
    /// The connector's environment (the access token) is being read.
    AwaitingToken(Epoch, ReadId),
    /// Spawned; waiting for the ready line.
    Spawning {
        epoch: Epoch,
        child: ChildId,
        sent_token: Option<String>,
    },
    /// Serving the socket; the token refresh is armed.
    Ready(Epoch, ChildId, Ready),
    /// Terminal intent: stdin closed, waiting for the exit (then SIGTERM at
    /// the deadline).
    Stopping(ChildId, StopReason),
    Stopped(StopReason),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum TokenRead {
    Ok(Env),
    Failed(LinkError),
    /// The connector is bound to an account that is no longer signed in.
    Fenced,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Event {
    Connect {
        waiter: WaiterId,
        keep_refusal: bool,
    },
    Stop,
    /// The machine paused: end the child, keep the serve.
    Park,
    AccountEnded,
    SocketClaimed(Epoch),
    TokenRead {
        epoch: Epoch,
        read: ReadId,
        result: TokenRead,
    },
    /// `failure` None: the child runs.
    Spawned {
        child: ChildId,
        failure: Option<LinkError>,
    },
    /// `held` false: the fence ended first (and closed the child).
    HeldResult {
        child: ChildId,
        held: bool,
    },
    /// `policy`: the socket check's refusal.
    ReadyLine {
        child: ChildId,
        socket: String,
        policy: Option<LinkError>,
    },
    OkLine {
        child: ChildId,
        vmk: Option<String>,
    },
    RefusalLine {
        child: ChildId,
        code: String,
        detail: Option<String>,
    },
    /// Its stderr tail; the exit follows.
    StderrEnded {
        child: ChildId,
        stderr: String,
    },
    ReadyDeadline(Epoch),
    ChildExit {
        child: ChildId,
        code: i32,
    },
    RefreshDue(Epoch),
    TokenWritten {
        child: ChildId,
        token: String,
        ok: bool,
    },
    StopDeadline(ChildId),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Effect {
    ClaimSocket(Epoch),
    ReadToken(Epoch, ReadId),
    Spawn { child: ChildId, env: Env },
    Hold(ChildId),
    Release(ChildId),
    ArmReadyDeadline(Epoch),
    CancelReadyDeadline,
    ArmRefresh(Epoch, Option<String>),
    CancelRefresh,
    WriteToken { child: ChildId, token: String },
    CloseStdin(ChildId),
    ArmStopDeadline(ChildId),
    Terminate(ChildId),
    TerminateAfterGrace(ChildId),
    Resume(Vec<WaiterId>, Result<String, LinkError>),
    Publish(Caller),
}

/// One serve's lifecycle (module docs).
#[derive(Debug, Clone)]
pub(crate) struct ServeMachine {
    /// The socket this serve claims; a ready line naming another one is
    /// refused.
    socket: String,
    state: State,
    /// Bumped by every launch and by every exit from a child-bound phase.
    epoch: Epoch,
    /// Connects parked until the launch, or the ready child's token read,
    /// answers.
    waiters: Vec<WaiterId>,
    last_read: ReadId,
}

impl ServeMachine {
    pub(crate) fn new(socket: &str) -> Self {
        Self {
            socket: socket.to_owned(),
            state: State::Idle { last_end: None, alive: None },
            epoch: 0,
            waiters: Vec::new(),
            last_read: 0,
        }
    }

    pub(crate) fn state(&self) -> &State {
        &self.state
    }

    #[cfg(test)]
    pub(crate) fn epoch(&self) -> Epoch {
        self.epoch
    }

    #[cfg(test)]
    pub(crate) fn waiters(&self) -> &[WaiterId] {
        &self.waiters
    }

    /// Why the link ended since the current connect: a refused dial's step,
    /// why the last child or launch ended, or that the serve was stopped.
    /// None while a launch is in flight.
    pub(crate) fn refusal(&self) -> Option<LinkError> {
        match &self.state {
            State::Ready(_, _, ready) => ready.refused.clone(),
            State::Idle { last_end, .. } => Some(last_end.clone().unwrap_or_else(exited)),
            State::Claiming(_)
            | State::Draining(..)
            | State::AwaitingToken(..)
            | State::Spawning { .. } => None,
            State::Stopping(..) | State::Stopped(_) => Some(closed()),
        }
    }

    /// The ready child's latest connected answer; None until it answered
    /// once, and in every other state.
    pub(crate) fn answer(&self) -> Option<Caller> {
        match &self.state {
            State::Ready(_, _, ready) => ready.answer,
            _ => None,
        }
    }

    #[cfg(test)]
    pub(crate) fn is_ready(&self) -> bool {
        matches!(self.state, State::Ready(..))
    }

    /// A launch between its socket claim and its child: the claim is still
    /// the launch's own.
    pub(crate) fn launching(&self) -> bool {
        matches!(self.state, State::AwaitingToken(..) | State::Spawning { .. })
    }

    pub(crate) fn is_terminal(&self) -> bool {
        matches!(self.state, State::Stopping(..) | State::Stopped(_))
    }

    /// Whether the machine is in `Claiming(epoch)`.
    pub(crate) fn is_claiming(&self, epoch: Epoch) -> bool {
        self.state == State::Claiming(epoch)
    }

    /// The child this state owns, if any.
    pub(crate) fn child(&self) -> Option<ChildId> {
        match &self.state {
            State::Idle { alive, .. } => *alive,
            State::Draining(_, child)
            | State::Spawning { child, .. }
            | State::Ready(_, child, _)
            | State::Stopping(child, _) => Some(*child),
            State::Claiming(_) | State::AwaitingToken(..) | State::Stopped(_) => None,
        }
    }

    pub(crate) fn reduce(&mut self, event: Event) -> Vec<Effect> {
        match event {
            Event::Connect { waiter, keep_refusal } => self.connect(waiter, keep_refusal),
            Event::Stop => self.stop(StopReason::Closed),
            Event::Park => self.park(),
            Event::AccountEnded => self.stop(StopReason::AccountEnded),
            Event::SocketClaimed(at) => {
                if self.state != State::Claiming(at) {
                    return Vec::new();
                }
                let read = self.next_read();
                self.state = State::AwaitingToken(at, read);
                vec![Effect::ReadToken(at, read)]
            }
            Event::TokenRead { epoch, read, result } => self.token_read(epoch, read, result),
            Event::Spawned { child, failure } => self.spawned(child, failure),
            Event::HeldResult { child, held } => {
                if held || !self.spawning(child) {
                    return Vec::new();
                }
                self.stop(StopReason::AccountEnded)
            }
            Event::ReadyLine { child, socket, policy } => self.ready_line(child, &socket, policy),
            Event::OkLine { child, vmk } => self.ok_line(child, vmk.as_deref()),
            Event::RefusalLine { child, code, detail } => {
                self.refusal_line(child, &code, detail.as_deref())
            }
            Event::StderrEnded { child, stderr } => match &mut self.state {
                // In ready, the exit follows: it names this tail.
                State::Ready(_, owned, ready) if *owned == child => {
                    ready.stderr = Some(stderr);
                    Vec::new()
                }
                State::Spawning { child: owned, .. } if *owned == child => {
                    self.fail(child, LinkError::HelperNotRunning { reason: stderr })
                }
                _ => Vec::new(),
            },
            Event::ReadyDeadline(at) => match self.state {
                State::Spawning { epoch, child, .. } if epoch == at => {
                    self.fail(child, no_ready_line())
                }
                _ => Vec::new(),
            },
            Event::ChildExit { child, code } => self.child_exit(child, code),
            Event::RefreshDue(at) => match &mut self.state {
                State::Ready(epoch, _, ready) if *epoch == at && ready.token_read.is_none() => {
                    self.last_read = self.last_read.wrapping_add(1);
                    ready.token_read = Some(self.last_read);
                    vec![Effect::ReadToken(at, self.last_read)]
                }
                _ => Vec::new(),
            },
            Event::TokenWritten { child, token, ok } => self.token_written(child, token, ok),
            Event::StopDeadline(child) => match self.state {
                State::Stopping(owned, _)
                | State::Idle { alive: Some(owned), .. }
                | State::Draining(_, owned)
                    if owned == child =>
                {
                    vec![Effect::Terminate(child)]
                }
                _ => Vec::new(),
            },
        }
    }

    fn spawning(&self, child: ChildId) -> bool {
        matches!(self.state, State::Spawning { child: owned, .. } if owned == child)
    }

    fn connect(&mut self, waiter: WaiterId, keep_refusal: bool) -> Vec<Effect> {
        match &mut self.state {
            State::Stopping(..) | State::Stopped(_) => {
                vec![Effect::Resume(vec![waiter], Err(closed()))]
            }
            State::Idle { alive, .. } => {
                let alive = *alive;
                self.waiters.push(waiter);
                self.launch(alive)
            }
            State::Claiming(_)
            | State::Draining(..)
            | State::AwaitingToken(..)
            | State::Spawning { .. } => {
                // Join the launch in flight: never a second child.
                self.waiters.push(waiter);
                Vec::new()
            }
            State::Ready(at, _, ready) => {
                if !keep_refusal {
                    ready.refused = None;
                }
                self.waiters.push(waiter);
                if ready.token_read.is_some() {
                    return Vec::new();
                }
                self.last_read = self.last_read.wrapping_add(1);
                ready.token_read = Some(self.last_read);
                vec![Effect::ReadToken(*at, self.last_read)]
            }
        }
    }

    /// A new epoch's launch: after this instance's previous child exited,
    /// else after the socket lease.
    fn launch(&mut self, draining: Option<ChildId>) -> Vec<Effect> {
        self.epoch = self.epoch.wrapping_add(1);
        if let Some(alive) = draining {
            self.state = State::Draining(self.epoch, alive);
            return Vec::new();
        }
        self.state = State::Claiming(self.epoch);
        vec![Effect::ClaimSocket(self.epoch)]
    }

    /// What leaving a child-bound phase cancels.
    fn leave_timers(&self) -> Vec<Effect> {
        match self.state {
            State::Spawning { .. } => vec![Effect::CancelReadyDeadline],
            State::Ready(..) => vec![Effect::CancelRefresh],
            _ => Vec::new(),
        }
    }

    fn stop(&mut self, reason: StopReason) -> Vec<Effect> {
        if self.is_terminal() {
            return Vec::new();
        }
        let mut effects = self.leave_timers();
        let child = self.child();
        self.epoch = self.epoch.wrapping_add(1);
        match child {
            Some(child) => {
                effects.extend([Effect::CloseStdin(child), Effect::Release(child)]);
                self.state = State::Stopping(child, reason);
            }
            None => self.state = State::Stopped(reason),
        }
        effects.extend(self.resume_all(Err(closed())));
        if let Some(child) = child {
            effects.push(Effect::ArmStopDeadline(child));
        }
        effects
    }

    /// Like [`Self::stop`] but not terminal: the child's stdin closes, the
    /// parked connects resume `closed`, and the state goes idle with the
    /// child exiting, so the next connect drains it and launches a fresh one.
    fn park(&mut self) -> Vec<Effect> {
        if self.is_terminal() {
            return Vec::new();
        }
        let mut effects = self.leave_timers();
        let child = self.child();
        self.epoch = self.epoch.wrapping_add(1);
        self.state = State::Idle { last_end: Some(closed()), alive: child };
        if let Some(child) = child {
            effects.extend([Effect::CloseStdin(child), Effect::Release(child)]);
        }
        effects.extend(self.resume_all(Err(closed())));
        if let Some(child) = child {
            effects.push(Effect::ArmStopDeadline(child));
        }
        effects
    }

    fn token_read(&mut self, at: Epoch, read: ReadId, result: TokenRead) -> Vec<Effect> {
        match &mut self.state {
            State::AwaitingToken(epoch, pending) if *epoch == at && *pending == read => {
                match result {
                    TokenRead::Ok(env) => {
                        let sent_token = env.get(TOKEN_KEY).cloned();
                        self.state = State::Spawning { epoch: at, child: at, sent_token };
                        vec![Effect::Spawn { child: at, env }]
                    }
                    TokenRead::Failed(error) => {
                        self.state = State::Idle { last_end: Some(error.clone()), alive: None };
                        self.resume_all(Err(error))
                    }
                    TokenRead::Fenced => self.stop(StopReason::AccountEnded),
                }
            }
            State::Ready(epoch, child, ready) if *epoch == at && ready.token_read == Some(read) => {
                ready.token_read = None;
                let child = *child;
                match result {
                    TokenRead::Ok(env) => match env.get(TOKEN_KEY) {
                        // The connects resume once the write answered
                        // ([`Event::TokenWritten`]).
                        Some(token) if Some(token) != ready.sent_token.as_ref() => {
                            vec![Effect::WriteToken { child, token: token.clone() }]
                        }
                        _ => self.answered(at),
                    },
                    // A failed lookup keeps the healthy child on its last token.
                    TokenRead::Failed(_) => self.answered(at),
                    TokenRead::Fenced => self.stop(StopReason::AccountEnded),
                }
            }
            _ => Vec::new(),
        }
    }

    fn token_written(&mut self, child: ChildId, token: String, ok: bool) -> Vec<Effect> {
        let at = match &mut self.state {
            State::Ready(at, owned, ready) if *owned == child => {
                if ok {
                    ready.sent_token = Some(token);
                }
                *at
            }
            _ => return Vec::new(),
        };
        if !ok {
            return self.gone(child, None);
        }
        self.answered(at)
    }

    /// A ready child's token read finished: the parked connects get the
    /// socket and the refresh re-arms.
    fn answered(&mut self, at: Epoch) -> Vec<Effect> {
        let token = match &self.state {
            State::Ready(_, _, ready) => ready.sent_token.clone(),
            _ => None,
        };
        let mut effects = self.resume_all(Ok(self.socket.clone()));
        effects.push(Effect::ArmRefresh(at, token));
        effects
    }

    fn spawned(&mut self, child: ChildId, failure: Option<LinkError>) -> Vec<Effect> {
        if !self.spawning(child) {
            // A stale spawn never orphans its child.
            return match failure {
                None => vec![Effect::CloseStdin(child), Effect::TerminateAfterGrace(child)],
                Some(_) => Vec::new(),
            };
        }
        match failure {
            Some(failure) => {
                // It never ran: no child is kept for the next launch to wait on.
                self.state = State::Idle { last_end: Some(failure.clone()), alive: None };
                self.resume_all(Err(failure))
            }
            None => vec![Effect::Hold(child), Effect::ArmReadyDeadline(child)],
        }
    }

    fn ready_line(
        &mut self,
        child: ChildId,
        served: &str,
        policy: Option<LinkError>,
    ) -> Vec<Effect> {
        let (at, sent_token) = match &self.state {
            State::Spawning { epoch, child: owned, sent_token } if *owned == child => {
                (*epoch, sent_token.clone())
            }
            _ => return Vec::new(),
        };
        if served != self.socket {
            return self.fail(child, LinkError::InvalidAnswer("served another socket".to_owned()));
        }
        if let Some(policy) = policy {
            return self.fail(child, policy);
        }
        self.state = State::Ready(at, child, Ready::sent(sent_token.as_deref()));
        let mut effects = vec![Effect::CancelReadyDeadline, Effect::ArmRefresh(at, sent_token)];
        effects.extend(self.resume_all(Ok(self.socket.clone())));
        effects
    }

    fn ok_line(&mut self, child: ChildId, vmk: Option<&str>) -> Vec<Effect> {
        match &mut self.state {
            State::Spawning { child: owned, .. } if *owned == child => {
                self.fail(child, LinkError::InvalidAnswer("no ready line".to_owned()))
            }
            State::Ready(_, owned, ready) if *owned == child => {
                let caller = Caller::of_vmk(vmk);
                ready.answer = Some(caller);
                vec![Effect::Publish(caller)]
            }
            _ => Vec::new(),
        }
    }

    fn refusal_line(&mut self, child: ChildId, code: &str, detail: Option<&str>) -> Vec<Effect> {
        match &mut self.state {
            State::Spawning { child: owned, .. } if *owned == child => {
                let error = LinkError::serve_start(code, detail, &self.socket);
                self.fail(child, error)
            }
            State::Ready(_, owned, ready) if *owned == child => {
                if let Some(refusal) = LinkError::serve_refusal(code, detail) {
                    ready.refused = Some(refusal);
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn child_exit(&mut self, child: ChildId, code: i32) -> Vec<Effect> {
        match &self.state {
            State::Spawning { child: owned, .. } if *owned == child => {
                // Stderr ends before the exit is read, so this is only a
                // reader that never saw its end.
                let effects = self.fail(child, exited_with(code, None));
                self.state = State::Idle { last_end: Some(exited_with(code, None)), alive: None };
                effects
            }
            State::Ready(_, owned, _) if *owned == child => self.gone(child, Some(code)),
            State::Draining(at, owned) if *owned == child => {
                let at = *at;
                self.state = State::Claiming(at);
                vec![Effect::ClaimSocket(at)]
            }
            State::Idle { last_end, alive: Some(owned) } if *owned == child => {
                self.state = State::Idle { last_end: last_end.clone(), alive: None };
                Vec::new()
            }
            State::Stopping(owned, reason) if *owned == child => {
                self.state = State::Stopped(*reason);
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// A launch that did not get ready: the child's stdin closes and the
    /// parked connects get `error`.
    fn fail(&mut self, child: ChildId, error: LinkError) -> Vec<Effect> {
        self.epoch = self.epoch.wrapping_add(1);
        self.state = State::Idle { last_end: Some(error.clone()), alive: Some(child) };
        let mut effects = vec![
            Effect::CancelReadyDeadline,
            Effect::CloseStdin(child),
            Effect::Release(child),
            Effect::ArmStopDeadline(child),
        ];
        effects.extend(self.resume_all(Err(error)));
        effects
    }

    /// The ready child exited with `exit` (its code), or stopped taking stdin
    /// (`exit` None: it may still run). The refusal is its last refused dial,
    /// else that it exited, with its status and last stderr line when it did;
    /// parked connects relaunch.
    fn gone(&mut self, child: ChildId, exit: Option<i32>) -> Vec<Effect> {
        let ended = match &self.state {
            State::Ready(_, owned, ready) if *owned == child => {
                ready.refused.clone().unwrap_or_else(|| match exit {
                    Some(code) => exited_with(code, ready.stderr.as_deref()),
                    None => exited(),
                })
            }
            _ => return Vec::new(),
        };
        self.epoch = self.epoch.wrapping_add(1);
        let exiting = exit.is_none().then_some(child);
        self.state = State::Idle { last_end: Some(ended), alive: exiting };
        let mut effects = vec![Effect::CancelRefresh];
        if exiting.is_some() {
            effects.extend([Effect::CloseStdin(child), Effect::ArmStopDeadline(child)]);
        }
        effects.push(Effect::Release(child));
        if !self.waiters.is_empty() {
            effects.extend(self.launch(exiting));
        }
        effects
    }

    fn resume_all(&mut self, result: Result<String, LinkError>) -> Vec<Effect> {
        if self.waiters.is_empty() {
            return Vec::new();
        }
        vec![Effect::Resume(std::mem::take(&mut self.waiters), result)]
    }

    fn next_read(&mut self) -> ReadId {
        self.last_read = self.last_read.wrapping_add(1);
        self.last_read
    }
}

#[cfg(test)]
#[path = "serve_machine_tests.rs"]
mod tests;
