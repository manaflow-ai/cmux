//! RFD 0170 phase 4 settings: only a person writes, the team's choices are its admins', every
//! choice is bounded, and no stored choice changes what anyone may read or wake. `Open in cmux`
//! answers whether the viewer may read the thread and never grants it.

mod common;

use std::time::Instant;

use proptest::prelude::*;

use cmux_team_messaging::customization::{Customization, Section};
use cmux_team_messaging::handoff::{Handoff, SlackMessage};
use cmux_team_messaging::model::Notify;
use cmux_team_messaging::permission::wake_allowed;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::settings::{
    self, MAX_PINS, Scope, SettingsError, SettingsStore, ViewContext,
};
use cmux_team_messaging::{
    Capability, DeliveryMode, Grants, Principal, RefKind, RefSource, Space, Team, Thread, effective,
};

use common::*;

const ME: &str = "p-me";
const PEER: &str = "p-peer";
const BOT: &str = "a-bot";
const PEER_BOT: &str = "a-peer";

fn mode() -> impl Strategy<Value = DeliveryMode> {
    prop::sample::select(vec![DeliveryMode::Fyi, DeliveryMode::Ask, DeliveryMode::Wake])
}

fn choice() -> impl Strategy<Value = Customization> {
    (
        prop::collection::vec("space-[0-5]", 0..4),
        prop::option::of(prop::collection::vec(prop::sample::select(Section::ALL.to_vec()), 0..6)),
        prop::option::of(prop::sample::select(vec![Notify::Inbox, Notify::Digest, Notify::Muted])),
        prop::option::of(mode()),
        prop::collection::btree_map("a-(bot|peer)", "[ -~]{0,50}", 0..3),
    )
        .prop_map(|(spaces_first, sections, notify, compose_mode, agent_labels)| {
            Customization {
                spaces_first,
                sections,
                notify,
                compose_mode,
                agent_labels,
                templates: Vec::new(),
            }
        })
}

struct World {
    team: Team,
    spaces: Vec<Space>,
    principals: Vec<Principal>,
    threads: Vec<Thread>,
}

impl World {
    /// Six spaces: ME reads the even ones, PEER every one; BOT (ME's) has wake where `wake[i]`.
    fn new(wake: &[bool]) -> Self {
        let mut team = team(Grants::all());
        team.members = [ME, PEER, BOT, PEER_BOT].map(str::to_owned).to_vec();
        team.admins = vec![PEER.to_owned()];
        team.spaces = (0..6).map(|i| format!("space-{i}")).collect();
        let spaces = (0..6)
            .map(|i| {
                let mut members = vec![PEER, PEER_BOT];
                if i % 2 == 0 {
                    members.extend([ME, BOT]);
                }
                let mut s = Space { id: format!("space-{i}"), ..space(&members) };
                if wake.get(i).copied().unwrap_or(false) {
                    grant_wake(&mut s, BOT, ME);
                }
                s
            })
            .collect();
        let principals = vec![
            person(ME, Grants::all()),
            person(PEER, Grants::all()),
            agent(BOT, ME, Grants::all()),
            agent(PEER_BOT, PEER, Grants::all()),
        ];
        let threads = (0..6)
            .map(|i| Thread { space_id: format!("space-{i}"), ..thread(&format!("t-{i}")) })
            .collect();
        Self { team, spaces, principals, threads }
    }

    fn cx(&self) -> ViewContext<'_> {
        ViewContext {
            team: &self.team,
            spaces: &self.spaces,
            principals: &self.principals,
            threads: &self.threads,
        }
    }

    fn p(&self, id: &str) -> &Principal {
        self.principals.iter().find(|p| p.id == id).unwrap()
    }

    fn reads(&self, id: &str) -> Vec<String> {
        let who = self.p(id);
        let owner = who.owner_person_id.as_deref().map(|o| self.p(o));
        self.spaces
            .iter()
            .filter(|s| effective(who, owner, &self.team, s).has(Capability::Read))
            .map(|s| s.id.clone())
            .collect()
    }
}

fn thread_ref(id: &str) -> RefKey {
    RefKey::new(RefKind::Thread, RefSource::Cmux, id).unwrap()
}

fn slack_msg(ts: &str) -> SlackMessage {
    SlackMessage {
        workspace: "T1".into(),
        channel: "C1".into(),
        ts: ts.into(),
        thread_ts: None,
        origin: None,
    }
}

proptest! {
    /// Whatever the team and the person choose, the page lists exactly the spaces the viewer can
    /// read, the team and spaces are unchanged, and the composer suggests wake only where the
    /// owner granted it.
    #[test]
    fn stored_choices_never_grant_access_or_wake(
        team_c in choice(),
        mine in choice(),
        wake in prop::collection::vec(any::<bool>(), 6),
    ) {
        let w = World::new(&wake);
        let before = (w.team.clone(), w.spaces.clone(), w.reads(ME), w.reads(BOT));
        let mut store = SettingsStore::default();
        store.set(w.p(PEER), &w.team, Scope::Team, team_c).unwrap();
        store.set(w.p(ME), &w.team, Scope::Person, mine).unwrap();
        for viewer in [ME, BOT] {
            let page = settings::view(&store, w.p(viewer), &w.cx()).unwrap();
            let mut listed: Vec<String> = page.spaces.iter().map(|s| s.id.clone()).collect();
            listed.sort();
            let mut readable = w.reads(viewer);
            readable.sort();
            prop_assert_eq!(listed, readable);
            for a in &page.agents {
                if a.compose_mode == DeliveryMode::Wake {
                    let agent = w.p(&a.id);
                    prop_assert!(w.spaces.iter().any(|s| wake_allowed(s, agent)));
                }
            }
        }
        prop_assert_eq!(before, (w.team.clone(), w.spaces.clone(), w.reads(ME), w.reads(BOT)));
    }

    /// A stored store read back keeps every choice and binding.
    #[test]
    fn a_saved_store_reads_back_the_same(team_c in choice(), mine in choice()) {
        let w = World::new(&[]);
        let mut store = SettingsStore::default();
        store.set(w.p(PEER), &w.team, Scope::Team, team_c).unwrap();
        store.set(w.p(ME), &w.team, Scope::Person, mine).unwrap();
        let slack = slack_msg("1.0").thread_key().unwrap();
        store.bind(w.p(ME), &w.cx(), slack, thread_ref("t-0")).unwrap();
        let back: SettingsStore =
            serde_json::from_slice(&serde_json::to_vec(&store).unwrap()).unwrap();
        let back = back.restored();
        prop_assert_eq!(back.team_choice(&w.team.id), store.team_choice(&w.team.id));
        prop_assert_eq!(back.person_choice(&w.team.id, ME), store.person_choice(&w.team.id, ME));
        prop_assert_eq!(back.bindings(), store.bindings());
    }
}

#[test]
fn only_a_person_writes_and_only_an_admin_writes_the_team() {
    let w = World::new(&[]);
    let mut store = SettingsStore::default();
    let c = Customization { notify: Some(Notify::Muted), ..Default::default() };
    assert_eq!(
        store.set(w.p(BOT), &w.team, Scope::Person, c.clone()),
        Err(SettingsError::PersonOnly)
    );
    assert_eq!(
        store.set(w.p(BOT), &w.team, Scope::Team, c.clone()),
        Err(SettingsError::PersonOnly)
    );
    assert_eq!(store.set(w.p(ME), &w.team, Scope::Team, c.clone()), Err(SettingsError::NotAdmin));
    let mut outsider = person("p-out", Grants::all());
    outsider.team_id = "other".into();
    assert_eq!(
        store.set(&outsider, &w.team, Scope::Person, c.clone()),
        Err(SettingsError::NotMember)
    );
    store.set(w.p(ME), &w.team, Scope::Person, c.clone()).unwrap();
    store.set(w.p(PEER), &w.team, Scope::Team, c).unwrap();

    let mine = settings::view(&store, w.p(ME), &w.cx()).unwrap();
    assert!(mine.can_edit_person && !mine.can_edit_team);
    let admin = settings::view(&store, w.p(PEER), &w.cx()).unwrap();
    assert!(admin.can_edit_team);
    let bot = settings::view(&store, w.p(BOT), &w.cx()).unwrap();
    assert!(!bot.can_edit_person && !bot.can_edit_team && bot.person.is_none());
    // The agent sees its owner's choices in force.
    assert_eq!(bot.effective.notify, Notify::Muted);
}

#[test]
fn a_person_choice_beats_the_team_and_clearing_restores_it() {
    let w = World::new(&[]);
    let mut store = SettingsStore::default();
    let team_c = Customization { spaces_first: vec!["space-4".into()], ..Default::default() };
    let mine = Customization { spaces_first: vec!["space-2".into()], ..Default::default() };
    store.set(w.p(PEER), &w.team, Scope::Team, team_c).unwrap();
    store.set(w.p(ME), &w.team, Scope::Person, mine).unwrap();
    let page = settings::view(&store, w.p(ME), &w.cx()).unwrap();
    assert_eq!(page.spaces[0].id, "space-2");
    assert!(page.spaces[0].pinned);
    store.set(w.p(ME), &w.team, Scope::Person, Customization::default()).unwrap();
    assert!(store.person_choice(&w.team.id, ME).is_none());
    let page = settings::view(&store, w.p(ME), &w.cx()).unwrap();
    assert_eq!(page.spaces[0].id, "space-4");
}

#[test]
fn pinning_a_space_the_viewer_cannot_read_never_lists_it() {
    let w = World::new(&[]);
    let mut store = SettingsStore::default();
    let c = Customization { spaces_first: vec!["space-1".into()], ..Default::default() };
    store.set(w.p(ME), &w.team, Scope::Person, c).unwrap();
    let page = settings::view(&store, w.p(ME), &w.cx()).unwrap();
    assert!(page.spaces.iter().all(|s| s.id != "space-1"));
}

#[test]
fn a_wake_default_without_the_owners_grant_suggests_ask() {
    let w = World::new(&[false, false, true]);
    let mut store = SettingsStore::default();
    let c = Customization { compose_mode: Some(DeliveryMode::Wake), ..Default::default() };
    store.set(w.p(ME), &w.team, Scope::Person, c).unwrap();
    let page = settings::view(&store, w.p(ME), &w.cx()).unwrap();
    let bot = page.agents.iter().find(|a| a.id == BOT).unwrap();
    // BOT's first listed space is space-0, where it has no wake grant.
    assert_eq!(bot.compose_mode, DeliveryMode::Ask);
    assert!(!wake_allowed(&w.spaces[0], w.p(BOT)));
}

#[test]
fn choices_past_the_bounds_are_refused() {
    let w = World::new(&[]);
    let mut store = SettingsStore::default();
    let pins = Customization {
        spaces_first: (0..=MAX_PINS).map(|i| format!("s{i}")).collect(),
        ..Default::default()
    };
    assert!(matches!(
        store.set(w.p(ME), &w.team, Scope::Person, pins),
        Err(SettingsError::TooLarge(_))
    ));
    let bad = Customization { spaces_first: vec!["a\u{7}b".into()], ..Default::default() };
    assert!(matches!(
        store.set(w.p(ME), &w.team, Scope::Person, bad),
        Err(SettingsError::BadId(_))
    ));
    let long = Customization { spaces_first: vec!["x".repeat(200)], ..Default::default() };
    assert!(matches!(
        store.set(w.p(ME), &w.team, Scope::Person, long),
        Err(SettingsError::BadId(_))
    ));
    assert!(store.person_choice(&w.team.id, ME).is_none());
}

#[test]
fn open_in_cmux_says_whether_the_viewer_can_read_and_never_grants_it() {
    let w = World::new(&[]);
    let mut store = SettingsStore::default();
    let root = slack_msg("1.0");
    let slack = root.thread_key().unwrap();
    assert!(matches!(store.handoff(w.p(ME), &w.cx(), &root).handoff, Handoff::Unbound { .. }));

    // ME cannot read t-1 (an odd space): binding it is refused.
    assert_eq!(
        store.bind(w.p(ME), &w.cx(), slack.clone(), thread_ref("t-1")),
        Err(SettingsError::NotMember)
    );
    // An agent never binds.
    assert_eq!(
        store.bind(w.p(PEER_BOT), &w.cx(), slack.clone(), thread_ref("t-1")),
        Err(SettingsError::PersonOnly)
    );
    store.bind(w.p(PEER), &w.cx(), slack.clone(), thread_ref("t-1")).unwrap();

    let reply = SlackMessage { ts: "2.0".into(), thread_ts: Some("1.0".into()), ..root.clone() };
    let peer = store.handoff(w.p(PEER), &w.cx(), &reply);
    assert!(matches!(peer.handoff, Handoff::Open { .. }));
    assert_eq!(peer.readable, Some(true));
    let mine = store.handoff(w.p(ME), &w.cx(), &reply);
    assert!(matches!(mine.handoff, Handoff::Open { .. }));
    assert_eq!(mine.readable, Some(false));

    let echo = SlackMessage { origin: Some("cmux".into()), ..reply };
    assert_eq!(store.handoff(w.p(PEER), &w.cx(), &echo).handoff, Handoff::Echo);
    assert_eq!(store.project(&thread_ref("t-1"), "m1").map(|p| p.slack), Some(slack));
}

/// Page size and build time at a team's scale: 200 spaces, 200 agents, every choice at its bound.
/// `cargo test --release --test settings -- --ignored --nocapture`
#[test]
#[ignore = "bench; run in release"]
fn page_at_team_scale() {
    let mut w = World::new(&[]);
    let n = 200;
    w.spaces = (0..n)
        .map(|i| {
            let members: Vec<String> = [ME.to_owned(), PEER.to_owned()]
                .into_iter()
                .chain((0..n).map(|a| format!("a-{a}")))
                .collect();
            let members: Vec<&str> = members.iter().map(String::as_str).collect();
            let mut s = Space { id: format!("space-{i}"), ..space(&members) };
            for a in 0..n {
                grant_wake(&mut s, &format!("a-{a}"), ME);
            }
            s
        })
        .collect();
    for a in 0..n {
        w.principals.push(agent(&format!("a-{a}"), ME, Grants::all()));
        w.team.members.push(format!("a-{a}"));
    }
    let mut store = SettingsStore::default();
    let c = Customization {
        spaces_first: (0..MAX_PINS).map(|i| format!("space-{}", i * 3)).collect(),
        compose_mode: Some(DeliveryMode::Wake),
        agent_labels: (0..n).map(|a| (format!("a-{a}"), format!("Label {a}"))).collect(),
        ..Default::default()
    };
    store.set(w.p(PEER), &w.team, Scope::Team, c.clone()).unwrap();
    store.set(w.p(ME), &w.team, Scope::Person, c).unwrap();
    let mut took = Vec::new();
    let mut bytes = 0;
    for _ in 0..400 {
        let t = Instant::now();
        let page = settings::view(&store, w.p(ME), &w.cx()).unwrap();
        let body = serde_json::to_vec(&page).unwrap();
        took.push(t.elapsed());
        bytes = body.len();
    }
    took.sort();
    let at = |p: f64| took[((took.len() as f64 * p) as usize).min(took.len() - 1)];
    eprintln!(
        "settings page: {bytes} bytes, p50 {:?} p95 {:?} p99 {:?} (n={})",
        at(0.50),
        at(0.95),
        at(0.99),
        took.len()
    );
}
