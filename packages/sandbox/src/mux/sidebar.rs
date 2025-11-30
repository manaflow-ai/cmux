use crate::models::{SandboxStatus, SandboxSummary};

/// State for the sidebar showing sandbox list.
#[derive(Debug)]
pub struct Sidebar {
    pub sandboxes: Vec<SandboxSummary>,
    pub selected_index: usize,
    pub scroll_offset: usize,
    pub is_loading: bool,
    pub last_error: Option<String>,
    pub visible: bool,
    pub width: u16,
}

impl Default for Sidebar {
    fn default() -> Self {
        Self::new()
    }
}

impl Sidebar {
    pub fn new() -> Self {
        Self {
            sandboxes: Vec::new(),
            selected_index: 0,
            scroll_offset: 0,
            is_loading: false,
            last_error: None,
            visible: true,
            width: 30,
        }
    }

    /// Set the list of sandboxes.
    pub fn set_sandboxes(&mut self, sandboxes: Vec<SandboxSummary>) {
        self.sandboxes = sandboxes;
        self.is_loading = false;
        self.last_error = None;

        // Ensure selection is still valid
        if !self.sandboxes.is_empty() && self.selected_index >= self.sandboxes.len() {
            self.selected_index = self.sandboxes.len() - 1;
        }
    }

    /// Set an error state.
    pub fn set_error(&mut self, error: String) {
        self.is_loading = false;
        self.last_error = Some(error);
    }

    /// Get the currently selected sandbox.
    pub fn selected_sandbox(&self) -> Option<&SandboxSummary> {
        self.sandboxes.get(self.selected_index)
    }

    /// Select the next sandbox in the list.
    pub fn select_next(&mut self) {
        if !self.sandboxes.is_empty() {
            self.selected_index = (self.selected_index + 1) % self.sandboxes.len();
            self.ensure_visible();
        }
    }

    /// Select the previous sandbox in the list.
    pub fn select_previous(&mut self) {
        if !self.sandboxes.is_empty() {
            self.selected_index = if self.selected_index == 0 {
                self.sandboxes.len() - 1
            } else {
                self.selected_index - 1
            };
            self.ensure_visible();
        }
    }

    /// Ensure the selected item is visible.
    fn ensure_visible(&mut self) {
        // This will be adjusted based on visible height during rendering
    }

    /// Toggle sidebar visibility.
    pub fn toggle(&mut self) {
        self.visible = !self.visible;
    }

    /// Select a sandbox by its ID string.
    pub fn select_by_id(&mut self, id_str: &str) {
        if let Some(idx) = self
            .sandboxes
            .iter()
            .position(|s| s.id.to_string() == id_str)
        {
            self.selected_index = idx;
            self.ensure_visible();
        }
    }

    /// Get status icon for a sandbox.
    pub fn status_icon(status: &SandboxStatus) -> &'static str {
        match status {
            SandboxStatus::Running => "●",
            SandboxStatus::Exited => "○",
            SandboxStatus::Failed => "✗",
            SandboxStatus::Unknown => "?",
        }
    }

    /// Get status color for a sandbox.
    pub fn status_color(status: &SandboxStatus) -> ratatui::style::Color {
        match status {
            SandboxStatus::Running => ratatui::style::Color::Green,
            SandboxStatus::Exited => ratatui::style::Color::DarkGray,
            SandboxStatus::Failed => ratatui::style::Color::Red,
            SandboxStatus::Unknown => ratatui::style::Color::Yellow,
        }
    }

    /// Format the sandbox name for display, truncating if needed.
    pub fn format_name(sandbox: &SandboxSummary, max_width: usize) -> String {
        let name = &sandbox.name;
        if name.len() <= max_width {
            name.clone()
        } else if max_width > 3 {
            format!("{}...", &name[..max_width - 3])
        } else {
            name.chars().take(max_width).collect()
        }
    }

    /// Format sandbox index for display.
    pub fn format_index(index: usize) -> String {
        format!("#{}", index + 1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::Utc;
    use uuid::Uuid;

    fn create_test_sandbox(name: &str, status: SandboxStatus) -> SandboxSummary {
        SandboxSummary {
            id: Uuid::new_v4(),
            index: 0,
            name: name.to_string(),
            created_at: Utc::now(),
            workspace: "/workspace".to_string(),
            status,
            network: crate::models::SandboxNetwork {
                host_interface: "veth0".to_string(),
                sandbox_interface: "eth0".to_string(),
                host_ip: "10.0.0.1".to_string(),
                sandbox_ip: "10.0.0.2".to_string(),
                cidr: 24,
            },
        }
    }

    #[test]
    fn sidebar_selection_works() {
        let mut sidebar = Sidebar::new();
        sidebar.set_sandboxes(vec![
            create_test_sandbox("sandbox1", SandboxStatus::Running),
            create_test_sandbox("sandbox2", SandboxStatus::Running),
            create_test_sandbox("sandbox3", SandboxStatus::Running),
        ]);

        assert_eq!(sidebar.selected_index, 0);
        sidebar.select_next();
        assert_eq!(sidebar.selected_index, 1);
        sidebar.select_next();
        assert_eq!(sidebar.selected_index, 2);
        sidebar.select_next();
        assert_eq!(sidebar.selected_index, 0); // Wrap around

        sidebar.select_previous();
        assert_eq!(sidebar.selected_index, 2); // Wrap around backwards
    }

    #[test]
    fn status_icons_are_correct() {
        assert_eq!(Sidebar::status_icon(&SandboxStatus::Running), "●");
        assert_eq!(Sidebar::status_icon(&SandboxStatus::Exited), "○");
        assert_eq!(Sidebar::status_icon(&SandboxStatus::Failed), "✗");
        assert_eq!(Sidebar::status_icon(&SandboxStatus::Unknown), "?");
    }

    #[test]
    fn name_truncation_works() {
        let sandbox = create_test_sandbox("very-long-sandbox-name", SandboxStatus::Running);
        let truncated = Sidebar::format_name(&sandbox, 10);
        assert!(truncated.len() <= 10);
        assert!(truncated.ends_with("..."));
    }
}
