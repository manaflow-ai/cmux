//! `LaunchPageDeferral` (LaunchPageDeferral.swift): no page view before the first window frame.
//! The gate, the marks and the page shows stay in Swift; this is the state machine.

use serde::{Deserialize, Serialize};

pub const MARK_DEFERRED: &str = "pages.deferred_until_frame";
pub const MARK_CREATED: &str = "pages.created";

/// What the app tells the deferral.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum Event {
    /// `bind(_:mark:)` to a gate that is open or not.
    Bind { open: bool },
    /// The gate opened (`whenOpen` fired, or it was open).
    Open,
    /// `defers(_:show:)`.
    Defer { key: String },
}

/// What the app does for one event.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Effects {
    /// `defers`' answer (false: make the page now).
    pub deferred: bool,
    /// Register `whenOpen` on the gate.
    pub when_open: bool,
    /// Marks to write, in order.
    pub marks: Vec<String>,
    /// Keys whose `show` runs now, in order.
    pub show: Vec<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct PageDeferral {
    pub bound: bool,
    pub open: bool,
    pub waiting: Vec<String>,
    /// `whenOpen` was registered and has not fired.
    pub armed: bool,
}

impl PageDeferral {
    /// `holds`: bound to a gate that has not opened.
    pub fn holds(&self) -> bool {
        self.bound && !self.open
    }

    pub fn step(&mut self, event: &Event) -> Effects {
        let mut out = Effects::default();
        match event {
            Event::Bind { open } => {
                self.bound = true;
                self.open = *open;
            }
            Event::Open => {
                self.open = true;
                if self.armed {
                    self.armed = false;
                    out.show = std::mem::take(&mut self.waiting);
                    out.marks.push(MARK_CREATED.into());
                }
            }
            Event::Defer { key } => {
                if !self.holds() {
                    return out;
                }
                out.deferred = true;
                if self.waiting.contains(key) {
                    return out;
                }
                if self.waiting.is_empty() {
                    out.marks.push(MARK_DEFERRED.into());
                    out.when_open = true;
                    self.armed = true;
                }
                self.waiting.push(key.clone());
            }
        }
        out
    }
}
