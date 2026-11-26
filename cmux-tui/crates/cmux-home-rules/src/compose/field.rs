//! The To field's behaviour (`HomeRecipientField`) and its suggestion list's rules
//! (`HomeRecipientSuggestionsView`, `HomeRecipientSuggestion`): which rows show, the highlight, keys,
//! typing, and the detail line that tells alike rows apart.

use super::text::{Address, AddressKind, trim_separators};
use super::types::{Contact, Draft, Recipient, Source};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The section a header names; the app words it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Section {
    Chiefs,
    Team,
}

/// One row of the suggestion list (`HomeRecipientSuggestion`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SuggestionRow {
    Header { section: Section },
    Recipient { recipient: Recipient },
    NewChief,
    Invite,
    InviteToTeam { address: Address, team: String },
}

impl SuggestionRow {
    pub fn is_selectable(&self) -> bool {
        !matches!(self, SuggestionRow::Header { .. })
    }
}

/// The suggestion list as the field drives it.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ListState {
    pub rows: Vec<SuggestionRow>,
    pub highlighted: Option<usize>,
    /// The "no contacts" line shows (browsing with nobody to offer).
    pub shows_empty_text: bool,
    pub hidden: bool,
}

impl ListState {
    /// `show(rows:empty:highlightFirst:)`.
    pub fn show(rows: Vec<SuggestionRow>, empty_text: bool, highlight_first: bool) -> Self {
        let highlighted =
            if highlight_first { rows.iter().position(SuggestionRow::is_selectable) } else { None };
        let shows_empty_text = empty_text && rows.is_empty();
        let hidden = rows.is_empty() && !empty_text;
        ListState { rows, highlighted, shows_empty_text, hidden }
    }

    /// `move(_:)`: up or down over the selectable rows, clamped at the ends.
    pub fn moved(&mut self, offset: i64) {
        let pickable: Vec<usize> = self
            .rows
            .iter()
            .enumerate()
            .filter(|(_, row)| row.is_selectable())
            .map(|(i, _)| i)
            .collect();
        if pickable.is_empty() {
            return;
        }
        let at = self
            .highlighted
            .and_then(|h| pickable.iter().position(|&i| i == h))
            .map_or(-1, |p| p as i64);
        let next = (at + offset).clamp(0, pickable.len() as i64 - 1) as usize;
        self.highlighted = Some(pickable[next]);
    }

    pub fn highlighted_row(&self) -> Option<&SuggestionRow> {
        self.highlighted.and_then(|h| self.rows.get(h))
    }
}

/// `idleRows()`: with nothing typed, the Chiefs (and New Chief), then the team (or Invite).
pub fn idle_rows(
    draft: &Draft,
    contacts: &[Contact],
    has_new_chief: bool,
    has_invite: bool,
    chief_limit: usize,
) -> Vec<SuggestionRow> {
    let offered = draft.idle_suggestions(contacts, chief_limit);
    let (chiefs, team): (Vec<Contact>, Vec<Contact>) =
        offered.into_iter().partition(|c| c.source == Source::Agent);
    let mut rows = Vec::new();
    if !chiefs.is_empty() || has_new_chief {
        rows.push(SuggestionRow::Header { section: Section::Chiefs });
        rows.extend(
            chiefs.iter().map(|c| SuggestionRow::Recipient { recipient: Recipient::contact(c) }),
        );
        if has_new_chief {
            rows.push(SuggestionRow::NewChief);
        }
    }
    if !team.is_empty() || has_invite {
        rows.push(SuggestionRow::Header { section: Section::Team });
        if team.is_empty() {
            rows.push(SuggestionRow::Invite);
        } else {
            rows.extend(
                team.iter().map(|c| SuggestionRow::Recipient { recipient: Recipient::contact(c) }),
            );
        }
    }
    rows
}

/// `typedRows()`: the draft's matches; with a team to invite to, "Invite to team" right after the
/// first typed email.
pub fn typed_rows(
    draft: &Draft,
    contacts: &[Contact],
    invite_team: Option<&str>,
) -> Vec<SuggestionRow> {
    let matches = draft.suggestions(contacts, 8);
    let email = matches.iter().find_map(|r| match r {
        Recipient::Address { address } if address.is_email() => Some(address.clone()),
        _ => None,
    });
    let mut rows: Vec<SuggestionRow> =
        matches.into_iter().map(|recipient| SuggestionRow::Recipient { recipient }).collect();
    if let (Some(team), Some(address)) = (invite_team, email) {
        let row =
            SuggestionRow::Recipient { recipient: Recipient::Address { address: address.clone() } };
        let at = rows.iter().position(|r| *r == row).map_or(rows.len(), |i| i + 1);
        rows.insert(at, SuggestionRow::InviteToTeam { address, team: team.to_owned() });
    }
    rows
}

/// `browse()`: every contact not yet chosen.
pub fn browse_rows(draft: &Draft, contacts: &[Contact]) -> Vec<SuggestionRow> {
    let chosen = draft.recipients();
    contacts
        .iter()
        .map(Recipient::contact)
        .filter(|r| !chosen.contains(r))
        .map(|recipient| SuggestionRow::Recipient { recipient })
        .collect()
}

// MARK: The field's state machine

/// The To field between events.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FieldState {
    pub draft: Draft,
    /// The text field's value (`text.stringValue`).
    pub text: String,
    pub browsing: bool,
    pub selected_token: Option<usize>,
    pub list: ListState,
}

/// What the field knows besides its state.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FieldContext {
    pub contacts: Vec<Contact>,
    /// `onNewChief` is set.
    pub has_new_chief: bool,
    /// `onInvite` is set.
    pub has_invite: bool,
    /// The team "Invite to team" names; set only when `onInviteToTeam` is and a team is active.
    pub invite_team: Option<String>,
    pub chief_limit: Option<usize>,
}

/// A key the field's text view passes on (`doCommandBy`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Key {
    Newline,
    Tab,
    DeleteBackward,
    DeleteForward,
    MoveDown,
    MoveUp,
    Cancel,
    #[serde(other)]
    Other,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "event", rename_all = "camelCase")]
pub enum FieldEvent {
    Key {
        key: Key,
    },
    TextChanged {
        value: String,
    },
    Choose {
        recipient: Recipient,
    },
    /// A click or Return on list row `index`.
    Activate {
        index: usize,
    },
    RemoveToken {
        index: usize,
    },
    SelectToken {
        index: usize,
    },
    Browse,
    SetDraft {
        draft: Draft,
    },
    Refresh,
    Commit {
        #[serde(default)]
        pick: bool,
    },
}

/// What the app does after a step.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum FieldEffect {
    /// `onChange(draft)`.
    Changed,
    /// `onDone()`: Return or Tab with nothing to commit.
    Done,
    /// `onEscape()`.
    Escape,
    NewChief,
    Invite,
    InviteToTeam {
        address: Address,
    },
    /// Focus the text field.
    Focus,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldStep {
    pub state: FieldState,
    /// The key was handled (the text view does nothing more with it).
    pub handled: bool,
    pub effects: Vec<FieldEffect>,
}

struct Machine<'a> {
    state: FieldState,
    context: &'a FieldContext,
    effects: Vec<FieldEffect>,
}

impl Machine<'_> {
    fn refresh(&mut self) {
        if self.state.browsing {
            return;
        }
        let c = self.context;
        self.state.list = if self.state.draft.is_empty() {
            let rows = idle_rows(
                &self.state.draft,
                &c.contacts,
                c.has_new_chief,
                c.has_invite,
                c.chief_limit.unwrap_or(6),
            );
            ListState::show(rows, false, false)
        } else {
            ListState::show(
                typed_rows(&self.state.draft, &c.contacts, c.invite_team.as_deref()),
                false,
                true,
            )
        };
    }

    fn changed(&mut self) {
        self.state.browsing = false;
        self.state.selected_token = None;
        self.refresh();
        self.effects.push(FieldEffect::Changed);
    }

    fn choose(&mut self, recipient: Recipient) {
        self.state.draft.add(recipient);
        self.state.text.clear();
        self.changed();
    }

    fn activate(&mut self, row: SuggestionRow) {
        match row {
            SuggestionRow::Recipient { recipient } => self.choose(recipient),
            SuggestionRow::NewChief => self.effects.push(FieldEffect::NewChief),
            SuggestionRow::Invite => self.effects.push(FieldEffect::Invite),
            SuggestionRow::InviteToTeam { address, .. } => {
                self.effects.push(FieldEffect::InviteToTeam { address });
            }
            SuggestionRow::Header { .. } => {}
        }
    }

    fn commit(&mut self, pick: bool) -> bool {
        let typed = trim_separators(&self.state.text).to_owned();
        if typed.is_empty() && !pick {
            return false;
        }
        if !self.state.list.hidden
            && let Some(row) = self.state.list.highlighted_row().cloned()
        {
            self.activate(row);
            return true;
        }
        if typed.is_empty() {
            return false;
        }
        self.state.draft.query = typed;
        self.state.draft.commit(&self.context.contacts);
        self.state.text.clear();
        self.changed();
        true
    }

    fn remove_token(&mut self, index: usize) {
        self.state.selected_token = None;
        self.state.draft.remove(index);
        self.changed();
        self.effects.push(FieldEffect::Focus);
    }

    fn delete_backward(&mut self) -> bool {
        if let Some(selected) = self.state.selected_token {
            self.remove_token(selected);
            return true;
        }
        self.state.draft.query = self.state.text.clone();
        if !self.state.draft.delete_backward() {
            return false;
        }
        self.changed();
        true
    }

    fn key(&mut self, key: Key) -> bool {
        match key {
            Key::Newline | Key::Tab => {
                if !self.commit(key == Key::Newline) {
                    self.effects.push(FieldEffect::Done);
                }
                true
            }
            Key::DeleteBackward | Key::DeleteForward => {
                self.state.text.is_empty() && self.delete_backward()
            }
            Key::MoveDown | Key::MoveUp => {
                if self.state.list.hidden {
                    return false;
                }
                self.state.list.moved(if key == Key::MoveDown { 1 } else { -1 });
                true
            }
            Key::Cancel => {
                if !self.state.list.hidden && (self.state.browsing || !self.state.draft.is_empty())
                {
                    self.state.browsing = false;
                    self.state.list = ListState::show(Vec::new(), false, true);
                } else {
                    self.effects.push(FieldEffect::Escape);
                }
                true
            }
            Key::Other => false,
        }
    }

    fn text_changed(&mut self, value: String) {
        // A comma or semicolon ends the token as Messages does.
        if let Some(rest) = value.strip_suffix([',', ';']) {
            self.state.text = rest.to_owned();
            self.commit(false);
            return;
        }
        self.state.draft.query = value.clone();
        self.state.text = value;
        self.state.browsing = false;
        self.state.selected_token = None;
        self.refresh();
        self.effects.push(FieldEffect::Changed);
    }

    fn browse(&mut self) {
        self.state.browsing = true;
        self.state.list =
            ListState::show(browse_rows(&self.state.draft, &self.context.contacts), true, true);
        self.effects.push(FieldEffect::Focus);
    }
}

/// One event on the To field.
pub fn step(state: FieldState, context: &FieldContext, event: FieldEvent) -> FieldStep {
    let mut machine = Machine { state, context, effects: Vec::new() };
    let handled = match event {
        FieldEvent::Key { key } => machine.key(key),
        FieldEvent::TextChanged { value } => {
            machine.text_changed(value);
            true
        }
        FieldEvent::Choose { recipient } => {
            machine.choose(recipient);
            true
        }
        FieldEvent::Activate { index } => match machine.state.list.rows.get(index).cloned() {
            Some(row) => {
                machine.activate(row);
                true
            }
            None => false,
        },
        FieldEvent::RemoveToken { index } => {
            machine.remove_token(index);
            true
        }
        FieldEvent::SelectToken { index } => {
            machine.effects.push(FieldEffect::Focus);
            machine.state.selected_token = Some(index);
            true
        }
        FieldEvent::Browse => {
            machine.browse();
            true
        }
        FieldEvent::SetDraft { draft } => {
            machine.state.text = draft.query.clone();
            machine.state.draft = draft;
            machine.refresh();
            true
        }
        FieldEvent::Refresh => {
            machine.refresh();
            true
        }
        FieldEvent::Commit { pick } => machine.commit(pick),
    };
    FieldStep { state: machine.state, handled, effects: machine.effects }
}

// MARK: Detail lines

/// What a recipient row's detail says first (`HomeRecipientSuggestionsView.detail`); the app words it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum DetailKind {
    Email,
    Phone,
    Team,
    Connection,
    Agent,
}

pub fn detail_kind(recipient: &Recipient) -> DetailKind {
    match recipient {
        Recipient::Address { address } => match address.kind {
            AddressKind::Email => DetailKind::Email,
            AddressKind::Phone => DetailKind::Phone,
        },
        Recipient::Contact { contact } => match contact.source {
            Source::Team => DetailKind::Team,
            Source::Connection => DetailKind::Connection,
            Source::Agent => DetailKind::Agent,
        },
    }
}

/// A recipient row's words for `lines`: its label, its worded detail, the Chief's tag and activity.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct LineInput {
    pub label: String,
    pub detail: String,
    pub tag: Option<String>,
    pub activity: Option<String>,
}

/// `lines(for:look:)`: each recipient row's detail line; rows that read the same get their activity, and
/// rows still alike get " · 2", " · 3".
pub fn lines(rows: &[Option<LineInput>]) -> Vec<Option<String>> {
    const DOT: &str = " \u{00B7} ";
    let mut result: Vec<Option<String>> = rows
        .iter()
        .map(|row| {
            row.as_ref().map(|line| match &line.tag {
                Some(tag) => format!("{}{DOT}{tag}", line.detail),
                None => line.detail.clone(),
            })
        })
        .collect();
    let collisions = |result: &[Option<String>]| -> Vec<Vec<usize>> {
        let mut groups: BTreeMap<String, Vec<usize>> = BTreeMap::new();
        for (index, detail) in result.iter().enumerate() {
            if let (Some(detail), Some(row)) = (detail, &rows[index]) {
                groups.entry(format!("{}\u{0}{detail}", row.label)).or_default().push(index);
            }
        }
        groups.into_values().filter(|group| group.len() > 1).collect()
    };
    for group in collisions(&result) {
        for index in group {
            if let (Some(detail), Some(Some(activity))) =
                (&mut result[index], rows[index].as_ref().map(|r| &r.activity))
            {
                detail.push_str(DOT);
                detail.push_str(activity);
            }
        }
    }
    for group in collisions(&result) {
        for (number, index) in group.into_iter().enumerate().skip(1) {
            if let Some(detail) = &mut result[index] {
                detail.push_str(&format!("{DOT}{}", number + 1));
            }
        }
    }
    result
}

// MARK: Requests

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RowsRequest {
    #[serde(default)]
    pub draft: Draft,
    #[serde(default)]
    pub contacts: Vec<Contact>,
    #[serde(default)]
    pub has_new_chief: bool,
    #[serde(default)]
    pub has_invite: bool,
    pub invite_team: Option<String>,
    pub chief_limit: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepRequest {
    #[serde(default)]
    pub state: FieldState,
    #[serde(default)]
    pub context: FieldContext,
    #[serde(flatten)]
    pub event: FieldEvent,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ShowRequest {
    #[serde(default)]
    pub rows: Vec<SuggestionRow>,
    #[serde(default)]
    pub empty_text: bool,
    #[serde(default = "yes")]
    pub highlight_first: bool,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MoveRequest {
    #[serde(default)]
    pub list: ListState,
    pub offset: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinesRequest {
    #[serde(default)]
    pub rows: Vec<Option<LineInput>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailRequest {
    pub recipient: Recipient,
}
