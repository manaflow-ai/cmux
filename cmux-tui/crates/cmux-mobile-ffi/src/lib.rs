//! uniffi bindings of `cmux-mobile-core` for the iOS and Android apps.
//!
//! One library per platform (MOBILE-RUST-2): a static library in an
//! xcframework for iOS and a shared library per ABI in an AAR for Android.
//! Swift and Kotlin get every type from the generated bindings; they hold UI
//! and platform APIs only (MOBILE-RUST-1).
//!
//! The wire types are the core's own types, declared to uniffi as remote
//! types. A field or variant that drifts from the core fails to compile here.
//!
//! Slice 0 (plans/cmux-next/mobile-rust-core.md) binds the shared terminal
//! sizing reducer to prove the pipeline: records, enums, an object, a
//! foreign-implemented callback and an error all cross the boundary, and the
//! shared fixtures run in Rust, Swift and Kotlin.

use std::fmt;
use std::sync::{Arc, Mutex, PoisonError};

use cmux_mobile_core::sizing::{
    self, TerminalDeviceKind, TerminalGridSize, TerminalSizingMode, TerminalSizingParticipant,
    TerminalSizingParticipantState, TerminalSizingPolicy, TerminalSizingReason,
    TerminalSizingState,
};

uniffi::setup_scaffolding!();

/// A terminal grid in cells.
#[uniffi::remote(Record)]
pub struct TerminalGridSize {
    pub cols: u16,
    pub rows: u16,
}

/// The kind of device behind one attached view. Unknown wire values decode as
/// `Unknown`.
#[uniffi::remote(Enum)]
pub enum TerminalDeviceKind {
    Mac,
    Iphone,
    Ipad,
    Tui,
    Browser,
    Linux,
    Windows,
    Unknown,
}

/// One attached view of a terminal, as the host sees it.
#[uniffi::remote(Record)]
pub struct TerminalSizingParticipant {
    pub id: String,
    pub user_id: Option<String>,
    pub display_name: Option<String>,
    pub device_kind: TerminalDeviceKind,
    pub device_name: Option<String>,
    pub device_id: Option<String>,
    pub via: Option<String>,
    pub viewport: Option<TerminalGridSize>,
    pub counts_override: Option<bool>,
}

/// How the host picks the grid. `Smallest` ("fit everyone") is the default.
#[uniffi::remote(Enum)]
pub enum TerminalSizingMode {
    Latest,
    Smallest,
    Largest,
    Priority,
    Fixed,
}

/// A sizing policy. Build it with `terminal_sizing_policy`, which clamps the
/// fixed grid the way every host does.
#[uniffi::remote(Record)]
pub struct TerminalSizingPolicy {
    pub mode: TerminalSizingMode,
    pub priority: Vec<String>,
    pub fixed: Option<TerminalGridSize>,
}

/// Why the grid has its current size.
#[uniffi::remote(Enum)]
pub enum TerminalSizingReason {
    Latest,
    Smallest,
    Largest,
    Priority,
    Fixed,
    Held,
    PriorityFallback,
}

/// One participant row of a published state.
#[uniffi::remote(Record)]
pub struct TerminalSizingParticipantState {
    pub participant: TerminalSizingParticipant,
    pub counts: bool,
    pub priority_key: String,
}

/// The state a host publishes to every viewer.
#[uniffi::remote(Record)]
pub struct TerminalSizingState {
    pub generation: u64,
    pub cols: u16,
    pub rows: u16,
    pub reason: TerminalSizingReason,
    pub owners: Vec<String>,
    pub policy: TerminalSizingPolicy,
    pub participants: Vec<TerminalSizingParticipantState>,
}

/// A wire value the shared sizing contract does not accept.
#[derive(Debug, PartialEq, Eq, uniffi::Error)]
pub enum TerminalSizingWireError {
    // Not `message`: Kotlin errors extend Throwable, which owns `message`.
    Invalid { detail: String },
}

impl fmt::Display for TerminalSizingWireError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Invalid { detail } => write!(f, "invalid terminal sizing JSON: {detail}"),
        }
    }
}

impl std::error::Error for TerminalSizingWireError {}

impl From<serde_json::Error> for TerminalSizingWireError {
    fn from(error: serde_json::Error) -> Self {
        Self::Invalid { detail: error.to_string() }
    }
}

/// Receives every published state of one engine. Swift and Kotlin implement
/// it. Deliveries happen on the mutating thread after the engine lock is
/// released; when several threads mutate one engine, keep the state with the
/// highest `generation`.
#[uniffi::export(with_foreign)]
pub trait TerminalSizingListener: Send + Sync {
    fn on_state(&self, state: TerminalSizingState);
}

struct EngineInner {
    engine: sizing::TerminalSizingEngine,
    listener: Option<Arc<dyn TerminalSizingListener>>,
}

/// Decides the PTY grid of one shared terminal. Each mutation returns true
/// when the published state changed, and then notifies the listener.
#[derive(uniffi::Object)]
pub struct TerminalSizingEngine {
    inner: Mutex<EngineInner>,
}

impl TerminalSizingEngine {
    fn mutate(&self, change: impl FnOnce(&mut sizing::TerminalSizingEngine) -> bool) -> bool {
        let (changed, delivery) = {
            let mut inner = self.inner.lock().unwrap_or_else(PoisonError::into_inner);
            let changed = change(&mut inner.engine);
            let delivery = match (&inner.listener, changed) {
                (Some(listener), true) => Some((listener.clone(), inner.engine.state().clone())),
                _ => None,
            };
            (changed, delivery)
        };
        if let Some((listener, state)) = delivery {
            listener.on_state(state);
        }
        changed
    }

    fn read<T>(&self, query: impl FnOnce(&sizing::TerminalSizingEngine) -> T) -> T {
        query(&self.inner.lock().unwrap_or_else(PoisonError::into_inner).engine)
    }
}

#[uniffi::export]
impl TerminalSizingEngine {
    /// `initial` is the grid before anyone reports, usually the PTY's size.
    #[uniffi::constructor]
    pub fn new(initial: TerminalGridSize, policy: TerminalSizingPolicy) -> Arc<Self> {
        Arc::new(Self {
            inner: Mutex::new(EngineInner {
                engine: sizing::TerminalSizingEngine::new(initial, policy),
                listener: None,
            }),
        })
    }

    pub fn state(&self) -> TerminalSizingState {
        self.read(|engine| engine.state().clone())
    }

    /// Whether the view counts toward the size right now.
    pub fn counts(&self, id: String) -> bool {
        self.read(|engine| engine.counts(&id))
    }

    /// Replaces the listener; `None` removes it.
    pub fn set_listener(&self, listener: Option<Arc<dyn TerminalSizingListener>>) {
        self.inner.lock().unwrap_or_else(PoisonError::into_inner).listener = listener;
    }

    /// Adds a view, or replaces one with the same id. Counts as activity.
    pub fn attach(&self, participant: TerminalSizingParticipant) -> bool {
        self.mutate(|engine| engine.attach(participant))
    }

    pub fn detach(&self, id: String) -> bool {
        self.mutate(|engine| engine.detach(&id))
    }

    pub fn report(&self, id: String, viewport: TerminalGridSize) -> bool {
        self.mutate(|engine| engine.report(&id, viewport))
    }

    /// Explicit focus-click or keyboard, paste or mouse input. Never hover.
    pub fn note_activity(&self, id: String) -> bool {
        self.mutate(|engine| engine.note_activity(&id))
    }

    pub fn set_counts_override(&self, id: String, value: Option<bool>) -> bool {
        self.mutate(|engine| engine.set_counts_override(&id, value))
    }

    pub fn set_policy(&self, policy: TerminalSizingPolicy) -> bool {
        self.mutate(|engine| engine.set_policy(policy))
    }

    /// Forgets the viewport of a view that hid the terminal; it stops
    /// counting until its next report.
    pub fn clear_viewport(&self, id: String) -> bool {
        self.mutate(|engine| engine.clear_viewport(&id))
    }

    /// Replaces identity fields, keeping activity, viewport and override.
    pub fn update_identity(&self, identity: TerminalSizingParticipant) -> bool {
        self.mutate(|engine| engine.update_identity(&identity))
    }
}

/// A policy with the fixed grid clamped to the smallest size a host applies.
#[uniffi::export]
pub fn terminal_sizing_policy(
    mode: TerminalSizingMode,
    priority: Vec<String>,
    fixed: Option<TerminalGridSize>,
) -> TerminalSizingPolicy {
    TerminalSizingPolicy::new(mode, priority, fixed)
}

/// Decodes a device kind wire value; unknown values give `Unknown`.
#[uniffi::export]
pub fn terminal_device_kind_from_wire(raw: String) -> TerminalDeviceKind {
    TerminalDeviceKind::parse(&raw)
}

#[uniffi::export]
pub fn terminal_device_kind_wire(kind: TerminalDeviceKind) -> String {
    kind.as_str().to_owned()
}

/// The wire value of a reason, for example `priority-fallback`.
#[uniffi::export]
pub fn terminal_sizing_reason_wire(reason: TerminalSizingReason) -> String {
    match serde_json::to_value(reason) {
        Ok(serde_json::Value::String(value)) => value,
        _ => String::new(),
    }
}

/// Decodes a policy from its wire JSON (missing fields take the defaults).
#[uniffi::export]
pub fn terminal_sizing_policy_from_json(
    json: String,
) -> Result<TerminalSizingPolicy, TerminalSizingWireError> {
    Ok(serde_json::from_str(&json)?)
}

/// Decodes a published state from its wire JSON.
#[uniffi::export]
pub fn terminal_sizing_state_from_json(
    json: String,
) -> Result<TerminalSizingState, TerminalSizingWireError> {
    Ok(serde_json::from_str(&json)?)
}

/// Encodes a published state as the wire JSON every host sends.
#[uniffi::export]
pub fn terminal_sizing_state_to_json(
    state: TerminalSizingState,
) -> Result<String, TerminalSizingWireError> {
    Ok(serde_json::to_string(&state)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct Recorder(Mutex<Vec<TerminalSizingState>>);

    impl TerminalSizingListener for Recorder {
        fn on_state(&self, state: TerminalSizingState) {
            self.0.lock().unwrap().push(state);
        }
    }

    fn mac(id: &str, cols: u16, rows: u16) -> TerminalSizingParticipant {
        TerminalSizingParticipant {
            viewport: Some(TerminalGridSize::new(cols, rows)),
            ..TerminalSizingParticipant::new(id, TerminalDeviceKind::Mac)
        }
    }

    #[test]
    fn listener_receives_every_changed_state_and_nothing_else() {
        let engine = TerminalSizingEngine::new(
            TerminalGridSize::new(80, 24),
            terminal_sizing_policy(TerminalSizingMode::Latest, Vec::new(), None),
        );
        let recorder = Arc::new(Recorder::default());
        engine.set_listener(Some(recorder.clone()));
        assert!(engine.attach(mac("a", 100, 30)));
        assert!(engine.attach(mac("b", 90, 20)));
        assert!(!engine.detach("missing".into()));
        assert!(engine.note_activity("a".into()));
        let states = recorder.0.lock().unwrap().clone();
        assert_eq!(states.iter().map(|state| state.generation).collect::<Vec<_>>(), [1, 2, 3]);
        assert_eq!(states.last(), Some(&engine.state()));
        assert_eq!(engine.state().owners, ["a"]);
        engine.set_listener(None);
        assert!(engine.detach("a".into()));
        assert_eq!(recorder.0.lock().unwrap().len(), 3);
    }
}
