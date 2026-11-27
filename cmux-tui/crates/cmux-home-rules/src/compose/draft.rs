//! The New Message To field's rules (`HomeNewMessageDraft`): tokens, commit, delete-back, resolving
//! typed text, suggestions and the existing-conversation match.

use super::text::{self, trim_separators};
use super::types::{
    Contact, Draft, Membership, Participant, Recipient, Row, RowKind, Source, Token,
};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Why the draft cannot be sent yet (`sendBlocker`); the app words it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum SendBlocker {
    /// The first token that matched nobody.
    UnknownRecipient { text: String },
    /// No recipient yet.
    NeedsRecipient,
}

/// What the view reads off a draft.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftState {
    pub recipients: Vec<Recipient>,
    pub has_invalid_tokens: bool,
    pub is_empty: bool,
    pub is_group: bool,
    pub send_blocker: Option<SendBlocker>,
}

impl Draft {
    pub fn recipients(&self) -> Vec<Recipient> {
        self.tokens.iter().filter_map(|t| t.recipient.clone()).collect()
    }

    pub fn has_invalid_tokens(&self) -> bool {
        self.tokens.iter().any(|t| t.recipient.is_none())
    }

    pub fn is_empty(&self) -> bool {
        self.tokens.is_empty() && text::trim_space(&self.query).is_empty()
    }

    fn holds(&self, recipient: &Recipient) -> bool {
        self.tokens.iter().any(|t| t.recipient.as_ref() == Some(recipient))
    }

    fn chosen(&self) -> HashSet<Recipient> {
        self.recipients().into_iter().collect()
    }

    pub fn state(&self) -> DraftState {
        let recipients = self.recipients();
        DraftState {
            has_invalid_tokens: self.has_invalid_tokens(),
            is_empty: self.is_empty(),
            is_group: recipients.len() > 1,
            send_blocker: self.send_blocker(),
            recipients,
        }
    }

    /// `add(_:)`: clears the query; a recipient already present is not added twice.
    pub fn add(&mut self, recipient: Recipient) {
        self.query.clear();
        if !self.holds(&recipient) {
            self.tokens
                .push(Token { text: recipient.label().to_owned(), recipient: Some(recipient) });
        }
    }

    /// `commit(contacts:)`: the query becomes a token (invalid when it matches nobody); false when empty.
    pub fn commit(&mut self, contacts: &[Contact]) -> bool {
        let typed = trim_separators(&self.query).to_owned();
        self.query.clear();
        if typed.is_empty() {
            return false;
        }
        match resolve(&typed, contacts) {
            None => self.tokens.push(Token { text: typed, recipient: None }),
            Some(recipient) if self.holds(&recipient) => {}
            Some(recipient) => {
                self.tokens
                    .push(Token { text: recipient.label().to_owned(), recipient: Some(recipient) });
            }
        }
        true
    }

    /// `deleteBackward()`: with nothing typed, the last token goes.
    pub fn delete_backward(&mut self) -> bool {
        if !self.query.is_empty() || self.tokens.is_empty() {
            return false;
        }
        self.tokens.pop();
        true
    }

    /// `remove(at:)`: an index out of range does nothing.
    pub fn remove(&mut self, index: usize) {
        if index < self.tokens.len() {
            self.tokens.remove(index);
        }
    }

    /// `suggestions(contacts:limit:)`: the typed address, then contacts a word of whose name starts
    /// with the text, then those whose name holds it; chosen ones left out.
    pub fn suggestions(&self, contacts: &[Contact], limit: usize) -> Vec<Recipient> {
        let typed = trim_separators(&self.query);
        if typed.is_empty() {
            return Vec::new();
        }
        let chosen = self.chosen();
        let mut result = Vec::new();
        if let Some(address) = text::address(typed) {
            let recipient = Recipient::Address { address };
            if !chosen.contains(&recipient) {
                result.push(recipient);
            }
        }
        let word_start: Vec<&Contact> = contacts
            .iter()
            .filter(|c| {
                c.name
                    .split(char::is_whitespace)
                    .any(|word| !word.is_empty() && text::folded_prefix(word, typed))
            })
            .collect();
        let inside = contacts
            .iter()
            .filter(|c| text::folded_contains(&c.name, typed) && !word_start.contains(c));
        for contact in word_start.iter().copied().chain(inside) {
            let recipient = Recipient::contact(contact);
            if !chosen.contains(&recipient) {
                result.push(recipient);
            }
        }
        result.truncate(limit);
        result
    }

    /// `chiefShortcuts(contacts:limit:)`: Chiefs not yet chosen.
    pub fn chief_shortcuts(&self, contacts: &[Contact], limit: usize) -> Vec<Contact> {
        let chosen = self.chosen();
        contacts
            .iter()
            .filter(|c| c.source == Source::Agent && !chosen.contains(&Recipient::contact(c)))
            .take(limit)
            .cloned()
            .collect()
    }

    /// `idleSuggestions(contacts:chiefLimit:)`: the Chief shortcuts, then the team.
    pub fn idle_suggestions(&self, contacts: &[Contact], chief_limit: usize) -> Vec<Contact> {
        let chosen = self.chosen();
        let mut result = self.chief_shortcuts(contacts, chief_limit);
        result.extend(
            contacts
                .iter()
                .filter(|c| c.source == Source::Team && !chosen.contains(&Recipient::contact(c)))
                .cloned(),
        );
        result
    }

    /// `existingConversation(in:me:)`: the first row (in the order given) with exactly these people.
    pub fn existing_conversation<'a>(&self, rows: &'a [Row], me: Option<&str>) -> Option<&'a str> {
        let recipients = self.recipients();
        if recipients.is_empty() || self.has_invalid_tokens() {
            return None;
        }
        let wanted: HashSet<String> = recipients.iter().map(Recipient::key).collect();
        let one = recipients.len() == 1;
        rows.iter()
            .find(|row| {
                if one == (row.kind == RowKind::Group) {
                    return false;
                }
                let others: Vec<&Participant> =
                    row.participants.iter().filter(|p| Some(p.id.as_str()) != me).collect();
                others.len() == wanted.len()
                    && others.iter().map(|p| participant_key(p)).collect::<HashSet<_>>() == wanted
            })
            .map(|row| row.id.as_str())
    }

    /// `sendBlocker`.
    pub fn send_blocker(&self) -> Option<SendBlocker> {
        if let Some(invalid) = self.tokens.iter().find(|t| t.recipient.is_none()) {
            return Some(SendBlocker::UnknownRecipient { text: invalid.text.clone() });
        }
        self.recipients().is_empty().then_some(SendBlocker::NeedsRecipient)
    }
}

fn participant_key(participant: &Participant) -> String {
    if participant.membership == Membership::Invited
        && let Some(address) = participant.invited_contact.as_deref().and_then(text::address)
    {
        return format!("address:{}", address.value);
    }
    format!("id:{}", participant.id)
}

/// `HomeNewMessageDraft.resolve(_:contacts:)`: an address, else a contact by id or whole name, else the
/// one contact whose name starts with the text.
pub fn resolve(raw: &str, contacts: &[Contact]) -> Option<Recipient> {
    let typed = trim_separators(raw);
    if typed.is_empty() {
        return None;
    }
    if let Some(address) = text::address(typed) {
        return Some(Recipient::Address { address });
    }
    if let Some(contact) =
        contacts.iter().find(|c| c.id == typed || text::folded_equal(&c.name, typed))
    {
        return Some(Recipient::contact(contact));
    }
    let starts: Vec<&Contact> =
        contacts.iter().filter(|c| text::folded_prefix(&c.name, typed)).collect();
    match starts.as_slice() {
        [only] => Some(Recipient::contact(only)),
        _ => None,
    }
}

// MARK: Requests

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DraftRequest {
    #[serde(default)]
    pub draft: Draft,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AddRequest {
    #[serde(default)]
    pub draft: Draft,
    pub recipient: Recipient,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveRequest {
    #[serde(default)]
    pub draft: Draft,
    pub index: usize,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContactsRequest {
    #[serde(default)]
    pub draft: Draft,
    #[serde(default)]
    pub contacts: Vec<Contact>,
    pub limit: Option<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveRequest {
    pub text: String,
    #[serde(default)]
    pub contacts: Vec<Contact>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExistingRequest {
    #[serde(default)]
    pub draft: Draft,
    #[serde(default)]
    pub rows: Vec<Row>,
    pub me: Option<String>,
}

/// A draft op's reply when it changes the draft: the new draft and whether it did anything.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Changed {
    pub draft: Draft,
    pub changed: bool,
}
