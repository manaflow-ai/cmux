//! The JSON shapes the compose ops read and write: contacts, recipients, tokens, the draft, and the
//! slice of an inbox row (`InboxRow`, `ConversationSummary`, `Participant`) the rules look at.

use super::text::{self, Address};
use serde::{Deserialize, Serialize};

/// Where a contact came from (`HomeContact.Source`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    Team,
    Connection,
    Agent,
}

/// Someone the composer can address (`HomeContact`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Contact {
    pub id: String,
    pub name: String,
    pub source: Source,
}

/// A contact or a typed address (`HomeRecipient`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Recipient {
    Contact { contact: Contact },
    Address { address: Address },
}

impl Recipient {
    /// The token's text: the contact's name, or the address.
    pub fn label(&self) -> &str {
        match self {
            Recipient::Contact { contact } => &contact.name,
            Recipient::Address { address } => &address.value,
        }
    }

    /// `id:` and the contact id, or `address:` and the address.
    pub fn key(&self) -> String {
        match self {
            Recipient::Contact { contact } => format!("id:{}", contact.id),
            Recipient::Address { address } => format!("address:{}", address.value),
        }
    }

    pub fn contact(contact: &Contact) -> Self {
        Recipient::Contact { contact: contact.clone() }
    }
}

/// One chip in the To field (`HomeRecipientToken`); no recipient means the text matched nobody.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Token {
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipient: Option<Recipient>,
}

/// The New Message To field (`HomeNewMessageDraft`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Draft {
    pub tokens: Vec<Token>,
    pub query: String,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ParticipantKind {
    #[default]
    Human,
    Agent,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AgentClass {
    Chief,
    Agent,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Membership {
    #[default]
    Active,
    Invited,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Role {
    Owner,
    Admin,
    Member,
    ReadOnly,
}

/// A conversation's participant (`Participant`).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Participant {
    pub id: String,
    pub kind: ParticipantKind,
    pub display_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub agent_class: Option<AgentClass>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner_user: Option<String>,
    pub membership: Membership,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub invited_contact: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<Role>,
}

impl Participant {
    pub fn is_chief(&self) -> bool {
        self.kind == ParticipantKind::Agent && self.agent_class == Some(AgentClass::Chief)
    }

    /// `visibleName`: the display name, else the invited email or phone, never an internal id.
    pub fn visible_name(&self) -> String {
        for candidate in [self.display_name.as_str(), self.invited_contact.as_deref().unwrap_or("")]
        {
            let trimmed = text::trim_space(candidate);
            if !trimmed.is_empty() && !text::is_home_internal_id(trimmed) {
                return trimmed.to_owned();
            }
        }
        String::new()
    }

    /// `initials`: the first letters of the first two words, uppercased, else `?`.
    pub fn initials(&self) -> String {
        let name = self.visible_name();
        let letters: String = name
            .split([' ', '-', '_'])
            .filter(|word| !word.is_empty())
            .take(2)
            .filter_map(|word| word.chars().next())
            .collect();
        let joined = letters.to_uppercase();
        if joined.is_empty() { "?".to_owned() } else { joined }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RowKind {
    Chief,
    #[default]
    Direct,
    Group,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Owner {
    Cloud,
    Local,
}

/// Who a Chief answers in a group (`ChiefReplyPolicy`); `auto` is the default.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReplyPolicy {
    #[default]
    Auto,
    Mentions,
    All,
}

/// The parts of an inbox row the compose rules read.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Row {
    pub id: String,
    /// `InboxRow.kind`, the kind as I see it.
    pub kind: RowKind,
    /// `InboxRow.title`, the title the list shows.
    pub title: String,
    /// `summary.title`, the owner's stored title (may be an internal id or empty).
    pub summary_title: String,
    pub participants: Vec<Participant>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub owner: Option<Owner>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub declared_kind: Option<RowKind>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub chief_replies: Option<ReplyPolicy>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub member_count: Option<u64>,
    pub muted: bool,
}

impl Row {
    /// `ConversationSummary.isMyChiefLine(me:)`.
    pub fn is_my_chief_line(&self, me: &str) -> bool {
        self.declared_kind == Some(RowKind::Chief)
            && self.participants.iter().any(|p| p.is_chief() && p.owner_user.as_deref() == Some(me))
    }
}
