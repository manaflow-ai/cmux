//! The conversation list's sections (`HomeConversationList`) and the invites still out.

use super::model::{Membership, Row, RowKind};
use serde::{Deserialize, Serialize};

/// `HomeConversationSectionKind`, in list order.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SectionKind {
    Chiefs,
    Pinned,
    Messages,
    Invited,
}

const ORDER: [SectionKind; 4] =
    [SectionKind::Chiefs, SectionKind::Pinned, SectionKind::Messages, SectionKind::Invited];

/// `InboxRow.homeSectionKind`.
pub fn section_kind(row: &Row) -> SectionKind {
    if row.kind == RowKind::Chief {
        SectionKind::Chiefs
    } else if row.is_pinned {
        SectionKind::Pinned
    } else if row.kind == RowKind::Direct && row.has_invited_participant() {
        SectionKind::Invited
    } else {
        SectionKind::Messages
    }
}

/// One section: its kind and its rows' ids, in the order given.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Section {
    pub kind: SectionKind,
    pub rows: Vec<String>,
}

/// `[InboxRow].homeSections`: non-empty sections in list order.
pub fn sections(rows: &[Row]) -> Vec<Section> {
    ORDER
        .iter()
        .filter_map(|kind| {
            let ids: Vec<String> = rows
                .iter()
                .filter(|row| section_kind(row) == *kind)
                .map(|row| row.id.clone())
                .collect();
            (!ids.is_empty()).then_some(Section { kind: *kind, rows: ids })
        })
        .collect()
}

/// `HomeConversationLine`: a header or a row.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", rename_all_fields = "camelCase", tag = "kind")]
pub enum Line {
    Header { section: SectionKind },
    Row { id: String },
}

/// `[InboxRow].homeLines`.
pub fn lines(rows: &[Row]) -> Vec<Line> {
    sections(rows)
        .into_iter()
        .flat_map(|section| {
            std::iter::once(Line::Header { section: section.kind })
                .chain(section.rows.into_iter().map(|id| Line::Row { id }))
        })
        .collect()
}

/// One invite still out (`pendingInvites`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PendingInvite {
    pub conversation: String,
    pub contact: String,
}

/// `[InboxRow].pendingInvites`.
pub fn pending_invites(rows: &[Row]) -> Vec<PendingInvite> {
    rows.iter()
        .flat_map(|row| {
            row.participants.iter().filter(|p| p.membership == Membership::Invited).map(|p| {
                PendingInvite {
                    conversation: row.id.clone(),
                    contact: p.invited_contact.clone().unwrap_or_else(|| p.display_name.clone()),
                }
            })
        })
        .collect()
}
