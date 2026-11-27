//! A stand-in for the app's side of the follower: it runs each effect as `SandboxRunFollower`
//! does (one poll per task, round-robin; waiters; the saved list; `onEnd`, `onForget`), against
//! a server scripted per task (each wait takes the next answer, the last repeats; none: 404).

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::follower::{Effect, Event, Failure, Kind, Next, step};
use crate::model::{self, Outcome, Record, State, Time};

/// Some time in 2026, in seconds since 2001.
pub const NOW: Time = 815_000_000.0;
pub const DAY: f64 = 86_400.0;

/// One scripted wait answer: a body, or an HTTP error status (`0`: a transport failure).
#[derive(Clone, Debug)]
pub enum Answer {
    Body(String),
    Status(u16),
}

pub fn body(text: &str) -> Answer {
    Answer::Body(text.into())
}

/// One `onEnd`.
#[derive(Clone, Debug)]
pub struct Told {
    pub record: Record,
    pub outcome: Outcome,
    pub replayed: bool,
    /// The wait's answer, or a replayed end's card (base64).
    pub snapshot: Option<String>,
    /// The saved list when it was told (a crash inside the banner leaves this).
    pub saved_then: Option<String>,
}

pub struct Sim {
    pub kind: Kind,
    pub state: State,
    pub now: Time,
    /// Added to `now` by each wait (a store that holds each call for days).
    pub per_wait: f64,
    pub polls: BTreeSet<String>,
    heard: BTreeMap<String, Time>,
    script: BTreeMap<String, VecDeque<Answer>>,
    /// Each wait: the task and the cursor it passed.
    pub calls: Vec<(String, Option<i64>)>,
    pub told: Vec<Told>,
    pub forgot: Vec<String>,
    /// The UserDefaults value.
    pub saved: Option<String>,
    /// What each task's waiters were answered, in order.
    pub answers: BTreeMap<String, Vec<Result<String, Failure>>>,
}

impl Sim {
    /// A launch of a follower of `kind`, reading `saved`.
    pub fn launch(kind: Kind, saved: Option<String>) -> Sim {
        Sim {
            kind,
            state: model::load(saved.as_deref()),
            now: NOW,
            per_wait: 0.0,
            polls: BTreeSet::new(),
            heard: BTreeMap::new(),
            script: BTreeMap::new(),
            calls: Vec::new(),
            told: Vec::new(),
            forgot: Vec::new(),
            saved,
            answers: BTreeMap::new(),
        }
    }

    /// A relaunch on this one's saved list, with its script.
    pub fn relaunch(&self) -> Sim {
        let mut next = Sim::launch(self.kind, self.saved.clone());
        next.script = self.script.clone();
        next.now = self.now;
        next
    }

    pub fn script(&mut self, id: &str, answers: Vec<Answer>) {
        self.script.insert(id.into(), answers.into());
    }

    pub fn event(&mut self, event: Event) -> crate::follower::Reply {
        self.event_answering(event, "")
    }

    fn event_answering(&mut self, event: Event, answer: &str) -> crate::follower::Reply {
        let reply = step(self.kind, self.state.clone(), event, self.now);
        self.state = reply.state.clone();
        for effect in reply.effects.clone() {
            self.apply(effect, answer);
        }
        reply
    }

    fn apply(&mut self, effect: Effect, answer: &str) {
        match effect {
            Effect::Save => self.saved = Some(model::saved(&self.state)),
            Effect::Start { id } => {
                if self.polls.insert(id.clone()) {
                    self.heard.insert(id, self.now);
                }
            }
            Effect::EndPoll { id, error } => {
                self.polls.remove(&id);
                self.answers.entry(id).or_default().push(Err(error));
            }
            Effect::ClearPoll { id } => {
                self.polls.remove(&id);
            }
            Effect::Answer { id, error } => {
                self.answers
                    .entry(id)
                    .or_default()
                    .push(error.map_or_else(|| Ok(answer.to_string()), Err));
            }
            Effect::Tell { record, outcome, replayed, card, mark_told } => {
                let snapshot = if replayed { card } else { Some(answer.to_string()) };
                let id = record.id.clone();
                self.told.push(Told {
                    record,
                    outcome,
                    replayed,
                    snapshot,
                    saved_then: self.saved.clone(),
                });
                if mark_told {
                    self.event(Event::MarkTold { id });
                }
            }
            Effect::Forget { ids } => self.forgot.extend(ids),
        }
    }

    pub fn account(&mut self, user: Option<&str>) {
        self.event(Event::Account { user: user.map(str::to_string) });
    }

    pub fn watch(&mut self, record: Record) {
        self.event(Event::Watch { record });
    }

    /// The app's `stop()`: every poll ends; the saved list stays.
    pub fn stop(&mut self) {
        self.polls.clear();
    }

    /// One pass of task `id`'s poll loop.
    fn pass(&mut self, id: &str) {
        let heard = self.heard.get(id).copied().unwrap_or(self.now);
        let Some(wait) = self.event(Event::Poll { id: id.into(), heard }).wait else {
            self.polls.remove(id);
            return;
        };
        self.calls.push((id.into(), wait.cursor));
        self.now += self.per_wait;
        let queue = self.script.entry(id.into()).or_default();
        let answer = if queue.len() > 1 { queue.pop_front() } else { queue.front().cloned() };
        let event = match &answer {
            Some(Answer::Body(body)) => Event::Answer {
                id: id.into(),
                body: Some(body.clone()),
                status: None,
                failed: false,
                cancelled: false,
            },
            Some(Answer::Status(status)) => Event::Answer {
                id: id.into(),
                body: None,
                status: Some(*status),
                failed: true,
                cancelled: false,
            },
            None => Event::Answer {
                id: id.into(),
                body: None,
                status: Some(404),
                failed: true,
                cancelled: false,
            },
        };
        let body = match answer {
            Some(Answer::Body(body)) => body,
            _ => String::new(),
        };
        let reply = self.event_answering(event, &body);
        if reply.heard {
            self.heard.insert(id.into(), self.now);
        }
        if reply.next == Next::Stop {
            self.polls.remove(id);
        }
    }

    /// Runs the polls round-robin until none is left or after `passes` passes.
    pub fn run(&mut self, passes: usize) {
        for _ in 0..passes {
            if self.polls.is_empty() {
                return;
            }
            let ids: Vec<String> = self.polls.iter().cloned().collect();
            for id in ids {
                if self.polls.contains(&id) {
                    self.pass(&id);
                }
            }
        }
    }

    /// Runs until no poll is left (at most 200 rounds).
    pub fn settle(&mut self) {
        self.run(200);
    }

    /// The app's `follow(_:)`: follows `record` and awaits its waiter's answer.
    pub fn follow(&mut self, record: Record) -> Result<String, Failure> {
        let id = record.id.clone();
        let reply = self.event(Event::Follow { record });
        if let Some(refused) = reply.refused {
            return Err(refused);
        }
        let path = format!("{}/{id}", self.kind.path());
        if !self.polls.contains(&id) {
            return Err(Failure::TimedOut { path });
        }
        let before = self.answers.get(&id).map_or(0, Vec::len);
        for _ in 0..200 {
            if let Some(answer) = self.answers.get(&id).and_then(|answers| answers.get(before)) {
                return answer.clone();
            }
            if !self.polls.contains(&id) {
                break;
            }
            self.pass(&id);
        }
        self.answers
            .get(&id)
            .and_then(|answers| answers.get(before))
            .cloned()
            .unwrap_or(Err(Failure::TimedOut { path }))
    }

    pub fn outcomes(&self) -> Vec<Outcome> {
        self.told.iter().map(|told| told.outcome).collect()
    }

    pub fn saved_text(&self) -> String {
        self.saved.clone().unwrap_or_default()
    }
}

/// A Run record of `user`, created at [`NOW`].
pub fn run_record(id: &str, user: &str) -> Record {
    Record {
        id: id.into(),
        task: "Fix the flaky test\nthen push".into(),
        key: format!("key-{id}"),
        user: user.into(),
        team: Some("t1".into()),
        started: NOW,
        cursor: None,
        told: None,
        changed: None,
        running: None,
        host: None,
        incognito: None,
    }
}
