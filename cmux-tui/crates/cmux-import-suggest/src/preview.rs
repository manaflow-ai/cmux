//! The classic import prompt's plan (`ClassicImportPreviewStrings`): which sentences it says for one
//! classic save, in which order, with which counts. A count of zero never shows. The app words them.

use serde::{Deserialize, Serialize};

/// What one classic save brings, as the daemon previewed it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Counts {
    pub workspaces: i64,
    pub browser_tabs: i64,
    pub file_pages: i64,
    pub ssh_workspaces: i64,
    pub agent_chats: i64,
    #[serde(rename = "skippedCloudVMs")]
    pub skipped_cloud_vms: i64,
    pub cleanup: i64,
}

/// One part of the summary's list ("8 workspaces, 2 browser tabs and 1 agent chat").
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Part {
    Workspaces,
    BrowserTabs,
    FilePages,
    SshWorkspaces,
    AgentChats,
}

/// What opening does ("pages load, SSH hosts connect and agent chats resume").
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Effect {
    PagesLoad,
    HostsConnect,
    ChatsResume,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Counted {
    pub part: Part,
    pub count: i64,
}

/// One line of the prompt, in order.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "line", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum Line {
    /// "… from cmux, saved today at 1:47 PM." (`autosaved` while classic still runs).
    Summary {
        parts: Vec<Counted>,
        autosaved: bool,
    },
    /// "They open exactly as classic saved them" (`: <effects>.` when there are some).
    OpensAsSaved {
        effects: Vec<Effect>,
    },
    /// "<app> is still open, so this is its last autosave."
    StillOpen,
    CloudVmsSkipped {
        count: i64,
    },
    InterruptedClose {
        count: i64,
    },
    /// "You can import them later from Settings › Import." (at launch only).
    Later,
}

impl Counts {
    pub fn summary(&self, classic_running: bool) -> Line {
        let counted = |part, count: i64| (count > 0).then_some(Counted { part, count });
        let mut parts = vec![Counted { part: Part::Workspaces, count: self.workspaces }];
        parts.extend(
            [
                counted(Part::BrowserTabs, self.browser_tabs),
                counted(Part::FilePages, self.file_pages),
                counted(Part::SshWorkspaces, self.ssh_workspaces),
                counted(Part::AgentChats, self.agent_chats),
            ]
            .into_iter()
            .flatten(),
        );
        Line::Summary { parts, autosaved: classic_running }
    }

    pub fn lines(&self, classic_running: bool, at_launch: bool) -> Vec<Line> {
        let mut effects = Vec::new();
        if self.browser_tabs + self.file_pages > 0 {
            effects.push(Effect::PagesLoad);
        }
        if self.ssh_workspaces > 0 {
            effects.push(Effect::HostsConnect);
        }
        if self.agent_chats > 0 {
            effects.push(Effect::ChatsResume);
        }
        let mut lines = vec![self.summary(classic_running), Line::OpensAsSaved { effects }];
        if classic_running {
            lines.push(Line::StillOpen);
        }
        if self.skipped_cloud_vms > 0 {
            lines.push(Line::CloudVmsSkipped { count: self.skipped_cloud_vms });
        }
        if self.cleanup > 0 {
            lines.push(Line::InterruptedClose { count: self.cleanup });
        }
        if at_launch {
            lines.push(Line::Later);
        }
        lines
    }
}

/// The classic app that saves under `bundle`, as its Dock names it. `classic` is cmux Classic's
/// release bundle id, which the app names; its channels add `.nightly`, `.rc`, `.staging` or
/// `.debug.<tag>`.
pub fn app_name(bundle: &str, classic: &str) -> &'static str {
    let channel = |suffix: &str| {
        bundle
            .strip_prefix(classic)
            .and_then(|rest| rest.strip_prefix(suffix))
            .is_some_and(|rest| rest.is_empty() || rest.starts_with('.'))
    };
    if bundle == classic {
        "cmux"
    } else if channel(".nightly") {
        "cmux NIGHTLY"
    } else if channel(".rc") {
        "cmux RC"
    } else if channel(".staging") {
        "cmux STAGING"
    } else {
        "cmux DEV"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leos_save_reads_as_three_sentences_without_zero_counts() {
        let counts = Counts { workspaces: 8, browser_tabs: 2, agent_chats: 1, ..Counts::default() };
        let lines = counts.lines(false, true);
        assert_eq!(
            lines,
            [
                Line::Summary {
                    parts: vec![
                        Counted { part: Part::Workspaces, count: 8 },
                        Counted { part: Part::BrowserTabs, count: 2 },
                        Counted { part: Part::AgentChats, count: 1 },
                    ],
                    autosaved: false,
                },
                Line::OpensAsSaved { effects: vec![Effect::PagesLoad, Effect::ChatsResume] },
                Line::Later,
            ]
        );
    }

    #[test]
    fn only_the_launch_says_where_the_import_waits() {
        let counts = Counts { workspaces: 3, ..Counts::default() };
        assert_eq!(
            counts.lines(false, false),
            [counts.summary(false), Line::OpensAsSaved { effects: vec![] }]
        );
        // Workspaces show even at zero: a run may only replace interrupted ones.
        assert_eq!(
            Counts::default().summary(true),
            Line::Summary {
                parts: vec![Counted { part: Part::Workspaces, count: 0 }],
                autosaved: true
            }
        );
    }

    #[test]
    fn cautions_show_only_when_they_apply() {
        let counts = Counts {
            workspaces: 12,
            ssh_workspaces: 2,
            skipped_cloud_vms: 2,
            cleanup: 3,
            ..Counts::default()
        };
        let lines = counts.lines(true, false);
        assert_eq!(lines[1], Line::OpensAsSaved { effects: vec![Effect::HostsConnect] });
        assert_eq!(
            &lines[2..],
            [
                Line::StillOpen,
                Line::CloudVmsSkipped { count: 2 },
                Line::InterruptedClose { count: 3 }
            ]
        );
        let json = serde_json::to_value(&lines[3]).unwrap();
        assert_eq!(json, serde_json::json!({"line": "cloudVmsSkipped", "count": 2}));
        let decoded: Counts =
            serde_json::from_value(serde_json::json!({"workspaces": 1, "skippedCloudVMs": 4}))
                .unwrap();
        assert_eq!(decoded.skipped_cloud_vms, 4);
    }

    #[test]
    fn app_name_follows_the_classic_channel() {
        const CLASSIC: &str = "com.example.classic";
        assert_eq!(app_name(CLASSIC, CLASSIC), "cmux");
        assert_eq!(app_name(&format!("{CLASSIC}.nightly"), CLASSIC), "cmux NIGHTLY");
        assert_eq!(app_name(&format!("{CLASSIC}.nightly.2"), CLASSIC), "cmux NIGHTLY");
        assert_eq!(app_name(&format!("{CLASSIC}.rc"), CLASSIC), "cmux RC");
        assert_eq!(app_name(&format!("{CLASSIC}.staging"), CLASSIC), "cmux STAGING");
        assert_eq!(app_name(&format!("{CLASSIC}.nightlyx"), CLASSIC), "cmux DEV");
        assert_eq!(app_name(&format!("{CLASSIC}.debug.foo"), CLASSIC), "cmux DEV");
    }
}
