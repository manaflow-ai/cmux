//! Per-terminal program status records (OSC 7501, decision
//! OSC-7501-PROGRAM-STATUS).
//!
//! libghostty-vt parses and validates the reports and keeps nothing; the
//! session host keeps one record per id here and applies the specification's
//! lifetime rules (https://mitchellh.com/writing/program-status-osc7501):
//! a report replaces its record, `clear` removes a record and its
//! descendants, a primary prompt start removes `working`, `blocked` and
//! `idle`, the process exit hides them, and at most [`MAX_RECORDS`] records
//! stay (the one updated longest ago goes first). `done` and `error` stay
//! until the program replaces or clears them; "seen" is client view state,
//! keyed by `updated_seq`. A record without `app` shows the app of its
//! nearest ancestor that has one. A record that starts waiting on the user
//! (`blocked`), fails (`error`) or finishes (`done`) raises one
//! [`ProgramStatusAlert`], which the terminal's reader posts as a
//! rate-limited terminal notification (the client shows a `done` only for a
//! terminal the user cannot see).
//!
//! Text is untrusted program output: display only, never interpreted.
//! libghostty already removed control characters; this module also removes
//! invisible formatting characters (bidi overrides, zero-width characters)
//! and caps the length, so a record cannot hide or reorder text when a
//! client shows it outside the terminal.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use ghostty_vt::{ProgramStatusEvent, ProgramStatusKind, ProgramStatusReport, ProgramStatusState};
use serde_json::{Value, json};

/// Records kept per terminal. The specification asks for at most 256 and at
/// least 64.
pub(crate) const MAX_RECORDS: usize = 256;
/// Shown text bounds, the same as terminal notifications.
pub(crate) const MAX_TITLE_CHARS: usize = 256;
pub(crate) const MAX_MESSAGE_CHARS: usize = 1024;

/// One kept record. `state` is never `Clear`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProgramStatusRecord {
    pub(crate) state: ProgramStatusState,
    pub(crate) kind: Option<ProgramStatusKind>,
    pub(crate) progress: Option<u8>,
    pub(crate) app: Option<String>,
    pub(crate) title: Option<String>,
    pub(crate) message: Option<String>,
    pub(crate) updated_seq: u64,
    pub(crate) updated_at_ms: u64,
    /// When the record entered its current state and kind (Unix ms): a
    /// report that keeps both (a progress or message update) keeps it, so a
    /// client can say how long a program has worked or waited. Not in the
    /// terminal-host snapshot codec: a restored record starts at its
    /// `updated_at_ms`.
    pub(crate) since_ms: u64,
}

impl ProgramStatusRecord {
    /// Whether the record ends at a new prompt or when the process exits.
    fn is_transient(&self) -> bool {
        matches!(
            self.state,
            ProgramStatusState::Working | ProgramStatusState::Blocked | ProgramStatusState::Idle
        )
    }

    /// `app` is the app the record shows (its own or an ancestor's).
    fn to_json(&self, id: &str, app: Option<&str>) -> Value {
        json!({
            "id": id,
            "state": self.state.as_str(),
            "progress": self.progress,
            "kind": self.kind.map(ProgramStatusKind::as_str),
            "app": app,
            "title": self.title,
            "msg": self.message,
            "updated_seq": self.updated_seq.to_string(),
            "updated_at_ms": self.updated_at_ms.to_string(),
            "since_ms": self.since_ms.to_string(),
        })
    }
}

/// Alerts kept between two takes; more in one output chunk drop the oldest.
const MAX_PENDING_ALERTS: usize = 8;

/// A notification a record asks for: it started waiting on the user,
/// failed or finished. `title` names the program and says what it needs; `body` is the
/// record's message. Both are shown text (no control or invisible
/// formatting characters).
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ProgramStatusAlert {
    /// The record that raised it; removing the record before the alert is
    /// taken withdraws it.
    pub(crate) id: String,
    pub(crate) title: String,
    pub(crate) body: String,
    /// `Blocked`, `Error` or `Done`.
    pub(crate) state: ProgramStatusState,
}

/// The records of one terminal, keyed by record id (`""` is the root).
#[derive(Debug, Default)]
pub(crate) struct ProgramStatusRecords {
    records: BTreeMap<String, ProgramStatusRecord>,
    /// Raised by `apply`, taken by the terminal's reader.
    alerts: Vec<ProgramStatusAlert>,
    next_seq: u64,
    /// Bumped on every visible change; `published` is the value last handed
    /// to the public graph.
    revision: u64,
    published: u64,
    /// The `shown` value last handed to frontends.
    shown_published: Option<ShownProgramStatus>,
}

impl ProgramStatusRecords {
    /// Applies one event from the terminal's parser at `now_ms`.
    pub(crate) fn apply(&mut self, event: ProgramStatusEvent, now_ms: u64) {
        match event {
            ProgramStatusEvent::PromptStart => self.end_transient(),
            ProgramStatusEvent::Report(report) => self.apply_report(report, now_ms),
        }
    }

    fn apply_report(&mut self, report: ProgramStatusReport, now_ms: u64) {
        let ProgramStatusReport { state, kind, progress, id, app, title, message } = report;
        if state == ProgramStatusState::Clear {
            let before = self.records.len();
            if id.is_empty() {
                self.records.clear();
            } else {
                let prefix = format!("{id}/");
                self.records.retain(|key, _| key != &id && !key.starts_with(&prefix));
            }
            self.withdraw_alerts_of_removed_records();
            if self.records.len() != before {
                self.revision += 1;
            }
            return;
        }
        if !self.records.contains_key(&id) && self.records.len() >= MAX_RECORDS {
            let oldest = self
                .records
                .iter()
                .min_by_key(|(_, record)| record.updated_seq)
                .map(|(key, _)| key.clone());
            if let Some(oldest) = oldest {
                self.records.remove(&oldest);
            }
        }
        self.next_seq += 1;
        let blocked = state == ProgramStatusState::Blocked;
        let shows_progress = blocked || state == ProgramStatusState::Working;
        let kind = kind.filter(|_| blocked);
        let since_ms = self
            .records
            .get(&id)
            .filter(|previous| previous.state == state && previous.kind == kind)
            .map_or(now_ms, |previous| previous.since_ms);
        let record = ProgramStatusRecord {
            state,
            kind,
            progress: progress.filter(|value| shows_progress && *value <= 100),
            app: non_empty(shown_text(&app, MAX_TITLE_CHARS)),
            title: non_empty(shown_text(&title, MAX_TITLE_CHARS)),
            message: non_empty(shown_text(&message, MAX_MESSAGE_CHARS)),
            updated_seq: self.next_seq,
            updated_at_ms: now_ms,
            since_ms,
        };
        let previous = self.records.insert(id.clone(), record);
        self.revision += 1;
        self.raise_alert(&id, previous.as_ref());
    }

    /// Raises an alert when the record `id` starts waiting on the user or
    /// fails, or a blocked record changes what it waits for (`kind`). A
    /// report that keeps the state and kind (a progress update, or a message
    /// that counts down while blocked) raises nothing, so a program cannot
    /// turn one wait into a stream of notifications.
    fn raise_alert(&mut self, id: &str, previous: Option<&ProgramStatusRecord>) {
        let Some(record) = self.records.get(id) else { return };
        let verb = match (record.state, record.kind) {
            (ProgramStatusState::Blocked, Some(ProgramStatusKind::Permission)) => "needs approval",
            (ProgramStatusState::Blocked, Some(ProgramStatusKind::Question)) => "asks a question",
            (ProgramStatusState::Blocked, Some(ProgramStatusKind::Auth)) => "needs sign-in",
            (ProgramStatusState::Blocked, None) => "needs input",
            (ProgramStatusState::Error, _) => "failed",
            (ProgramStatusState::Done, _) => "is done",
            _ => return,
        };
        if previous
            .is_some_and(|previous| previous.state == record.state && previous.kind == record.kind)
        {
            return;
        }
        let name = record
            .title
            .clone()
            .or_else(|| self.app_of(id).map(str::to_owned))
            .unwrap_or_else(|| "A program".to_owned());
        let alert = ProgramStatusAlert {
            id: id.to_owned(),
            title: shown_text(&format!("{name} {verb}"), MAX_TITLE_CHARS),
            body: record.message.clone().unwrap_or_default(),
            state: record.state,
        };
        if self.alerts.len() == MAX_PENDING_ALERTS {
            self.alerts.remove(0);
        }
        self.alerts.push(alert);
    }

    /// The alerts raised since the last take, oldest first.
    pub(crate) fn take_alerts(&mut self) -> Vec<ProgramStatusAlert> {
        std::mem::take(&mut self.alerts)
    }

    /// The app record `id` shows: its own, else that of its nearest ancestor
    /// that has one (`a/b` looks at `a`, then the root `""`). The ancestors
    /// do not have to exist.
    fn app_of(&self, id: &str) -> Option<&str> {
        let mut current = id;
        loop {
            if let Some(app) = self.records.get(current).and_then(|record| record.app.as_deref()) {
                return Some(app);
            }
            if current.is_empty() {
                return None;
            }
            current = current.rfind('/').map_or("", |slash| &current[..slash]);
        }
    }

    /// A primary prompt started: the program that reported `working`,
    /// `blocked` or `idle` is no longer in the foreground.
    pub(crate) fn end_transient(&mut self) {
        let before = self.records.len();
        self.records.retain(|_, record| !record.is_transient());
        if self.records.len() != before {
            self.revision += 1;
        }
        self.withdraw_alerts_of_removed_records();
    }

    /// A record cleared (or ended by a prompt) before its alert was taken
    /// no longer asks for anything: its alert goes too.
    fn withdraw_alerts_of_removed_records(&mut self) {
        let records = &self.records;
        self.alerts.retain(|alert| records.contains_key(&alert.id));
    }

    #[cfg(test)]
    pub(crate) fn get(&self, id: &str) -> Option<&ProgramStatusRecord> {
        self.records.get(id)
    }

    #[cfg(test)]
    pub(crate) fn len(&self) -> usize {
        self.records.len()
    }

    /// The public value (`extra.program_status`): records sorted by id.
    /// `running` false hides transient records, as at process exit. `None`
    /// when nothing is shown.
    pub(crate) fn to_json(&self, running: bool) -> Option<Value> {
        let records = self
            .records
            .iter()
            .filter(|(_, record)| running || !record.is_transient())
            .map(|(id, record)| record.to_json(id, self.app_of(id)))
            .collect::<Vec<_>>();
        (!records.is_empty()).then_some(Value::Array(records))
    }

    /// What a tab shows for these records: the strongest one that is not
    /// idle, picked as the app's `ProgramStatusRecord.strongest` does
    /// (blocked, error, working, done; the newest of equals). `running`
    /// false hides the records that end with the process.
    pub(crate) fn shown(&self, running: bool) -> Option<ShownProgramStatus> {
        self.records
            .values()
            .filter(|record| record.state != ProgramStatusState::Idle)
            .filter(|record| running || !record.is_transient())
            .max_by_key(|record| (strength(record.state), record.updated_seq))
            .map(|record| ShownProgramStatus { state: record.state, progress: record.progress })
    }

    /// The new `shown` value when it differs from the one last handed to
    /// frontends, marking it handed.
    pub(crate) fn take_shown_change(
        &mut self,
        running: bool,
    ) -> Option<Option<ShownProgramStatus>> {
        let shown = self.shown(running);
        (shown != self.shown_published).then(|| {
            self.shown_published = shown;
            shown
        })
    }

    /// True once per visible change, marking it published.
    pub(crate) fn take_change(&mut self) -> bool {
        let changed = self.revision != self.published;
        self.published = self.revision;
        changed
    }

    /// The records a terminal host hands to the daemon that attaches.
    pub(crate) fn snapshot(&self) -> ProgramStatusSnapshot {
        ProgramStatusSnapshot {
            records: self.records.iter().map(|(id, record)| (id.clone(), record.clone())).collect(),
            next_seq: self.next_seq,
        }
    }

    /// Replaces the records with the host's when a daemon adopts it. It
    /// raises no alert: a program that started waiting while no daemon was
    /// attached shows it on its tab, but posts no notification. The host's
    /// bytes are untrusted, so `apply_report`'s rules and bounds apply again,
    /// and `next_seq` never goes back.
    pub(crate) fn restore(&mut self, snapshot: ProgramStatusSnapshot) {
        let mut records = BTreeMap::new();
        for (id, record) in snapshot.records {
            if record.state == ProgramStatusState::Clear {
                continue;
            }
            let blocked = record.state == ProgramStatusState::Blocked;
            let shows_progress = blocked || record.state == ProgramStatusState::Working;
            let bounded = |text: Option<String>, limit| {
                text.and_then(|text| non_empty(shown_text(&text, limit)))
            };
            // A host this daemon seeded (a replacement) hands back the same report: keep when
            // its state began, which the snapshot codec does not carry.
            let since_ms = self
                .records
                .get(&id)
                .filter(|kept| {
                    kept.updated_seq == record.updated_seq
                        && kept.state == record.state
                        && kept.kind == record.kind
                })
                .map_or(record.since_ms, |kept| kept.since_ms);
            let record = ProgramStatusRecord {
                since_ms,
                kind: record.kind.filter(|_| blocked),
                progress: record.progress.filter(|value| shows_progress && *value <= 100),
                app: bounded(record.app, MAX_TITLE_CHARS),
                title: bounded(record.title, MAX_TITLE_CHARS),
                message: bounded(record.message, MAX_MESSAGE_CHARS),
                ..record
            };
            records.insert(id, record);
        }
        let newest = records.values().map(|record| record.updated_seq).max().unwrap_or(0);
        self.next_seq = self.next_seq.max(snapshot.next_seq).max(newest);
        self.alerts.clear();
        if records != self.records {
            self.records = records;
            self.revision += 1;
        }
        // Clients read the restored status from the tree; a later change
        // (a prompt ending a wait) must still reach them as an event.
        self.shown_published = self.shown(true);
    }
}

/// The one status a terminal's tab shows (`program_status` on a tab in the
/// tree): its strongest record's state and progress.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ShownProgramStatus {
    pub state: ProgramStatusState,
    /// 0 through 100, only while working or blocked.
    pub progress: Option<u8>,
}

impl ShownProgramStatus {
    pub fn wire(&self) -> Value {
        json!({"state": self.state.as_str(), "progress": self.progress})
    }

    /// The tree's `program_status` value of a tab, as `wire` writes it.
    pub fn from_wire(value: &Value) -> Option<Self> {
        let state = match value.get("state")?.as_str()? {
            "working" => ProgramStatusState::Working,
            "blocked" => ProgramStatusState::Blocked,
            "error" => ProgramStatusState::Error,
            "done" => ProgramStatusState::Done,
            _ => return None,
        };
        let progress = value
            .get("progress")
            .and_then(Value::as_u64)
            .and_then(|value| u8::try_from(value).ok())
            .filter(|value| *value <= 100);
        Some(Self { state, progress })
    }
}

fn strength(state: ProgramStatusState) -> u8 {
    match state {
        ProgramStatusState::Blocked => 4,
        ProgramStatusState::Error => 3,
        ProgramStatusState::Working => 2,
        ProgramStatusState::Done => 1,
        ProgramStatusState::Idle | ProgramStatusState::Clear => 0,
    }
}

/// A terminal's records as they cross the terminal-host protocol
/// (`FLAG_PROGRAM_STATUS`), so they outlive the daemon that showed them.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ProgramStatusSnapshot {
    pub(crate) records: Vec<(String, ProgramStatusRecord)>,
    pub(crate) next_seq: u64,
}

/// The records shared by a terminal's parser callback (inside `vt_write`)
/// and the publisher. The callback never takes the terminal lock, so the
/// order is always terminal lock, then this lock.
pub(crate) type SharedProgramStatus = Arc<Mutex<ProgramStatusRecords>>;

/// The parser callback that feeds `records`.
pub(crate) fn sink(records: SharedProgramStatus) -> ghostty_vt::ProgramStatusFn {
    Box::new(move |event| {
        records
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .apply(event, crate::mux::now_ms());
    })
}

fn non_empty(text: String) -> Option<String> {
    (!text.is_empty()).then_some(text)
}

/// Untrusted text as shown outside the terminal: no control characters, no
/// invisible formatting characters, at most `limit` characters.
pub(crate) fn shown_text(text: &str, limit: usize) -> String {
    text.chars()
        .filter(|character| !character.is_control() && !is_invisible_format(*character))
        .take(limit)
        .collect()
}

/// Bidi controls, zero-width characters, word joiners, invisible operators,
/// the BOM and interlinear annotation marks (Unicode Cf characters that can
/// hide or reorder shown text).
pub(crate) fn is_invisible_format(character: char) -> bool {
    matches!(
        character,
        '\u{00AD}'
            | '\u{0600}'..='\u{0605}'
            | '\u{061C}'
            | '\u{06DD}'
            | '\u{070F}'
            | '\u{0890}'..='\u{0891}'
            | '\u{08E2}'
            | '\u{180E}'
            | '\u{200B}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}'
            | '\u{110BD}'
            | '\u{110CD}'
            | '\u{13430}'..='\u{1343F}'
            | '\u{1BCA0}'..='\u{1BCA3}'
            | '\u{1D173}'..='\u{1D17A}'
            | '\u{E0001}'
            | '\u{E0020}'..='\u{E007F}'
    )
}

#[cfg(test)]
#[path = "program_status_tests.rs"]
mod tests;
