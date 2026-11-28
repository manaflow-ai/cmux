//! RFD 0170 phase 4: team and person customization never grants access or wake, a person's choice
//! wins over the team's, and `Open in cmux` resolves every Slack root and reply to one forum thread
//! without importing cmux's own echo.

mod common;

use std::collections::{BTreeMap, BTreeSet};

use proptest::prelude::*;

use cmux_team_messaging::customization::{
    Customization, Section, TeamTemplate, TeamTemplateError, resolve,
};
use cmux_team_messaging::handoff::{BindError, Handoff, HandoffIndex, MIRROR_ORIGIN, SlackMessage};
use cmux_team_messaging::model::{AgentGrant, Notify};
use cmux_team_messaging::permission::wake_allowed;
use cmux_team_messaging::refs::RefKey;
use cmux_team_messaging::{
    Capability, DeliveryMode, Grants, RefKind, RefSource, Space, StableRef, Template,
    TemplateDraft, effective,
};

use common::*;

fn mode() -> impl Strategy<Value = DeliveryMode> {
    prop::sample::select(vec![DeliveryMode::Fyi, DeliveryMode::Ask, DeliveryMode::Wake])
}

fn notify() -> impl Strategy<Value = Notify> {
    prop::sample::select(vec![Notify::Inbox, Notify::Digest, Notify::Muted])
}

fn grants() -> impl Strategy<Value = Grants> {
    prop::collection::btree_set(prop::sample::select(Capability::ALL.to_vec()), 0..=4)
        .prop_map(|s| Grants(s.into_iter().collect()))
}

fn customization() -> impl Strategy<Value = Customization> {
    (
        prop::collection::vec("space-[0-5]", 0..4),
        prop::option::of(prop::collection::vec(prop::sample::select(Section::ALL.to_vec()), 0..6)),
        prop::option::of(notify()),
        prop::option::of(mode()),
        prop::collection::btree_map("a-[a-c]", "[ -~]{0,50}", 0..3),
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

fn spaces(ids: &[u8]) -> Vec<Space> {
    ids.iter().map(|i| Space { id: format!("space-{i}"), ..space(&[]) }).collect()
}

proptest! {
    /// Customization holds no grants: written into the team's customization map, it changes no
    /// principal's effective grants.
    #[test]
    fn customization_never_changes_grants(
        team_c in customization(),
        policy in grants(),
        caps in grants(),
        member in any::<bool>(),
    ) {
        let owner = person("p-a", caps.clone());
        let bot = agent("a-a", "p-a", caps);
        let members: Vec<&str> = if member { vec!["p-a", "a-a"] } else { vec![] };
        let sp = space(&members);
        let plain = team(policy);
        let mut custom = plain.clone();
        custom.customization.insert(
            "teamMessaging".to_owned(),
            serde_json::to_string(&team_c).unwrap(),
        );
        prop_assert_eq!(effective(&owner, None, &plain, &sp), effective(&owner, None, &custom, &sp));
        prop_assert_eq!(
            effective(&bot, Some(&owner), &plain, &sp),
            effective(&bot, Some(&owner), &custom, &sp)
        );
    }

    /// The composer suggests `wake` only where the agent's owner granted wake in that space.
    #[test]
    fn compose_mode_never_grants_wake(
        team_c in customization(),
        person_c in prop::option::of(customization()),
        member in any::<bool>(),
        grant in prop::option::of((any::<bool>(), any::<bool>(), mode())),
    ) {
        let bot = agent("a-a", "p-a", Grants::all());
        let mut sp = space(if member { &["a-a"] } else { &[] });
        if let Some((by_owner, wake, default_mode)) = grant {
            let granted_by = if by_owner { "p-a" } else { "p-b" }.to_owned();
            sp.agent_policy.insert("a-a".to_owned(), AgentGrant { granted_by, wake, default_mode });
        }
        let eff = resolve(&team_c, person_c.as_ref());
        if eff.compose_mode(&sp, &bot) == DeliveryMode::Wake {
            prop_assert!(wake_allowed(&sp, &bot));
        }
    }

    /// Ordering spaces only reorders what the viewer can already see.
    #[test]
    fn order_spaces_is_a_permutation(
        team_c in customization(),
        person_c in prop::option::of(customization()),
        ids in prop::collection::vec(0u8..6, 0..6),
    ) {
        let visible = spaces(&ids);
        let eff = resolve(&team_c, person_c.as_ref());
        let ordered = eff.order_spaces(&visible);
        prop_assert_eq!(ordered.len(), visible.len());
        let mut a: Vec<&str> = ordered.iter().map(|s| s.id.as_str()).collect();
        let mut b: Vec<&str> = visible.iter().map(|s| s.id.as_str()).collect();
        a.sort_unstable();
        b.sort_unstable();
        prop_assert_eq!(a, b);
    }

    /// A person's choice wins over the team's; the team's over the default.
    #[test]
    fn person_overrides_team(team_c in customization(), person_c in customization()) {
        let eff = resolve(&team_c, Some(&person_c));
        prop_assert_eq!(
            eff.notify,
            person_c.notify.or(team_c.notify).unwrap_or_default()
        );
        prop_assert_eq!(
            eff.compose_mode,
            person_c.compose_mode.or(team_c.compose_mode).unwrap_or_default()
        );
        if !person_c.spaces_first.is_empty() {
            let first: BTreeSet<&String> = person_c.spaces_first.iter().collect();
            prop_assert_eq!(eff.spaces_first.iter().collect::<BTreeSet<_>>(), first);
        }
        prop_assert!(!eff.sections.is_empty());
        for (agent, label) in &eff.agent_labels {
            prop_assert!(!label.is_empty() && label.chars().count() <= 40);
            prop_assert!(!label.chars().any(char::is_control));
            if let Some(mine) = person_c.agent_labels.get(agent)
                && !mine.trim().is_empty()
            {
                prop_assert!(mine.trim().starts_with(label.trim_end()));
            }
        }
    }

    /// Every message in a bound Slack thread opens the same forum thread; cmux's own echo never
    /// opens anything.
    #[test]
    fn handoff_is_canonical(
        roots in prop::collection::vec(1u32..20, 1..6),
        replies in prop::collection::vec((0usize..6, 1u32..1000), 0..10),
    ) {
        let mut index = HandoffIndex::new();
        let mut bound = BTreeMap::new();
        for (i, root) in roots.iter().enumerate() {
            let slack = msg(&root.to_string(), None, None).thread_key().unwrap();
            let thread = RefKey::new(RefKind::Thread, RefSource::Cmux, &format!("t-{i}")).unwrap();
            if index.bind(slack.clone(), thread.clone()).is_ok() {
                bound.insert(root.to_string(), thread);
            }
        }
        for (pick, ts) in replies {
            let root = roots[pick % roots.len()].to_string();
            let reply = msg(&format!("{root}.{ts}"), Some(&root), None);
            match index.resolve(&reply) {
                Handoff::Open { thread, .. } => prop_assert_eq!(Some(&thread), bound.get(&root)),
                other => prop_assert!(false, "a reply in a bound thread resolved to {:?}", other),
            }
            let echo = msg(&format!("{root}.{ts}"), Some(&root), Some("CMUX"));
            prop_assert_eq!(index.resolve(&echo), Handoff::Echo);
        }
        prop_assert_eq!(index.len(), bound.len());
    }
}

fn msg(ts: &str, thread_ts: Option<&str>, origin: Option<&str>) -> SlackMessage {
    SlackMessage {
        workspace: "T01".to_owned(),
        channel: "C01".to_owned(),
        ts: ts.to_owned(),
        thread_ts: thread_ts.map(str::to_owned),
        origin: origin.map(str::to_owned),
    }
}

#[test]
fn a_persons_own_space_setting_beats_the_default() {
    let team_c = Customization { notify: Some(Notify::Digest), ..Default::default() };
    let eff = resolve(&team_c, None);
    let mut sp = space(&["p-a"]);
    assert_eq!(eff.notify_for(&sp, "p-a"), Notify::Digest);
    set_notify(&mut sp, "p-a", Notify::Muted);
    assert_eq!(eff.notify_for(&sp, "p-a"), Notify::Muted);
}

#[test]
fn a_label_sits_beside_the_handle_and_never_on_a_person() {
    let mut labels = BTreeMap::new();
    labels.insert("a-a".to_owned(), "  Release bot\n ".to_owned());
    labels.insert("p-a".to_owned(), "Not a person label".to_owned());
    let eff = resolve(&Customization { agent_labels: labels, ..Default::default() }, None);
    assert_eq!(eff.display_name(&agent("a-a", "p-a", Grants::none())), "Release bot (@a-a)");
    assert_eq!(eff.display_name(&person("p-a", Grants::none())), "p-a");
}

#[test]
fn an_empty_person_label_clears_the_teams() {
    let team_c = Customization {
        agent_labels: [("a-a".to_owned(), "Team label".to_owned())].into(),
        ..Default::default()
    };
    let person_c = Customization {
        agent_labels: [("a-a".to_owned(), " ".to_owned())].into(),
        ..Default::default()
    };
    assert!(resolve(&team_c, Some(&person_c)).agent_labels.is_empty());
}

#[test]
fn sections_default_to_all_and_drop_repeats() {
    assert_eq!(resolve(&Customization::default(), None).sections, Section::ALL.to_vec());
    let team_c = Customization {
        sections: Some(vec![Section::Actions, Section::People, Section::Actions]),
        ..Default::default()
    };
    assert_eq!(resolve(&team_c, None).sections, vec![Section::Actions, Section::People]);
    let person_c = Customization { sections: Some(vec![]), ..Default::default() };
    assert_eq!(resolve(&team_c, Some(&person_c)).sections, vec![Section::Actions, Section::People]);
}

#[test]
fn regression_template_is_built_in_and_teams_can_replace_it() {
    let eff = resolve(&Customization::default(), None);
    let regression = eff.template("regression").unwrap();
    assert_eq!(regression.base, Template::Finding);

    let mut draft = TemplateDraft {
        template: Template::Finding,
        space_id: "space-1".to_owned(),
        subject: "Scroll jumps".to_owned(),
        body: "Since the last nightly".to_owned(),
        fields: BTreeMap::new(),
        refs: Vec::new(),
    };
    assert_eq!(
        regression.check(&draft),
        Err(TeamTemplateError::MissingField("lastGood".to_owned()))
    );
    draft.fields.insert("lastGood".to_owned(), "1.4.1".to_owned());
    draft.fields.insert("firstBad".to_owned(), "1.4.2".to_owned());
    assert!(matches!(regression.check(&draft), Err(TeamTemplateError::MissingRef(_))));
    draft.refs.push(StableRef::new(RefKind::Issue, RefSource::GitHub, "o/r#7", "Issue").unwrap());
    assert_eq!(regression.check(&draft), Ok(()));
    draft.template = Template::Tip;
    assert!(matches!(regression.check(&draft), Err(TeamTemplateError::WrongBase { .. })));

    let ours = TeamTemplate {
        title: "Our regression".to_owned(),
        fields: vec![],
        refs: vec![],
        ..TeamTemplate::regression()
    };
    let person_c = Customization { templates: vec![ours.clone()], ..Default::default() };
    let eff = resolve(&Customization::default(), Some(&person_c));
    assert_eq!(eff.templates.len(), 1);
    assert_eq!(eff.template("regression"), Some(&ours));
}

#[test]
fn a_slack_thread_binds_to_one_forum_thread() {
    let mut index = HandoffIndex::new();
    let slack = msg("100.1", None, None).thread_key().unwrap();
    assert_eq!(slack.canonical(), "slack-thread:slack/T01/C01/100.1");
    let t1 = RefKey::new(RefKind::Thread, RefSource::Cmux, "t-1").unwrap();
    let t2 = RefKey::new(RefKind::Thread, RefSource::Cmux, "t-2").unwrap();

    assert_eq!(index.resolve(&msg("100.1", None, None)), Handoff::Unbound { slack: slack.clone() });
    index.bind(slack.clone(), t1.clone()).unwrap();
    index.bind(slack.clone(), t1.clone()).unwrap();
    assert_eq!(
        index.bind(slack.clone(), t2.clone()),
        Err(BindError::SlackBound { thread: t1.clone() })
    );
    let other = msg("200.1", None, None).thread_key().unwrap();
    assert_eq!(index.bind(other, t1.clone()), Err(BindError::ThreadBound { slack: slack.clone() }));
    assert_eq!(index.bind(t1.clone(), slack.clone()), Err(BindError::WrongKind));

    let reply = msg("100.9", Some("100.1"), None);
    assert_eq!(index.resolve(&reply), Handoff::Open { slack: slack.clone(), thread: t1.clone() });

    let out = index.project(&t1, "m-1").unwrap();
    assert_eq!(out.slack, slack);
    assert_eq!(out.origin, MIRROR_ORIGIN);
    assert_eq!(out.thread, "thread:cmux/t-1");
    assert!(index.project(&t2, "m-2").is_none());
    assert_eq!(index.resolve(&msg("100.9", Some("100.1"), Some(MIRROR_ORIGIN))), Handoff::Echo);

    let bad = SlackMessage { channel: "C/1".to_owned(), ..msg("1", None, None) };
    assert_eq!(index.resolve(&bad), Handoff::Invalid);
}
