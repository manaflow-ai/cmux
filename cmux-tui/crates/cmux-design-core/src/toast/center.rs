//! CmuxToastCenter's decisions as a pure state machine: which toasts show in which window, the
//! stack per window, dedupe and repeats, a working toast's result taking its slot, one-window
//! toasts, quiet after close, Don't Show Again, the undo key and the timers.
//!
//! The app keeps the windows, views, timers and callbacks; it sends each event here and carries
//! out the returned [`CenterEffect`]s in order. Windows are named by any stable string; time is
//! the caller's clock in milliseconds (the center owns no clock).

use super::model::{DismissReason, Toast, ToastStack, ToastTone, ToastTuning, UNTIL_CLOSED};
use super::stores::NeverShowStore;
use serde::{Deserialize, Serialize};

/// A closed notice stays quiet this long (`closedCooldown`).
pub const CLOSED_COOLDOWN_SECONDS: f64 = 120.0;

/// The same notice: id, message and detail.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuietKey {
    pub id: String,
    pub message: String,
    pub detail: Option<String>,
}

impl QuietKey {
    pub fn of(toast: &Toast) -> Self {
        Self {
            id: toast.id.clone(),
            message: toast.message.clone(),
            detail: toast.detail().map(str::to_string),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CenterEntry {
    pub serial: i64,
    pub toast: Toast,
    pub window: String,
    #[serde(default)]
    pub shows_details: bool,
    #[serde(default)]
    pub timer_scheduled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Quieted {
    pub key: QuietKey,
    pub until_ms: f64,
}

/// One toast as the host draws it (CmuxToastShown).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToastShown {
    pub serial: i64,
    pub toast: Toast,
    pub shows_details: bool,
    pub shows_undo_key: bool,
}

/// What the app does, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "effect")]
pub enum CenterEffect {
    /// The handle finishes: call its onDismiss with the reason.
    #[serde(rename_all = "camelCase")]
    Finished { serial: i64, reason: DismissReason },
    /// The host draws the window's toasts.
    #[serde(rename_all = "camelCase")]
    Render { window: String, shown: Vec<ToastShown> },
    /// VoiceOver announces the message (high priority).
    #[serde(rename_all = "camelCase")]
    Announce { window: String, message: String },
    /// Start the toast's timer; when it fires, send [`CenterEvent::Timeout`].
    #[serde(rename_all = "camelCase")]
    Schedule { serial: i64, seconds: f64 },
    /// Cancel the toast's timer.
    #[serde(rename_all = "camelCase")]
    Cancel { serial: i64 },
    /// Run the handle's onAction.
    #[serde(rename_all = "camelCase")]
    RunAction { serial: i64 },
    /// Run the handle's onSecondaryAction.
    #[serde(rename_all = "camelCase")]
    RunSecondaryAction { serial: i64 },
    /// Write the never-show kinds (none removes the key).
    #[serde(rename_all = "camelCase")]
    PersistNeverShow { kinds: Option<Vec<String>> },
    /// The answer to a query event (close/run by id, undo key).
    #[serde(rename_all = "camelCase")]
    Answer { value: bool },
}

/// What happened.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "event")]
pub enum CenterEvent {
    #[serde(rename_all = "camelCase")]
    Show {
        toast: Toast,
        window: String,
        #[serde(default)]
        now_ms: f64,
    },
    #[serde(rename_all = "camelCase")]
    Timeout { serial: i64 },
    #[serde(rename_all = "camelCase")]
    PersonClosed {
        serial: i64,
        #[serde(default)]
        now_ms: f64,
    },
    /// `close(id:in:)`: the newest toast with the id, as if the person closed it.
    #[serde(rename_all = "camelCase")]
    CloseInWindow {
        id: String,
        window: String,
        #[serde(default)]
        now_ms: f64,
    },
    /// `close(id:)`: every window.
    #[serde(rename_all = "camelCase")]
    Close { id: String },
    #[serde(rename_all = "camelCase")]
    PersonRanAction { serial: i64 },
    #[serde(rename_all = "camelCase")]
    RunActionById { id: String, window: String },
    #[serde(rename_all = "camelCase")]
    PersonRanSecondaryAction { serial: i64 },
    #[serde(rename_all = "camelCase")]
    RunSecondaryActionById { id: String, window: String },
    /// `runUndo(in:)`.
    #[serde(rename_all = "camelCase")]
    RunUndo { window: String },
    /// `takesUndoKey(in:)`: the responder's undo state comes from the app.
    #[serde(rename_all = "camelCase")]
    TakesUndoKey { window: String, responder_can_undo: bool, owns_undo_top: bool },
    /// `handle.dismiss()`.
    #[serde(rename_all = "camelCase")]
    Dismiss { serial: i64 },
    #[serde(rename_all = "camelCase")]
    PersonChoseNeverShow { serial: i64 },
    #[serde(rename_all = "camelCase")]
    Hover { serial: i64, hovered: bool },
    #[serde(rename_all = "camelCase")]
    WindowClosed { window: String },
    /// Redraw every window (the style changed).
    RedrawAll,
    /// Settings changed.
    #[serde(rename_all = "camelCase")]
    SetTuning { tuning: ToastTuning },
}

/// The center's whole state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ToastCenter {
    pub next_serial: i64,
    /// Ordered by serial.
    pub entries: Vec<CenterEntry>,
    pub stacks: Vec<(String, ToastStack)>,
    /// Windows the host last drew toasts in (`windows`).
    pub known_windows: Vec<String>,
    pub quieted: Vec<Quieted>,
    pub closed_cooldown: f64,
    pub closed_working: Vec<String>,
    pub never_show: NeverShowStore,
    pub tuning: ToastTuning,
}

impl Default for ToastCenter {
    fn default() -> Self {
        Self {
            next_serial: 1,
            entries: Vec::new(),
            stacks: Vec::new(),
            known_windows: Vec::new(),
            quieted: Vec::new(),
            closed_cooldown: CLOSED_COOLDOWN_SECONDS,
            closed_working: Vec::new(),
            never_show: NeverShowStore::default(),
            tuning: ToastTuning::default(),
        }
    }
}

impl ToastCenter {
    pub fn handle(&mut self, event: CenterEvent) -> Vec<CenterEffect> {
        let mut out = Vec::new();
        match event {
            CenterEvent::Show { toast, window, now_ms } => {
                self.show(toast, &window, now_ms, &mut out);
            }
            CenterEvent::Timeout { serial } => {
                if let Some(entry) = self.entry_mut(serial) {
                    entry.timer_scheduled = false;
                }
                self.end(serial, DismissReason::Timeout, true, &mut out);
            }
            CenterEvent::PersonClosed { serial, now_ms } => {
                if self.entry(serial).is_some() {
                    self.closed_by_person(serial, now_ms, &mut out);
                }
            }
            CenterEvent::CloseInWindow { id, window, now_ms } => {
                let found = self.newest_with_id(&id, &window);
                if let Some(serial) = found {
                    self.closed_by_person(serial, now_ms, &mut out);
                }
                out.push(CenterEffect::Answer { value: found.is_some() });
            }
            CenterEvent::Close { id } => {
                self.closed_working.retain(|w| *w != id);
                for serial in self.serials_where(|e| e.toast.id == id) {
                    self.end(serial, DismissReason::Closed, true, &mut out);
                }
            }
            CenterEvent::PersonRanAction { serial } => self.person_ran_action(serial, &mut out),
            CenterEvent::RunActionById { id, window } => {
                let serial = self.newest_with_id(&id, &window);
                let ok =
                    serial.is_some_and(|s| self.entry(s).is_some_and(|e| e.toast.action.is_some()));
                if ok {
                    self.person_ran_action(serial.unwrap_or_default(), &mut out);
                }
                out.push(CenterEffect::Answer { value: ok });
            }
            CenterEvent::PersonRanSecondaryAction { serial } => {
                self.run_secondary(serial, &mut out);
            }
            CenterEvent::RunSecondaryActionById { id, window } => {
                let serial = self.newest_with_id(&id, &window);
                let ok = serial.is_some_and(|s| {
                    self.entry(s).is_some_and(|e| e.toast.secondary_action.is_some())
                });
                if ok {
                    self.run_secondary(serial.unwrap_or_default(), &mut out);
                }
                out.push(CenterEffect::Answer { value: ok });
            }
            CenterEvent::RunUndo { window } => {
                let serial = self
                    .stack(&window)
                    .and_then(ToastStack::newest_undo)
                    .filter(|s| self.entry(*s).is_some());
                if let Some(serial) = serial {
                    self.run_action(serial, &mut out);
                }
                out.push(CenterEffect::Answer { value: serial.is_some() });
            }
            CenterEvent::TakesUndoKey { window, responder_can_undo, owns_undo_top } => {
                let takes = self.stack(&window).and_then(ToastStack::newest_undo).is_some()
                    && (!responder_can_undo || owns_undo_top);
                out.push(CenterEffect::Answer { value: takes });
            }
            CenterEvent::Dismiss { serial } => {
                self.end(serial, DismissReason::Closed, true, &mut out);
            }
            CenterEvent::PersonChoseNeverShow { serial } => {
                let Some(toast) = self.entry(serial).map(|e| e.toast.clone()) else { return out };
                if !toast.offers_never_show() {
                    return out;
                }
                if self.never_show.hide(toast.kind()) {
                    out.push(CenterEffect::PersistNeverShow { kinds: self.never_show.persisted() });
                }
                for other in self.serials_where(|e| {
                    e.toast.kind() == toast.kind() && e.toast.offers_never_show()
                }) {
                    self.end(other, DismissReason::Closed, true, &mut out);
                }
            }
            CenterEvent::Hover { serial, hovered } => self.set_hovered(serial, hovered, &mut out),
            CenterEvent::WindowClosed { window } => {
                let serials = self.stack(&window).map(|s| s.serials.clone()).unwrap_or_default();
                for serial in serials {
                    self.end(serial, DismissReason::Closed, false, &mut out);
                }
                self.stacks.retain(|(w, _)| *w != window);
                self.known_windows.retain(|w| *w != window);
            }
            CenterEvent::RedrawAll => {
                let windows: Vec<String> = self.stacks.iter().map(|(w, _)| w.clone()).collect();
                for window in windows {
                    self.render(&window, &mut out);
                }
            }
            CenterEvent::SetTuning { tuning } => self.tuning = tuning,
        }
        out
    }

    /// The window's toasts, oldest first.
    pub fn toasts(&self, window: &str) -> Vec<Toast> {
        self.stack(window)
            .map(|s| {
                s.serials.iter().filter_map(|x| self.entry(*x).map(|e| e.toast.clone())).collect()
            })
            .unwrap_or_default()
    }

    /// The person closed this notice a moment ago, or its working run: it stays quiet. A toast with
    /// an action always shows.
    pub fn is_quieted(&self, toast: &Toast, now_ms: f64) -> bool {
        let key = QuietKey::of(toast);
        toast.action.is_none()
            && (self.quieted.iter().any(|q| q.key == key && q.until_ms > now_ms)
                || toast.working && self.closed_working.contains(&toast.id))
    }

    pub fn shows_details(&self, serial: i64) -> bool {
        self.entry(serial).is_some_and(|e| e.shows_details)
    }

    fn show(
        &mut self,
        toast: Toast,
        window: &str,
        now_ms: f64,
        out: &mut Vec<CenterEffect>,
    ) -> i64 {
        let toast = toast.normalized();
        let serial = self.next_serial;
        self.next_serial += 1;
        self.quieted.retain(|q| q.until_ms > now_ms);
        if !toast.working {
            self.closed_working.retain(|w| *w != toast.id);
        }
        if toast.one_window {
            let quiet = self.is_quieted(&toast, now_ms);
            for other in
                self.serials_where(|e| e.toast.id == toast.id && (quiet || e.window != window))
            {
                self.end(other, DismissReason::Replaced, true, out);
            }
        }
        if self.is_quieted(&toast, now_ms)
            || (toast.offers_never_show() && self.never_show.is_hidden(toast.kind()))
        {
            out.push(CenterEffect::Finished { serial, reason: DismissReason::Closed });
            return serial;
        }
        let mut stack = self.stack(window).cloned().unwrap_or_default();
        let repeats =
            stack.serials.last().and_then(|s| self.entry(*s)).is_some_and(|e| e.toast == toast);
        let resolves = stack.serials.iter().any(|s| {
            self.entry(*s)
                .is_some_and(|e| e.toast.id == toast.id && e.toast.tone() == ToastTone::Working)
        });
        let replaced = stack.push(serial, &toast.id, toast.is_undo(), resolves);
        self.set_stack(window, stack);
        let message = toast.message.clone();
        self.entries.push(CenterEntry {
            serial,
            toast,
            window: window.into(),
            shows_details: false,
            timer_scheduled: false,
        });
        for old in replaced {
            self.end(old, DismissReason::Replaced, false, out);
        }
        self.start_timer(serial, out);
        self.render(window, out);
        if !repeats {
            out.push(CenterEffect::Announce { window: window.into(), message });
        }
        serial
    }

    fn closed_by_person(&mut self, serial: i64, now_ms: f64, out: &mut Vec<CenterEffect>) {
        if let Some(toast) = self.entry(serial).map(|e| e.toast.clone()) {
            if toast.action.is_none() && toast.working {
                if !self.closed_working.contains(&toast.id) {
                    self.closed_working.push(toast.id);
                }
            } else if toast.action.is_none() && self.closed_cooldown > 0.0 {
                let key = QuietKey::of(&toast);
                self.quieted.retain(|q| q.key != key);
                self.quieted
                    .push(Quieted { key, until_ms: now_ms + self.closed_cooldown * 1000.0 });
            }
        }
        self.end(serial, DismissReason::Closed, true, out);
    }

    fn person_ran_action(&mut self, serial: i64, out: &mut Vec<CenterEffect>) {
        let Some(action) = self.entry(serial).and_then(|e| e.toast.action.clone()) else { return };
        if action.reveals_details {
            self.toggle_details(serial, out);
        } else {
            self.run_action(serial, out);
        }
    }

    /// `handle.runAction()`: not for Details.
    fn run_action(&mut self, serial: i64, out: &mut Vec<CenterEffect>) {
        let Some(entry) = self.entry(serial) else { return };
        match &entry.toast.action {
            Some(a) if !a.reveals_details => {}
            _ => return,
        }
        out.push(CenterEffect::RunAction { serial });
        self.end(serial, DismissReason::Action, true, out);
    }

    fn run_secondary(&mut self, serial: i64, out: &mut Vec<CenterEffect>) {
        if self.entry(serial).is_none_or(|e| e.toast.secondary_action.is_none()) {
            return;
        }
        out.push(CenterEffect::RunSecondaryAction { serial });
        self.end(serial, DismissReason::Action, true, out);
    }

    fn toggle_details(&mut self, serial: i64, out: &mut Vec<CenterEffect>) {
        let Some(entry) = self.entry_mut(serial) else { return };
        entry.shows_details = !entry.shows_details;
        let window = entry.window.clone();
        self.render(&window, out);
    }

    fn set_hovered(&mut self, serial: i64, hovered: bool, out: &mut Vec<CenterEffect>) {
        let Some(entry) = self.entry_mut(serial) else { return };
        if hovered {
            entry.timer_scheduled = false;
            out.push(CenterEffect::Cancel { serial });
        } else if !entry.timer_scheduled {
            self.start_timer(serial, out);
        }
    }

    fn start_timer(&mut self, serial: i64, out: &mut Vec<CenterEffect>) {
        let tuning = self.tuning.clone();
        let Some(entry) = self.entry_mut(serial) else { return };
        if entry.toast.duration() == UNTIL_CLOSED {
            return;
        }
        entry.timer_scheduled = true;
        out.push(CenterEffect::Schedule { serial, seconds: tuning.shown_duration(&entry.toast) });
    }

    fn end(
        &mut self,
        serial: i64,
        reason: DismissReason,
        render: bool,
        out: &mut Vec<CenterEffect>,
    ) {
        let Some(index) = self.entries.iter().position(|e| e.serial == serial) else { return };
        let entry = self.entries.remove(index);
        if entry.timer_scheduled {
            out.push(CenterEffect::Cancel { serial });
        }
        if let Some((_, stack)) = self.stacks.iter_mut().find(|(w, _)| *w == entry.window) {
            stack.remove(serial);
        }
        if render {
            self.render(&entry.window, out);
        }
        out.push(CenterEffect::Finished { serial, reason });
    }

    fn render(&mut self, window: &str, out: &mut Vec<CenterEffect>) {
        let (serials, newest_undo) = match self.stack(window) {
            Some(s) => (s.serials.clone(), s.newest_undo()),
            None => (Vec::new(), None),
        };
        let has_window = serials.iter().any(|s| self.entry(*s).is_some())
            || self.known_windows.iter().any(|w| w == window);
        if !has_window {
            return;
        }
        self.known_windows.retain(|w| w != window);
        if !serials.is_empty() {
            self.known_windows.push(window.into());
        }
        let shown = serials
            .iter()
            .filter_map(|serial| {
                self.entry(*serial).map(|e| ToastShown {
                    serial: *serial,
                    toast: e.toast.clone(),
                    shows_details: e.shows_details,
                    shows_undo_key: Some(*serial) == newest_undo,
                })
            })
            .collect();
        out.push(CenterEffect::Render { window: window.into(), shown });
    }

    fn entry(&self, serial: i64) -> Option<&CenterEntry> {
        self.entries.iter().find(|e| e.serial == serial)
    }

    fn entry_mut(&mut self, serial: i64) -> Option<&mut CenterEntry> {
        self.entries.iter_mut().find(|e| e.serial == serial)
    }

    fn stack(&self, window: &str) -> Option<&ToastStack> {
        self.stacks.iter().find(|(w, _)| w == window).map(|(_, s)| s)
    }

    fn set_stack(&mut self, window: &str, stack: ToastStack) {
        match self.stacks.iter_mut().find(|(w, _)| w == window) {
            Some((_, s)) => *s = stack,
            None => self.stacks.push((window.into(), stack)),
        }
    }

    fn serials_where(&self, keep: impl Fn(&CenterEntry) -> bool) -> Vec<i64> {
        self.entries.iter().filter(|e| keep(e)).map(|e| e.serial).collect()
    }

    fn newest_with_id(&self, id: &str, window: &str) -> Option<i64> {
        let stack = self.stack(window)?;
        stack
            .serials
            .iter()
            .rev()
            .copied()
            .find(|s| self.entry(*s).is_some_and(|e| e.toast.id == id))
    }
}
