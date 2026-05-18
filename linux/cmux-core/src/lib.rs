//! Shared Linux cmux domain logic.
//!
//! This crate intentionally has no GTK dependency. UI, terminal widgets, and
//! platform integrations live in the `cmux-gtk` crate.

pub mod terminal;

/// Application metadata shared by Linux crates.
pub const APP_ID: &str = "ai.manaflow.cmux";

/// A Linux workspace/session descriptor.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Workspace {
    pub id: String,
    pub title: String,
}

impl Workspace {
    #[must_use]
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self { id: id.into(), title: title.into() }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn workspace_stores_id_and_title() {
        let workspace = Workspace::new("one", "Claude");
        assert_eq!(workspace.id, "one");
        assert_eq!(workspace.title, "Claude");
    }
}
