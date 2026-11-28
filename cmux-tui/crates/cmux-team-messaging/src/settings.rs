//! What the daemon's customization and `Open in cmux` RPCs answer (RFD 0170 phase 4): the stored
//! team and person [`Customization`]s, the bound Slack threads, and the typed, bounded views a
//! settings page or a Slack card renders as they are.
//!
//! Every rule is here, so a view only draws what it is given:
//!
//! - only a person writes; an agent reads its own view and never changes one;
//! - a person writes their own choices in a team they are a member of, and the team's choices only
//!   when [`Team::admins`] names them;
//! - a stored choice is checked against fixed bounds before it is kept, and the whole store is
//!   bounded ([`MAX_TEAMS`], [`MAX_PEOPLE_PER_TEAM`], [`MAX_BINDINGS`]);
//! - nothing here changes a [`Team`], a [`Space`] or a [`Principal`]: the view orders, labels and
//!   suggests over what [`effective`] already allows, so customization never grants access or wake.
//!
//! The handoff names a thread; whether the viewer may read it is still [`effective`]'s answer
//! ([`HandoffView::readable`]).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::customization::{Customization, Effective, LABEL_MAX, resolve};
use crate::delivery::DeliveryMode;
use crate::handoff::{BindError, Handoff, HandoffIndex, Projection, SlackMessage};
use crate::identity::PrincipalKind;
use crate::model::{Notify, Principal, Space, Team, Thread};
use crate::permission::{Capability, effective};
use crate::refs::{RefKey, RefKind, RefSource};

/// Teams the store keeps choices for.
pub const MAX_TEAMS: usize = 64;
/// People per team the store keeps choices for.
pub const MAX_PEOPLE_PER_TEAM: usize = 256;
/// Slack thread bindings kept.
pub const MAX_BINDINGS: usize = 4096;
/// Pinned spaces in one choice.
pub const MAX_PINS: usize = 64;
/// Agent labels in one choice.
pub const MAX_LABELS: usize = 256;
/// Templates in one choice.
pub const MAX_TEMPLATES: usize = 32;
/// Fields or ref kinds one template adds.
pub const MAX_TEMPLATE_PARTS: usize = 16;
/// The longest id (space, agent, template, field) a choice names, in bytes.
pub const MAX_ID: usize = 128;
/// The longest template title, in characters.
pub const MAX_TITLE: usize = 120;
/// Space rows one view returns.
pub const MAX_VIEW_SPACES: usize = 256;
/// Agent rows one view returns.
pub const MAX_VIEW_AGENTS: usize = 256;

/// Whose choices a write sets.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Scope {
    Team,
    Person,
}

/// Why a write or a handoff was refused.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SettingsError {
    /// Agents read; only a person writes.
    PersonOnly,
    /// The writer is not a member of the team.
    NotMember,
    /// The team's choices are its admins' to set.
    NotAdmin,
    /// A choice is past one of the bounds above.
    TooLarge(&'static str),
    /// An id is empty, too long or has a control character.
    BadId(&'static str),
    /// The store holds as many teams, people or bindings as it keeps.
    StoreFull(&'static str),
    Bind(BindError),
}

impl SettingsError {
    /// A stable reason for an RPC error's data.
    pub fn reason(&self) -> &'static str {
        match self {
            Self::PersonOnly => "customization_person_only",
            Self::NotMember => "customization_not_member",
            Self::NotAdmin => "customization_not_admin",
            Self::TooLarge(_) => "customization_too_large",
            Self::BadId(_) => "customization_bad_id",
            Self::StoreFull(_) => "customization_store_full",
            Self::Bind(_) => "handoff_bind_refused",
        }
    }
}

impl std::fmt::Display for SettingsError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::PersonOnly => write!(f, "only a person changes customization; agents read it"),
            Self::NotMember => write!(f, "not a member of this team"),
            Self::NotAdmin => write!(f, "the team's choices are set by its admins"),
            Self::TooLarge(what) => write!(f, "too many {what}"),
            Self::BadId(what) => write!(f, "a {what} id is empty, too long or not plain text"),
            Self::StoreFull(what) => write!(f, "the store keeps no more {what}"),
            Self::Bind(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for SettingsError {}

impl From<BindError> for SettingsError {
    fn from(e: BindError) -> Self {
        Self::Bind(e)
    }
}

/// One Slack thread bound to its forum thread, as the store keeps it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Binding {
    pub slack: RefKey,
    pub thread: RefKey,
}

/// What the daemon keeps: each team's and each person's choices, and the Slack bindings.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsStore {
    #[serde(default)]
    team: BTreeMap<String, Customization>,
    /// Team id, then person id.
    #[serde(default)]
    person: BTreeMap<String, BTreeMap<String, Customization>>,
    #[serde(default)]
    bindings: Vec<Binding>,
    #[serde(skip)]
    index: Option<HandoffIndex>,
}

impl SettingsStore {
    /// A store read back from its saved form: bindings past the bound, or ones that no longer bind
    /// one to one, are dropped rather than refused, so a bad file never stops the daemon.
    pub fn restored(mut self) -> Self {
        let mut index = HandoffIndex::new();
        let mut kept = Vec::new();
        for b in std::mem::take(&mut self.bindings).into_iter().take(MAX_BINDINGS) {
            if index.bind(b.slack.clone(), b.thread.clone()).is_ok() && !kept.contains(&b) {
                kept.push(b);
            }
        }
        self.bindings = kept;
        self.index = Some(index);
        self.team.retain(|_, c| check(c).is_ok());
        for people in self.person.values_mut() {
            people.retain(|_, c| check(c).is_ok());
        }
        self
    }

    fn index(&mut self) -> &mut HandoffIndex {
        let bindings = &self.bindings;
        self.index.get_or_insert_with(|| {
            let mut index = HandoffIndex::new();
            for b in bindings {
                let _ = index.bind(b.slack.clone(), b.thread.clone());
            }
            index
        })
    }

    pub fn team_choice(&self, team_id: &str) -> Option<&Customization> {
        self.team.get(team_id)
    }

    pub fn person_choice(&self, team_id: &str, person_id: &str) -> Option<&Customization> {
        self.person.get(team_id).and_then(|p| p.get(person_id))
    }

    /// Set `scope`'s choices in `team` as `writer`, or refuse. An empty choice clears it.
    pub fn set(
        &mut self,
        writer: &Principal,
        team: &Team,
        scope: Scope,
        choice: Customization,
    ) -> Result<(), SettingsError> {
        if writer.kind != PrincipalKind::Person {
            return Err(SettingsError::PersonOnly);
        }
        if !team.members.iter().any(|m| m == &writer.id) {
            return Err(SettingsError::NotMember);
        }
        if scope == Scope::Team && !team.admins.iter().any(|a| a == &writer.id) {
            return Err(SettingsError::NotAdmin);
        }
        check(&choice)?;
        let clear = choice == Customization::default();
        let known_team = self.team.contains_key(&team.id) || self.person.contains_key(&team.id);
        if !clear && !known_team && self.teams() >= MAX_TEAMS {
            return Err(SettingsError::StoreFull("teams"));
        }
        match scope {
            Scope::Team if clear => {
                self.team.remove(&team.id);
            }
            Scope::Team => {
                self.team.insert(team.id.clone(), choice);
            }
            Scope::Person => {
                let people = self.person.entry(team.id.clone()).or_default();
                if clear {
                    people.remove(&writer.id);
                } else {
                    if !people.contains_key(&writer.id) && people.len() >= MAX_PEOPLE_PER_TEAM {
                        return Err(SettingsError::StoreFull("people in this team"));
                    }
                    people.insert(writer.id.clone(), choice);
                }
                if people.is_empty() {
                    self.person.remove(&team.id);
                }
            }
        }
        Ok(())
    }

    fn teams(&self) -> usize {
        self.team.keys().chain(self.person.keys().filter(|k| !self.team.contains_key(*k))).count()
    }

    /// Where a Slack root or reply opens in cmux, and whether `viewer` may read it there.
    pub fn handoff(
        &mut self,
        viewer: &Principal,
        cx: &ViewContext<'_>,
        message: &SlackMessage,
    ) -> HandoffView {
        let handoff = self.index().resolve(message);
        let readable = match &handoff {
            Handoff::Open { thread, .. } => Some(cx.can_read_thread(viewer, thread)),
            _ => None,
        };
        HandoffView { handoff, readable }
    }

    /// Bind a Slack thread to its forum thread, as a person who can read that thread.
    pub fn bind(
        &mut self,
        writer: &Principal,
        cx: &ViewContext<'_>,
        slack: RefKey,
        thread: RefKey,
    ) -> Result<(), SettingsError> {
        if writer.kind != PrincipalKind::Person {
            return Err(SettingsError::PersonOnly);
        }
        if !cx.can_read_thread(writer, &thread) {
            return Err(SettingsError::NotMember);
        }
        let new = self.index().slack_for(&thread).is_none();
        if new && self.bindings.len() >= MAX_BINDINGS {
            return Err(SettingsError::StoreFull("Slack bindings"));
        }
        self.index().bind(slack.clone(), thread.clone())?;
        if new {
            self.bindings.push(Binding { slack, thread });
        }
        Ok(())
    }

    /// How a cmux reply in `thread` goes to its Slack thread, if it has one.
    pub fn project(&mut self, thread: &RefKey, message_id: &str) -> Option<Projection> {
        self.index().project(thread, message_id)
    }

    pub fn bindings(&self) -> &[Binding] {
        &self.bindings
    }
}

/// A choice within the bounds, every id plain.
pub fn check(c: &Customization) -> Result<(), SettingsError> {
    if c.spaces_first.len() > MAX_PINS {
        return Err(SettingsError::TooLarge("pinned spaces"));
    }
    if c.agent_labels.len() > MAX_LABELS {
        return Err(SettingsError::TooLarge("agent labels"));
    }
    if c.templates.len() > MAX_TEMPLATES {
        return Err(SettingsError::TooLarge("templates"));
    }
    if c.sections.as_ref().is_some_and(|s| s.len() > crate::customization::Section::ALL.len() * 2) {
        return Err(SettingsError::TooLarge("sections"));
    }
    for id in &c.spaces_first {
        plain(id, "space")?;
    }
    for (agent, label) in &c.agent_labels {
        plain(agent, "agent")?;
        if label.chars().count() > LABEL_MAX * 4 {
            return Err(SettingsError::TooLarge("characters in an agent label"));
        }
    }
    for t in &c.templates {
        plain(&t.id, "template")?;
        if t.title.chars().count() > MAX_TITLE {
            return Err(SettingsError::TooLarge("characters in a template title"));
        }
        if t.fields.len() > MAX_TEMPLATE_PARTS || t.refs.len() > MAX_TEMPLATE_PARTS {
            return Err(SettingsError::TooLarge("template fields or refs"));
        }
        for f in &t.fields {
            plain(f, "field")?;
        }
    }
    Ok(())
}

fn plain(id: &str, what: &'static str) -> Result<(), SettingsError> {
    if id.trim().is_empty() || id.len() > MAX_ID || id.chars().any(char::is_control) {
        return Err(SettingsError::BadId(what));
    }
    Ok(())
}

/// The records a view reads, borrowed from the published team directory.
pub struct ViewContext<'a> {
    pub team: &'a Team,
    pub spaces: &'a [Space],
    pub principals: &'a [Principal],
    pub threads: &'a [Thread],
}

impl ViewContext<'_> {
    fn principal(&self, id: &str) -> Option<&Principal> {
        self.principals.iter().find(|p| p.id == id)
    }

    fn can_read(&self, viewer: &Principal, space: &Space) -> bool {
        let owner = viewer.owner_person_id.as_deref().and_then(|o| self.principal(o));
        effective(viewer, owner, self.team, space).has(Capability::Read)
    }

    /// Whether `viewer` may read the cmux thread `thread` names: [`effective`]'s `read` in its space.
    pub fn can_read_thread(&self, viewer: &Principal, thread: &RefKey) -> bool {
        if thread.kind != RefKind::Thread || thread.source != RefSource::Cmux {
            return false;
        }
        let Some(t) = self.threads.iter().find(|t| t.id == thread.id) else { return false };
        self.spaces.iter().find(|s| s.id == t.space_id).is_some_and(|s| self.can_read(viewer, s))
    }
}

/// One space as the settings page lists it, in the viewer's order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpaceRow {
    pub id: String,
    pub title: String,
    pub pinned: bool,
    pub notify: Notify,
}

/// One agent as the settings page lists it: its handle, the label shown beside it, and the composer
/// mode it suggests in the team's first space the agent is in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentRow {
    pub id: String,
    pub handle: String,
    pub shown_as: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    pub compose_mode: DeliveryMode,
}

/// The customization page for one viewer in one team.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomizationView {
    pub team_id: String,
    /// The choices in force: the person's over the team's over the defaults.
    pub effective: Effective,
    /// The team's own choices, as stored.
    pub team: Customization,
    /// The viewer's own choices, as stored; none for an agent.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub person: Option<Customization>,
    /// The spaces the viewer can read, pinned first.
    pub spaces: Vec<SpaceRow>,
    pub agents: Vec<AgentRow>,
    /// Whether the viewer may set their own choices (a person member).
    pub can_edit_person: bool,
    /// Whether the viewer may set the team's choices (an admin).
    pub can_edit_team: bool,
    /// Rows past the bounds that were left out.
    pub truncated: bool,
}

/// The viewer's customization page, or None when the viewer is not in the team.
pub fn view(
    store: &SettingsStore,
    viewer: &Principal,
    cx: &ViewContext<'_>,
) -> Option<CustomizationView> {
    let team = cx.team;
    if !team.members.iter().any(|m| m == &viewer.id) {
        return None;
    }
    let person_id = match viewer.kind {
        PrincipalKind::Person => Some(viewer.id.as_str()),
        PrincipalKind::Agent => viewer.owner_person_id.as_deref(),
    };
    let team_choice = store.team_choice(&team.id).cloned().unwrap_or_default();
    let person_choice = person_id.and_then(|p| store.person_choice(&team.id, p));
    let eff = resolve(&team_choice, person_choice);

    let readable: Vec<Space> = cx
        .spaces
        .iter()
        .filter(|s| s.team_id == team.id && cx.can_read(viewer, s))
        .cloned()
        .collect();
    let ordered = eff.order_spaces(&readable);
    let mut truncated = ordered.len() > MAX_VIEW_SPACES;
    let notify_id = person_id.unwrap_or(viewer.id.as_str());
    let spaces: Vec<SpaceRow> = ordered
        .iter()
        .take(MAX_VIEW_SPACES)
        .map(|s| SpaceRow {
            id: s.id.clone(),
            title: s.title.clone(),
            pinned: eff.spaces_first.contains(&s.id),
            notify: eff.notify_for(s, notify_id),
        })
        .collect();

    // Each member's first space in the viewer's order, in one pass over the members.
    let mut first: BTreeMap<&str, &Space> = BTreeMap::new();
    for s in &ordered {
        for m in &s.members {
            first.entry(m.as_str()).or_insert(*s);
        }
    }
    let mut agents = Vec::new();
    for p in cx.principals.iter().filter(|p| p.kind == PrincipalKind::Agent) {
        let Some(space) = first.get(p.id.as_str()).copied() else { continue };
        if agents.len() == MAX_VIEW_AGENTS {
            truncated = true;
            break;
        }
        agents.push(AgentRow {
            id: p.id.clone(),
            handle: p.handle.clone(),
            shown_as: eff.display_name(p),
            label: eff.agent_labels.get(&p.id).cloned(),
            compose_mode: eff.compose_mode(space, p),
        });
    }

    let is_person = viewer.kind == PrincipalKind::Person;
    Some(CustomizationView {
        team_id: team.id.clone(),
        effective: eff,
        team: team_choice,
        person: if is_person { Some(person_choice.cloned().unwrap_or_default()) } else { None },
        spaces,
        agents,
        can_edit_person: is_person,
        can_edit_team: is_person && team.admins.iter().any(|a| a == &viewer.id),
        truncated,
    })
}

/// What `Open in cmux` answers for one Slack message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HandoffView {
    #[serde(flatten)]
    pub handoff: Handoff,
    /// For an open: whether the viewer may read the thread. The handoff never grants it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub readable: Option<bool>,
}
