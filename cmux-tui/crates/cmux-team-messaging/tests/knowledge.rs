//! RFD 0170 phase 2: templates, the RFD reader, thread back-links and search-before-work.

mod common;

use std::collections::BTreeMap;
use std::time::Instant;

use cmux_team_messaging::knowledge::{
    Corpus, ReaderAction, Template, TemplateDraft, TemplateError, thread_key,
};
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::{
    Bridge, Feedback, FeedbackKind, Grants, LinkGraph, Principal, RefKind, RefSource, RootKind,
    Space, StableRef, Thread, ThreadState, VoteBoard,
};
use common::{agent, bridged, person, space, team, thread};

fn rfd(n: u32) -> RefKey {
    StableRef::rfd(n, "").key
}

fn session(id: &str) -> StableRef {
    StableRef::new(RefKind::Session, RefSource::Cmux, id, id).unwrap()
}

fn pr(n: u32) -> StableRef {
    StableRef::new(RefKind::Pr, RefSource::GitHub, &format!("manaflow-ai/cmux#{n}"), "pr").unwrap()
}

fn private_space(id: &str, members: &[&str]) -> Space {
    Space { id: id.to_owned(), ..space(members) }
}

/// alice and bob are people; alice-agent acts for alice. space-1 holds all three; pair holds bob.
fn corpus() -> Corpus {
    let mut t = team(Grants::all());
    t.spaces.push("pair".to_owned());
    Corpus {
        principals: vec![
            person("alice", Grants::all()),
            person("bob", Grants::all()),
            agent("alice-agent", "alice", Grants::all()),
        ],
        teams: vec![t],
        spaces: vec![space(&["alice", "bob", "alice-agent"]), private_space("pair", &["bob"])],
        threads: Vec::new(),
    }
}

fn draft(template: Template) -> TemplateDraft {
    let mut fields = BTreeMap::new();
    for f in template.required_fields() {
        fields.insert((*f).to_owned(), "x".to_owned());
    }
    let refs = match template {
        Template::Feedback => vec![StableRef::rfd(170, "Messaging")],
        Template::Receipt => vec![pr(1)],
        _ => Vec::new(),
    };
    TemplateDraft {
        template,
        space_id: "space-1".to_owned(),
        subject: "  Sidebar stalls on resume  ".to_owned(),
        body: "body".to_owned(),
        fields,
        refs,
    }
}

fn alice() -> Principal {
    person("alice", Grants::all())
}

fn bob() -> Principal {
    person("bob", Grants::all())
}

// ---------------------------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------------------------

#[test]
fn every_template_builds_its_root_kind() {
    let c = corpus();
    for t in Template::ALL {
        let built = c.build(&alice(), &draft(t), "t1").unwrap();
        assert_eq!(built.thread.root_kind, t.root_kind());
        assert_eq!(built.thread.subject, "Sidebar stalls on resume");
        assert_eq!(built.thread.participants, vec!["alice".to_owned()]);
        assert_eq!(built.thread.state, ThreadState::Open);
        assert_eq!(built.thread.revision, 0);
    }
}

#[test]
fn each_required_field_is_required() {
    let c = corpus();
    for t in Template::ALL {
        for field in t.required_fields() {
            let mut d = draft(t);
            d.fields.insert((*field).to_owned(), "   ".to_owned());
            assert_eq!(
                c.build(&alice(), &d, "t1"),
                Err(TemplateError::MissingField { template: t, field })
            );
            d.fields.remove(*field);
            assert!(matches!(c.build(&alice(), &d, "t1"), Err(TemplateError::MissingField { .. })));
        }
    }
}

#[test]
fn feedback_and_receipt_need_a_ref() {
    let c = corpus();
    for t in [Template::Feedback, Template::Receipt] {
        let mut d = draft(t);
        d.refs.clear();
        assert!(matches!(c.build(&alice(), &d, "t1"), Err(TemplateError::MissingRef { .. })));
        // A ref of the wrong kind does not count.
        d.refs.push(StableRef::new(RefKind::File, RefSource::Cmux, "a.rs", "a").unwrap());
        assert!(matches!(c.build(&alice(), &d, "t1"), Err(TemplateError::MissingRef { .. })));
    }
    let mut d = draft(Template::Receipt);
    d.refs = vec![StableRef::new(RefKind::Thread, RefSource::Cmux, "t0", "t").unwrap()];
    assert!(c.build(&alice(), &d, "t1").is_ok());
}

#[test]
fn empty_subject_or_body_and_unknown_space_are_refused() {
    let c = corpus();
    let mut d = draft(Template::Tip);
    d.subject = " ".to_owned();
    assert_eq!(c.build(&alice(), &d, "t1"), Err(TemplateError::EmptySubject));
    let mut d = draft(Template::Tip);
    d.body = "\n".to_owned();
    assert_eq!(c.build(&alice(), &d, "t1"), Err(TemplateError::EmptyBody));
    let mut d = draft(Template::Tip);
    d.space_id = "nope".to_owned();
    assert_eq!(c.build(&alice(), &d, "t1"), Err(TemplateError::UnknownSpace("nope".to_owned())));
}

#[test]
fn a_non_member_or_bridge_author_cannot_post() {
    let c = corpus();
    let mut d = draft(Template::Finding);
    d.space_id = "pair".to_owned();
    assert_eq!(
        c.build(&alice(), &d, "t1"),
        Err(TemplateError::CannotPost { author: "alice".to_owned(), space: "pair".to_owned() })
    );
    assert!(c.build(&bob(), &d, "t1").is_ok());
    let slack = bridged("alice", Bridge::Slack);
    assert!(matches!(
        c.build(&slack, &draft(Template::Tip), "t1"),
        Err(TemplateError::Identity(_))
    ));
    // An agent's reach is its owner's: alice-agent cannot post where alice cannot.
    let a = agent("alice-agent", "alice", Grants::all());
    assert!(c.build(&a, &draft(Template::Tip), "t1").is_ok());
    let mut c2 = corpus();
    c2.spaces[0].members.retain(|m| m != "alice");
    assert!(matches!(
        c2.build(&a, &draft(Template::Tip), "t1"),
        Err(TemplateError::CannotPost { .. })
    ));
}

#[test]
fn built_thread_carries_its_refs_and_links_both_ways() {
    let c = corpus();
    let mut d = draft(Template::Feedback);
    d.refs.push(StableRef::rfd(170, "dup"));
    d.refs.push(session("s1"));
    d.refs.push(pr(9));
    d.refs.push(StableRef::new(RefKind::Thread, RefSource::Cmux, "t1", "self").unwrap());
    let built = c.build(&alice(), &d, "t1").unwrap();
    assert_eq!(built.thread.linked_rfd_ids, vec!["0170".to_owned()]);
    assert_eq!(built.thread.linked_session_ids, vec!["s1".to_owned()]);
    assert_eq!(built.links.len(), 3, "deduped, no self-link");
    let mut g = LinkGraph::new();
    assert_eq!(built.link_into(&mut g), 3);
    assert_eq!(built.link_into(&mut g), 0);
    assert!(g.links(&rfd(170)).contains(&thread_key("t1")));
}

// ---------------------------------------------------------------------------------------------
// RFD reader and back-links
// ---------------------------------------------------------------------------------------------

fn vote(id: &str, author: Principal, value: i8, at: u64) -> Feedback {
    Feedback {
        id: id.to_owned(),
        target_ref: StableRef::rfd(170, "Messaging"),
        target_revision: 0,
        author,
        kind: FeedbackKind::Vote,
        value: Some(value),
        body: None,
        created_at: at,
    }
}

struct World {
    c: Corpus,
    g: LinkGraph,
    board: VoteBoard,
    titles: BTreeMap<String, String>,
}

fn world() -> World {
    let mut c = corpus();
    let mut open = thread("open");
    open.subject = "Discuss 0170".to_owned();
    open.revision = 3;
    let mut older = thread("older");
    older.subject = "Older thread".to_owned();
    older.revision = 1;
    let mut secret = thread("secret");
    secret.space_id = "pair".to_owned();
    secret.subject = "Bob's private notes".to_owned();
    // Linked only by its own record, not the graph.
    let mut recorded = thread("recorded");
    recorded.subject = "Recorded only".to_owned();
    recorded.linked_rfd_ids = vec!["170".to_owned()];
    c.threads = vec![open, older, secret, recorded];

    let mut g = LinkGraph::new();
    let r = rfd(170);
    for id in ["open", "older", "secret"] {
        g.link(&r, &thread_key(id));
    }
    g.link(&r, &session("s1").key);
    g.link(&r, &pr(42).key);
    g.link(&thread_key("open"), &session("s1").key);

    let mut board = VoteBoard::new();
    board.record(vote("v1", alice(), 1, 1)).unwrap();
    board.record(vote("v2", bob(), -1, 2)).unwrap();
    board.record(vote("v3", bob(), 1, 3)).unwrap();
    board.record(vote("v4", agent("alice-agent", "alice", Grants::all()), 1, 4)).unwrap();

    let mut titles = BTreeMap::new();
    titles.insert(r.canonical(), "RFD 0170: Messaging".to_owned());
    titles.insert(pr(42).key.canonical(), "phase 0 contract".to_owned());
    World { c, g, board, titles }
}

#[test]
fn rfd_reader_shows_readable_links_and_counts_the_rest() {
    let w = world();
    let view = w.c.rfd_reader(&alice(), &rfd(170), &w.g, &w.board, &w.titles);
    assert_eq!(view.rfd.title, "RFD 0170: Messaging");
    let ids: Vec<&str> = view.threads.iter().map(|t| t.key.id.as_str()).collect();
    assert_eq!(ids, ["open", "older", "recorded"], "newest revision first, record links included");
    assert_eq!(view.hidden, 1);
    let json = serde_json::to_string(&view).unwrap();
    assert!(!json.contains("secret") && !json.contains("private notes"), "{json}");
    assert_eq!(view.sessions.len(), 1);
    assert_eq!(view.implementation[0].title, "phase 0 contract");
    assert_eq!(
        view.actions,
        vec![
            ReaderAction::DiscussInThread { target: "thread:cmux/open".to_owned() },
            ReaderAction::OpenSession { target: "session:cmux/s1".to_owned() },
        ]
    );
    // bob reads the pair thread too.
    let view = w.c.rfd_reader(&bob(), &rfd(170), &w.g, &w.board, &w.titles);
    assert_eq!(view.threads.len(), 4);
    assert_eq!(view.hidden, 0);
}

#[test]
fn rfd_reader_offers_a_new_discussion_when_none_is_readable() {
    let w = world();
    let view = w.c.rfd_reader(&alice(), &rfd(9), &w.g, &w.board, &w.titles);
    assert!(view.threads.is_empty());
    assert_eq!(view.actions, vec![ReaderAction::StartDiscussion { rfd: "rfd:hq/0009".to_owned() }]);
}

#[test]
fn feedback_counts_people_and_labels_agents_advisory() {
    let w = world();
    let view = w.c.rfd_reader(&bob(), &rfd(170), &w.g, &w.board, &w.titles);
    // bob changed -1 to +1: one current vote each for alice and bob.
    assert_eq!(view.feedback.people, vec![(1, 2)]);
    assert_eq!(view.feedback.mine, Some(1));
    assert_eq!(view.feedback.advisory.len(), 1);
    let a = &view.feedback.advisory[0];
    assert_eq!(a.agent_id, "alice-agent");
    assert_eq!(a.owner_id.as_deref(), Some("alice"));
    assert_eq!(a.owner_name.as_deref(), Some("alice"));
    assert_eq!(w.board.events().len(), 4, "the change appended an event");
}

#[test]
fn thread_links_back_to_its_rfds_and_hides_from_outsiders() {
    let w = world();
    let links = w.c.thread_links(&alice(), "open", &w.g, &w.titles).unwrap();
    assert_eq!(links.rfds[0].canonical, "rfd:hq/0170");
    assert_eq!(links.rfds[0].title, "RFD 0170: Messaging");
    assert_eq!(
        links.actions,
        vec![
            ReaderAction::OpenRfd { target: "rfd:hq/0170".to_owned() },
            ReaderAction::OpenSession { target: "session:cmux/s1".to_owned() },
        ]
    );
    let rec = w.c.thread_links(&alice(), "recorded", &w.g, &w.titles).unwrap();
    assert_eq!(rec.rfds.len(), 1, "the record's own RFD id back-links");
    assert!(w.c.thread_links(&alice(), "secret", &w.g, &w.titles).is_none());
    assert!(w.c.thread_links(&bob(), "secret", &w.g, &w.titles).is_some());
    assert!(w.c.thread_links(&alice(), "missing", &w.g, &w.titles).is_none());
}

#[test]
fn actions_serialize_with_an_action_tag_and_camel_case() {
    let w = world();
    let view = w.c.rfd_reader(&alice(), &rfd(170), &w.g, &w.board, &w.titles);
    let v = serde_json::to_value(&view).unwrap();
    assert_eq!(v["actions"][0]["action"], "discussInThread");
    assert_eq!(v["actions"][0]["target"], "thread:cmux/open");
    assert!(v["feedback"]["advisory"][0]["ownerName"].is_string());
    assert!(v.get("implementation").is_some());
    let s =
        serde_json::to_value(ReaderAction::StartDiscussion { rfd: "rfd:hq/0001".into() }).unwrap();
    assert_eq!(s["action"], "startDiscussion");
    assert_eq!(serde_json::to_value(Template::Receipt).unwrap(), "receipt");
}

// ---------------------------------------------------------------------------------------------
// Search before work
// ---------------------------------------------------------------------------------------------

fn kinded(id: &str, space: &str, kind: RootKind, subject: &str) -> Thread {
    Thread {
        space_id: space.to_owned(),
        root_kind: kind,
        subject: subject.to_owned(),
        ..thread(id)
    }
}

#[test]
fn search_before_work_offers_the_existing_thread() {
    let mut c = corpus();
    c.threads = vec![
        kinded("best", "space-1", RootKind::Finding, "Sidebar stalls on resume after sleep"),
        kinded("some", "space-1", RootKind::Finding, "Sidebar is slow"),
        kinded("other-kind", "space-1", RootKind::Tip, "Sidebar stalls on resume"),
        kinded("hidden", "pair", RootKind::Finding, "Sidebar stalls on resume"),
        Thread {
            state: ThreadState::Closed,
            ..kinded("closed", "space-1", RootKind::Finding, "Sidebar stalls on resume")
        },
        kinded("none", "space-1", RootKind::Finding, "Unrelated words"),
    ];
    let hits =
        c.search_before_work(&alice(), Template::Finding, "The sidebar stalls on resume", 0, 10);
    let ids: Vec<&str> = hits.iter().map(|h| h.thread.key.id.as_str()).collect();
    assert_eq!(ids, ["best", "some"]);
    assert!(hits[0].score > hits[1].score);
    let top =
        c.search_before_work(&alice(), Template::Finding, "sidebar stalls on resume", 500, 10);
    assert_eq!(top.len(), 1);
    assert_eq!(c.search_before_work(&alice(), Template::Finding, "sidebar", 0, 1).len(), 1);
    assert!(c.search_before_work(&alice(), Template::Finding, "the of", 0, 10).is_empty());
    // bob reads the pair space.
    let hits = c.search_before_work(&bob(), Template::Finding, "sidebar stalls on resume", 0, 10);
    assert_eq!(hits[0].thread.key.id, "hidden", "exact match first");
}

// ---------------------------------------------------------------------------------------------
// Scale
// ---------------------------------------------------------------------------------------------

fn pct(mut v: Vec<u128>, p: usize) -> u128 {
    v.sort_unstable();
    v[(v.len() - 1) * p / 100]
}

#[test]
#[ignore = "measurement: cargo test --release --test knowledge -- --ignored --nocapture"]
fn scale_5000_threads_200_rfds() {
    const THREADS: usize = 5000;
    const RFDS: u32 = 200;
    const SPACES: usize = 50;
    let mut c = corpus();
    let mut t = team(Grants::all());
    for s in 0..SPACES {
        let id = format!("s{s}");
        t.spaces.push(id.clone());
        let members: Vec<&str> =
            if s % 5 == 0 { vec!["bob"] } else { vec!["alice", "bob", "alice-agent"] };
        c.spaces.push(private_space(&id, &members));
    }
    c.teams = vec![t];
    let kinds =
        [RootKind::Tip, RootKind::Finding, RootKind::Ask, RootKind::Feedback, RootKind::Receipt];
    let words = [
        "sidebar", "resume", "stall", "cache", "socket", "render", "agent", "vote", "thread", "rfd",
    ];
    let mut g = LinkGraph::new();
    let mut board = VoteBoard::new();
    for i in 0..THREADS {
        let n = (i as u32 % RFDS) + 1;
        let mut th = kinded(
            &format!("t{i}"),
            &format!("s{}", i % SPACES),
            kinds[i % kinds.len()],
            &format!(
                "{} {} {} item {i}",
                words[i % 10],
                words[(i / 10) % 10],
                words[(i / 100) % 10]
            ),
        );
        th.revision = i as u64;
        if i % 2 == 0 {
            th.linked_rfd_ids = vec![n.to_string()];
        } else {
            g.link(&rfd(n), &thread_key(&th.id));
        }
        g.link(&thread_key(&th.id), &session(&format!("sess{i}")).key);
        c.threads.push(th);
    }
    for n in 1..=RFDS {
        g.link(&rfd(n), &pr(n).key);
        board
            .record(Feedback {
                target_ref: StableRef::rfd(n, ""),
                ..vote(&format!("a{n}"), alice(), 1, 1)
            })
            .unwrap();
        board
            .record(Feedback {
                target_ref: StableRef::rfd(n, ""),
                ..vote(&format!("b{n}"), bob(), -1, 2)
            })
            .unwrap();
    }
    let titles = BTreeMap::new();
    let viewer = alice();

    let mut reader = Vec::new();
    for n in 1..=RFDS {
        let t0 = Instant::now();
        let v = c.rfd_reader(&viewer, &rfd(n), &g, &board, &titles);
        reader.push(t0.elapsed().as_micros());
        assert_eq!(v.threads.len() + v.hidden, THREADS / RFDS as usize, "rfd {n}");
    }
    let mut back = Vec::new();
    for i in (0..THREADS).step_by(25) {
        let t0 = Instant::now();
        let _ = c.thread_links(&viewer, &format!("t{i}"), &g, &titles);
        back.push(t0.elapsed().as_micros());
    }
    let mut search = Vec::new();
    for i in 0..200 {
        let t0 = Instant::now();
        let hits = c.search_before_work(
            &viewer,
            Template::ALL[i % 5],
            &format!("{} {} stall", words[i % 10], words[(i / 3) % 10]),
            0,
            5,
        );
        search.push(t0.elapsed().as_micros());
        assert!(hits.len() <= 5);
    }
    let build = {
        let t0 = Instant::now();
        for i in 0..200 {
            let _ = c.build(
                &viewer,
                &TemplateDraft { space_id: "s1".into(), ..draft(Template::Tip) },
                &format!("n{i}"),
            );
        }
        t0.elapsed().as_micros() / 200
    };
    println!(
        "knowledge scale ({THREADS} threads, {RFDS} RFDs, {SPACES} spaces): \
         rfd_reader p50 {}us p95 {}us; thread_links p50 {}us p95 {}us; \
         search_before_work p50 {}us p95 {}us; build mean {build}us",
        pct(reader.clone(), 50),
        pct(reader, 95),
        pct(back.clone(), 50),
        pct(back, 95),
        pct(search.clone(), 50),
        pct(search, 95),
    );
}
