//! RFD 0170 phase 3: the shared-document projection. Property tests for role intersection, revoke,
//! deduplication and the suggestion state machine, plus an ignored bench at 20 participants.

mod common;

use std::collections::BTreeMap;
use std::time::Instant;

use proptest::prelude::*;

use cmux_team_messaging::model::DocRole;
use cmux_team_messaging::shared_doc::{
    Actor, Applied, DocError, DocKind, DocOp, DocState, DocUpdate, MAX_PENDING_SUGGESTIONS,
    MAX_UPDATE_BYTES, Scope, SuggestionState, TextEdit, role_ceiling,
};
use cmux_team_messaging::{
    Capability, Grants, Principal, RefKind, RefSource, SharedDocument, Space, StableRef, Team,
    effective,
};

use common::*;

fn doc(roles: &[(&str, DocRole)]) -> SharedDocument {
    SharedDocument {
        id: "doc-1".to_owned(),
        owner_ref: StableRef::new(RefKind::Thread, RefSource::Cmux, "thread-1", "Thread").unwrap(),
        thread_id: Some("thread-1".to_owned()),
        session_id: None,
        revision: 0,
        sync_cursor: 0,
        roles: roles.iter().map(|(p, r)| ((*p).to_owned(), *r)).collect(),
        presence_scope: "space-1".to_owned(),
    }
}

fn state(kind: DocKind, roles: &[(&str, DocRole)]) -> DocState {
    DocState::new(doc(roles), "owner", kind, "hello world".to_owned())
}

fn rfd_draft() -> DocKind {
    DocKind::RfdDraft {
        repo: "manaflow-ai/cmuxterm-hq".to_owned(),
        path: "docs/rfd/0170-native-team-messaging.md".to_owned(),
    }
}

fn me(p: &Principal) -> Actor<'_> {
    Actor { principal: p, owner: None }
}

fn up(id: &str, actor: &str, op: DocOp) -> DocUpdate {
    DocUpdate { id: id.to_owned(), actor_id: actor.to_owned(), op }
}

fn ins(at: usize, text: &str) -> TextEdit {
    TextEdit { at, delete: 0, insert: text.to_owned() }
}

fn propose(id: &str, actor: &str, sid: &str, base: u64) -> DocUpdate {
    up(
        id,
        actor,
        DocOp::Propose { suggestion_id: sid.to_owned(), base_revision: base, edit: ins(0, "x") },
    )
}

struct World {
    team: Team,
    space: Space,
}

impl World {
    fn new(members: &[&str]) -> Self {
        Self { team: team(Grants::all()), space: space(members) }
    }
    fn scope(&self) -> Scope<'_> {
        Scope { team: &self.team, space: &self.space }
    }
}

fn grants() -> impl Strategy<Value = Grants> {
    prop::collection::btree_set(prop::sample::select(Capability::ALL.to_vec()), 0..=4)
        .prop_map(|s| Grants(s.into_iter().collect()))
}

fn role() -> impl Strategy<Value = Option<DocRole>> {
    prop::option::of(prop::sample::select(vec![DocRole::View, DocRole::Suggest, DocRole::Edit]))
}

proptest! {
    /// A role is never more than the document grants, the space allows, or (for an agent) its owner has.
    #[test]
    fn role_is_the_intersection(
        policy in grants(), own in grants(), owner_caps in grants(),
        doc_role in role(), owner_role in role(), in_space in any::<bool>(),
    ) {
        let t = team(policy);
        let members: &[&str] = if in_space { &["owner", "p", "bot"] } else { &["owner"] };
        let s = space(members);
        let p = person("p", owner_caps);
        let bot = agent("bot", "p", own);
        let mut roles = BTreeMap::new();
        if let Some(r) = owner_role { roles.insert("p".to_owned(), r); }
        if let Some(r) = doc_role { roles.insert("bot".to_owned(), r); }
        let mut d = doc(&[]);
        d.roles = roles;
        let st = DocState::new(d, "owner", DocKind::Shared, String::new());
        let scope = Scope { team: &t, space: &s };

        let pr = st.role_of(scope, me(&p));
        prop_assert!(pr <= owner_role);
        prop_assert!(pr <= role_ceiling(&effective(&p, None, &t, &s)));
        let br = st.role_of(scope, Actor { principal: &bot, owner: Some(&p) });
        prop_assert!(br <= doc_role);
        prop_assert!(br <= pr);
        prop_assert!(br <= role_ceiling(&effective(&bot, Some(&p), &t, &s)));
        if !in_space { prop_assert_eq!(pr, None); prop_assert_eq!(br, None); }
        // No owner: an agent gets nothing.
        prop_assert_eq!(st.role_of(scope, me(&bot)), None);
    }

    /// Replaying any update sequence, each update twice, leaves the same document as applying it once.
    #[test]
    fn replay_is_idempotent(ops in prop::collection::vec((0u8..5, 0u8..6, 0u8..3), 0..60)) {
        let w = World::new(&["owner", "a", "b"]);
        let owner = person("owner", Grants::all());
        let a = person("a", Grants::all());
        let b = person("b", Grants::of(&[Capability::Read, Capability::Feedback]));
        let roles = [("a", DocRole::Edit), ("b", DocRole::Suggest)];
        let mut once = state(DocKind::Shared, &roles);
        let mut twice = state(DocKind::Shared, &roles);
        for (i, (kind, sid, who)) in ops.into_iter().enumerate() {
            let p = [&owner, &a, &b][who as usize];
            let sid = format!("s{sid}");
            let op = match kind {
                0 => DocOp::Propose { suggestion_id: sid, base_revision: once.revision(), edit: ins(0, "x") },
                1 => DocOp::Accept { suggestion_id: sid },
                2 => DocOp::Reject { suggestion_id: sid },
                3 => DocOp::Withdraw { suggestion_id: sid },
                _ => DocOp::Edit { base_revision: once.revision(), edit: ins(0, "y") },
            };
            let u = up(&format!("u{i}"), &p.id, op);
            let r1 = once.apply(w.scope(), me(p), &u);
            let r2 = twice.apply(w.scope(), me(p), &u);
            prop_assert_eq!(&r1, &r2);
            let r3 = twice.apply(w.scope(), me(p), &u);
            if r1.is_ok() { prop_assert_eq!(r3, Ok(Applied::Duplicate)); }
        }
        prop_assert_eq!(once.body(), twice.body());
        prop_assert_eq!(once.revision(), twice.revision());
        prop_assert_eq!(once.pending_len(), twice.pending_len());
    }

    /// A suggestion leaves `pending` at most once; revision counts accepted suggestions and edits;
    /// pending never passes its cap.
    #[test]
    fn suggestion_state_machine(ops in prop::collection::vec((0u8..5, 0u8..8, 0u8..3), 0..120)) {
        let w = World::new(&["owner", "a", "b"]);
        let owner = person("owner", Grants::all());
        let a = person("a", Grants::all());
        let b = person("b", Grants::of(&[Capability::Read, Capability::Feedback]));
        let mut st = state(DocKind::Shared, &[("a", DocRole::Edit), ("b", DocRole::Suggest)]);
        let mut finals: BTreeMap<String, SuggestionState> = BTreeMap::new();
        let mut changes = 0u64;
        for (i, (kind, sid, who)) in ops.into_iter().enumerate() {
            let p = [&owner, &a, &b][who as usize];
            let sid = format!("s{sid}");
            let op = match kind {
                0 => DocOp::Propose { suggestion_id: sid.clone(), base_revision: st.revision(), edit: ins(0, "x") },
                1 => DocOp::Accept { suggestion_id: sid.clone() },
                2 => DocOp::Reject { suggestion_id: sid.clone() },
                3 => DocOp::Withdraw { suggestion_id: sid.clone() },
                _ => DocOp::Edit { base_revision: st.revision(), edit: ins(0, "y") },
            };
            let before = st.suggestion_state(&sid);
            let r = st.apply(w.scope(), me(p), &up(&format!("u{i}"), &p.id, op));
            let after = st.suggestion_state(&sid);
            if let Some(f) = finals.get(&sid) {
                prop_assert_eq!(after, Some(*f), "a resolved suggestion never moves");
                prop_assert!(r.is_err() || kind == 4);
            }
            if let Some(done) = after && done.is_terminal() { finals.insert(sid.clone(), done); }
            if r.is_ok() && (kind == 4 || (kind == 1 && before == Some(SuggestionState::Pending))) {
                changes += 1;
            }
            // A suggester never accepts, rejects or edits.
            if who == 2 && matches!(kind, 1 | 2 | 4) { prop_assert!(r.is_err()); }
            prop_assert!(st.pending_len() <= MAX_PENDING_SUGGESTIONS);
        }
        prop_assert_eq!(st.revision(), changes);
    }
}

#[test]
fn revoke_takes_effect_on_the_next_read() {
    let mut w = World::new(&["owner", "a"]);
    let owner = person("owner", Grants::all());
    let a = person("a", Grants::all());
    let mut st = state(DocKind::Shared, &[("a", DocRole::Edit)]);
    assert_eq!(st.read(w.scope(), me(&a)).unwrap().role, DocRole::Edit);

    // Only the owner revokes, and the owner cannot be revoked.
    let r =
        st.apply(w.scope(), me(&a), &up("u0", "a", DocOp::Revoke { principal_id: "owner".into() }));
    assert_eq!(r, Err(DocError::OwnerOnly));
    st.apply(w.scope(), me(&owner), &up("u1", "owner", DocOp::Revoke { principal_id: "a".into() }))
        .unwrap();
    assert_eq!(st.read(w.scope(), me(&a)), Err(DocError::NoAccess));
    assert_eq!(st.apply(w.scope(), me(&a), &propose("u2", "a", "s1", 0)), Err(DocError::NoAccess));

    // Leaving the space also ends access, with the document role still in place.
    st.apply(
        w.scope(),
        me(&owner),
        &up("u3", "owner", DocOp::Grant { principal_id: "a".into(), role: DocRole::Edit }),
    )
    .unwrap();
    assert!(st.read(w.scope(), me(&a)).is_ok());
    w.space.members.retain(|m| m != "a");
    assert_eq!(st.read(w.scope(), me(&a)), Err(DocError::NoAccess));
}

#[test]
fn commenter_suggests_but_does_not_edit() {
    let w = World::new(&["owner", "c"]);
    let owner = person("owner", Grants::all());
    // Space grants allow edit; the document role is suggest.
    let c = person("c", Grants::all());
    let mut st = state(DocKind::Shared, &[("c", DocRole::Suggest)]);
    let edit = up("u0", "c", DocOp::Edit { base_revision: 0, edit: ins(0, "x") });
    assert_eq!(
        st.apply(w.scope(), me(&c), &edit),
        Err(DocError::NotAllowed { have: DocRole::Suggest, need: DocRole::Edit })
    );
    st.apply(w.scope(), me(&c), &propose("u1", "c", "s1", 0)).unwrap();
    assert_eq!(
        st.apply(w.scope(), me(&c), &up("u2", "c", DocOp::Accept { suggestion_id: "s1".into() })),
        Err(DocError::NotAllowed { have: DocRole::Suggest, need: DocRole::Edit })
    );
    assert_eq!(
        st.apply(
            w.scope(),
            me(&owner),
            &up("u3", "owner", DocOp::Accept { suggestion_id: "s1".into() })
        ),
        Ok(Applied::Changed { revision: 1 })
    );
    assert_eq!(st.body(), "xhello world");
    // A stale suggestion stays pending.
    st.apply(w.scope(), me(&c), &propose("u4", "c", "s2", 0)).unwrap();
    assert_eq!(
        st.apply(
            w.scope(),
            me(&owner),
            &up("u5", "owner", DocOp::Accept { suggestion_id: "s2".into() })
        ),
        Err(DocError::Stale { base: 0, current: 1 })
    );
    assert_eq!(st.suggestion_state("s2"), Some(SuggestionState::Pending));
    // Only the author withdraws.
    assert_eq!(
        st.apply(
            w.scope(),
            me(&owner),
            &up("u6", "owner", DocOp::Withdraw { suggestion_id: "s2".into() })
        ),
        Err(DocError::NotAuthor)
    );
    st.apply(w.scope(), me(&c), &up("u7", "c", DocOp::Withdraw { suggestion_id: "s2".into() }))
        .unwrap();
    assert_eq!(st.suggestion_state("s2"), Some(SuggestionState::Withdrawn));
}

#[test]
fn space_grants_cap_the_document_role() {
    let w = World::new(&["owner", "r"]);
    // Read and feedback only: a document editor can suggest at most.
    let r = person("r", Grants::of(&[Capability::Read, Capability::Feedback]));
    let st = state(DocKind::Shared, &[("r", DocRole::Edit)]);
    assert_eq!(st.role_of(w.scope(), me(&r)), Some(DocRole::Suggest));
    let r = person("r", Grants::of(&[Capability::Read]));
    assert_eq!(st.role_of(w.scope(), me(&r)), Some(DocRole::View));
    let r = person("r", Grants::of(&[Capability::Post]));
    assert_eq!(st.role_of(w.scope(), me(&r)), None);
}

#[test]
fn rfd_draft_lands_through_a_pr() {
    let w = World::new(&["owner", "c"]);
    let owner = person("owner", Grants::all());
    let c = person("c", Grants::all());
    let mut st = state(rfd_draft(), &[("c", DocRole::Suggest)]);
    assert_eq!(
        st.apply(
            w.scope(),
            me(&owner),
            &up("u0", "owner", DocOp::Edit { base_revision: 0, edit: ins(0, "x") })
        ),
        Err(DocError::DraftEditsAreSuggestions)
    );
    st.apply(w.scope(), me(&c), &propose("u1", "c", "s1", 0)).unwrap();
    let out = st
        .apply(
            w.scope(),
            me(&owner),
            &up("u2", "owner", DocOp::Accept { suggestion_id: "s1".into() }),
        )
        .unwrap();
    let Applied::LandsThroughPr(plan) = out else { panic!("expected a PR plan, got {out:?}") };
    assert_eq!(plan.repo, "manaflow-ai/cmuxterm-hq");
    assert_eq!(plan.path, "docs/rfd/0170-native-team-messaging.md");
    assert_eq!(
        (plan.suggestion_id.as_str(), plan.author_id.as_str(), plan.revision),
        ("s1", "c", 1)
    );
}

#[test]
fn bounds_hold() {
    let w = World::new(&["owner"]);
    let owner = person("owner", Grants::all());
    let mut st = state(DocKind::Shared, &[]);
    let big = up(
        "big",
        "owner",
        DocOp::Edit { base_revision: 0, edit: ins(0, &"x".repeat(MAX_UPDATE_BYTES)) },
    );
    assert!(matches!(st.apply(w.scope(), me(&owner), &big), Err(DocError::TooLarge { .. })));
    for i in 0..MAX_PENDING_SUGGESTIONS {
        st.apply(w.scope(), me(&owner), &propose(&format!("u{i}"), "owner", &format!("s{i}"), 0))
            .unwrap();
    }
    assert_eq!(
        st.apply(w.scope(), me(&owner), &propose("over", "owner", "over", 0)),
        Err(DocError::TooManyPending { max: MAX_PENDING_SUGGESTIONS })
    );
    // An edit outside the body or off a char boundary is refused.
    let bad = up(
        "bad",
        "owner",
        DocOp::Edit { base_revision: 0, edit: TextEdit { at: 99, delete: 0, insert: "x".into() } },
    );
    assert_eq!(st.apply(w.scope(), me(&owner), &bad), Err(DocError::BadEdit));
    // The wrong actor id is refused before anything else.
    assert_eq!(
        st.apply(w.scope(), me(&owner), &propose("x", "someone", "sx", 0)),
        Err(DocError::ActorMismatch)
    );
}

/// Propose then accept, round robin over 20 participants. Prints suggestions per second, bytes per
/// update and per-update p50/p95. `cargo test --release --test shared_doc -- --ignored --nocapture`.
#[test]
#[ignore]
fn shared_doc_at_20_participants() {
    const PEOPLE: usize = 20;
    const ROUNDS: usize = 50_000;
    let ids: Vec<String> =
        (0..PEOPLE).map(|i| if i == 0 { "owner".to_owned() } else { format!("p{i}") }).collect();
    let members: Vec<&str> = ids.iter().map(String::as_str).collect();
    let w = World::new(&members);
    let people: Vec<Principal> = ids.iter().map(|id| person(id, Grants::all())).collect();
    let roles: Vec<(&str, DocRole)> =
        ids[1..].iter().map(|id| (id.as_str(), DocRole::Suggest)).collect();
    let mut st = DocState::new(doc(&roles), "owner", DocKind::Shared, "x".repeat(4096));
    let mut lat = Vec::with_capacity(ROUNDS * 2);
    let mut bytes = 0usize;
    let start = Instant::now();
    for i in 0..ROUNDS {
        let p = &people[1 + i % (PEOPLE - 1)];
        let sid = format!("s{i}");
        let at = (i * 7) % 4096;
        let prop = up(
            &format!("p{i}"),
            &p.id,
            DocOp::Propose {
                suggestion_id: sid.clone(),
                base_revision: st.revision(),
                edit: TextEdit { at, delete: 1, insert: "y".to_owned() },
            },
        );
        let acc = up(&format!("a{i}"), "owner", DocOp::Accept { suggestion_id: sid });
        bytes += serde_json::to_vec(&prop).unwrap().len() + serde_json::to_vec(&acc).unwrap().len();
        let t = Instant::now();
        st.apply(w.scope(), me(p), &prop).unwrap();
        lat.push(t.elapsed().as_nanos() as u64);
        let t = Instant::now();
        st.apply(w.scope(), me(&people[0]), &acc).unwrap();
        lat.push(t.elapsed().as_nanos() as u64);
    }
    let total = start.elapsed();
    lat.sort_unstable();
    let pct = |q: f64| lat[((lat.len() as f64 - 1.0) * q) as usize] as f64 / 1000.0;
    println!(
        "shared_doc participants={PEOPLE} suggestions/s={:.0} bytes/update={:.1} update p50={:.2}us p95={:.2}us p99={:.2}us",
        ROUNDS as f64 / total.as_secs_f64(),
        bytes as f64 / (ROUNDS * 2) as f64,
        pct(0.50),
        pct(0.95),
        pct(0.99),
    );
    assert_eq!(st.revision(), ROUNDS as u64);
}
