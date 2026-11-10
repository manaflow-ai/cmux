//! `list-workspaces-known-v1`: one revision of everything `list-workspaces`
//! shows, so a client that holds a tree can ask whether it is still current
//! and get `{"unchanged": true}` in O(1) instead of the whole tree again.
//!
//! The workspace, pane and terminal revisions do not cover the whole reply:
//! a tab title, an unread marker, the selection or a git branch changes none
//! of them. Every change the reply shows reaches clients as a mux event, so
//! the revision counts the events that can change it ([`changes_tree`]), and
//! a git HEAD that a refresh reads differently (presentation.rs). An event a
//! client cannot see in the tree, such as terminal output, leaves it alone.
//!
//! The value is `"<boot>.<count>"`: the boot part is random per daemon, so a
//! count from before a restart never matches one after it.

use std::sync::atomic::{AtomicU64, Ordering};

use super::MuxEvent;

pub(crate) struct TreeRevision {
    boot: String,
    changes: AtomicU64,
}

impl TreeRevision {
    pub(crate) fn new() -> Self {
        let mut bytes = [0u8; 8];
        if getrandom::fill(&mut bytes).is_err() {
            let nanos = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_nanos() as u64);
            bytes = (nanos ^ u64::from(std::process::id())).to_le_bytes();
        }
        let boot = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
        Self { boot, changes: AtomicU64::new(0) }
    }

    /// Something the tree shows changed (call after the change is visible).
    pub(crate) fn bump(&self) {
        self.changes.fetch_add(1, Ordering::SeqCst);
    }

    /// The current revision. A reader takes it before it reads the tree, so
    /// a change that lands while it reads makes the next request read again.
    pub(crate) fn current(&self) -> String {
        format!("{}.{}", self.boot, self.changes.load(Ordering::SeqCst))
    }
}

/// Whether `event` may change what `list-workspaces` returns. Exhaustive, so
/// a new event has to say; when in doubt it counts (a needless whole tree
/// costs one reply, a missed change shows a stale list).
pub(super) fn changes_tree(event: &MuxEvent) -> bool {
    match event {
        MuxEvent::SurfaceOutput(_)
        | MuxEvent::ScrollChanged { .. }
        | MuxEvent::SurfaceResizeFailed { .. }
        | MuxEvent::SizeStateChanged { .. }
        | MuxEvent::GraphicsStatus(_)
        | MuxEvent::Status(_)
        | MuxEvent::ConfigReloadRequested
        | MuxEvent::WindowTitleRequested(_)
        | MuxEvent::FrontendProjectionChanged { .. }
        | MuxEvent::BookmarksChanged(_)
        | MuxEvent::HistoryChanged { .. }
        | MuxEvent::FeedViewChanged { .. }
        | MuxEvent::FeedReportsChanged { .. }
        | MuxEvent::KeybindingsChanged(_)
        | MuxEvent::CloudConversation(_)
        | MuxEvent::TerminalReaped { .. }
        | MuxEvent::ClientAttached { .. }
        | MuxEvent::ClientChanged { .. }
        | MuxEvent::ClientDetached(_)
        | MuxEvent::ClientListInvalidated
        | MuxEvent::PairingRequested(_)
        | MuxEvent::PairingResolved { .. }
        | MuxEvent::MachineUsageChanged(_)
        | MuxEvent::StashChanged { .. }
        | MuxEvent::TasksChanged(_) => false,
        MuxEvent::SurfaceResized { .. }
        | MuxEvent::SurfaceExited(..)
        | MuxEvent::ProgramStatusChanged { .. }
        | MuxEvent::TitleChanged { .. }
        | MuxEvent::AgentChanged { .. }
        | MuxEvent::AgentPresenceChanged { .. }
        | MuxEvent::Bell(_)
        | MuxEvent::Notification(_)
        | MuxEvent::TreeChanged
        | MuxEvent::TreeSelectionChanged(_)
        | MuxEvent::WorkspacePresentationChanged(_)
        | MuxEvent::TreeDelta(_)
        | MuxEvent::PersonalChanged { .. }
        | MuxEvent::SettingsChanged(_)
        | MuxEvent::Conversation(_)
        | MuxEvent::TerminalRegistryChanged { .. }
        | MuxEvent::LayoutChanged(..)
        | MuxEvent::AppsChanged(_)
        | MuxEvent::Empty => true,
    }
}
