use super::*;

/// Fields of `create-profile`.
#[derive(Debug, Clone, Default)]
pub struct ProfileInput {
    pub id: Option<String>,
    pub name: String,
    pub color: Option<String>,
    pub icon: Option<String>,
    pub theme: Option<String>,
    pub index: Option<usize>,
    pub browser_profile_id: Option<String>,
    pub default_session_id: Option<String>,
    pub defaults: Option<Value>,
    pub follows: Option<Vec<String>>,
}

/// Fields of `update-profile`: `None` unchanged, `Some(None)` clears.
#[derive(Debug, Clone, Default)]
pub struct ProfileUpdate {
    pub name: Option<String>,
    pub color: Option<Option<String>>,
    pub icon: Option<Option<String>>,
    pub theme: Option<Option<String>>,
    pub browser_profile_id: Option<Option<String>>,
    pub default_session_id: Option<Option<String>>,
    pub defaults: Option<Option<Value>>,
}

/// Fields of `set-personal-workspace`: `None` unchanged, `Some(None)` clears.
#[derive(Debug, Clone, Default)]
pub struct PersonalWorkspaceUpdate {
    pub index: Option<usize>,
    pub group: Option<Option<String>>,
    pub browser_profile_id: Option<Option<String>>,
    pub theme: Option<Option<String>>,
}

/// Result of `delete-profile`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProfileDeletion {
    pub moved_to: Option<String>,
    /// Pins removed (the workspaces return to their followers).
    pub unpinned: Vec<(String, String)>,
}
