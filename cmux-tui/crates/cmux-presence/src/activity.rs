//! Agent activities used by the terminal daemon and the sidebar.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AgentActivity {
    /// Between tool calls, or a tool presence cannot classify.
    Thinking,
    Editing,
    Reading,
    Running,
    Browsing,
    ComputerUse,
    /// Blocked on the user: an approval, a question or a plan review.
    Waiting,
}

impl AgentActivity {
    pub fn as_str(self) -> &'static str {
        match self {
            AgentActivity::Thinking => "thinking",
            AgentActivity::Editing => "editing",
            AgentActivity::Reading => "reading",
            AgentActivity::Running => "running",
            AgentActivity::Browsing => "browsing",
            AgentActivity::ComputerUse => "computer_use",
            AgentActivity::Waiting => "waiting",
        }
    }
}
