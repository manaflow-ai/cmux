//! Subagents and background work (section 9): acpmux sessions tagged
//! `mux.parent=optchat-chief` (mux/host's tag, with this Chief's value) are
//! the Chief's children. When one ends a turn, its final reply becomes one
//! `user` entry `[<child name>] <report>`, which starts a new turn when the
//! Chief is idle; the Chief never waits or polls for it.
//!
//! Deviation: section 9 delivers one message per spawn (all of a spawn's
//! subagents together) and gives subagents the view. Here each child reports
//! on its own, and a child is a plain acpmux agent started with its task.

use cmux_chief::acp::{SessionStatus, SessionSummary, last_reply};
use cmux_chief::rules::{PARENT_TAG, turn_ended};
use optchat_host::cap_tool_result;
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
                self.sessions = sessions
                    .into_iter()
                    .map(|s| (s.session_id.clone(), s))
                    .collect();
                for name in std::mem::take(&mut self.stale_sessions) {
                    if let Ok(Some(id)) = self.agents.find(&name) {
                        let _ = self.agents.end_session(&id);
                    }
                }
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
                let Some(session) = self.sessions.get(&session_id).cloned() else {
                    return;
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
        let before = self
            .sessions
            .insert(session.session_id.clone(), session.clone())
            .map(|s| s.status);
        if !self.is_child(&session) {
            return;
        }
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

    /// After a reconnect: children whose turn ended while the host was away.
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
            self.state.children.remove(&id);
        }
        for session in finished {
            self.child_finished(&session);
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

    /// Queues the child's report: the text of its last ended turn after its floor.
    fn child_finished(&mut self, session: &SessionSummary) {
        let id = &session.session_id;
        if self
            .queue
            .iter()
            .any(|q| matches!(&q.source, Source::Child { session_id, .. } if session_id == id))
        {
            return;
        }
        let floor = self.state.children.get(id).map_or(0, |r| r.floor);
        let (report, next_floor) = match self.agents.events(id, floor) {
            Ok(events) => {
                let top = events.iter().map(|e| e.seq).max().unwrap_or(floor);
                (
                    last_reply(&events),
                    session.last_seq.unwrap_or(top).max(top),
                )
            }
            Err(e) => (
                format!("(its report could not be read: {e})"),
                session.last_seq.unwrap_or(floor),
            ),
        };
        let report = if report.is_empty() {
            "(no reply text)".to_owned()
        } else {
            report
        };
        let text = format!("[{}] {}", session.name, cap_tool_result(&report));
        (self.log)(&format!(
            "child {} finished; queued its report",
            session.name
        ));
        self.queue(
            text,
            Source::Child {
                session_id: id.clone(),
                floor: next_floor,
            },
        );
    }
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
