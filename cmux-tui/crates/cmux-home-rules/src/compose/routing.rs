//! Where a send goes (`HomeMessageRouting`, `+Suggestions`), `@` mention runs (`HomeMentions`), the
//! attachment check (`HomeComposerCheck`) and the New Message composer source's gates
//! (`HomeNewMessageComposerSource`).

use super::text::{self, case_equal, trim_space};
use super::types::{Contact, Row, RowKind};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The inbox as routing sees it; `rows` come in inbox order (`orderedForInbox`, the inbox area's).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Routing {
    pub rows: Vec<Row>,
    pub me: Option<String>,
    /// The app's own Chief conversation, if it knows one.
    pub chief: Option<String>,
    /// Chief conversations' names by conversation id.
    pub chief_names: BTreeMap<String, String>,
}

/// A conversation offered to an action's `to` field.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Choice {
    pub value: String,
    pub title: String,
}

impl Routing {
    fn title<'a>(&'a self, row: &'a Row) -> &'a str {
        self.chief_names.get(&row.id).map_or(row.title.as_str(), String::as_str)
    }

    /// `chiefConversation`: the app's Chief while it is listed, else the first Chief row.
    pub fn chief_conversation(&self) -> Option<&str> {
        if let Some(id) = self.chief.as_deref()
            && self.rows.iter().any(|r| r.id == id)
        {
            return Some(id);
        }
        self.rows.iter().find(|r| r.kind == RowKind::Chief).map(|r| r.id.as_str())
    }

    /// `recipients()`: Chiefs first, then the rest; a row without a title shows its id.
    pub fn recipients(&self) -> Vec<Choice> {
        let chiefs = self.rows.iter().filter(|r| r.kind == RowKind::Chief);
        let others = self.rows.iter().filter(|r| r.kind != RowKind::Chief);
        chiefs
            .chain(others)
            .map(|row| {
                let title = self.title(row);
                Choice {
                    value: row.id.clone(),
                    title: if title.is_empty() { row.id.clone() } else { title.to_owned() },
                }
            })
            .collect()
    }

    /// `resolve(_:)`: an id, "chief", a one-to-one peer's id or name, else a conversation title.
    pub fn resolve(&self, raw: &str) -> Option<&str> {
        let name = trim_space(raw);
        if name.is_empty() {
            return None;
        }
        if let Some(row) = self.rows.iter().find(|r| r.id == name) {
            return Some(&row.id);
        }
        if case_equal(name, "chief") {
            return self.chief_conversation();
        }
        let me = self.me.as_deref();
        let one_to_one: Vec<&Row> = self.rows.iter().filter(|r| r.kind != RowKind::Group).collect();
        if let Some(row) = one_to_one
            .iter()
            .find(|row| row.participants.iter().any(|p| Some(p.id.as_str()) != me && p.id == name))
        {
            return Some(&row.id);
        }
        if let Some(row) = one_to_one.iter().find(|row| {
            row.participants.iter().any(|p| {
                let visible = p.visible_name();
                Some(p.id.as_str()) != me && !visible.is_empty() && case_equal(&visible, name)
            })
        }) {
            return Some(&row.id);
        }
        self.rows
            .iter()
            .find(|row| {
                let title = self.title(row);
                !title.is_empty() && case_equal(title, name)
            })
            .map(|r| r.id.as_str())
    }
}

/// `compose(_:into:)`: the text added to the conversation's own draft on a new line.
pub fn compose(text: &str, own: &str) -> String {
    let added = text.trim_start_matches(text::is_newline);
    if own.is_empty() || own.ends_with('\n') {
        format!("{own}{added}")
    } else {
        format!("{own}\n{added}")
    }
}

/// `quoted(_:)`: the text as a Markdown quote, and a blank line to type under.
pub fn quoted(text: &str) -> String {
    let lines: Vec<String> = text::trim_newlines(text)
        .split('\n')
        .map(|line| if line.is_empty() { ">".to_owned() } else { format!("> {line}") })
        .collect();
    format!("{}\n\n", lines.join("\n"))
}

/// `mention(_:link:)`: a Markdown link to the conversation, brackets in the title made parentheses.
pub fn mention(title: &str, link: &str) -> String {
    let label = trim_space(title).replace('[', "(").replace(']', ")");
    format!("[{}]({link}) ", if label.is_empty() { link } else { &label })
}

/// Which list an action field's suggestions come from (`suggestions(for:)`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum SuggestionSource {
    /// `recipients()`.
    Recipients,
    /// The team's members: value the id, title the name.
    Members,
    /// The Chiefs the caller lists.
    Chiefs,
}

pub fn suggestion_source(source: &str) -> Option<SuggestionSource> {
    match source {
        "homeRecipients" => Some(SuggestionSource::Recipients),
        "homeMembers" => Some(SuggestionSource::Members),
        "homeChiefs" => Some(SuggestionSource::Chiefs),
        _ => None,
    }
}

/// `suggestions(for:members:)` for the members list.
pub fn member_choices(members: &[Contact]) -> Vec<Choice> {
    members.iter().map(|m| Choice { value: m.id.clone(), title: m.name.clone() }).collect()
}

// MARK: Mentions

/// A name `@`-mentioned in a message.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Named {
    pub id: String,
    pub display_name: String,
}

/// One mention run, in UTF-16 units (`ConversationTextRun`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Run {
    pub start: usize,
    pub length: usize,
    pub mention: String,
}

fn is_boundary(unit: u16) -> bool {
    match char::from_u32(u32::from(unit)) {
        None => true,
        Some(c) => !c.is_alphanumeric() && c != '_',
    }
}

/// `HomeMentions.runs(in:participants:)`: each `@name` at a word start, the longest name winning, compared
/// against a window as long as the longest name (never the whole rest of the text).
pub fn mention_runs(text: &str, participants: &[Named]) -> Vec<Run> {
    let utf16: Vec<u16> = text.encode_utf16().collect();
    let names: Vec<(&Named, String)> = participants
        .iter()
        .map(|p| (p, p.display_name.to_lowercase()))
        .filter(|(_, name)| !name.is_empty())
        .collect();
    let Some(longest) = names.iter().map(|(_, n)| n.encode_utf16().count()).max() else {
        return Vec::new();
    };
    let window = longest + 8;
    let mut runs = Vec::new();
    let mut index = 0;
    while index < utf16.len() {
        let at = index;
        index += 1;
        if utf16[at] != u16::from(b'@') || (at > 0 && !is_boundary(utf16[at - 1])) {
            continue;
        }
        let upper = utf16.len().min(at + 1 + window);
        let rest = String::from_utf16_lossy(&utf16[at + 1..upper]).to_lowercase();
        let mut best: Option<(&Named, usize)> = None;
        for (participant, name) in &names {
            let units = name.encode_utf16().count();
            if rest.starts_with(name.as_str()) && best.is_none_or(|(_, b)| units > b) {
                best = Some((participant, units));
            }
        }
        let Some((participant, units)) = best else {
            continue;
        };
        let end = at + 1 + units;
        if end > utf16.len() || (end < utf16.len() && !is_boundary(utf16[end])) {
            continue;
        }
        runs.push(Run { start: at, length: end - at, mention: participant.id.clone() });
        index = end;
    }
    runs
}

// MARK: The attachment check

/// What the composer was handed (`HomeDraftInput`), with the policy's answer.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum DraftInput {
    /// A file: its name (`lastPathComponent`), whether `HomeAttachmentPolicy` takes it, its size.
    File {
        name: String,
        accepted: bool,
        #[serde(default)]
        size: u64,
    },
    /// Pasted data: its type identifier, whether the policy takes it, its byte count.
    Data {
        identifier: String,
        accepted: bool,
        #[serde(default)]
        size: u64,
    },
}

/// Why an attachment is refused (`HomeAttachmentError`'s cases the check gives), and the name to show.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum AttachmentProblem {
    Folder { name: String, shown: Option<String> },
    TypeRefused { mime_type: String, name: String, shown: Option<String> },
    Empty { name: String, shown: Option<String> },
}

/// `HomeComposerCheck.problem(for:)`.
pub fn attachment_problem(input: &DraftInput) -> Option<AttachmentProblem> {
    let (shown, accepted, size, type_name) = match input {
        DraftInput::File { name, accepted, size } => {
            if !accepted {
                return Some(AttachmentProblem::Folder {
                    name: name.clone(),
                    shown: Some(name.clone()),
                });
            }
            let extension = name.rsplit_once('.').map(|(_, e)| e.to_owned()).unwrap_or_default();
            (Some(name.clone()), true, *size, extension)
        }
        DraftInput::Data { identifier, accepted, size } => {
            (None, *accepted, *size, identifier.clone())
        }
    };
    let name = shown.clone().unwrap_or_default();
    if !accepted {
        return Some(AttachmentProblem::TypeRefused { mime_type: type_name, name, shown });
    }
    (size == 0).then_some(AttachmentProblem::Empty { name, shown })
}

// MARK: The New Message composer source

/// The New Message composer's own conversation id.
pub const NEW_MESSAGE_CONVERSATION: &str = "cmux.home.new-message";

/// The source's gate: `Ok` lets the op through, `Err` is the `HomeRejection.invalid` reason.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Gate {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invalid: Option<String>,
}

impl Gate {
    fn from(ok: bool, reason: &str) -> Self {
        Gate { ok, invalid: (!ok).then(|| reason.to_owned()) }
    }
}

/// `submit(_:)`: only a send to the New Message conversation.
pub fn source_submit(op: &str, conversation: Option<&str>) -> Gate {
    Gate::from(
        op == "sendMessage" && conversation == Some(NEW_MESSAGE_CONVERSATION),
        "new_message.unsupported",
    )
}

/// `snapshot(of:tail:)`: only the New Message conversation.
pub fn source_snapshot(conversation: &str) -> Gate {
    Gate::from(conversation == NEW_MESSAGE_CONVERSATION, "new_message.unknown_conversation")
}

// MARK: Requests

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveRequest {
    pub text: String,
    #[serde(flatten)]
    pub routing: Routing,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComposeRequest {
    pub text: String,
    /// The conversation's own draft; null when the conversation is not listed (the reply is then null).
    pub own: Option<String>,
    #[serde(default = "listed")]
    pub listed: bool,
}

fn listed() -> bool {
    true
}

#[derive(Deserialize)]
pub struct TextRequest {
    pub text: String,
}

#[derive(Deserialize)]
pub struct MentionRequest {
    #[serde(default)]
    pub title: String,
    pub link: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceRequest {
    pub source: String,
    #[serde(flatten)]
    pub routing: Routing,
    #[serde(default)]
    pub members: Vec<Contact>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunsRequest {
    pub text: String,
    #[serde(default)]
    pub participants: Vec<Named>,
}

#[derive(Deserialize)]
pub struct ProblemRequest {
    pub input: DraftInput,
}

#[derive(Deserialize)]
pub struct SubmitRequest {
    pub op: String,
    pub conversation: Option<String>,
}

#[derive(Deserialize)]
pub struct SnapshotRequest {
    pub conversation: String,
}
