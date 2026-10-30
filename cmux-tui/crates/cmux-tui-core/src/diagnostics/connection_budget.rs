//! How many connections the session daemon admits, and on which lane.
//!
//! Red-test seam (#27698 B1): the budget is still the fixed 64 of one shared
//! pool; lanes and identities are not told apart yet.

/// The connections the daemon admits at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectionBudget {
    total: u64,
}

impl ConnectionBudget {
    /// The budget of this process.
    pub fn of_process() -> Self {
        Self { total: 64 }
    }

    /// A budget of `total` connections, for tests that fill it.
    pub fn for_test(total: u64) -> Self {
        Self { total }
    }

    /// Connections admitted at once, both lanes together.
    pub fn total(self) -> u64 {
        self.total
    }
}

/// Which socket a connection came in on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ConnectionLane {
    /// The app's own socket (`<session socket>.app`).
    App,
    /// The session socket every other local client uses.
    Shared,
}

/// One admitted connection's place: its lane and the client identity it
/// counts against.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ConnectionSlot {
    pub lane: ConnectionLane,
    pub identity: Option<u32>,
}
