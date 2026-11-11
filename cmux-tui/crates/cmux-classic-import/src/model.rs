//! A classic cmux session as read: every window, its workspaces in sidebar
//! order with their splits and tabs, its groups, and each workspace's key,
//! color, pin and group. This is what the app receives (snake_case JSON) and
//! makes into cmux NEXT workspaces.

use serde::{Deserialize, Serialize};

/// A whole classic session file, window by window.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    /// Classic's schema version (`version`); 1 for every classic release so far.
    pub version: i64,
    /// When classic wrote it (`createdAt`, seconds since 1970).
    pub created_at: Option<f64>,
    pub windows: Vec<Window>,
}

impl Snapshot {
    /// Every workspace, window after window.
    pub fn workspaces(&self) -> impl Iterator<Item = &Workspace> {
        self.windows.iter().flat_map(|window| window.workspaces.iter())
    }

    /// This snapshot with each local folder that `exists` rejects replaced by
    /// `home`: no terminal can start in a folder that is gone (a deleted
    /// project, a cleared /tmp). SSH and Cloud VM folders are on their hosts.
    pub fn opening_missing_folders(&self, home: &str, exists: &dyn Fn(&str) -> bool) -> Snapshot {
        let mut opened = self.clone();
        for window in &mut opened.windows {
            for workspace in &mut window.workspaces {
                if workspace.remote.is_none() && workspace.cloud_vm.is_none() {
                    *workspace = workspace.opening_missing_folders(home, exists);
                }
            }
        }
        opened
    }
}

/// A window's frame in screen coordinates.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// One window of a classic session: its workspaces in sidebar order and its groups.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Window {
    /// Classic's window id (`windowId`); absent in older snapshots.
    pub id: Option<String>,
    pub frame: Option<Rect>,
    /// The index into `workspaces` that was selected.
    pub selected_workspace: Option<i64>,
    pub workspaces: Vec<Workspace>,
    /// Groups in sidebar order.
    pub groups: Vec<Group>,
}

/// A sidebar group of a classic window (`tabManager.workspaceGroups`).
/// Classic keeps no member list: each workspace names its group.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Group {
    /// Classic's group id; the ledger maps it to the cmux NEXT group.
    pub id: String,
    pub name: String,
    pub collapsed: bool,
    /// A pinned group comes over even when empty.
    pub pinned: bool,
    /// `#RRGGBB`; none for the default.
    pub color: Option<String>,
    /// An SF Symbol name.
    pub icon: Option<String>,
}

/// One classic workspace.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Workspace {
    pub name: String,
    pub working_directory: String,
    pub layout: Layout,
    /// The SSH host its terminals ran on; none for a local workspace.
    pub remote: Option<Remote>,
    /// The Cloud VM it ran on (an empty id when classic saved none).
    pub cloud_vm: Option<String>,
    /// Whether it had panels that do not come over (markdown, file preview).
    pub left_out_panels: bool,
    /// Classic's identity across saves: `stableId`, else `workspaceId`, else
    /// a digest of its folder, name and panel ids. The ledger keys on it.
    pub key: String,
    pub color: Option<String>,
    pub pinned: bool,
    pub group_id: Option<String>,
}

impl Workspace {
    /// This workspace with each folder `exists` rejects replaced by `home`.
    pub fn opening_missing_folders(&self, home: &str, exists: &dyn Fn(&str) -> bool) -> Workspace {
        let folder = |path: &str| if exists(path) { path.to_string() } else { home.to_string() };
        Workspace {
            working_directory: folder(&self.working_directory),
            layout: self.layout.mapping_folders(&folder),
            ..self.clone()
        }
    }
}

/// Where a classic SSH workspace ran: `user@host` and its port.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Remote {
    pub destination: String,
    pub port: Option<i64>,
}

impl Remote {
    /// `[user@]host[:port]`, an IPv6 host in brackets. Port 22 is left out,
    /// so it names the same machine as a saved entry without a port.
    pub fn ssh_destination(&self) -> String {
        let (user, host) = match self.destination.rsplit_once('@') {
            Some((user, host)) => (format!("{user}@"), host),
            None => (String::new(), self.destination.as_str()),
        };
        let host = if host.contains(':') && !host.starts_with('[') {
            format!("[{host}]")
        } else {
            host.to_string()
        };
        match self.port {
            Some(port) if port != 22 => format!("{user}{host}:{port}"),
            _ => format!("{user}{host}"),
        }
    }
}

/// A Claude Code or Codex session classic recorded on a terminal, to resume as a chat.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Agent {
    /// The acpmux harness: `claude` or `codex`.
    pub harness: String,
    pub session_id: String,
    pub working_directory: Option<String>,
}

/// A terminal or browser tab.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Tab {
    pub working_directory: Option<String>,
    /// The person's tab title, or a terminal's last title.
    pub title: Option<String>,
    /// A browser tab's page; none for a terminal.
    pub url: Option<String>,
    pub agent: Option<Agent>,
    /// The terminal's saved scrollback text, with its colors.
    pub scrollback: Option<String>,
}

/// A pane and its tabs, in classic's order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pane {
    pub tabs: Vec<Tab>,
    pub selected_tab: usize,
}

/// A split's axis.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Orientation {
    Horizontal,
    Vertical,
}

/// The classic split tree: a pane is a leaf; a split keeps its axis and divider.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Layout {
    Pane(Pane),
    Split { orientation: Orientation, ratio: f64, first: Box<Layout>, second: Box<Layout> },
}

impl Layout {
    /// The tree with only the tabs `keep` accepts; a side left with none
    /// closes up. None when no tab is kept.
    pub fn keeping(&self, keep: &dyn Fn(&Tab) -> bool) -> Option<Layout> {
        match self {
            Layout::Pane(pane) => {
                let tabs: Vec<Tab> = pane.tabs.iter().filter(|tab| keep(tab)).cloned().collect();
                if tabs.is_empty() {
                    return None;
                }
                let selected = pane
                    .tabs
                    .get(pane.selected_tab)
                    .and_then(|chosen| tabs.iter().position(|tab| tab == chosen))
                    .unwrap_or(0);
                Some(Layout::Pane(Pane { tabs, selected_tab: selected }))
            }
            Layout::Split { orientation, ratio, first, second } => {
                match (first.keeping(keep), second.keeping(keep)) {
                    (Some(a), Some(b)) => Some(Layout::Split {
                        orientation: *orientation,
                        ratio: *ratio,
                        first: Box::new(a),
                        second: Box::new(b),
                    }),
                    (a, b) => a.or(b),
                }
            }
        }
    }

    /// The tree with each tab's folder, and its agent's, passed through `folder`.
    pub fn mapping_folders(&self, folder: &dyn Fn(&str) -> String) -> Layout {
        match self {
            Layout::Pane(pane) => Layout::Pane(Pane {
                tabs: pane
                    .tabs
                    .iter()
                    .map(|tab| Tab {
                        working_directory: tab.working_directory.as_deref().map(folder),
                        agent: tab.agent.as_ref().map(|agent| Agent {
                            working_directory: agent.working_directory.as_deref().map(folder),
                            ..agent.clone()
                        }),
                        ..tab.clone()
                    })
                    .collect(),
                selected_tab: pane.selected_tab,
            }),
            Layout::Split { orientation, ratio, first, second } => Layout::Split {
                orientation: *orientation,
                ratio: *ratio,
                first: Box::new(first.mapping_folders(folder)),
                second: Box::new(second.mapping_folders(folder)),
            },
        }
    }

    /// Tabs in pane order, first side first.
    pub fn tabs(&self) -> Vec<&Tab> {
        match self {
            Layout::Pane(pane) => pane.tabs.iter().collect(),
            Layout::Split { first, second, .. } => {
                let mut tabs = first.tabs();
                tabs.extend(second.tabs());
                tabs
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tab(dir: &str) -> Tab {
        Tab {
            working_directory: Some(dir.into()),
            title: None,
            url: None,
            agent: None,
            scrollback: None,
        }
    }

    #[test]
    fn an_ssh_destination_brackets_ipv6_and_leaves_out_port_22() {
        let remote = |destination: &str, port| Remote { destination: destination.into(), port };
        assert_eq!(remote("me@host", Some(22)).ssh_destination(), "me@host");
        assert_eq!(remote("me@host", Some(2222)).ssh_destination(), "me@host:2222");
        assert_eq!(remote("::1", None).ssh_destination(), "[::1]");
        assert_eq!(remote("a@b@fe80::1", Some(23)).ssh_destination(), "a@b@[fe80::1]:23");
    }

    #[test]
    fn a_side_with_no_tab_kept_closes_up_and_the_selection_follows_its_tab() {
        let layout = Layout::Split {
            orientation: Orientation::Vertical,
            ratio: 0.3,
            first: Box::new(Layout::Pane(Pane { tabs: vec![tab("/drop")], selected_tab: 0 })),
            second: Box::new(Layout::Pane(Pane {
                tabs: vec![tab("/drop"), tab("/a"), tab("/b")],
                selected_tab: 2,
            })),
        };
        let kept =
            layout.keeping(&|tab| tab.working_directory.as_deref() != Some("/drop")).unwrap();
        assert_eq!(kept, Layout::Pane(Pane { tabs: vec![tab("/a"), tab("/b")], selected_tab: 1 }));
        assert_eq!(layout.keeping(&|_| false), None);
    }
}
