//! The app's one waiter on each cloud task it handed off, as a pure state machine: the app sends
//! the state, one event and the time; this answers the next state and the effects to run, in
//! order (start or end a poll, answer the waiters, tell an end, save, forget old banners). The app
//! keeps the poll tasks, their sleeps, the waiters and the saved list's storage.
//!
//! Stop conditions the app's polls obey: a poll ends when its task is terminal, when the account
//! that made it signs out or another account signs in, when the server no longer shows it (403,
//! 404), or after the source's maximum age.

use serde::{Deserialize, Serialize};

use crate::model::{Ended, Notice, Outcome, Record, State, Time};
use crate::read::{self, Read};

/// How long an ended task's card is kept for its banner (its banner is withdrawn with it).
pub const KEPT_ENDED: f64 = 7.0 * 86_400.0;
/// The cancels this app sent that are kept for Runs still in flight.
pub const CANCEL_LIMIT: usize = 256;
/// The notice keys kept per task: a hand-off's turn tells at most three, and turns only go up.
pub const TOLD_LIMIT: usize = 16;

/// What a follower waits on.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    /// Sandboxed Runs (hq#3367): the server caps a task at 12 minutes; every end is told.
    #[default]
    Runs,
    /// Hand-offs (hq#4706): one lasts the whole session and counts turns; each turn's done, failed
    /// and needs-you is told once, never a cancel. It stops when closed, or when it has not
    /// changed for three days while no turn runs.
    Handoffs,
}

impl Kind {
    /// A task that has not changed for this long is given up, so the tasks in flight need no count limit.
    pub fn maximum_age(self) -> f64 {
        match self {
            Kind::Runs => 6.0 * 3_600.0,
            Kind::Handoffs => 3.0 * 86_400.0,
        }
    }

    /// Whether an end (a Run's `ended` read) is told.
    pub fn tells(self, outcome: Outcome) -> bool {
        self == Kind::Runs
            && matches!(
                outcome,
                Outcome::Succeeded | Outcome::Failed | Outcome::TimedOut | Outcome::Cancelled
            )
    }

    /// The path errors name.
    pub fn path(self) -> &'static str {
        match self {
            Kind::Runs => "cloud.runs",
            Kind::Handoffs => "/v1/handoffs",
        }
    }

    /// Whether the owner's list can bring a task back after a relaunch (hand-offs): its incognito
    /// ids are kept until that list answers. Otherwise nothing brings an unsaved incognito task
    /// back, so its id is dropped at the next sign-in.
    pub fn relisted(self) -> bool {
        self == Kind::Handoffs
    }

    /// How one wait's answer reads.
    pub fn read(self, body: &str) -> Read {
        match self {
            Kind::Runs => read::run(body),
            Kind::Handoffs => read::handoff(body),
        }
    }
}

/// One thing that happened, as the app tells it.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "on", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Event {
    /// The signed-in user is now `user` (none: none).
    Account {
        #[serde(default)]
        user: Option<String>,
    },
    /// A send of this app follows the task it just made and awaits its end.
    Follow { record: Record },
    /// Follows a task without awaiting it (found in the owner's list, or just made).
    Watch { record: Record },
    /// The owner's list shows task `id` changed at `changed`, its turn `running` or not.
    Refresh { id: String, changed: Time, running: bool },
    /// The signed-in owner's list answered with the open tasks `listed`.
    KeepIncognito { listed: Vec<String> },
    /// This app asked the server to cancel Run `id` (the person's own action).
    NoteCancel { id: String },
    /// The end of task `id` was told.
    MarkTold { id: String },
    /// Drop the ended tasks older than [`KEPT_ENDED`].
    ForgetOld,
    /// Task `id`'s poll is about to wait; the server last answered it at `heard`.
    Poll { id: String, heard: Time },
    /// Task `id`'s wait answered `body`, or failed (`failed`, with its HTTP `status` if any);
    /// `cancelled`: the poll was stopped while the call was out.
    Answer {
        id: String,
        #[serde(default)]
        body: Option<String>,
        #[serde(default)]
        status: Option<u16>,
        #[serde(default)]
        failed: bool,
        #[serde(default)]
        cancelled: bool,
    },
}

/// The error a waiter or the caller gets.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Failure {
    /// No receipt in time (the send's own poll's answer), naming `path`.
    TimedOut { path: String },
    /// The account that made it is no longer signed in.
    NotSignedIn,
}

/// One effect for the app to run, in order.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "do", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Effect {
    /// Write the saved list of the state as it is when this effect runs.
    Save,
    /// Start task `id`'s poll, unless one runs.
    Start { id: String },
    /// Cancel task `id`'s poll and answer its waiters with `error`.
    EndPoll { id: String, error: Failure },
    /// Task `id`'s poll ends by itself (it is the one asking): forget it, cancel nothing.
    ClearPoll { id: String },
    /// Answer task `id`'s waiters with the wait's answer, or `error`.
    Answer {
        id: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<Failure>,
    },
    /// Tell `outcome` of `record` (the app's `onEnd`). Its snapshot is the wait's answer, or for a
    /// `replayed` end the saved `card`. With `mark_told`, mark it told once the app told it.
    Tell {
        record: Record,
        outcome: Outcome,
        #[serde(default)]
        replayed: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        card: Option<String>,
        #[serde(default)]
        mark_told: bool,
    },
    /// The ended tasks `ids` were dropped after [`KEPT_ENDED`]: their banners go too.
    Forget { ids: Vec<String> },
}

/// What a poll does next.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Next {
    /// Its task is ended or no longer followed.
    #[default]
    Stop,
    /// Wait again (no sooner than 2 s after the last call began).
    Again,
    /// Wait again after a back-off delay.
    Backoff,
}

/// The next wait of a poll.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Wait {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cursor: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub team: Option<String>,
}

/// The answer to one event.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reply {
    pub state: State,
    pub effects: Vec<Effect>,
    /// A follow refused (another account signed in since the create): the caller's error.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub refused: Option<Failure>,
    /// A poll's next wait (none: the poll ends).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub wait: Option<Wait>,
    /// What a poll does after an answer.
    #[serde(default)]
    pub next: Next,
    /// The answer was readable: the server was heard now.
    #[serde(default)]
    pub heard: bool,
}

/// One step of a follower of `kind`: `event` at `now` on `state`.
pub fn step(kind: Kind, state: State, event: Event, now: Time) -> Reply {
    let mut follower = Follower { kind, now, reply: Reply { state, ..Reply::default() } };
    follower.on(event);
    follower.reply
}

struct Follower {
    kind: Kind,
    now: Time,
    reply: Reply,
}

impl Follower {
    fn state(&mut self) -> &mut State {
        &mut self.reply.state
    }

    fn effect(&mut self, effect: Effect) {
        self.reply.effects.push(effect);
    }

    fn timed_out(&self, id: &str) -> Failure {
        Failure::TimedOut { path: format!("{}/{id}", self.kind.path()) }
    }

    fn on(&mut self, event: Event) {
        match event {
            Event::Account { user } => self.account(user),
            Event::Follow { record } => self.follow(record),
            Event::Watch { record } => {
                if self.reply.state.user.as_deref() == Some(record.user.as_str()) {
                    self.add(record);
                }
            }
            Event::Refresh { id, changed, running } => self.refresh(&id, changed, running),
            Event::KeepIncognito { listed } => {
                if let Some(user) = self.reply.state.user.clone() {
                    self.prune_incognito(&listed, Some(&user));
                }
            }
            Event::NoteCancel { id } => self.note_cancel(id),
            Event::MarkTold { id } => self.mark_told(&id),
            Event::ForgetOld => self.prune(),
            Event::Poll { id, heard } => self.poll(&id, heard),
            Event::Answer { id, body, status, failed, cancelled } => {
                self.answer(&id, body, status, failed, cancelled);
            }
        }
    }

    /// A sign-out after a sign-in drops every task; a user signing in resumes that user's tasks
    /// and drops the others (another account can't read them). The launch's first none (the
    /// session still loading) keeps the saved tasks for their user.
    fn account(&mut self, user: Option<String>) {
        if user == self.reply.state.user {
            return;
        }
        let signed_out = user.is_none() && self.reply.state.user.is_some();
        self.state().user.clone_from(&user);
        let dropped: Vec<String> = self
            .reply
            .state
            .records
            .iter()
            .filter(|record| signed_out || user.as_ref().is_some_and(|user| &record.user != user))
            .map(|record| record.id.clone())
            .collect();
        for id in dropped {
            self.drop_task(&id, Failure::NotSignedIn);
        }
        let Some(user) = user else { return };
        self.prune();
        // Nothing brings an unsaved incognito Run back, whichever account made it.
        if !self.kind.relisted() {
            self.prune_incognito(&[], None);
        }
        self.tell_untold(&user);
        let ids: Vec<String> =
            self.reply.state.records.iter().map(|record| record.id.clone()).collect();
        for id in ids {
            self.effect(Effect::Start { id });
        }
    }

    /// Another account signed in since the create: its session can't read this task, and must
    /// not hear of it.
    fn follow(&mut self, record: Record) {
        if self.reply.state.user.as_ref().is_some_and(|user| user != &record.user) {
            self.reply.refused = Some(self.timed_out(&record.id));
            return;
        }
        self.add(record);
    }

    /// Keeps `record` (unless followed or ended already) and starts its poll.
    fn add(&mut self, mut record: Record) {
        let id = record.id.clone();
        let state = self.state();
        if record.is_incognito() && !state.incognito.contains(&id) {
            state.incognito.push(id.clone());
        }
        if state.incognito.contains(&id) {
            state.incognito_owners.entry(id.clone()).or_insert_with(|| record.user.clone());
            record.incognito = Some(true);
        }
        if !state.knows(&id) {
            state.insert_record(record);
            self.effect(Effect::Save);
        } else if record.is_incognito() {
            self.flag_incognito(&id);
        }
        if self.reply.state.record(&id).is_some() {
            self.effect(Effect::Start { id });
        }
    }

    /// Task `id`, followed or ended already as a normal one (the owner's list answered before this
    /// app's watch), is incognito from now on.
    fn flag_incognito(&mut self, id: &str) {
        let state = self.state();
        if let Some(record) = state.record_mut(id) {
            record.incognito = Some(true);
        }
        if let Some(ended) = state.ended.iter_mut().rev().find(|ended| ended.record.id == id) {
            ended.record.incognito = Some(true);
        }
        self.effect(Effect::Save);
    }

    /// Task `id` changed at `changed` as the owner's list shows it (a record saved before a
    /// relaunch may be days behind): its age counts from the later of that and what it has.
    fn refresh(&mut self, id: &str, changed: Time, running: bool) {
        let Some(record) = self.state().record_mut(id) else { return };
        let latest = record.changed.unwrap_or(record.started).max(changed);
        if record.changed == Some(latest) && running == record.running.unwrap_or(false) {
            return;
        }
        record.changed = Some(latest);
        record.running = running.then_some(true);
        self.effect(Effect::Save);
    }

    /// Drops the incognito ids of `owner` (none: every account) that are neither followed nor
    /// `listed`: their task ended while the app was stopped, so nothing else would remove them (#31208).
    fn prune_incognito(&mut self, listed: &[String], owner: Option<&str>) {
        let state = &self.reply.state;
        let gone: Vec<String> = state
            .incognito
            .iter()
            .filter(|id| state.record(id).is_none() && !listed.contains(*id))
            .filter(|id| {
                owner.is_none_or(|owner| {
                    state.incognito_owners.get(*id).map_or(owner, String::as_str) == owner
                })
            })
            .cloned()
            .collect();
        if gone.is_empty() {
            return;
        }
        for id in gone {
            self.forget_incognito(&id);
        }
        self.effect(Effect::Save);
    }

    /// Task `id` is no longer an incognito task that may be open (the caller saves).
    fn forget_incognito(&mut self, id: &str) {
        let state = self.state();
        state.incognito.retain(|kept| kept != id);
        state.incognito_owners.remove(id);
    }

    /// It ends silently, also when the note comes before the Run's follow or the app quits first.
    fn note_cancel(&mut self, id: String) {
        let cancelled = &mut self.state().cancelled;
        if cancelled.contains(&id) {
            return;
        }
        cancelled.push(id);
        if cancelled.len() > CANCEL_LIMIT {
            let excess = cancelled.len() - CANCEL_LIMIT;
            cancelled.drain(..excess);
        }
        self.effect(Effect::Save);
    }

    fn mark_told(&mut self, id: &str) {
        let Some(ended) = self.state().ended.iter_mut().rev().find(|ended| ended.record.id == id)
        else {
            return;
        };
        if ended.told {
            return;
        }
        ended.told = true;
        self.effect(Effect::Save);
    }

    /// Tells the ends of `user`'s tasks that were saved but not told (the app quit or crashed
    /// between the two). Each is marked by its listener once its banner is handled.
    fn tell_untold(&mut self, user: &str) {
        let untold: Vec<Ended> = self
            .reply
            .state
            .ended
            .iter()
            .filter(|ended| !ended.told && ended.record.user == user)
            .cloned()
            .collect();
        for ended in untold {
            self.effect(Effect::Tell {
                record: ended.record,
                outcome: ended.outcome,
                replayed: true,
                card: ended.card,
                mark_told: false,
            });
        }
    }

    /// Drops the ended tasks older than [`KEPT_ENDED`] and forgets their banners.
    fn prune(&mut self) {
        let cutoff = self.now - KEPT_ENDED;
        let ended = &mut self.state().ended;
        let old: Vec<String> = ended
            .iter()
            .filter(|ended| ended.at < cutoff)
            .map(|ended| ended.record.id.clone())
            .collect();
        if old.is_empty() {
            return;
        }
        ended.retain(|ended| ended.at >= cutoff);
        self.effect(Effect::Forget { ids: old });
    }

    /// Stops following `id` without telling it.
    fn drop_task(&mut self, id: &str, error: Failure) {
        let state = self.state();
        state.remove_record(id);
        state.cancelled.retain(|kept| kept != id);
        self.effect(Effect::Save);
        self.effect(Effect::EndPoll { id: id.into(), error });
    }

    /// A turn that runs is never given up for how long since it changed, only when the server is
    /// silent (`heard`); any other task after the maximum age since it changed.
    fn poll(&mut self, id: &str, heard: Time) {
        let Some(record) = self.reply.state.record(id) else { return };
        let since = if record.running == Some(true) {
            heard
        } else {
            record.changed.unwrap_or(record.started)
        };
        if self.now - since >= self.kind.maximum_age() {
            let error = self.timed_out(id);
            return self.drop_task(id, error);
        }
        self.reply.wait = Some(Wait { cursor: record.cursor, team: record.team.clone() });
    }

    fn answer(
        &mut self,
        id: &str,
        body: Option<String>,
        status: Option<u16>,
        failed: bool,
        cancelled: bool,
    ) {
        if failed && matches!(status, Some(403 | 404)) {
            // The server doesn't show this task to this account any more: nothing to wait for.
            self.forget_incognito(id);
            let error = self.timed_out(id);
            return self.drop_task(id, error);
        }
        // Stopped while the call was out (a quit, a sign-out): its answer is the next launch's.
        if cancelled {
            return;
        }
        let body = body.filter(|_| !failed);
        let read = body.as_deref().map_or(Read::Unreadable, |body| self.kind.read(body));
        self.reply.heard = read != Read::Unreadable;
        let body = body.unwrap_or_default();
        self.reply.next = match read {
            Read::Ended(outcome) => self.end(id, outcome, &body, false),
            Read::Closed(notice) => {
                self.notice(id, notice.as_ref(), None, None);
                let outcome = notice.map_or(Outcome::Cancelled, |notice| notice.outcome);
                self.end(id, outcome, &body, true)
            }
            Read::Going { cursor, notice, running } => {
                self.notice(id, notice.as_ref(), cursor, Some(running));
                Next::Again
            }
            Read::Unreadable => {
                let error = self.timed_out(id);
                self.effect(Effect::Answer { id: id.into(), error: Some(error) });
                Next::Backoff
            }
        };
    }

    /// Task `id` ended with `outcome` (its final answer `snapshot`): kept as ended, saved untold
    /// first (a crash before the banner leaves it to the next launch, never lost), its waiters
    /// answered, then told unless `silent`, this app cancelled it, or the source tells no such end;
    /// marked told once told, so it is never told twice.
    fn end(&mut self, id: &str, outcome: Outcome, snapshot: &str, silent: bool) -> Next {
        let Some(record) = self.state().remove_record(id) else { return Next::Stop };
        let state = &self.reply.state;
        let silent = silent
            || (state.cancelled.iter().any(|kept| kept == id) && outcome == Outcome::Cancelled)
            || !self.kind.tells(outcome);
        self.state().cancelled.retain(|kept| kept != id);
        self.forget_incognito(id);
        let ended = Ended {
            record: record.clone(),
            outcome,
            card: read::card(snapshot),
            at: self.now,
            told: silent,
        };
        self.state().ended.push(ended);
        self.prune();
        self.effect(Effect::Save);
        self.effect(Effect::ClearPoll { id: id.into() });
        self.effect(Effect::Answer { id: id.into(), error: None });
        if !silent {
            self.effect(Effect::Tell {
                record,
                outcome,
                replayed: false,
                card: None,
                mark_told: true,
            });
        }
        Next::Stop
    }

    /// Task `id` goes on at `cursor` (none: where it was), its turn `running` or not (none: as it
    /// was); `notice` is told unless its key was. Saved after it is told: a crash in between tells
    /// it again at the next launch (its banner, of the same id, replaces the first), never loses it.
    fn notice(
        &mut self,
        id: &str,
        notice: Option<&Notice>,
        cursor: Option<i64>,
        running: Option<bool>,
    ) {
        let now = self.now;
        let Some(record) = self.state().record_mut(id) else { return };
        let moved = cursor.is_some() && cursor != record.cursor;
        let fresh = notice.is_some_and(|notice| {
            !record.told.as_ref().is_some_and(|told| told.contains(&notice.key))
        });
        let ran = running.is_some_and(|running| running != record.running.unwrap_or(false));
        if !(moved || fresh || ran) {
            return;
        }
        if moved || ran {
            record.changed = Some(now);
        }
        if moved {
            record.cursor = cursor;
        }
        if ran {
            record.running = (running == Some(true)).then_some(true);
        }
        let told = match notice {
            Some(notice) if fresh => {
                let keys = record.told.get_or_insert_with(Vec::new);
                keys.push(notice.key.clone());
                if keys.len() > TOLD_LIMIT {
                    keys.drain(..keys.len() - TOLD_LIMIT);
                }
                Some((record.clone(), notice.outcome))
            }
            _ => None,
        };
        if let Some((record, outcome)) = told {
            self.effect(Effect::Tell {
                record,
                outcome,
                replayed: false,
                card: None,
                mark_told: false,
            });
        }
        self.effect(Effect::Save);
    }
}
