//! RFD 0170 phase 3, the shared-document projection: a document attached to a thread or a session,
//! with an owner, RFD 0077's roles (view, suggest, edit), suggestions and bounded live updates.
//!
//! - **Roles.** A principal's role on a document is its document role (the owner always edits),
//!   capped by what its effective grants in the space allow: no `read` means no access, `read` alone
//!   means view, `read` + `feedback` allows suggest, `read` + `post` allows edit. An agent is also
//!   capped by its owner's role. Nothing is cached: a revoke, a role change or a space removal takes
//!   effect on the next read or update.
//! - **Suggestions.** `pending` moves once to `accepted`, `rejected` or `withdrawn` and never again.
//!   A suggester proposes; an editor accepts or rejects; only the author withdraws. A suggestion
//!   accepts only against the revision it was written on; a stale one stays pending.
//! - **RFD drafts.** A shared RFD draft takes suggestions only, never a direct edit, and accepting
//!   one returns a [`PrPlan`]: the change lands through a normal PR, never by a write to `main`.
//! - **Bounds.** Every update has a size cap, the pending suggestions have a count cap, the body has
//!   a size cap, and update ids are deduplicated over a fixed window, so an update costs the same at
//!   any history length.
//!
//! Nothing here does I/O, reads a clock or draws UI, and nothing in the app calls it yet.

use std::collections::{BTreeMap, HashSet, VecDeque};
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::model::{DocRole, Principal, SharedDocument, Space, Team};
use crate::permission::{Capability, Grants, effective};

/// Pending suggestions one document holds at most.
pub const MAX_PENDING_SUGGESTIONS: usize = 64;
/// The largest update, counted over its strings (ids, inserted text) plus a fixed header.
pub const MAX_UPDATE_BYTES: usize = 16 * 1024;
/// The largest document body.
pub const MAX_DOC_BYTES: usize = 256 * 1024;
/// How many recent update ids are remembered to drop a replay.
pub const DEDUP_WINDOW: usize = 512;
/// How many resolved suggestions keep their final state readable.
pub const RESOLVED_WINDOW: usize = 256;

const UPDATE_HEADER_BYTES: usize = 32;

/// Who acts: the principal and, for an agent, its owner.
#[derive(Debug, Clone, Copy)]
pub struct Actor<'a> {
    pub principal: &'a Principal,
    pub owner: Option<&'a Principal>,
}

/// Where the document's thread or session lives.
#[derive(Debug, Clone, Copy)]
pub struct Scope<'a> {
    pub team: &'a Team,
    pub space: &'a Space,
}

/// The most a principal's space grants allow on a document.
pub fn role_ceiling(grants: &Grants) -> Option<DocRole> {
    if !grants.has(Capability::Read) {
        None
    } else if grants.has(Capability::Post) {
        Some(DocRole::Edit)
    } else if grants.has(Capability::Feedback) {
        Some(DocRole::Suggest)
    } else {
        Some(DocRole::View)
    }
}

/// What kind of document this is, which decides how an accepted change lands.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum DocKind {
    /// A document edited in place.
    Shared,
    /// A shared RFD draft: suggestions only, and an accepted one lands through a PR.
    RfdDraft { repo: String, path: String },
}

/// A text change at a byte offset on a char boundary.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TextEdit {
    pub at: usize,
    pub delete: usize,
    pub insert: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SuggestionState {
    Pending,
    Accepted,
    Rejected,
    Withdrawn,
}

impl SuggestionState {
    pub fn is_terminal(self) -> bool {
        self != Self::Pending
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub id: String,
    pub author_id: String,
    pub base_revision: u64,
    pub edit: TextEdit,
    pub state: SuggestionState,
}

/// One change on the live channel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DocUpdate {
    /// Idempotency key: the same id is the same update.
    pub id: String,
    pub actor_id: String,
    pub op: DocOp,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", tag = "op")]
pub enum DocOp {
    Propose { suggestion_id: String, base_revision: u64, edit: TextEdit },
    Accept { suggestion_id: String },
    Reject { suggestion_id: String },
    Withdraw { suggestion_id: String },
    Edit { base_revision: u64, edit: TextEdit },
    Grant { principal_id: String, role: DocRole },
    Revoke { principal_id: String },
}

impl DocUpdate {
    /// The size this update counts against [`MAX_UPDATE_BYTES`]: its strings plus a fixed header.
    pub fn wire_len(&self) -> usize {
        let op = match &self.op {
            DocOp::Propose { suggestion_id, edit, .. } => suggestion_id.len() + edit.insert.len(),
            DocOp::Accept { suggestion_id }
            | DocOp::Reject { suggestion_id }
            | DocOp::Withdraw { suggestion_id } => suggestion_id.len(),
            DocOp::Edit { edit, .. } => edit.insert.len(),
            DocOp::Grant { principal_id, .. } | DocOp::Revoke { principal_id } => {
                principal_id.len()
            }
        };
        UPDATE_HEADER_BYTES + self.id.len() + self.actor_id.len() + op
    }
}

/// The PR an accepted RFD-draft suggestion opens. The draft changes; `main` does not.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PrPlan {
    pub repo: String,
    pub path: String,
    pub document_id: String,
    pub suggestion_id: String,
    pub author_id: String,
    /// The draft revision the PR carries.
    pub revision: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Applied {
    /// The id was seen within the window; nothing changed.
    Duplicate,
    /// Applied; the document is at `revision`.
    Changed { revision: u64 },
    /// An RFD-draft suggestion was accepted: open this PR.
    LandsThroughPr(PrPlan),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DocError {
    /// The actor cannot read the document (no role, revoked, or outside the space).
    NoAccess,
    /// The actor's role does not allow this op.
    NotAllowed {
        have: DocRole,
        need: DocRole,
    },
    /// Only the owner grants or revokes, and the owner cannot be revoked.
    OwnerOnly,
    /// Only a suggestion's author withdraws it.
    NotAuthor,
    /// `actor_id` is not the acting principal.
    ActorMismatch,
    TooLarge {
        bytes: usize,
        max: usize,
    },
    TooManyPending {
        max: usize,
    },
    UnknownSuggestion,
    /// The suggestion id is already used.
    SuggestionExists,
    /// The suggestion is already accepted, rejected or withdrawn.
    InvalidTransition {
        from: SuggestionState,
    },
    /// Written against an older revision; it stays pending.
    Stale {
        base: u64,
        current: u64,
    },
    /// The edit does not fit the body.
    BadEdit,
    /// An RFD draft changes through suggestions only.
    DraftEditsAreSuggestions,
}

impl fmt::Display for DocError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for DocError {}

/// What a reader sees.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DocView<'a> {
    pub revision: u64,
    pub role: DocRole,
    pub body: &'a str,
    pub pending: Vec<&'a Suggestion>,
}

/// A shared document's live state.
#[derive(Debug, Clone)]
pub struct DocState {
    pub doc: SharedDocument,
    pub owner_id: String,
    pub kind: DocKind,
    body: String,
    pending: BTreeMap<String, Suggestion>,
    resolved: VecDeque<(String, SuggestionState)>,
    seen: VecDeque<String>,
    seen_set: HashSet<String>,
}

impl DocState {
    pub fn new(doc: SharedDocument, owner_id: &str, kind: DocKind, body: String) -> Self {
        Self {
            doc,
            owner_id: owner_id.to_owned(),
            kind,
            body,
            pending: BTreeMap::new(),
            resolved: VecDeque::new(),
            seen: VecDeque::new(),
            seen_set: HashSet::new(),
        }
    }

    pub fn body(&self) -> &str {
        &self.body
    }

    pub fn revision(&self) -> u64 {
        self.doc.revision
    }

    pub fn pending_len(&self) -> usize {
        self.pending.len()
    }

    /// A suggestion's state while it is pending or among the recently resolved.
    pub fn suggestion_state(&self, id: &str) -> Option<SuggestionState> {
        self.pending
            .get(id)
            .map(|s| s.state)
            .or_else(|| self.resolved.iter().find(|(rid, _)| rid == id).map(|(_, st)| *st))
    }

    fn doc_role(&self, id: &str) -> Option<DocRole> {
        if id == self.owner_id { Some(DocRole::Edit) } else { self.doc.roles.get(id).copied() }
    }

    /// `actor`'s role now, or `None` when it cannot read the document.
    pub fn role_of(&self, scope: Scope<'_>, actor: Actor<'_>) -> Option<DocRole> {
        let p = actor.principal;
        let ceiling = role_ceiling(&effective(p, actor.owner, scope.team, scope.space))?;
        let mut role = self.doc_role(&p.id)?.min(ceiling);
        if let Some(owner) = actor.owner {
            let owner_role = self.role_of(scope, Actor { principal: owner, owner: None })?;
            role = role.min(owner_role);
        }
        Some(role)
    }

    pub fn read(&self, scope: Scope<'_>, actor: Actor<'_>) -> Result<DocView<'_>, DocError> {
        let role = self.role_of(scope, actor).ok_or(DocError::NoAccess)?;
        Ok(DocView {
            revision: self.doc.revision,
            role,
            body: &self.body,
            pending: self.pending.values().collect(),
        })
    }

    /// Apply one live update.
    pub fn apply(
        &mut self,
        scope: Scope<'_>,
        actor: Actor<'_>,
        update: &DocUpdate,
    ) -> Result<Applied, DocError> {
        let bytes = update.wire_len();
        if bytes > MAX_UPDATE_BYTES {
            return Err(DocError::TooLarge { bytes, max: MAX_UPDATE_BYTES });
        }
        if update.actor_id != actor.principal.id {
            return Err(DocError::ActorMismatch);
        }
        if self.seen_set.contains(&update.id) {
            return Ok(Applied::Duplicate);
        }
        let role = self.role_of(scope, actor).ok_or(DocError::NoAccess)?;
        let out = self.apply_op(&actor.principal.id, role, &update.op)?;
        self.remember(&update.id);
        Ok(out)
    }

    fn remember(&mut self, id: &str) {
        if self.seen.len() == DEDUP_WINDOW
            && let Some(old) = self.seen.pop_front()
        {
            self.seen_set.remove(&old);
        }
        self.seen.push_back(id.to_owned());
        self.seen_set.insert(id.to_owned());
    }

    fn resolve(&mut self, id: &str, state: SuggestionState) -> Result<Suggestion, DocError> {
        let Some(mut s) = self.pending.remove(id) else { return Err(DocError::UnknownSuggestion) };
        s.state = state;
        if self.resolved.len() == RESOLVED_WINDOW {
            self.resolved.pop_front();
        }
        self.resolved.push_back((s.id.clone(), state));
        Ok(s)
    }

    fn pending_or_err(&self, id: &str) -> Result<&Suggestion, DocError> {
        match self.pending.get(id) {
            Some(s) => Ok(s),
            None => match self.suggestion_state(id) {
                Some(from) => Err(DocError::InvalidTransition { from }),
                None => Err(DocError::UnknownSuggestion),
            },
        }
    }

    fn bump(&mut self) -> u64 {
        self.doc.revision += 1;
        self.doc.sync_cursor += 1;
        self.doc.revision
    }

    fn apply_op(&mut self, actor_id: &str, role: DocRole, op: &DocOp) -> Result<Applied, DocError> {
        let need = |need: DocRole| {
            if role >= need { Ok(()) } else { Err(DocError::NotAllowed { have: role, need }) }
        };
        match op {
            DocOp::Propose { suggestion_id, base_revision, edit } => {
                need(DocRole::Suggest)?;
                if self.suggestion_state(suggestion_id).is_some() {
                    return Err(DocError::SuggestionExists);
                }
                if self.pending.len() >= MAX_PENDING_SUGGESTIONS {
                    return Err(DocError::TooManyPending { max: MAX_PENDING_SUGGESTIONS });
                }
                if *base_revision > self.doc.revision {
                    return Err(DocError::Stale {
                        base: *base_revision,
                        current: self.doc.revision,
                    });
                }
                if *base_revision == self.doc.revision {
                    check_edit(&self.body, edit)?;
                }
                self.pending.insert(
                    suggestion_id.clone(),
                    Suggestion {
                        id: suggestion_id.clone(),
                        author_id: actor_id.to_owned(),
                        base_revision: *base_revision,
                        edit: edit.clone(),
                        state: SuggestionState::Pending,
                    },
                );
                Ok(Applied::Changed { revision: self.doc.revision })
            }
            DocOp::Accept { suggestion_id } => {
                need(DocRole::Edit)?;
                let s = self.pending_or_err(suggestion_id)?;
                if s.base_revision != self.doc.revision {
                    return Err(DocError::Stale {
                        base: s.base_revision,
                        current: self.doc.revision,
                    });
                }
                let edit = s.edit.clone();
                splice(&mut self.body, &edit)?;
                let s = self.resolve(suggestion_id, SuggestionState::Accepted)?;
                let revision = self.bump();
                Ok(match &self.kind {
                    DocKind::Shared => Applied::Changed { revision },
                    DocKind::RfdDraft { repo, path } => Applied::LandsThroughPr(PrPlan {
                        repo: repo.clone(),
                        path: path.clone(),
                        document_id: self.doc.id.clone(),
                        suggestion_id: s.id,
                        author_id: s.author_id,
                        revision,
                    }),
                })
            }
            DocOp::Reject { suggestion_id } => {
                need(DocRole::Edit)?;
                self.pending_or_err(suggestion_id)?;
                self.resolve(suggestion_id, SuggestionState::Rejected)?;
                Ok(Applied::Changed { revision: self.doc.revision })
            }
            DocOp::Withdraw { suggestion_id } => {
                if self.pending_or_err(suggestion_id)?.author_id != actor_id {
                    return Err(DocError::NotAuthor);
                }
                self.resolve(suggestion_id, SuggestionState::Withdrawn)?;
                Ok(Applied::Changed { revision: self.doc.revision })
            }
            DocOp::Edit { base_revision, edit } => {
                need(DocRole::Edit)?;
                if matches!(self.kind, DocKind::RfdDraft { .. }) {
                    return Err(DocError::DraftEditsAreSuggestions);
                }
                if *base_revision != self.doc.revision {
                    return Err(DocError::Stale {
                        base: *base_revision,
                        current: self.doc.revision,
                    });
                }
                splice(&mut self.body, edit)?;
                Ok(Applied::Changed { revision: self.bump() })
            }
            DocOp::Grant { principal_id, role: granted } => {
                if actor_id != self.owner_id {
                    return Err(DocError::OwnerOnly);
                }
                if *principal_id != self.owner_id {
                    self.doc.roles.insert(principal_id.clone(), *granted);
                }
                Ok(Applied::Changed { revision: self.doc.revision })
            }
            DocOp::Revoke { principal_id } => {
                if actor_id != self.owner_id || *principal_id == self.owner_id {
                    return Err(DocError::OwnerOnly);
                }
                self.doc.roles.remove(principal_id);
                Ok(Applied::Changed { revision: self.doc.revision })
            }
        }
    }
}

fn check_edit(body: &str, e: &TextEdit) -> Result<(), DocError> {
    let end = e.at.checked_add(e.delete).ok_or(DocError::BadEdit)?;
    if end > body.len() || !body.is_char_boundary(e.at) || !body.is_char_boundary(end) {
        return Err(DocError::BadEdit);
    }
    let bytes = body.len() - e.delete + e.insert.len();
    if bytes > MAX_DOC_BYTES {
        return Err(DocError::TooLarge { bytes, max: MAX_DOC_BYTES });
    }
    Ok(())
}

/// Splice in place: one memmove, no new buffer.
fn splice(body: &mut String, e: &TextEdit) -> Result<(), DocError> {
    check_edit(body, e)?;
    body.replace_range(e.at..e.at + e.delete, &e.insert);
    Ok(())
}
