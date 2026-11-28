//! A daemon closed item (`ClosedItemSnapshot`, `closed-history-v2`) as the app decodes it
//! (`CmuxNextDaemon.ClosedItem`, StateResources.swift). The JSON is the daemon's wire shape
//! (`workspace_id`, `pane_id`, `closed_at_ms`, `members`, `agent_session`,
//! `browser_profile_id`), so step B can hand the mirrored item through unchanged.

use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize};

/// What a closed item recreates.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Tab,
    Screen,
    Workspace,
    /// A window the app closed (`window-records-v1`); it has no member.
    Window,
}

impl Kind {
    /// Every kind (`DaemonClosedHistory.allKinds`).
    pub const ALL: [Kind; 4] = [Kind::Tab, Kind::Screen, Kind::Workspace, Kind::Window];

    /// The kind cmux-window-rules' closed rules read.
    pub fn rules_kind(self) -> cmux_window_rules::closed::ItemKind {
        use cmux_window_rules::closed::ItemKind;
        match self {
            Kind::Tab => ItemKind::Tab,
            Kind::Screen => ItemKind::Screen,
            Kind::Workspace => ItemKind::Workspace,
            Kind::Window => ItemKind::Window,
        }
    }
}

/// The safe public identity of a closed agent chat; host and install metadata are never exposed.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(default)]
pub struct AgentSession {
    pub session: Option<String>,
    pub harness: Option<String>,
}

/// What reopening recreates for one tab (`ClosedTabRecord`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Tab {
    /// `terminal`, `browser`, or `conversation` (closed-conversation-tabs-v1). Required.
    pub kind: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cwd: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(
        default,
        rename = "browser_profile_id",
        alias = "browserProfileID",
        skip_serializing_if = "Option::is_none"
    )]
    pub browser_profile_id: Option<String>,
    #[serde(default, deserialize_with = "null_false")]
    pub pinned: bool,
    #[serde(
        default,
        rename = "agent_session",
        alias = "agentSession",
        skip_serializing_if = "Option::is_none"
    )]
    pub agent_session: Option<AgentSession>,
    /// The page a closed page tab showed (`page-tabs-v1`); its `url` is then `about:blank`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub page: Option<String>,
    /// True when the tab would reopen as nothing: an untouched New Tab page or a browser on
    /// `about:blank`. False from a daemon that does not say.
    #[serde(default, deserialize_with = "null_false")]
    pub empty: bool,
}

impl Tab {
    /// A tab of `kind` with every other field unset (tests and fixtures).
    pub fn of(kind: &str) -> Tab {
        Tab { kind: kind.to_owned(), ..Tab::default() }
    }
}

/// One screen of the item (`ClosedScreenRecord`); a closed tab has one screen with one tab.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Screen {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    pub tabs: Vec<Tab>,
}

/// One member of an item (`ClosedMemberRecord`): one close gesture over several workspaces
/// is one item of several members.
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Member {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screens: Option<Vec<Screen>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
}

/// A deleted personal workspace group (`ClosedWorkspaceGroupRecord`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Group {
    pub id: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub color: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

/// One recently closed tab, screen, workspace or window.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ClosedItem {
    /// `closed_…` state id.
    pub id: String,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    /// The workspace a tab or screen was closed from.
    #[serde(
        default,
        rename = "workspace_id",
        alias = "workspaceID",
        skip_serializing_if = "Option::is_none"
    )]
    pub workspace_id: Option<String>,
    /// The pane a tab was closed from.
    #[serde(
        default,
        rename = "pane_id",
        alias = "paneID",
        skip_serializing_if = "Option::is_none"
    )]
    pub pane_id: Option<String>,
    /// Position the item held when it closed.
    #[serde(default, deserialize_with = "null_zero_i64")]
    pub index: i64,
    /// Close time, ms since 1970: the daemon sends a decimal string or a number.
    #[serde(
        default,
        rename = "closed_at_ms",
        alias = "closedAtMs",
        deserialize_with = "state_decimal"
    )]
    pub closed_at_ms: u64,
    /// The first member's screens (closed-history-v2 mirrors its first member at the top level).
    #[serde(default, deserialize_with = "null_vec")]
    pub screens: Vec<Screen>,
    /// Every member, empty for a v1 item, whose `screens` are the whole item.
    #[serde(default, deserialize_with = "null_vec", skip_serializing_if = "Vec::is_empty")]
    pub members: Vec<Member>,
    /// Set when the item is a deleted personal workspace group.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub group: Option<Group>,
    /// The window record (`install/window`) the group left, or, for a `window` item, the closed
    /// window itself; None when no window listed it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub window: Option<String>,
}

impl ClosedItem {
    /// An item with `id` and `kind` and nothing else (tests and fixtures).
    pub fn new(id: &str, kind: Kind) -> ClosedItem {
        ClosedItem {
            id: id.to_owned(),
            kind,
            name: None,
            workspace_id: None,
            pane_id: None,
            index: 0,
            closed_at_ms: 0,
            screens: Vec::new(),
            members: Vec::new(),
            group: None,
            window: None,
        }
    }

    /// Every member's screens, one list per member (`memberScreens`); a member without
    /// screens has none.
    pub fn member_screens(&self) -> Vec<&[Screen]> {
        self.members.iter().map(|member| member.screens.as_deref().unwrap_or(&[])).collect()
    }

    /// Every member's name (`memberNames`).
    pub fn member_names(&self) -> Vec<Option<&str>> {
        self.members.iter().map(|member| member.name.as_deref()).collect()
    }

    /// Every tab the item would recreate, in order: every member's (one close gesture of
    /// several tabs is one item), else the item's own screens'. A member list without screens
    /// means no tabs, even when the top level mirrors some (Swift's `tabs`).
    pub fn tabs(&self) -> Vec<&Tab> {
        if self.members.is_empty() {
            self.screens.iter().flat_map(|screen| screen.tabs.iter()).collect()
        } else {
            self.member_screens()
                .into_iter()
                .flatten()
                .flat_map(|screen| screen.tabs.iter())
                .collect()
        }
    }

    /// How many tabs [`ClosedItem::tabs`] holds.
    pub fn tab_count(&self) -> usize {
        self.tabs().len()
    }

    /// The facts cmux-window-rules' page-once rule reads (`WindowRules.ClosedFacts(item,
    /// machine:)`): grouped is a group record, a tab is a page tab when it names its page.
    pub fn rules_facts(&self, machine: &str) -> cmux_window_rules::closed::ClosedItem {
        use cmux_window_rules::closed::{ClosedItem as Facts, ClosedTab};
        Facts {
            kind: self.kind.rules_kind(),
            grouped: self.group.is_some(),
            tabs: self
                .tabs()
                .into_iter()
                .map(|tab| ClosedTab {
                    kind: tab.kind.clone(),
                    empty: tab.empty,
                    page: tab.page.is_some(),
                    url: tab.url.clone(),
                })
                .collect(),
            machine: machine.to_owned(),
        }
    }
}

/// `StateDecimal.decode`: a decimal string (one that does not parse reads as absent, so 0), or
/// an unsigned number; absent or null is 0. A negative or fractional number does not decode.
fn state_decimal<'de, D: Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
    match serde_json::Value::deserialize(deserializer)? {
        serde_json::Value::Null => Ok(0),
        serde_json::Value::String(text) => Ok(parse_decimal(&text).unwrap_or(0)),
        serde_json::Value::Number(number) => number
            .as_u64()
            .ok_or_else(|| D::Error::custom("closed_at_ms is not an unsigned integer")),
        _ => Err(D::Error::custom("closed_at_ms is neither a string nor a number")),
    }
}

/// `UInt64(text, radix: 10)`: an optional sign, then only ASCII digits, within range; a minus
/// sign only before a zero value (`-0` is 0, `-1` does not parse).
pub fn parse_decimal(text: &str) -> Option<u64> {
    let (negative, digits) = if let Some(digits) = text.strip_prefix('+') {
        (false, digits)
    } else if let Some(digits) = text.strip_prefix('-') {
        (true, digits)
    } else {
        (false, text)
    };
    if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let value: u64 = digits.parse().ok()?;
    (!negative || value == 0).then_some(value)
}

fn null_false<'de, D: Deserializer<'de>>(deserializer: D) -> Result<bool, D::Error> {
    Ok(Option::<bool>::deserialize(deserializer)?.unwrap_or(false))
}

fn null_zero_i64<'de, D: Deserializer<'de>>(deserializer: D) -> Result<i64, D::Error> {
    Ok(Option::<i64>::deserialize(deserializer)?.unwrap_or(0))
}

fn null_vec<'de, D: Deserializer<'de>, T: Deserialize<'de>>(
    deserializer: D,
) -> Result<Vec<T>, D::Error> {
    Ok(Option::<Vec<T>>::deserialize(deserializer)?.unwrap_or_default())
}
