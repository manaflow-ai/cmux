//! Team and person customization (RFD 0170 "Customization" and phase 4).
//!
//! A team admin chooses which spaces appear first, the Session Info sections and their order, the
//! notification and composer defaults, agent display labels and the team's templates. A person may
//! make the same choices for themself, and a person's choice wins over the team's. The state follows
//! RFD 0038 and RFD 0103 (a customization is display data scoped to a team or a person, stored with
//! the team as [`crate::model::Team::customization`]) and it holds no grants:
//!
//! - [`Effective::order_spaces`] only reorders the spaces it is given, so pinning a space the viewer
//!   cannot read never shows it to them;
//! - [`Effective::compose_mode`] suggests `wake` only where the agent's owner granted wake in that
//!   space ([`crate::permission::wake_allowed`]); anything else falls back to `ask`;
//! - an agent label is shown beside the agent's `@handle`, never instead of it, and never on a person.
//!
//! Nothing here reads [`crate::permission::effective`]'s inputs, so customization cannot change
//! what a principal may do.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::delivery::DeliveryMode;
use crate::identity::PrincipalKind;
use crate::knowledge::{Template, TemplateDraft};
use crate::model::{Notify, Principal, Space};
use crate::permission::wake_allowed;
use crate::refs::RefKind;

/// The longest agent label kept, in characters.
pub const LABEL_MAX: usize = 40;

/// A Session Info section, in the order RFD 0170 lists them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Section {
    Team,
    People,
    Agents,
    Threads,
    Rfds,
    Ask,
    Feedback,
    Actions,
}

impl Section {
    pub const ALL: [Section; 8] = [
        Self::Team,
        Self::People,
        Self::Agents,
        Self::Threads,
        Self::Rfds,
        Self::Ask,
        Self::Feedback,
        Self::Actions,
    ];
}

/// A team's own template: a built-in [`Template`] plus the fields and refs the team asks for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamTemplate {
    pub id: String,
    pub title: String,
    /// The built-in it extends; its own required fields and refs still apply.
    pub base: Template,
    /// Fields the team adds, besides the base's.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fields: Vec<String>,
    /// Ref kinds of which the draft must carry at least one, besides the base's.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub refs: Vec<RefKind>,
}

/// What a draft lacks for a team template.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TeamTemplateError {
    /// The draft uses another built-in than the template extends.
    WrongBase {
        expected: Template,
        got: Template,
    },
    MissingField(String),
    MissingRef(Vec<RefKind>),
}

impl std::fmt::Display for TeamTemplateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::WrongBase { expected, got } => write!(
                f,
                "this template is a {}, not a {}",
                expected.root_kind().as_str(),
                got.root_kind().as_str()
            ),
            Self::MissingField(field) => write!(f, "this template needs {field}"),
            Self::MissingRef(kinds) => {
                let k: Vec<&str> = kinds.iter().map(|k| k.as_str()).collect();
                write!(f, "this template links one of {}", k.join(", "))
            }
        }
    }
}

impl std::error::Error for TeamTemplateError {}

impl TeamTemplate {
    /// The regression template RFD 0170 names for teams: a finding with the last good and first bad
    /// build, and the PR or issue it is tracked on.
    pub fn regression() -> Self {
        Self {
            id: "regression".to_owned(),
            title: "Regression".to_owned(),
            base: Template::Finding,
            fields: vec!["lastGood".to_owned(), "firstBad".to_owned()],
            refs: vec![RefKind::Pr, RefKind::Issue, RefKind::Thread],
        }
    }

    /// Check what this template adds. The base's own checks run when the draft is built
    /// ([`crate::knowledge`]).
    pub fn check(&self, draft: &TemplateDraft) -> Result<(), TeamTemplateError> {
        if draft.template != self.base {
            return Err(TeamTemplateError::WrongBase { expected: self.base, got: draft.template });
        }
        for field in &self.fields {
            if draft.fields.get(field).is_none_or(|v| v.trim().is_empty()) {
                return Err(TeamTemplateError::MissingField(field.clone()));
            }
        }
        if !self.refs.is_empty() && !draft.refs.iter().any(|r| self.refs.contains(&r.key.kind)) {
            return Err(TeamTemplateError::MissingRef(self.refs.clone()));
        }
        Ok(())
    }
}

/// One scope's choices, a team's or a person's. Every field unset means "no choice here".
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Customization {
    /// Space ids shown first, in this order.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub spaces_first: Vec<String>,
    /// Session Info sections, in order. Unset or empty shows them all.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sections: Option<Vec<Section>>,
    /// How a person hears about a space they have not set ([`Space::notification_policy`] wins).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<Notify>,
    /// The composer's suggested mode toward an agent. `wake` only holds where wake is granted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compose_mode: Option<DeliveryMode>,
    /// Agent id to the label shown beside its handle.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub agent_labels: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub templates: Vec<TeamTemplate>,
}

/// The choices in force for one person in one team.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Effective {
    pub spaces_first: Vec<String>,
    pub sections: Vec<Section>,
    pub notify: Notify,
    pub compose_mode: DeliveryMode,
    pub agent_labels: BTreeMap<String, String>,
    /// The regression preset, then the team's, then the person's; a later id replaces an earlier one.
    pub templates: Vec<TeamTemplate>,
}

/// The person's choices over the team's, over the defaults.
pub fn resolve(team: &Customization, person: Option<&Customization>) -> Effective {
    let empty = Customization::default();
    let person = person.unwrap_or(&empty);

    let pins =
        if person.spaces_first.is_empty() { &team.spaces_first } else { &person.spaces_first };
    let mut spaces_first: Vec<String> = Vec::new();
    for id in pins {
        if !spaces_first.contains(id) {
            spaces_first.push(id.clone());
        }
    }

    let chosen = [person.sections.as_ref(), team.sections.as_ref()]
        .into_iter()
        .flatten()
        .find(|s| !s.is_empty());
    let mut sections: Vec<Section> = Vec::new();
    for s in chosen.map_or(&Section::ALL[..], |v| &v[..]) {
        if !sections.contains(s) {
            sections.push(*s);
        }
    }

    let mut agent_labels = BTreeMap::new();
    for (agent, label) in team.agent_labels.iter().chain(&person.agent_labels) {
        match clean_label(label) {
            Some(l) => agent_labels.insert(agent.clone(), l),
            None => agent_labels.remove(agent),
        };
    }

    let mut templates: Vec<TeamTemplate> = Vec::new();
    let all = std::iter::once(TeamTemplate::regression())
        .chain(team.templates.iter().cloned())
        .chain(person.templates.iter().cloned());
    for t in all {
        if t.id.trim().is_empty() {
            continue;
        }
        match templates.iter_mut().find(|e| e.id == t.id) {
            Some(existing) => *existing = t,
            None => templates.push(t),
        }
    }

    Effective {
        spaces_first,
        sections,
        notify: person.notify.or(team.notify).unwrap_or_default(),
        compose_mode: person.compose_mode.or(team.compose_mode).unwrap_or_default(),
        agent_labels,
        templates,
    }
}

/// Trimmed, control characters dropped, at most [`LABEL_MAX`] characters; empty is no label.
fn clean_label(label: &str) -> Option<String> {
    let cleaned: String = label
        .chars()
        .filter(|c| !c.is_control())
        .collect::<String>()
        .trim()
        .chars()
        .take(LABEL_MAX)
        .collect();
    let cleaned = cleaned.trim_end().to_owned();
    (!cleaned.is_empty()).then_some(cleaned)
}

impl Effective {
    /// `visible` reordered: pinned spaces first in pin order, then the rest as given. Only spaces in
    /// `visible` come back, so a pin never reaches a space the viewer cannot read.
    pub fn order_spaces<'a>(&self, visible: &'a [Space]) -> Vec<&'a Space> {
        let mut out: Vec<&Space> = Vec::with_capacity(visible.len());
        let pinned =
            self.spaces_first.iter().filter_map(|pin| visible.iter().find(|s| &s.id == pin));
        for s in pinned.chain(visible) {
            if !out.iter().any(|o| std::ptr::eq(*o, s)) {
                out.push(s);
            }
        }
        out
    }

    /// How `person_id` hears about `space`: their own setting there, else this default.
    pub fn notify_for(&self, space: &Space, person_id: &str) -> Notify {
        space.notification_policy.get(person_id).copied().unwrap_or(self.notify)
    }

    /// The mode the composer suggests toward `agent` in `space`: the owner's per-space default if they
    /// set one, else this default. `wake` holds only where [`wake_allowed`]; otherwise it is `ask`.
    pub fn compose_mode(&self, space: &Space, agent: &Principal) -> DeliveryMode {
        let owner_choice = space.agent_policy.get(&agent.id).filter(|g| {
            agent.owner_person_id.as_deref().is_some_and(|owner| owner == g.granted_by)
        });
        let mode = owner_choice.map_or(self.compose_mode, |g| g.default_mode);
        if mode == DeliveryMode::Wake && !wake_allowed(space, agent) {
            DeliveryMode::Ask
        } else {
            mode
        }
    }

    /// What to show for `p`: an agent's label beside its handle (`Label (@handle)`), or its display
    /// name. A label never applies to a person.
    pub fn display_name(&self, p: &Principal) -> String {
        match (p.kind, self.agent_labels.get(&p.id)) {
            (PrincipalKind::Agent, Some(label)) => format!("{label} (@{})", p.handle),
            _ => p.display_name.clone(),
        }
    }

    pub fn template(&self, id: &str) -> Option<&TeamTemplate> {
        self.templates.iter().find(|t| t.id == id)
    }
}
