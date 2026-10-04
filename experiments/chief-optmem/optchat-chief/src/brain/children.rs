//! Subagents and background work (section 9): acpmux sessions tagged
//! `mux.parent=optchat-chief` (mux/host's tag, with this Chief's value) are
//! the Chief's children. When one ends a turn, its final reply becomes one
//! `user` entry `[<child name>] <report>`, which starts a new turn when the
//! Chief is idle; the Chief never waits or polls for it.
//!
//! Deviation: section 9 delivers one message per spawn (all of a spawn's
//! subagents together) and gives subagents the view. Here each child reports
//! on its own, and a child is a plain acpmux agent started with its task.
//! A report is logged whole, like any user message (section 4.2: never cut
//! the compactor's input; CAP is for tool results only).

use cmux_chief::acp::{AcpmuxEvent, SessionStatus, SessionSummary, TurnFolder, TurnOutput};
use cmux_chief::rules::{PARENT_TAG, turn_ended};
use serde_json::Value;

use super::{Brain, Source};
use crate::acpmux::AgentEvent;
use crate::state::{ChildRecord, ChildStatus};

fn busy(status: SessionStatus) -> bool {
    matches!(status, SessionStatus::Running | SessionStatus::Waiting)
}

impl Brain {
    pub(super) fn on_agents(&mut self, event: AgentEvent) {
        match event {
            AgentEvent::Up(sessions) => {
                self.agents_up = true;
                // Only the Chief's own children: the compactor and turn
                // sessions come and go by the thousand.
                self.sessions = sessions
                    .into_iter()
                    .filter(|s| self.is_child(s))
                    .map(|s| (s.session_id.clone(), s))
                    .collect();
                for name in std::mem::take(&mut self.stale_sessions) {
                    if let Ok(Some(id)) = self.agents.find(&name) {
                        let _ = self.agents.end_session(&id);
                    }
                }
                self.adopt_orphans();
                self.reconcile_children();
                self.maybe_start_turn();
            }
            AgentEvent::Down => self.agents_up = false,
            AgentEvent::SessionChanged(session) => self.on_session(session),
            AgentEvent::Permission {
                session_id,
                permission_id: _,
                request,
            } => {
                // A child can ask before its session_changed reached us.
                let known = self.sessions.get(&session_id).cloned();
                let session = match known {
                    Some(s) => s,
                    None => match self.agents.session(&session_id) {
                        Ok(Some(s)) => {
                            if self.is_child(&s) {
                                self.sessions.insert(s.session_id.clone(), s.clone());
                            }
                            s
                        }
                        Ok(None) => return,
                        Err(e) => {
                            (self.log)(&format!(
                                "permission request from unknown session {session_id}: {e}"
                            ));
                            return;
                        }
                    },
                };
                if self.is_child(&session) {
                    let text = permission_text(&session.name, &request);
                    self.queue(text, Source::Note);
                }
            }
        }
    }

    fn is_child(&self, session: &SessionSummary) -> bool {
        session.tags.get(PARENT_TAG).map(String::as_str) == Some(self.settings.parent.as_str())
    }

    fn on_session(&mut self, session: SessionSummary) {
        if !self.is_child(&session) {
            self.sessions.remove(&session.session_id);
            return;
        }
        let before = self
            .sessions
            .insert(session.session_id.clone(), session.clone())
            .map(|s| s.status);
        let id = session.session_id.clone();
        let record = self
            .state
            .children
            .entry(id.clone())
            .or_insert_with(|| ChildRecord {
                name: session.name.clone(),
                status: if busy(session.status) {
                    ChildStatus::Running
                } else {
                    ChildStatus::Reported
                },
                floor: 0,
            });
        let was = record.status;
        if turn_ended(before, session.status) && was == ChildStatus::Running {
            self.child_finished(&session);
        } else if busy(session.status) {
            record.status = ChildStatus::Running;
        } else if matches!(
            session.status,
            SessionStatus::Closed | SessionStatus::Disconnected
        ) && was == ChildStatus::Running
        {
            record.status = ChildStatus::Reported;
            let text = format!(
                "[{}] (stopped without a report: its session is {:?})",
                session.name, session.status
            );
            self.queue(text, Source::Note);
        }
        if self.state.children.get(&id).map(|r| r.status) != Some(was) || before.is_none() {
            self.save();
        }
    }

    /// Turn sessions whose connection was lost: fold what they did since into
    /// the log, then remove them. One that cannot be read stays for the next
    /// connect, unless acpmux no longer knows it (a daemon restart purged it):
    /// then nothing more can be read and it is dropped.
    fn adopt_orphans(&mut self) {
        if self.state.orphans.is_empty() {
            return;
        }
        let orphans = std::mem::take(&mut self.state.orphans);
        for orphan in orphans {
            match crate::turn::adopt_orphan(&*self.agents, &self.chat, &orphan, &*self.log) {
                Ok(()) => (self.log)(&format!("folded orphan turn session {}", orphan.session)),
                Err(e) if e.contains("no session matches") => (self.log)(&format!(
                    "orphan turn session {} is gone from acpmux; dropped ({e})",
                    orphan.session
                )),
                Err(e) => {
                    (self.log)(&format!("orphan turn session {}: {e}", orphan.session));
                    self.state.orphans.push(orphan);
                }
            }
        }
        self.save();
    }

    /// After a reconnect: children whose turn ended while the host was away,
    /// children that vanished, and permission requests still pending.
    fn reconcile_children(&mut self) {
        let mut finished = Vec::new();
        let mut gone = Vec::new();
        for (id, record) in &self.state.children {
            if record.status != ChildStatus::Running {
                continue;
            }
            match self.sessions.get(id) {
                Some(s) if matches!(s.status, SessionStatus::Ready | SessionStatus::Idle) => {
                    finished.push(s.clone())
                }
                Some(_) => {}
                None => gone.push(id.clone()),
            }
        }
        for id in gone {
            // The Chief may have told the user it is running: say it is gone.
            if let Some(record) = self.state.children.remove(&id) {
                let text = format!(
                    "[{}] (gone: its session no longer exists, so no report will come)",
                    record.name
                );
                self.queue(text, Source::Note);
            }
        }
        for session in finished {
            self.child_finished(&session);
        }
        // Requests raised while the host was away arrive as no notification.
        let asking: Vec<SessionSummary> = self
            .sessions
            .values()
            .filter(|s| self.is_child(s) && s.pending_permissions > 0)
            .cloned()
            .collect();
        for s in asking {
            let text = format!(
                "[{}] has {} pending permission request(s). See `chief agents list`; answer with `chief agents allow {} [OPTION_ID]` or `chief agents deny {}`.",
                s.name, s.pending_permissions, s.name, s.name
            );
            self.queue(text, Source::Note);
        }
        // Tagged sessions first seen now: running ones report when they end.
        let unseen: Vec<SessionSummary> = self
            .sessions
            .values()
            .filter(|s| self.is_child(s) && !self.state.children.contains_key(&s.session_id))
            .cloned()
            .collect();
        for s in unseen {
            let status = if busy(s.status) {
                ChildStatus::Running
            } else {
                ChildStatus::Reported
            };
            self.state.children.insert(
                s.session_id.clone(),
                ChildRecord {
                    name: s.name.clone(),
                    status,
                    floor: 0,
                },
            );
        }
        self.save();
    }

    /// Queues the child's report: every turn it ended after its floor, one
    /// `[name] reply` each. A report already queued for this child (it ended
    /// again before the Chief's next turn) is made again from all of its
    /// turns, so no turn's report is lost.
    fn child_finished(&mut self, session: &SessionSummary) {
        let id = &session.session_id;
        let floor = self.state.children.get(id).map_or(0, |r| r.floor);
        let queued = self.queue.iter().position(
            |q| matches!(&q.source, Source::Child { session_id, .. } if session_id == id),
        );
        let (text, next_floor) = match self.agents.events(id, floor) {
            Ok(events) => {
                let (mut replies, last_end) = ended_replies(&events);
                if replies.is_empty() {
                    replies.push("(no reply text)".to_owned());
                }
                let text = replies
                    .iter()
                    .map(|r| format!("[{}] {r}", session.name))
                    .collect::<Vec<_>>()
                    .join("\n\n");
                // The floor is the last folded turn end, not the session's
                // last seq: that can already be inside the next turn, whose
                // `turn_started` the next fold would then never see.
                (text, last_end.unwrap_or(floor))
            }
            Err(e) if queued.is_some() => {
                // Keep what is queued; the next turn end reads it again.
                (self.log)(&format!(
                    "child {}: its report could not be read: {e}",
                    session.name
                ));
                return;
            }
            Err(e) => (
                format!("[{}] (its report could not be read: {e})", session.name),
                session.last_seq.unwrap_or(floor),
            ),
        };
        (self.log)(&format!(
            "child {} finished; queued its report",
            session.name
        ));
        let source = Source::Child {
            session_id: id.clone(),
            floor: next_floor,
        };
        match queued {
            Some(k) => self.queue[k] = super::Queued { text, source },
            None => self.queue(text, source),
        }
    }
}

/// The final reply of every turn that ended in `events`, oldest first (a
/// failed turn's error included), and the seq of the last turn end.
fn ended_replies(events: &[AcpmuxEvent]) -> (Vec<String>, Option<u64>) {
    let mut folder = TurnFolder::default();
    let mut replies = Vec::new();
    let mut last_end = None;
    for event in events {
        for output in folder.apply(event) {
            if let TurnOutput::Ended { turn, seq, error } = output {
                last_end = Some(seq);
                let text = turn.text.trim();
                let reply = match error {
                    Some(error) if text.is_empty() => format!("(turn failed: {error})"),
                    Some(error) => format!("{text}\n\n(turn failed: {error})"),
                    None => text.to_owned(),
                };
                if !reply.is_empty() {
                    replies.push(reply);
                }
            }
        }
    }
    (replies, last_end)
}

/// A child's permission request as a message to the Chief.
fn permission_text(name: &str, request: &Value) -> String {
    let call = request.get("toolCall");
    let title = call
        .and_then(|c| c.get("title"))
        .and_then(Value::as_str)
        .unwrap_or("a tool call");
    let input = call
        .and_then(|c| c.get("rawInput"))
        .map(|raw| {
            format!(
                "\nInput: {}",
                raw.to_string().chars().take(600).collect::<String>()
            )
        })
        .unwrap_or_default();
    let options: Vec<String> = request
        .get("options")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .map(|o| {
            let text = |k| o.get(k).and_then(Value::as_str).unwrap_or("");
            format!(
                "{} ({})",
                text("optionId"),
                if text("name").is_empty() {
                    text("kind")
                } else {
                    text("name")
                }
            )
        })
        .collect();
    let options = if options.is_empty() {
        "(none)".to_owned()
    } else {
        options.join(", ")
    };
    format!(
        "[{name}] asks permission: {title}{input}\nOptions: {options}\nAnswer with `chief agents allow {name} OPTION_ID` or `chief agents deny {name}`."
    )
}
