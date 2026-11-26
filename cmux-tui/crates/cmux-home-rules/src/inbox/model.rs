//! The Home list's shared values as the Swift side sends them: a participant
//! (CmuxHomeCore `Participant`, its own Codable keys), a list row (the parts of
//! `InboxRow` the rules read) and a contact (`HomeContact`), plus the text rules
//! every Home names people with (`visibleName`, `initials`, the search fold).

use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::BTreeMap;

/// A person or an agent principal (`Participant.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ParticipantKind {
    #[default]
    Human,
    Agent,
}

/// `Participant.AgentClass`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AgentClass {
    Chief,
    Agent,
}

/// `Participant.Membership`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum Membership {
    #[default]
    Active,
    Invited,
}

/// `Participant.Role` (the Cloud owner's group role).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Role {
    #[serde(rename = "owner")]
    Owner,
    #[serde(rename = "admin")]
    Admin,
    #[serde(rename = "member")]
    Member,
    #[serde(rename = "read_only")]
    ReadOnly,
}

/// A member of a conversation, as CmuxHomeCore's `Participant` encodes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
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
    /// An agent of the Chief class (`Participant.isChief`).
    pub fn is_chief(&self) -> bool {
        self.kind == ParticipantKind::Agent && self.agent_class == Some(AgentClass::Chief)
    }

    /// The name a person reads (`Participant.visibleName`): the display name, else the invited
    /// address, trimmed; never an internal id.
    pub fn visible_name(&self) -> String {
        let invited = self.invited_contact.as_deref().unwrap_or("");
        for candidate in [self.display_name.as_str(), invited] {
            let trimmed = candidate.trim();
            if !trimmed.is_empty() && !is_home_internal_id(trimmed) {
                return trimmed.to_owned();
            }
        }
        String::new()
    }

    /// One or two letters for a monogram (`Participant.initials`); "?" for none.
    pub fn initials(&self) -> String {
        initials_of(&self.visible_name())
    }
}

/// `Participant.initials` of a visible name.
pub fn initials_of(name: &str) -> String {
    let letters: String = name
        .split([' ', '-', '_'])
        .filter(|word| !word.is_empty())
        .take(2)
        .filter_map(|word| word.chars().next())
        .collect();
    let joined = letters.to_uppercase();
    if joined.is_empty() { "?".to_owned() } else { joined }
}

/// An id the Home owners mint (`String.isHomeInternalID`): `PREFIX_rest` with a known prefix and
/// an ASCII letters, digits, `_` and `-` rest.
pub fn is_home_internal_id(text: &str) -> bool {
    const PREFIXES: &[&str] =
        &["addr", "user", "agent", "conv", "inv", "msg", "team", "inst", "grant", "task", "vm"];
    let Some((prefix, rest)) = text.split_once('_') else {
        return false;
    };
    PREFIXES.contains(&prefix)
        && !rest.is_empty()
        && rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// A row's kind (`ConversationSummary.Kind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum RowKind {
    Chief,
    #[default]
    Direct,
    Group,
}

/// One row of the conversation list: the parts of `InboxRow` (and its summary) the rules read.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Row {
    pub id: String,
    pub kind: RowKind,
    pub title: String,
    pub preview: String,
    /// The newest activity, seconds since 1970.
    pub timestamp: f64,
    pub unread: i64,
    pub mentions: i64,
    /// The owner pinned it (`InboxRow.isPinned`).
    pub is_pinned: bool,
    pub is_typing: bool,
    /// `summary.muted`.
    pub muted: bool,
    /// `summary.isChannel` (a group with its own Chief).
    pub is_channel: bool,
    /// `summary.lastSeq`.
    pub last_seq: i64,
    /// `summary.participants`.
    pub participants: Vec<Participant>,
}

impl Row {
    /// A participant is invited and has not joined (`hasInvitedParticipant`).
    pub fn has_invited_participant(&self) -> bool {
        self.participants.iter().any(|p| p.membership == Membership::Invited)
    }

    /// The participants other than `me`.
    pub fn others<'a>(&'a self, me: Option<&'a str>) -> impl Iterator<Item = &'a Participant> + 'a {
        self.participants.iter().filter(move |p| Some(p.id.as_str()) != me)
    }

    /// The search match (`InboxRow.matches`): the title, the preview or a member's name.
    pub fn matches(&self, needle: &str, me: Option<&str>) -> bool {
        standard_contains(&self.title, needle)
            || standard_contains(&self.preview, needle)
            || self.others(me).any(|p| standard_contains(&p.display_name, needle))
    }
}

/// Where a contact comes from (`HomeContact.Source`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ContactSource {
    Team,
    Connection,
    Agent,
}

/// A person (or Chief) New Message offers (`HomeContact`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Contact {
    pub id: String,
    pub name: String,
    pub source: ContactSource,
}

/// Where a Chief's brain runs (`HomeChiefPlace`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum ChiefPlace {
    ThisMac,
    Cloud,
    Server { name: String },
}

/// The roster the list reads (`HomeChiefRoster`): the main Chief and each Chief's place.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Roster {
    pub main: Option<String>,
    pub places: BTreeMap<String, ChiefPlace>,
}

/// One character as Foundation's standard (Finder) comparison sees it: lower case, without its
/// accent, full-width forms as ASCII.
fn fold_char(c: char, out: &mut String) {
    let c = match c as u32 {
        0xFF01..=0xFF5E => char::from_u32(c as u32 - 0xFEE0).unwrap_or(c),
        0x3000 => ' ',
        _ => c,
    };
    let base = match c {
        'À'..='Å' | 'à'..='å' | 'Ā' | 'ā' | 'Ă' | 'ă' | 'Ą' | 'ą' => 'a',
        'Ç' | 'ç' | 'Ć' | 'ć' | 'Ĉ' | 'ĉ' | 'Ċ' | 'ċ' | 'Č' | 'č' => 'c',
        'Ď' | 'ď' => 'd',
        'È'..='Ë' | 'è'..='ë' | 'Ē' | 'ē' | 'Ĕ' | 'ĕ' | 'Ė' | 'ė' | 'Ę' | 'ę' | 'Ě' | 'ě' => {
            'e'
        }
        'Ĝ' | 'ĝ' | 'Ğ' | 'ğ' | 'Ġ' | 'ġ' | 'Ģ' | 'ģ' => 'g',
        'Ĥ' | 'ĥ' => 'h',
        'Ì'..='Ï' | 'ì'..='ï' | 'Ĩ' | 'ĩ' | 'Ī' | 'ī' | 'Ĭ' | 'ĭ' | 'Į' | 'į' | 'İ' => {
            'i'
        }
        'Ĵ' | 'ĵ' => 'j',
        'Ķ' | 'ķ' => 'k',
        'Ĺ' | 'ĺ' | 'Ļ' | 'ļ' | 'Ľ' | 'ľ' => 'l',
        'Ñ' | 'ñ' | 'Ń' | 'ń' | 'Ņ' | 'ņ' | 'Ň' | 'ň' => 'n',
        'Ò'..='Ö' | 'Ø' | 'ò'..='ö' | 'ø' | 'Ō' | 'ō' | 'Ŏ' | 'ŏ' | 'Ő' | 'ő' => 'o',
        'Ŕ' | 'ŕ' | 'Ŗ' | 'ŗ' | 'Ř' | 'ř' => 'r',
        'Ś' | 'ś' | 'Ŝ' | 'ŝ' | 'Ş' | 'ş' | 'Š' | 'š' => 's',
        'Ţ' | 'ţ' | 'Ť' | 'ť' => 't',
        'Ù'..='Ü'
        | 'ù'..='ü'
        | 'Ũ'
        | 'ũ'
        | 'Ū'
        | 'ū'
        | 'Ŭ'
        | 'ŭ'
        | 'Ů'
        | 'ů'
        | 'Ű'
        | 'ű'
        | 'Ų'
        | 'ų' => 'u',
        'Ý' | 'ý' | 'ÿ' | 'Ÿ' => 'y',
        'Ź' | 'ź' | 'Ż' | 'ż' | 'Ž' | 'ž' => 'z',
        // Combining marks (an accent sent decomposed) fold away.
        '\u{0300}'..='\u{036F}' => return,
        _ => {
            out.extend(c.to_lowercase());
            return;
        }
    };
    out.push(base);
}

/// `text` folded case, accent and width aside (Foundation's `.caseInsensitive,
/// .diacriticInsensitive, .widthInsensitive`).
pub fn fold(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        fold_char(c, &mut out);
    }
    out
}

/// `String.localizedStandardContains`: `text` holds `needle`, case, accent and width aside. An
/// empty needle is in no text (Foundation's answer).
pub fn standard_contains(text: &str, needle: &str) -> bool {
    let needle = fold(needle);
    !needle.is_empty() && fold(text).contains(&needle)
}

/// `String.localizedStandardCompare`: Finder's order, case and accent aside, digit runs by value.
pub fn standard_compare(a: &str, b: &str) -> Ordering {
    let (a, b) = (fold(a), fold(b));
    let (mut x, mut y) = (a.chars().peekable(), b.chars().peekable());
    loop {
        match (x.peek().copied(), y.peek().copied()) {
            (None, None) => return a.cmp(&b),
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(p), Some(q)) if p.is_ascii_digit() && q.is_ascii_digit() => {
                let take = |it: &mut std::iter::Peekable<std::str::Chars<'_>>| {
                    let mut run = String::new();
                    while let Some(d) = it.peek().copied().filter(char::is_ascii_digit) {
                        run.push(d);
                        it.next();
                    }
                    run
                };
                let (m, n) = (take(&mut x), take(&mut y));
                let (m_trim, n_trim) = (m.trim_start_matches('0'), n.trim_start_matches('0'));
                let order = m_trim.len().cmp(&n_trim.len()).then_with(|| m_trim.cmp(n_trim));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(p), Some(q)) => {
                if p != q {
                    return p.cmp(&q);
                }
                x.next();
                y.next();
            }
        }
    }
}
