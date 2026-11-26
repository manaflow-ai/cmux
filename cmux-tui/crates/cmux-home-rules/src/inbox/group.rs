//! The group info sheet (`HomeGroupInfo`, `HomeGroupInfoModel`) as a step: drafts, the people
//! chosen to add, and which action runs. Swift runs the actions and words the outcomes.

use super::model::{Contact, standard_contains};
use serde::{Deserialize, Serialize};

/// `HomeGroupInfo`'s defaults and its members header.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InfoFlags {
    pub can_add_people: bool,
    pub can_rename: bool,
    /// `membersHeader`: `None` reads "Members", else the count's words.
    pub members_header_count: Option<i64>,
}

/// `HomeGroupInfo.init`'s `canAddPeople ?? isGroup`, `canRename ?? isGroup`.
pub fn info_flags(
    is_group: bool,
    can_add_people: Option<bool>,
    can_rename: Option<bool>,
    member_count: Option<i64>,
) -> InfoFlags {
    InfoFlags {
        can_add_people: can_add_people.unwrap_or(is_group),
        can_rename: can_rename.unwrap_or(is_group),
        members_header_count: member_count,
    }
}

/// The action running (`work`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Running {
    Rename,
    Add,
    ChiefReplies,
    Remove,
}

/// `HomeGroupInfoModel`'s state.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Sheet {
    /// `info.title`.
    pub title: String,
    /// `info.chiefReplies` (a `ChiefReplyPolicy` raw value).
    pub chief_replies: Option<String>,
    pub addable: Vec<Contact>,
    pub name_draft: String,
    /// `outcome.message`.
    pub status: Option<String>,
    pub offers_invite: bool,
    pub running: Option<Running>,
    pub is_adding: bool,
    pub search: String,
    pub chosen: Vec<String>,
}

impl Sheet {
    /// `HomeGroupInfoModel.init`.
    pub fn new(title: &str, chief_replies: Option<String>, addable: Vec<Contact>) -> Self {
        Self {
            title: title.to_owned(),
            chief_replies,
            addable,
            name_draft: title.to_owned(),
            ..Self::default()
        }
    }

    pub fn is_running(&self) -> bool {
        self.running.is_some()
    }

    /// `shownAddable`.
    pub fn shown_addable(&self) -> Vec<Contact> {
        let query = self.search.trim_matches([' ', '\t']);
        if query.is_empty() {
            return self.addable.clone();
        }
        self.addable.iter().filter(|c| standard_contains(&c.name, query)).cloned().collect()
    }

    /// `canRename`.
    pub fn can_rename(&self) -> bool {
        !self.is_running() && self.name_draft.trim() != self.title
    }
}

/// A finished action's outcome (`HomeGroupOutcome`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Outcome {
    pub succeeded: bool,
    pub message: Option<String>,
    pub not_reachable: bool,
}

/// What the person did, or what came back.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Event {
    #[serde(rename_all = "camelCase")]
    Update {
        title: String,
        chief_replies: Option<String>,
        addable: Vec<Contact>,
    },
    SetDraft {
        text: String,
    },
    SetSearch {
        text: String,
    },
    SetAdding {
        on: bool,
    },
    Toggle {
        id: String,
    },
    Rename,
    AddChosen,
    SetChiefReplies {
        policy: String,
    },
    Remove {
        id: String,
    },
    /// `setMuted`'s synchronous outcome.
    Muted {
        outcome: Outcome,
    },
    /// The running action finished (not cancelled).
    Finished {
        outcome: Outcome,
    },
}

/// What Swift runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Effect {
    Rename { name: String },
    Add { people: Vec<String>, names: String },
    SetChiefReplies { policy: String },
    Remove { id: String },
}

fn show(sheet: &mut Sheet, outcome: &Outcome) {
    sheet.status = outcome.message.clone();
    sheet.offers_invite = outcome.not_reachable;
}

fn run(sheet: &mut Sheet, running: Running, effect: Effect) -> Vec<Effect> {
    if sheet.is_running() {
        return Vec::new();
    }
    sheet.running = Some(running);
    sheet.status = None;
    sheet.offers_invite = false;
    vec![effect]
}

/// One step of the sheet.
pub fn step(sheet: &mut Sheet, event: &Event) -> Vec<Effect> {
    match event {
        Event::Update { title, chief_replies, addable } => {
            if sheet.name_draft == sheet.title {
                sheet.name_draft = title.clone();
            }
            sheet.title = title.clone();
            sheet.chief_replies = chief_replies.clone();
            sheet.addable = addable.clone();
            sheet.chosen.retain(|id| addable.iter().any(|c| &c.id == id));
            Vec::new()
        }
        Event::SetDraft { text } => {
            sheet.name_draft = text.clone();
            Vec::new()
        }
        Event::SetSearch { text } => {
            sheet.search = text.clone();
            Vec::new()
        }
        Event::SetAdding { on } => {
            sheet.is_adding = *on;
            Vec::new()
        }
        Event::Toggle { id } => {
            if let Some(at) = sheet.chosen.iter().position(|c| c == id) {
                sheet.chosen.remove(at);
            } else {
                sheet.chosen.push(id.clone());
            }
            Vec::new()
        }
        Event::Rename => {
            if !sheet.can_rename() {
                return Vec::new();
            }
            let name = sheet.name_draft.clone();
            run(sheet, Running::Rename, Effect::Rename { name })
        }
        Event::AddChosen => {
            let people = sheet.chosen.clone();
            let names = sheet
                .addable
                .iter()
                .filter(|c| people.contains(&c.id))
                .map(|c| c.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            run(sheet, Running::Add, Effect::Add { people, names })
        }
        Event::SetChiefReplies { policy } => {
            if sheet.chief_replies.as_deref() == Some(policy.as_str()) {
                return Vec::new();
            }
            run(sheet, Running::ChiefReplies, Effect::SetChiefReplies { policy: policy.clone() })
        }
        Event::Remove { id } => run(sheet, Running::Remove, Effect::Remove { id: id.clone() }),
        Event::Muted { outcome } => {
            show(sheet, outcome);
            Vec::new()
        }
        Event::Finished { outcome } => {
            if sheet.running.take() == Some(Running::Add) && outcome.succeeded {
                sheet.chosen.clear();
                sheet.is_adding = false;
                sheet.search.clear();
            }
            show(sheet, outcome);
            Vec::new()
        }
    }
}
