//! RFD 0170 phase 2, the knowledge loop: typed templates for a tip, finding, ask, feedback or
//! receipt; the RFD reader's discussion, session, implementation and feedback sections; a thread's
//! back-link to its RFDs; and search-before-work, which offers an existing open thread before a
//! duplicate post.
//!
//! Every view is computed for one viewer. A link never names a target the viewer cannot read; it is
//! counted in `hidden` instead. Votes are feedback, never a gate: people's votes are counted, an
//! agent's vote is advisory and shown with its owner. Nothing here does I/O or reads a clock.

use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fmt;

use serde::{Deserialize, Serialize};

use crate::feedback::{FeedbackKind, VoteBoard};
use crate::identity::{self, IdentityError, PrincipalKind};
use crate::model::{Principal, RootKind, Space, Team, Thread, ThreadState};
use crate::permission::{Capability, effective};
use crate::refs::{LinkGraph, RefKey, RefKind, RefSource, StableRef};

/// The records the knowledge views are computed from.
#[derive(Debug, Clone, Default)]
pub struct Corpus {
    pub principals: Vec<Principal>,
    pub teams: Vec<Team>,
    pub spaces: Vec<Space>,
    pub threads: Vec<Thread>,
}

// ---------------------------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------------------------

/// The built-in templates RFD 0170 names for phase 2.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Template {
    Tip,
    Finding,
    Ask,
    Feedback,
    Receipt,
}

impl Template {
    pub const ALL: [Template; 5] =
        [Self::Tip, Self::Finding, Self::Ask, Self::Feedback, Self::Receipt];

    pub fn root_kind(self) -> RootKind {
        match self {
            Self::Tip => RootKind::Tip,
            Self::Finding => RootKind::Finding,
            Self::Ask => RootKind::Ask,
            Self::Feedback => RootKind::Feedback,
            Self::Receipt => RootKind::Receipt,
        }
    }

    /// Fields the template needs filled, besides the subject and body.
    pub fn required_fields(self) -> &'static [&'static str] {
        match self {
            // When the tip applies, so a reader can tell whether it is theirs.
            Self::Tip => &["appliesWhen"],
            // What was seen and how to see it again.
            Self::Finding => &["evidence", "reproduce"],
            // What answers the ask.
            Self::Ask => &["doneWhen"],
            Self::Feedback => &["verdict"],
            Self::Receipt => &["outcome"],
        }
    }

    /// The ref kinds of which the draft must carry at least one, if any.
    pub fn required_ref(self) -> Option<&'static [RefKind]> {
        match self {
            Self::Feedback => Some(&[RefKind::Rfd, RefKind::Thread, RefKind::Session]),
            Self::Receipt => Some(&[RefKind::Pr, RefKind::Issue, RefKind::Thread]),
            Self::Tip | Self::Finding | Self::Ask => None,
        }
    }
}

/// What a template composer holds before posting.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TemplateDraft {
    pub template: Template,
    pub space_id: String,
    pub subject: String,
    pub body: String,
    #[serde(default)]
    pub fields: BTreeMap<String, String>,
    #[serde(default)]
    pub refs: Vec<StableRef>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateError {
    EmptySubject,
    EmptyBody,
    MissingField { template: Template, field: &'static str },
    MissingRef { template: Template, kinds: &'static [RefKind] },
    UnknownSpace(String),
    UnknownTeam(String),
    CannotPost { author: String, space: String },
    Identity(IdentityError),
}

impl fmt::Display for TemplateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::EmptySubject => write!(f, "the subject is empty"),
            Self::EmptyBody => write!(f, "the body is empty"),
            Self::MissingField { template, field } => {
                write!(f, "a {} needs {field}", template.root_kind().as_str())
            }
            Self::MissingRef { template, kinds } => {
                let k: Vec<&str> = kinds.iter().map(|k| k.as_str()).collect();
                write!(f, "a {} links one of {}", template.root_kind().as_str(), k.join(", "))
            }
            Self::UnknownSpace(s) => write!(f, "no space {s}"),
            Self::UnknownTeam(t) => write!(f, "no team {t}"),
            Self::CannotPost { author, space } => write!(f, "{author} cannot post in {space}"),
            Self::Identity(e) => write!(f, "{e}"),
        }
    }
}

impl std::error::Error for TemplateError {}

/// A built thread and the links to record for it, both ways.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Built {
    pub thread: Thread,
    pub links: Vec<(RefKey, RefKey)>,
}

impl Built {
    /// Record the thread's links in `graph`. Returns how many were new.
    pub fn link_into(&self, graph: &mut LinkGraph) -> usize {
        self.links.iter().filter(|(a, b)| graph.link(a, b)).count()
    }
}

pub fn thread_key(id: &str) -> RefKey {
    RefKey { kind: RefKind::Thread, source: RefSource::Cmux, id: id.to_owned() }
}

// ---------------------------------------------------------------------------------------------
// One call's index
// ---------------------------------------------------------------------------------------------

/// Lookups by id, built once per call in O(records).
struct Ix<'a> {
    threads: &'a [Thread],
    principal_by: HashMap<&'a str, &'a Principal>,
    team_by: HashMap<&'a str, &'a Team>,
    space_by: HashMap<&'a str, &'a Space>,
    thread_by: HashMap<&'a str, &'a Thread>,
    members: HashMap<&'a str, HashSet<&'a str>>,
}

impl<'a> Ix<'a> {
    fn new(c: &'a Corpus) -> Self {
        Self {
            threads: &c.threads,
            principal_by: c.principals.iter().map(|p| (p.id.as_str(), p)).collect(),
            team_by: c.teams.iter().map(|t| (t.id.as_str(), t)).collect(),
            space_by: c.spaces.iter().map(|s| (s.id.as_str(), s)).collect(),
            thread_by: c.threads.iter().map(|t| (t.id.as_str(), t)).collect(),
            members: c
                .spaces
                .iter()
                .map(|s| (s.id.as_str(), s.members.iter().map(String::as_str).collect()))
                .collect(),
        }
    }

    fn owner_of(&self, p: &Principal) -> Option<&'a Principal> {
        match p.kind {
            PrincipalKind::Agent => {
                p.owner_person_id.as_deref().and_then(|o| self.principal_by.get(o).copied())
            }
            PrincipalKind::Person => None,
        }
    }

    fn is_member(&self, space: &Space, id: &str) -> bool {
        self.members.get(space.id.as_str()).is_some_and(|m| m.contains(id))
    }

    fn grants_has(&self, p: &Principal, space: &Space, cap: Capability) -> bool {
        // `effective` needs the principal, and an agent's owner, to be members: an O(1) check first.
        if !self.is_member(space, &p.id) {
            return false;
        }
        let owner = self.owner_of(p);
        if p.kind == PrincipalKind::Agent && !owner.is_some_and(|o| self.is_member(space, &o.id)) {
            return false;
        }
        self.team_by
            .get(space.team_id.as_str())
            .is_some_and(|team| effective(p, owner, team, space).has(cap))
    }

    fn can_read_thread(&self, viewer: &Principal, id: &str) -> bool {
        self.thread_by
            .get(id)
            .and_then(|t| self.space_by.get(t.space_id.as_str()))
            .is_some_and(|s| self.grants_has(viewer, s, Capability::Read))
    }

    /// Threads and spaces carry cmux permissions; RFDs, sessions, PRs and issues carry their own
    /// access and are only linked here.
    fn can_read(&self, viewer: &Principal, key: &RefKey) -> bool {
        match key.kind {
            RefKind::Thread => self.can_read_thread(viewer, &key.id),
            RefKind::Space => self
                .space_by
                .get(key.id.as_str())
                .is_some_and(|s| self.grants_has(viewer, s, Capability::Read)),
            _ => true,
        }
    }
}

impl Corpus {
    /// Check a template draft and build its thread, writing nothing. The author is validated as in
    /// the send path, must be able to post in the space, and becomes the first participant.
    pub fn build(
        &self,
        author: &Principal,
        draft: &TemplateDraft,
        thread_id: &str,
    ) -> Result<Built, TemplateError> {
        identity::validate(author).map_err(TemplateError::Identity)?;
        identity::require_rights(author).map_err(TemplateError::Identity)?;
        if draft.subject.trim().is_empty() {
            return Err(TemplateError::EmptySubject);
        }
        if draft.body.trim().is_empty() {
            return Err(TemplateError::EmptyBody);
        }
        let t = draft.template;
        for field in t.required_fields() {
            if draft.fields.get(*field).is_none_or(|v| v.trim().is_empty()) {
                return Err(TemplateError::MissingField { template: t, field });
            }
        }
        if let Some(kinds) = t.required_ref() {
            if !draft.refs.iter().any(|r| kinds.contains(&r.key.kind)) {
                return Err(TemplateError::MissingRef { template: t, kinds });
            }
        }
        let ix = Ix::new(self);
        let space = ix
            .space_by
            .get(draft.space_id.as_str())
            .copied()
            .ok_or_else(|| TemplateError::UnknownSpace(draft.space_id.clone()))?;
        if !ix.team_by.contains_key(space.team_id.as_str()) {
            return Err(TemplateError::UnknownTeam(space.team_id.clone()));
        }
        if !ix.grants_has(author, space, Capability::Post) {
            return Err(TemplateError::CannotPost {
                author: author.id.clone(),
                space: space.id.clone(),
            });
        }

        let mut rfds: Vec<String> = Vec::new();
        let mut sessions: Vec<String> = Vec::new();
        let me = thread_key(thread_id);
        let mut links = Vec::new();
        let mut seen = BTreeSet::new();
        for r in &draft.refs {
            if r.key == me || !seen.insert(r.key.clone()) {
                continue;
            }
            match r.key.kind {
                RefKind::Rfd => rfds.push(r.key.id.clone()),
                RefKind::Session => sessions.push(r.key.id.clone()),
                _ => {}
            }
            links.push((me.clone(), r.key.clone()));
        }
        Ok(Built {
            thread: Thread {
                id: thread_id.to_owned(),
                space_id: space.id.clone(),
                root_kind: t.root_kind(),
                subject: draft.subject.trim().to_owned(),
                participants: vec![author.id.clone()],
                linked_rfd_ids: rfds,
                linked_session_ids: sessions,
                revision: 0,
                state: ThreadState::Open,
            },
            links,
        })
    }
}

// ---------------------------------------------------------------------------------------------
// RFD reader and thread back-links
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RefRow {
    pub key: RefKey,
    /// `kind:source/id`, what the opener and `Copy link` take.
    pub canonical: String,
    pub title: String,
}

fn row(key: RefKey, title: impl Into<String>) -> RefRow {
    RefRow { canonical: key.canonical(), key, title: title.into() }
}

/// An agent's current vote, shown as advice with the person it acts for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AdvisoryVote {
    pub agent_id: String,
    pub agent_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_name: Option<String>,
    pub value: i8,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedbackView {
    /// `(value, people)` for each value some person currently holds, by value.
    pub people: Vec<(i8, u32)>,
    /// Agents' current votes; never added into `people`.
    pub advisory: Vec<AdvisoryVote>,
    pub comments: u32,
    /// The viewer's own current vote, if any.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mine: Option<i8>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", rename_all_fields = "camelCase")]
pub enum ReaderAction {
    /// The newest readable discussion thread.
    DiscussInThread {
        target: String,
    },
    /// No readable discussion yet: start a `feedback` thread linked to the RFD.
    StartDiscussion {
        rfd: String,
    },
    OpenSession {
        target: String,
    },
    OpenRfd {
        target: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RfdReader {
    pub rfd: RefRow,
    /// Readable threads linked to the RFD, newest revision first.
    pub threads: Vec<RefRow>,
    pub sessions: Vec<RefRow>,
    /// Implementation PRs and issues.
    pub implementation: Vec<RefRow>,
    pub feedback: FeedbackView,
    /// Linked targets the viewer cannot read, counted and never named.
    pub hidden: usize,
    pub actions: Vec<ReaderAction>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ThreadLinks {
    pub thread: RefRow,
    pub rfds: Vec<RefRow>,
    pub sessions: Vec<RefRow>,
    pub hidden: usize,
    pub actions: Vec<ReaderAction>,
}

/// The feedback summary for `target` as `viewer` sees it.
pub fn feedback_view(
    corpus: &Corpus,
    board: &VoteBoard,
    target: &RefKey,
    viewer: &Principal,
) -> FeedbackView {
    let ix = Ix::new(corpus);
    feedback_with(&ix, board, target, viewer)
}

fn feedback_with(
    ix: &Ix<'_>,
    board: &VoteBoard,
    target: &RefKey,
    viewer: &Principal,
) -> FeedbackView {
    let summary = board.summary(target);
    // The agents' current votes, newest per agent, from the board's own current-vote rule.
    let mut agents: BTreeSet<&str> = BTreeSet::new();
    for f in board.events() {
        if f.kind == FeedbackKind::Vote
            && &f.target_ref.key == target
            && f.author.kind == PrincipalKind::Agent
        {
            agents.insert(f.author.id.as_str());
        }
    }
    let advisory = agents
        .into_iter()
        .filter_map(|a| board.current(target, a))
        .filter_map(|f| {
            let owner_id = f.author.owner_person_id.clone();
            let owner_name = owner_id
                .as_deref()
                .and_then(|o| ix.principal_by.get(o))
                .map(|p| p.display_name.clone());
            Some(AdvisoryVote {
                agent_id: f.author.id.clone(),
                agent_name: f.author.display_name.clone(),
                owner_id,
                owner_name,
                value: f.value?,
            })
        })
        .collect();
    FeedbackView {
        people: summary.people.into_iter().collect(),
        advisory,
        comments: summary.comments,
        mine: board.current(target, &viewer.id).and_then(|f| f.value),
    }
}

impl Corpus {
    /// The RFD reader's sections for `viewer`. `titles` maps a canonical ref to its display title.
    pub fn rfd_reader(
        &self,
        viewer: &Principal,
        rfd: &RefKey,
        links: &LinkGraph,
        board: &VoteBoard,
        titles: &BTreeMap<String, String>,
    ) -> RfdReader {
        let ix = Ix::new(self);
        let title_of =
            |k: &RefKey| titles.get(&k.canonical()).cloned().unwrap_or_else(|| k.id.clone());
        let mut hidden = 0;
        let mut thread_ids: BTreeSet<&str> = BTreeSet::new();
        let mut sessions: Vec<RefRow> = Vec::new();
        let mut implementation: Vec<RefRow> = Vec::new();
        let mut unreadable: HashSet<&str> = HashSet::new();
        let linked = links.links(rfd);
        for k in &linked {
            if !ix.can_read(viewer, k) {
                hidden += 1;
                if k.kind == RefKind::Thread {
                    unreadable.insert(k.id.as_str());
                }
                continue;
            }
            match k.kind {
                RefKind::Thread => {
                    thread_ids.insert(k.id.as_str());
                }
                RefKind::Session => sessions.push(row(k.clone(), title_of(k))),
                RefKind::Pr | RefKind::Issue => implementation.push(row(k.clone(), title_of(k))),
                _ => {}
            }
        }
        // A thread whose own record names the RFD is a discussion too, linked in the graph or not.
        for t in ix.threads {
            if thread_ids.contains(t.id.as_str()) || unreadable.contains(t.id.as_str()) {
                continue;
            }
            let names = t
                .linked_rfd_ids
                .iter()
                .any(|id| RefKey::new(RefKind::Rfd, RefSource::Hq, id).is_ok_and(|k| &k == rfd));
            if !names {
                continue;
            }
            if ix.can_read_thread(viewer, &t.id) {
                thread_ids.insert(t.id.as_str());
            } else {
                hidden += 1;
            }
        }
        let mut threads: Vec<&Thread> =
            thread_ids.into_iter().filter_map(|id| ix.thread_by.get(id).copied()).collect();
        threads.sort_by(|a, b| b.revision.cmp(&a.revision).then_with(|| a.id.cmp(&b.id)));
        let threads: Vec<RefRow> =
            threads.iter().map(|t| row(thread_key(&t.id), t.subject.clone())).collect();

        let mut actions = Vec::new();
        match threads.first() {
            Some(t) => actions.push(ReaderAction::DiscussInThread { target: t.canonical.clone() }),
            None => actions.push(ReaderAction::StartDiscussion { rfd: rfd.canonical() }),
        }
        if let Some(s) = sessions.first() {
            actions.push(ReaderAction::OpenSession { target: s.canonical.clone() });
        }
        RfdReader {
            rfd: row(rfd.clone(), title_of(rfd)),
            threads,
            sessions,
            implementation,
            feedback: feedback_with(&ix, board, rfd, viewer),
            hidden,
            actions,
        }
    }

    /// A thread's back-links to its RFDs and sessions, from the graph and its own record. `None`
    /// when the viewer cannot read the thread.
    pub fn thread_links(
        &self,
        viewer: &Principal,
        thread_id: &str,
        links: &LinkGraph,
        titles: &BTreeMap<String, String>,
    ) -> Option<ThreadLinks> {
        let ix = Ix::new(self);
        if !ix.can_read_thread(viewer, thread_id) {
            return None;
        }
        let t = ix.thread_by.get(thread_id)?;
        let title_of =
            |k: &RefKey| titles.get(&k.canonical()).cloned().unwrap_or_else(|| k.id.clone());
        let me = thread_key(thread_id);
        let mut rfds: BTreeSet<RefKey> = BTreeSet::new();
        let mut sessions: BTreeSet<RefKey> = BTreeSet::new();
        let mut hidden = 0;
        for k in links.links(&me) {
            if !ix.can_read(viewer, &k) {
                hidden += 1;
                continue;
            }
            match k.kind {
                RefKind::Rfd => {
                    rfds.insert(k);
                }
                RefKind::Session => {
                    sessions.insert(k);
                }
                _ => {}
            }
        }
        for id in &t.linked_rfd_ids {
            if let Ok(k) = RefKey::new(RefKind::Rfd, RefSource::Hq, id) {
                rfds.insert(k);
            }
        }
        for id in &t.linked_session_ids {
            if let Ok(k) = RefKey::new(RefKind::Session, RefSource::Cmux, id) {
                sessions.insert(k);
            }
        }
        let rfds: Vec<RefRow> = rfds
            .into_iter()
            .map(|k| {
                let t = title_of(&k);
                row(k, t)
            })
            .collect();
        let sessions: Vec<RefRow> = sessions
            .into_iter()
            .map(|k| {
                let t = title_of(&k);
                row(k, t)
            })
            .collect();
        let mut actions = Vec::new();
        if let Some(r) = rfds.first() {
            actions.push(ReaderAction::OpenRfd { target: r.canonical.clone() });
        }
        if let Some(s) = sessions.first() {
            actions.push(ReaderAction::OpenSession { target: s.canonical.clone() });
        }
        Some(ThreadLinks { thread: row(me, t.subject.clone()), rfds, sessions, hidden, actions })
    }
}

// ---------------------------------------------------------------------------------------------
// Search before work
// ---------------------------------------------------------------------------------------------

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Similar {
    pub thread: RefRow,
    pub space_id: String,
    /// Shared tokens over the union, in thousandths.
    pub score: u32,
}

const STOP: &[&str] = &[
    "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on",
    "or", "the", "to", "with",
];

fn tokens(s: &str) -> HashSet<String> {
    s.split(|c: char| !c.is_alphanumeric())
        .filter(|w| !w.is_empty())
        .map(str::to_lowercase)
        .filter(|w| !STOP.contains(&w.as_str()))
        .collect()
}

impl Corpus {
    /// Before posting a `template` with `subject`, the open threads of the same kind the viewer can
    /// read, ranked by token overlap (at least `min_score` thousandths), best first, at most `limit`.
    pub fn search_before_work(
        &self,
        viewer: &Principal,
        template: Template,
        subject: &str,
        min_score: u32,
        limit: usize,
    ) -> Vec<Similar> {
        let want = tokens(subject);
        if want.is_empty() {
            return Vec::new();
        }
        let ix = Ix::new(self);
        let kind = template.root_kind();
        // Readability is per space: decide each space once.
        let mut readable: HashMap<&str, bool> = HashMap::new();
        let mut out: Vec<Similar> = Vec::new();
        for t in ix.threads {
            if t.root_kind != kind || t.state != ThreadState::Open {
                continue;
            }
            let have = tokens(&t.subject);
            let shared = want.intersection(&have).count();
            if shared == 0 {
                continue;
            }
            let union = want.len() + have.len() - shared;
            let score = (shared * 1000 / union) as u32;
            if score < min_score {
                continue;
            }
            let ok = *readable.entry(t.space_id.as_str()).or_insert_with(|| {
                ix.space_by
                    .get(t.space_id.as_str())
                    .is_some_and(|s| ix.grants_has(viewer, s, Capability::Read))
            });
            if !ok {
                continue;
            }
            out.push(Similar {
                thread: row(thread_key(&t.id), t.subject.clone()),
                space_id: t.space_id.clone(),
                score,
            });
        }
        out.sort_by(|a, b| {
            b.score.cmp(&a.score).then_with(|| a.thread.key.id.cmp(&b.thread.key.id))
        });
        out.truncate(limit);
        out
    }
}
