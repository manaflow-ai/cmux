//! Which session gets an event of a shared headless browser (item 4c,
//! driver-protocol.md "Sessions and tabs"): a dialog, a file chooser or a
//! download goes to ONE session: the session with a handler for it in its
//! last `tab.handleEvents` for the tab (the creating session's first, then
//! the first that registered), else the session that created the tab, else
//! (dialog, chooser) the session whose call the page is handling. None of
//! them: D2 (ff, 2026-10-06), the host answers it (dialog dismissed, download
//! cancelled) and logs it. Every other event goes to every session.
//!
//! The log (ff, 2026-10-06): each unrouted entry goes to the policy log of
//! the session that opened the tab (also after it kept it; popups count as
//! its tabs) while that session is attached, and to the host's own log of
//! the newest [`LOG_KEPT`] entries, which only the person reads
//! (`tab.info unroutedEvents`).
//!
//! Bounded: per-tab entries go with `tab.closed`, a session's with its end,
//! a dialog's with its answer, a download's with `download.finished`.

use crate::protocol::DriverEvent;
use serde_json::{Value, json};
use std::collections::{HashMap, VecDeque};

/// Unrouted events kept in the log (newest last).
const LOG_KEPT: usize = 64;

#[derive(Debug, PartialEq)]
pub enum Route {
    Everyone,
    Session(u64),
    /// No session takes it; the host answers it (`kind`).
    Unrouted(&'static str),
}

/// What an ended session left open, as (tab, id).
#[derive(Debug, Default)]
pub struct LeftOpen {
    pub dialogs: Vec<(String, String)>,
    pub choosers: Vec<(String, String)>,
}

#[derive(Debug, Default)]
pub struct Routes {
    /// Tab -> sessions with handlers, in registration order.
    handlers: HashMap<String, Vec<(u64, Vec<String>)>>,
    creator: HashMap<String, u64>,
    /// Tab -> the session that opened it (or its opener), kept or not: the
    /// session whose policy log gets the tab's unrouted events.
    opened_by: HashMap<String, u64>,
    /// Tab -> the session whose call the page is handling now.
    in_call: HashMap<String, u64>,
    /// Dialog id -> the session it went to.
    dialogs: HashMap<String, (u64, String)>,
    /// Download id -> the session it went to.
    downloads: HashMap<String, u64>,
    /// File chooser id -> (the session it went to, its tab).
    choosers: HashMap<String, (u64, String)>,
    log: VecDeque<Value>,
}

fn kind(name: &str) -> Option<&'static str> {
    match name {
        "dialog.opened" => Some("dialog"),
        "filechooser.opened" => Some("filechooser"),
        "download.started" => Some("download"),
        _ => None,
    }
}

impl Routes {
    pub fn handle_events(&mut self, session: u64, target: &str, events: Vec<String>) {
        let list = self.handlers.entry(target.to_owned()).or_default();
        list.retain(|(s, _)| *s != session);
        if !events.is_empty() {
            list.push((session, events));
        }
    }

    pub fn created(&mut self, session: u64, target: &str) {
        self.creator.insert(target.to_owned(), session);
        self.opened_by.insert(target.to_owned(), session);
    }

    /// The open tabs the session created and did not keep (popups too):
    /// the tabs its `session.configure` options apply to.
    pub fn tabs_of(&self, session: u64) -> Vec<String> {
        self.creator.iter().filter(|(_, s)| **s == session).map(|(t, _)| t.clone()).collect()
    }

    /// Whether `session` created `target` and did not keep it.
    pub fn is_creator(&self, session: u64, target: &str) -> bool {
        self.creator.get(target) == Some(&session)
    }

    /// The session whose policy log gets the tab's unrouted events.
    pub fn log_session(&self, target: &str) -> Option<u64> {
        self.opened_by.get(target).copied()
    }

    /// A kept tab is the person's: it has no creating session any more.
    pub fn kept(&mut self, session: u64, target: &str) {
        if self.creator.get(target) == Some(&session) {
            self.creator.remove(target);
        }
    }

    pub fn call_started(&mut self, session: u64, target: &str) {
        self.in_call.insert(target.to_owned(), session);
    }

    pub fn call_ended(&mut self, session: u64, target: &str) {
        if self.in_call.get(target) == Some(&session) {
            self.in_call.remove(target);
        }
    }

    /// The session a dialog went to, if it went to one.
    pub fn dialog_owner(&self, dialog: &str) -> Option<u64> {
        self.dialogs.get(dialog).map(|(session, _)| *session)
    }

    pub fn dialog_answered(&mut self, dialog: &str) {
        self.dialogs.remove(dialog);
    }

    /// The session a file chooser went to, if it went to one.
    pub fn chooser_owner(&self, chooser: &str) -> Option<u64> {
        self.choosers.get(chooser).map(|(session, _)| *session)
    }

    pub fn chooser_answered(&mut self, chooser: &str) {
        self.choosers.remove(chooser);
    }

    /// Forgets the session; returns what it left open, which the host
    /// answers (dialogs dismissed, choosers cancelled).
    pub fn session_ended(&mut self, session: u64) -> LeftOpen {
        for list in self.handlers.values_mut() {
            list.retain(|(s, _)| *s != session);
        }
        self.handlers.retain(|_, list| !list.is_empty());
        self.creator.retain(|_, s| *s != session);
        self.opened_by.retain(|_, s| *s != session);
        self.in_call.retain(|_, s| *s != session);
        let mut dialogs = Vec::new();
        self.dialogs.retain(|dialog, (s, target)| {
            if *s == session {
                dialogs.push((target.clone(), dialog.clone()));
            }
            *s != session
        });
        self.downloads.retain(|_, s| *s != session);
        let mut open = Vec::new();
        self.choosers.retain(|chooser, (s, target)| {
            if *s == session {
                open.push((target.clone(), chooser.clone()));
            }
            *s != session
        });
        LeftOpen { dialogs, choosers: open }
    }

    pub fn log_unrouted(&mut self, entry: Value) {
        self.log.push_back(entry);
        while self.log.len() > LOG_KEPT {
            self.log.pop_front();
        }
    }

    pub fn unrouted_log(&self) -> Vec<Value> {
        self.log.iter().cloned().collect()
    }

    /// The host log's entries for one tab.
    pub fn unrouted_for(&self, target: &str) -> Vec<Value> {
        self.log.iter().filter(|entry| entry["targetId"] == target).cloned().collect()
    }

    /// Where `event` goes; `attached` says whether a session is still there.
    pub fn route(&mut self, event: &DriverEvent, attached: &dyn Fn(u64) -> bool) -> Route {
        let payload = &event.payload;
        let target = payload.get("targetId").and_then(Value::as_str).unwrap_or("");
        match event.name.as_str() {
            "tab.closed" => {
                self.handlers.remove(target);
                self.creator.remove(target);
                self.opened_by.remove(target);
                self.in_call.remove(target);
                self.choosers.retain(|_, (_, tab)| tab != target);
                self.dialogs.retain(|_, (_, tab)| tab != target);
                return Route::Everyone;
            }
            // A popup of a session's tab is that session's too.
            "tab.created" => {
                if let Some(opener) = payload.get("openerTargetId").and_then(Value::as_str)
                    && let Some(session) = self.creator.get(opener).copied()
                {
                    self.creator.insert(target.to_owned(), session);
                }
                if let Some(opener) = payload.get("openerTargetId").and_then(Value::as_str)
                    && let Some(session) = self.opened_by.get(opener).copied()
                {
                    self.opened_by.insert(target.to_owned(), session);
                }
                return Route::Everyone;
            }
            "download.finished" => {
                let id = payload.get("downloadId").and_then(Value::as_str).unwrap_or("");
                return match self.downloads.remove(id) {
                    Some(session) if attached(session) => Route::Session(session),
                    _ => Route::Unrouted("download"),
                };
            }
            _ => {}
        }
        let Some(kind) = kind(&event.name) else {
            return Route::Everyone;
        };
        let creator = self.creator.get(target).copied().filter(|s| attached(*s));
        let handlers: Vec<u64> = self
            .handlers
            .get(target)
            .into_iter()
            .flatten()
            .filter(|(s, events)| attached(*s) && events.iter().any(|e| e == kind))
            .map(|(s, _)| *s)
            .collect();
        let owner = creator
            .filter(|c| handlers.contains(c))
            .or_else(|| handlers.first().copied())
            .or(creator)
            .or_else(|| {
                (kind != "download")
                    .then(|| self.in_call.get(target).copied().filter(|s| attached(*s)))
                    .flatten()
            });
        let Some(owner) = owner else {
            return Route::Unrouted(kind);
        };
        if kind == "dialog"
            && let Some(id) = payload.get("dialogId").and_then(Value::as_str)
        {
            self.dialogs.insert(id.to_owned(), (owner, target.to_owned()));
        }
        if kind == "download"
            && let Some(id) = payload.get("downloadId").and_then(Value::as_str)
        {
            self.downloads.insert(id.to_owned(), owner);
        }
        if kind == "filechooser"
            && let Some(id) = payload.get("chooserId").and_then(Value::as_str)
        {
            // One open chooser per tab (the driver replaces an older one).
            self.choosers.retain(|_, (_, tab)| tab != target);
            self.choosers.insert(id.to_owned(), (owner, target.to_owned()));
        }
        Route::Session(owner)
    }
}

/// A log entry for an event no session took, in the policy log's shape
/// (`{url, reason, at, blocked}`, `blocked: "unrouted"`); `url` is the
/// tab's. The page's own text (a dialog message) stays out.
pub fn unrouted_entry(event: &DriverEvent, action: &str, url: &str) -> Value {
    json!({
        "url": url,
        "reason": format!("{}: no session takes it; the host {action} it", event.name),
        "blocked": "unrouted",
        "event": event.name,
        "targetId": event.payload.get("targetId").cloned().unwrap_or(Value::Null),
        "action": action,
        "at": std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dialog(target: &str, id: &str) -> DriverEvent {
        DriverEvent {
            name: "dialog.opened".into(),
            payload: json!({"targetId": target, "dialogId": id}),
        }
    }

    #[test]
    fn a_handler_wins_then_the_creator_then_the_caller() {
        let all = |_| true;
        let mut routes = Routes::default();
        routes.created(1, "T");
        routes.handle_events(2, "T", vec!["dialog".into()]);
        assert_eq!(routes.route(&dialog("T", "d1"), &all), Route::Session(2));
        assert_eq!(routes.dialog_owner("d1"), Some(2));
        routes.handle_events(1, "T", vec!["dialog".into()]);
        assert_eq!(routes.route(&dialog("T", "d2"), &all), Route::Session(1), "creator first");
        routes.handle_events(1, "T", vec![]);
        routes.handle_events(2, "T", vec![]);
        assert_eq!(routes.route(&dialog("T", "d3"), &all), Route::Session(1), "the creator");
        routes.kept(1, "T");
        assert_eq!(routes.route(&dialog("T", "d4"), &all), Route::Unrouted("dialog"));
        assert_eq!(routes.log_session("T"), Some(1), "a kept tab still logs to its opener");
        routes.call_started(3, "T");
        assert_eq!(routes.route(&dialog("T", "d5"), &all), Route::Session(3), "the caller");
        routes.call_ended(3, "T");
        assert_eq!(routes.route(&dialog("T", "d6"), &|s| s != 3), Route::Unrouted("dialog"));
    }

    #[test]
    fn entries_go_with_their_tab_session_and_log_bound() {
        let all = |_| true;
        let mut routes = Routes::default();
        routes.created(1, "T");
        routes.handle_events(2, "T", vec!["dialog".into()]);
        routes.route(&dialog("T", "d1"), &all);
        routes.session_ended(2);
        assert!(routes.dialogs.is_empty() && routes.handlers.is_empty());
        routes.route(
            &DriverEvent { name: "tab.closed".into(), payload: json!({"targetId": "T"}) },
            &all,
        );
        assert!(routes.creator.is_empty() && routes.opened_by.is_empty());
        for i in 0..LOG_KEPT + 5 {
            routes.log_unrouted(json!(i));
        }
        assert_eq!(routes.unrouted_log().len(), LOG_KEPT);
    }
}
