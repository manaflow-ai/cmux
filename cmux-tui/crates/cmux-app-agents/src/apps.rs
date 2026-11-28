//! cmux apps: which runs reach an app (the palette, CLI, MCP and
//! automations), and what a refused provider registration does next.

use serde::{Deserialize, Serialize};

/// Where a run comes from (`ActionOrigin`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Origin {
    User,
    Cli,
    Mcp,
    Script,
    Remote,
    /// Any other origin (an agent, a shortcut): reaches presented apps only.
    #[serde(other)]
    Other,
}

/// The channels a hidden app lets in (`hidden_access`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct HiddenAccess {
    pub cli: bool,
    pub mcp: bool,
    pub automations: bool,
}

/// One app, as the app's client reads it.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Reach {
    pub presented: bool,
    pub active: bool,
    pub hidden: bool,
    pub hidden_access: HiddenAccess,
}

/// Whether a run from `origin` reaches the app: a presented app always; a
/// hidden, active one only through a channel its `hidden_access` allows.
pub fn reaches(app: &Reach, origin: Origin) -> bool {
    if app.presented {
        return true;
    }
    if !app.active || !app.hidden {
        return false;
    }
    match origin {
        Origin::Cli => app.hidden_access.cli,
        Origin::Mcp => app.hidden_access.mcp,
        Origin::Script | Origin::Remote => app.hidden_access.automations,
        Origin::User | Origin::Other => false,
    }
}

/// Refusals tried again on the same connection, with backoff.
pub const RETRIED: [&str; 4] = ["apps.provider.taken", "failed", "not_connected", "timeout"];

/// Families newer daemons know (`apps/provider.rs` `FAMILIES`), newest
/// first: an older daemon's `bad-request` registers again without the newest
/// one sent, so one that knows `memory` keeps it.
pub const NEWER_FAMILIES: [&str; 5] = ["media", "system_calendar", "page", "toast", "memory"];

/// What the channel does after a refused registration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "next", rename_all = "camelCase")]
pub enum AfterRefusal {
    /// Register again now with `families` (the newest one an older daemon
    /// refused dropped).
    Register { families: Vec<String>, dropped: String },
    /// Wait out the backoff, then register the same families again.
    Retry,
    /// Stop; the next connection tries again.
    Stop,
}

/// The next step after the daemon refused registering `families` with
/// `refused`.
pub fn after_refusal(refused: &str, families: &[String]) -> AfterRefusal {
    if refused == "bad-request"
        && let Some(newest) =
            NEWER_FAMILIES.iter().find(|family| families.iter().any(|sent| sent == *family))
    {
        let kept: Vec<String> =
            families.iter().filter(|family| family != newest).cloned().collect();
        if kept.is_empty() {
            return AfterRefusal::Stop;
        }
        return AfterRefusal::Register { families: kept, dropped: (*newest).to_owned() };
    }
    if RETRIED.contains(&refused) { AfterRefusal::Retry } else { AfterRefusal::Stop }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn families(names: &[&str]) -> Vec<String> {
        names.iter().map(|name| (*name).to_owned()).collect()
    }

    fn hidden(access: HiddenAccess) -> Reach {
        Reach { presented: false, active: true, hidden: true, hidden_access: access }
    }

    #[test]
    fn a_presented_app_reaches_every_origin() {
        let app = Reach { presented: true, ..Reach::default() };
        for origin in
            [Origin::User, Origin::Cli, Origin::Mcp, Origin::Script, Origin::Remote, Origin::Other]
        {
            assert!(reaches(&app, origin));
        }
    }

    #[test]
    fn a_hidden_app_reaches_only_its_channels() {
        let cli = hidden(HiddenAccess { cli: true, ..HiddenAccess::default() });
        assert!(reaches(&cli, Origin::Cli));
        assert!(!reaches(&cli, Origin::Mcp));
        assert!(!reaches(&cli, Origin::Script));
        let mcp = hidden(HiddenAccess { mcp: true, ..HiddenAccess::default() });
        assert!(reaches(&mcp, Origin::Mcp));
        assert!(!reaches(&mcp, Origin::Cli));
        let automations = hidden(HiddenAccess { automations: true, ..HiddenAccess::default() });
        assert!(reaches(&automations, Origin::Script));
        assert!(reaches(&automations, Origin::Remote));
        assert!(!reaches(&automations, Origin::Cli));
        let all = hidden(HiddenAccess { cli: true, mcp: true, automations: true });
        assert!(!reaches(&all, Origin::User));
        assert!(!reaches(&all, Origin::Other));
    }

    #[test]
    fn an_inactive_or_unhidden_app_that_is_not_presented_reaches_nothing() {
        let access = HiddenAccess { cli: true, mcp: true, automations: true };
        let inactive = Reach { active: false, ..hidden(access) };
        let shown = Reach { hidden: false, ..hidden(access) };
        for origin in [Origin::Cli, Origin::Mcp, Origin::Script] {
            assert!(!reaches(&inactive, origin));
            assert!(!reaches(&shown, origin));
        }
    }

    #[test]
    fn origins_decode() {
        let decoded: Vec<Origin> =
            serde_json::from_str(r#"["user","cli","mcp","script","remote","agent","shortcut"]"#)
                .unwrap();
        assert_eq!(
            decoded,
            vec![
                Origin::User,
                Origin::Cli,
                Origin::Mcp,
                Origin::Script,
                Origin::Remote,
                Origin::Other,
                Origin::Other
            ]
        );
    }

    // AppsProviderChannelNewerFamilyTests: an older daemon keeps the families it knows.
    #[test]
    fn an_older_daemon_keeps_the_families_it_knows() {
        assert_eq!(
            after_refusal("bad-request", &families(&["agent_cli", "coderouter", "memory"])),
            AfterRefusal::Register {
                families: families(&["agent_cli", "coderouter"]),
                dropped: "memory".into()
            }
        );
    }

    #[test]
    fn only_the_newest_family_drops() {
        assert_eq!(
            after_refusal("bad-request", &families(&["coderouter", "memory", "toast"])),
            AfterRefusal::Register {
                families: families(&["coderouter", "memory"]),
                dropped: "toast".into()
            }
        );
        assert_eq!(
            after_refusal("bad-request", &families(&["page", "media", "memory"])),
            AfterRefusal::Register {
                families: families(&["page", "memory"]),
                dropped: "media".into()
            }
        );
    }

    #[test]
    fn a_bad_request_with_only_newer_families_left_stops() {
        assert_eq!(after_refusal("bad-request", &families(&["memory"])), AfterRefusal::Stop);
    }

    #[test]
    fn a_bad_request_without_newer_families_stops() {
        assert_eq!(after_refusal("bad-request", &families(&["coderouter"])), AfterRefusal::Stop);
        assert_eq!(after_refusal("bad-request", &[]), AfterRefusal::Stop);
    }

    #[test]
    fn transient_refusals_retry() {
        for refused in RETRIED {
            assert_eq!(
                after_refusal(refused, &families(&["memory"])),
                AfterRefusal::Retry,
                "{refused}"
            );
        }
        assert_eq!(after_refusal("apps.disabled", &families(&["memory"])), AfterRefusal::Stop);
        assert_eq!(after_refusal("", &[]), AfterRefusal::Stop);
    }
}
