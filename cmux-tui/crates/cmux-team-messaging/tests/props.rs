//! Property tests for RFD 0170 phase 0: identity, permission intersection, deduplication and
//! delivery states, plus stable refs and links.

mod common;

use std::collections::BTreeSet;

use proptest::prelude::*;

use cmux_team_messaging::fake::FakeForum;
use cmux_team_messaging::identity::{check_author, validate};
use cmux_team_messaging::model::Notify;
use cmux_team_messaging::permission::wake_allowed;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::{
    Bridge, Capability, DeliveryMode, DeliveryState, Draft, Feedback, FeedbackKind, ForumBackend,
    Grants, IdentityError, LinkGraph, Messenger, Principal, PrincipalKind, RefKind, RefSource,
    Route, StableRef, VoteBoard, effective, route,
};

use common::*;

fn grants() -> impl Strategy<Value = Grants> {
    prop::collection::btree_set(prop::sample::select(Capability::ALL.to_vec()), 0..=4)
        .prop_map(|s| Grants(s.into_iter().collect()))
}

fn kind() -> impl Strategy<Value = RefKind> {
    prop::sample::select(RefKind::ALL.to_vec())
}

fn source() -> impl Strategy<Value = RefSource> {
    prop::sample::select(vec![
        RefSource::Cmux,
        RefSource::Hq,
        RefSource::GitHub,
        RefSource::Linear,
        RefSource::Slack,
    ])
}

/// A raw id that is valid for `kind`.
fn raw_id(kind: RefKind) -> BoxedStrategy<String> {
    match kind {
        RefKind::Rfd => (0u32..100_000, prop::sample::select(vec!["", "RFD ", "rfd-", "0"]))
            .prop_map(|(n, p)| format!("{p}{n}"))
            .boxed(),
        RefKind::Pr | RefKind::Issue => {
            ("[A-Za-z][A-Za-z0-9-]{0,8}", "[A-Za-z][A-Za-z0-9.-]{0,8}", 1u64..1_000_000)
                .prop_map(|(o, r, n)| format!("{o}/{r}#{n}"))
                .boxed()
        }
        _ => "[ ]{0,2}[A-Za-z0-9][A-Za-z0-9:/#._-]{0,20}[ ]{0,2}".boxed(),
    }
}

fn key() -> impl Strategy<Value = RefKey> {
    (kind(), source())
        .prop_flat_map(|(k, s)| raw_id(k).prop_map(move |id| RefKey::new(k, s, &id).unwrap()))
}

fn principal() -> impl Strategy<Value = Principal> {
    (
        0u8..3,
        "[a-c]",
        grants(),
        prop::option::of(prop::sample::select(vec![Bridge::Slack, Bridge::GitHub])),
    )
        .prop_map(|(k, id, caps, via)| {
            let mut p = match k {
                0 => person(&format!("p-{id}"), caps),
                1 => agent(&format!("a-{id}"), &format!("p-{id}"), caps),
                _ => agent(&format!("a-{id}"), "", caps), // ownerless: invalid
            };
            p.via = via;
            p
        })
}

proptest! {
    // ---- stable refs ----

    #[test]
    fn ref_canonical_roundtrips(k in key()) {
        let back = RefKey::parse(&k.canonical()).unwrap();
        prop_assert_eq!(&back, &k);
        prop_assert_eq!(back.canonical(), k.canonical());
    }

    #[test]
    fn rfd_spellings_are_one_key(n in 0u32..100_000) {
        let plain = RefKey::new(RefKind::Rfd, RefSource::Hq, &n.to_string()).unwrap();
        for s in [format!("RFD {n}"), format!("rfd-{n}"), format!("{n:04}"), format!(" {n} ")] {
            prop_assert_eq!(&RefKey::new(RefKind::Rfd, RefSource::Hq, &s).unwrap(), &plain);
        }
        prop_assert_eq!(&StableRef::rfd(n, "x").key, &plain);
    }

    #[test]
    fn pr_repo_case_is_one_key(o in "[A-Za-z]{1,8}", r in "[A-Za-z]{1,8}", n in 1u64..10_000) {
        let a = RefKey::new(RefKind::Pr, RefSource::GitHub, &format!("{o}/{r}#{n}")).unwrap();
        let b = RefKey::new(RefKind::Pr, RefSource::GitHub, &format!("{}/{}#{n}", o.to_uppercase(), r.to_lowercase())).unwrap();
        prop_assert_eq!(a, b);
    }

    #[test]
    fn titles_never_change_identity(k in key(), t1 in ".*", t2 in ".*") {
        let a = StableRef { key: k.clone(), title: t1 };
        let b = StableRef { key: k, title: t2 };
        prop_assert!(a.same_target(&b));
    }

    // ---- links ----

    #[test]
    fn links_are_symmetric(ops in prop::collection::vec((key(), key(), any::<bool>()), 0..40)) {
        let mut g = LinkGraph::new();
        let mut model: BTreeSet<(RefKey, RefKey)> = BTreeSet::new();
        for (a, b, add) in ops {
            let pair = if a <= b { (a.clone(), b.clone()) } else { (b.clone(), a.clone()) };
            if add {
                g.link(&a, &b);
                if a != b { model.insert(pair); }
            } else {
                g.unlink(&a, &b);
                model.remove(&pair);
            }
        }
        prop_assert_eq!(g.len(), model.len());
        for (a, b) in &model {
            prop_assert!(g.linked(a, b) && g.linked(b, a));
            prop_assert!(g.links(a).contains(b) && g.links(b).contains(a));
        }
    }

    #[test]
    fn links_never_widen_reads(edges in prop::collection::vec((key(), key()), 0..30), readable in prop::collection::btree_set(key(), 0..10)) {
        let mut g = LinkGraph::new();
        for (a, b) in &edges { g.link(a, b); }
        for (a, _) in &edges {
            for v in g.visible_links(a, |k| readable.contains(k)) {
                prop_assert!(readable.contains(&v));
                prop_assert!(g.linked(a, &v));
            }
        }
    }

    // ---- identity ----

    #[test]
    fn only_the_caller_writes_as_itself(claimed in principal(), caller in principal()) {
        let ok = check_author(&claimed, &caller).is_ok();
        let same = claimed.id == caller.id && claimed.kind == caller.kind && claimed.via == caller.via;
        prop_assert_eq!(ok, same && validate(&caller).is_ok());
    }

    #[test]
    fn an_agent_never_writes_as_its_owner(id in "[a-c]", caps in grants()) {
        let owner = person(&format!("p-{id}"), caps.clone());
        let a = agent(&format!("a-{id}"), &owner.id, caps);
        let refused = matches!(check_author(&owner, &a), Err(IdentityError::AgentAsOwner { .. }));
        prop_assert!(refused);
    }

    // ---- permission intersection ----

    #[test]
    fn effective_is_an_intersection(policy in grants(), p_caps in grants(), a_caps in grants(), members in prop::collection::btree_set(prop::sample::select(vec!["p-a", "a-a"]), 0..=2)) {
        let t = team(policy.clone());
        let members: Vec<&str> = members.into_iter().collect();
        let s = space(&members);
        let owner = person("p-a", p_caps.clone());
        let ag = agent("a-a", "p-a", a_caps.clone());

        let pe = effective(&owner, None, &t, &s);
        prop_assert!(pe.is_subset(&policy) && pe.is_subset(&p_caps));
        if !s.is_member("p-a") { prop_assert!(pe.is_empty()); }

        let ae = effective(&ag, Some(&owner), &t, &s);
        prop_assert!(ae.is_subset(&policy) && ae.is_subset(&a_caps) && ae.is_subset(&pe));
        if !s.is_member("a-a") { prop_assert!(ae.is_empty()); }
        prop_assert!(effective(&ag, None, &t, &s).is_empty());

        let mut br = owner.clone();
        br.via = Some(Bridge::Slack);
        prop_assert!(effective(&br, None, &t, &s).is_empty());

        let mut other = s;
        other.team_id = "team-b".to_owned();
        prop_assert!(effective(&owner, None, &t, &other).is_empty());
    }

    // ---- delivery ----

    #[test]
    fn route_wakes_only_with_the_owners_grant(
        mode in prop::sample::select(vec![DeliveryMode::Fyi, DeliveryMode::Ask, DeliveryMode::Wake]),
        author in principal(),
        recipient in principal(),
        granted_by in prop::sample::select(vec!["p-a", "p-b", "p-c"]),
        member in any::<bool>(),
        notify in prop::sample::select(vec![Notify::Inbox, Notify::Digest, Notify::Muted]),
    ) {
        let ids = [recipient.id.as_str()];
        let mut s = space(if member { &ids[..] } else { &[] });
        grant_wake(&mut s, &recipient.id, granted_by);
        let allowed = wake_allowed(&s, &recipient);
        let r = route(mode, &author, &recipient, allowed, notify);
        if r.wakes() {
            prop_assert_eq!(mode, DeliveryMode::Wake);
            prop_assert_eq!(recipient.kind, PrincipalKind::Agent);
            prop_assert!(member);
            prop_assert_eq!(recipient.owner_person_id.as_deref(), Some(granted_by));
            prop_assert!(author.via.is_none());
        }
        if recipient.kind == PrincipalKind::Person {
            prop_assert!(!r.wakes());
            if author.id != recipient.id {
                prop_assert_eq!(r, match notify { Notify::Inbox => Route::Inbox, Notify::Digest => Route::PersonDigest, Notify::Muted => Route::Muted });
            }
        }
    }

    #[test]
    fn delivery_states_converge_on_the_furthest(states in prop::collection::vec(prop::sample::select(vec![DeliveryState::Sent, DeliveryState::Stored, DeliveryState::Delivered, DeliveryState::Read, DeliveryState::Handled]), 0..20)) {
        let fold = |xs: &[DeliveryState]| {
            let mut s = DeliveryState::default();
            let mut prev = s;
            for x in xs { s.advance(*x); assert!(s >= prev); prev = s; }
            s
        };
        let max = states.iter().copied().max().unwrap_or_default();
        prop_assert_eq!(fold(&states), max);
        let mut rev = states.clone();
        rev.reverse();
        prop_assert_eq!(fold(&rev), max);
        let mut twice = states.clone();
        twice.extend(states.iter().copied());
        prop_assert_eq!(fold(&twice), max);
    }

    // ---- deduplication ----

    #[test]
    fn votes_dedupe_and_one_is_current(votes in prop::collection::vec((0usize..3, -1i8..=1, 0u64..5, 0u8..6), 1..25)) {
        let target = StableRef::rfd(170, "RFD 0170");
        let authors = [person("p-a", Grants::all()), person("p-b", Grants::all()), agent("a-a", "p-a", Grants::all())];
        let events: Vec<Feedback> = votes.iter().map(|(who, v, at, id)| Feedback {
            id: format!("f-{who}-{at}-{id}"),
            target_ref: target.clone(),
            target_revision: 1,
            author: authors[*who].clone(),
            kind: FeedbackKind::Vote,
            value: Some(*v),
            body: None,
            created_at: *at,
        }).collect();
        // Same id means the same event (a retry or a bridge echo), so keep the first of each id.
        let mut seen = BTreeSet::new();
        let unique: Vec<&Feedback> = events.iter().filter(|f| seen.insert(f.id.clone())).collect();

        let run = |order: &mut dyn Iterator<Item = &Feedback>| {
            let mut b = VoteBoard::new();
            for f in order { b.record(f.clone()).unwrap(); }
            b
        };
        let fwd = run(&mut unique.iter().copied().chain(unique.iter().copied()));
        let rev = run(&mut unique.iter().rev().copied());
        prop_assert_eq!(fwd.events().len(), unique.len());
        prop_assert_eq!(fwd.summary(&target.key), rev.summary(&target.key));
        let s = fwd.summary(&target.key);
        let people: u32 = s.people.values().sum();
        let advisory: u32 = s.advisory.values().sum();
        let distinct_people = unique.iter().filter(|f| f.author.kind == PrincipalKind::Person).map(|f| f.author.id.clone()).collect::<BTreeSet<_>>().len();
        let distinct_agents = unique.iter().filter(|f| f.author.kind == PrincipalKind::Agent).map(|f| f.author.id.clone()).collect::<BTreeSet<_>>().len();
        prop_assert_eq!(people as usize, distinct_people);
        prop_assert_eq!(advisory as usize, distinct_agents);
        for a in &authors {
            prop_assert_eq!(fwd.current(&target.key, &a.id).map(|f| &f.id), rev.current(&target.key, &a.id).map(|f| &f.id));
        }
    }

    #[test]
    fn a_resend_is_the_same_message(keys in prop::collection::vec(0u8..5, 1..20), fail in 0u32..3) {
        let forum = FakeForum::new();
        forum.put_thread(thread("space-1/1")).unwrap();
        let alice = person("alice", Grants::all());
        let bob = person("bob", Grants::all());
        let m = Messenger::new(forum, vec![alice.clone(), bob], vec![team(Grants::all())], vec![space(&["alice", "bob"])]);
        m.forum().fail_next(fail);
        let mut first: std::collections::BTreeMap<u8, (String, u64)> = Default::default();
        for k in &keys {
            let draft = Draft {
                thread_id: "space-1/1".to_owned(),
                body: format!("hello {k}"),
                audience: vec!["@bob".to_owned()],
                mode: DeliveryMode::Ask,
                refs: Vec::new(),
                reply_to: None,
                idempotency_key: format!("k{k}"),
                created_at: 1,
            };
            let r = loop {
                match m.send(&alice, &draft) {
                    Ok(r) => break r,
                    Err(cmux_team_messaging::SendError::Backend(_)) => continue,
                    Err(e) => panic!("{e}"),
                }
            };
            match first.get(k) {
                Some((id, seq)) => {
                    prop_assert!(r.duplicate);
                    prop_assert_eq!(&r.message_id, id);
                    prop_assert_eq!(r.seq, *seq);
                }
                None => {
                    prop_assert!(!r.duplicate);
                    first.insert(*k, (r.message_id.clone(), r.seq));
                }
            }
        }
        prop_assert_eq!(m.forum().stored_count(), first.len());
        let msgs = m.forum().messages("space-1/1", 0).unwrap();
        let seqs: Vec<u64> = msgs.iter().map(|s| s.seq).collect();
        prop_assert_eq!(seqs, (1..=first.len() as u64).collect::<Vec<_>>());
    }
}
