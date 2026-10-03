//! Random op sequences against the reducer contract and the state invariants
//! (plans/cmux-next/tasks.md section 2; OWNERSHIP-PRINCIPLES "Verification").

use cmux_tasks_core::event::Change;
use cmux_tasks_core::ids::{AgentClass, AgentRef, Principal};
use cmux_tasks_core::model::{
    Category, PlanStep, PlanStepStatus, Priority, RelationKind, SessionStatus, State,
};
use cmux_tasks_core::op::*;
use cmux_tasks_core::{Ctx, Envelope, Origin, invariants, reduce};
use proptest::prelude::*;

fn actors() -> Vec<Principal> {
    let agent = |id: &str, class| {
        Principal::Agent(AgentRef {
            principal: id.to_owned(),
            class,
            harness: "claude".to_owned(),
            on_behalf_of: "usr_a".to_owned(),
        })
    };
    vec![
        Principal::user("usr_a"),
        Principal::user("usr_b"),
        agent("agt_mux-a", AgentClass::Mux),
        agent("agt_claude-a", AgentClass::Ordinary),
    ]
}

fn task(i: u8) -> String {
    format!("task_{i}")
}

fn status_ref(i: u8) -> String {
    [
        "st_backlog",
        "st_todo",
        "st_in_progress",
        "st_in_review",
        "st_done",
        "st_canceled",
        "st_triage",
        "st_x0",
        "st_x1",
    ][usize::from(i % 9)]
    .to_owned()
}

fn op_strategy() -> impl Strategy<Value = Op> {
    let t = 0u8..8;
    prop_oneof![
        6 => (t.clone(), 0u8..9, 0u8..16, 0u8..8).prop_map(|(i, s, parent, label)| Op::TaskCreate(TaskCreate {
            id: task(i),
            title: format!("Task {i}"),
            status: Some(status_ref(s)),
            // Mostly valid: an occasional parent or label that may not exist.
            parent: (parent < 8).then(|| task(parent)),
            labels: if label < 2 { vec![format!("lbl_{label}")] } else { Vec::new() },
            priority: Some(Priority::High),
            ..TaskCreate::default()
        })),
        4 => (t.clone(), prop::option::of(0u8..9), prop::option::of(0u8..8), any::<bool>(), prop::option::of(0u8..3)).prop_map(|(i, s, parent, unassign, desc)| Op::TaskUpdate(TaskUpdate {
            task: task(i),
            status: s.map(status_ref),
            parent: parent.map(task),
            assignee: (!unassign).then(|| "me".to_owned()),
            unassign,
            description: desc.map(|v| format!("text {v}")),
            if_version: desc.map(u64::from),
            add_labels: if desc == Some(2) { vec!["lbl_1".to_owned()] } else { Vec::new() },
            ..TaskUpdate::default()
        })),
        1 => (t.clone(), prop::option::of(0u8..8), prop::option::of(0u8..8)).prop_map(|(i, a, b)| Op::TaskMove(TaskMove { task: task(i), after: a.map(task), before: b.map(task) })),
        1 => t.clone().prop_map(|i| Op::TaskArchive(TaskRef { task: task(i) })),
        1 => t.clone().prop_map(|i| Op::TaskUnarchive(TaskRef { task: task(i) })),
        1 => t.clone().prop_map(|i| Op::TaskDelete(TaskRef { task: task(i) })),
        2 => (t.clone(), 0u8..4, any::<bool>()).prop_map(|(i, s, mux)| Op::TaskDelegate(TaskDelegate {
            task: task(i),
            session: format!("asess_{s}"),
            harness: if mux { "codex".to_owned() } else { "claude".to_owned() },
            agent: Some(if mux { "agt_mux-a".to_owned() } else { "agt_claude-a".to_owned() }),
            class: Some(if mux { AgentClass::Mux } else { AgentClass::Ordinary }),
            target: Some("local".to_owned()),
            prompt: None,
        })),
        1 => (0u8..4, 0u8..2).prop_map(|(s, h)| Op::SessionClaim(SessionClaim { session: format!("asess_{s}"), host: format!("host-{h}") })),
        2 => (0u8..4, 0u8..2).prop_map(|(s, h)| Op::SessionAttach(SessionAttach { session: format!("asess_{s}"), acp_session: "acp_1".to_owned(), workspace: None, host: Some(format!("host-{h}")) })),
        3 => (0u8..4, 0u8..4).prop_map(|(s, st)| Op::SessionUpdate(SessionUpdate {
            session: format!("asess_{s}"),
            status: Some([SessionStatus::Working, SessionStatus::AwaitingInput, SessionStatus::Done, SessionStatus::Failed][usize::from(st)]),
            plan: Some(vec![PlanStep { content: "step".to_owned(), status: PlanStepStatus::InProgress }]),
            pr: None,
        })),
        1 => (0u8..4).prop_map(|s| Op::SessionCancel(SessionRef { session: format!("asess_{s}") })),
        2 => (0u8..6, 0u8..3, t.clone(), t.clone()).prop_map(|(r, k, a, b)| Op::RelationAdd(RelationAdd {
            id: format!("rel_{r}"),
            kind: [RelationKind::Blocks, RelationKind::Related, RelationKind::Duplicate][usize::from(k)],
            from: task(a),
            to: task(b),
        })),
        1 => (0u8..6).prop_map(|r| Op::RelationRemove(RelationRef { relation: format!("rel_{r}") })),
        2 => (0u8..4, 0u8..3).prop_map(|(l, n)| Op::LabelCreate(LabelCreate { id: format!("lbl_{l}"), name: format!("Label{n}"), color: Some(l) })),
        1 => (0u8..4).prop_map(|l| Op::LabelDelete(LabelRef { label: format!("lbl_{l}") })),
        1 => (0u8..2, 0usize..6).prop_map(|(s, c)| Op::StatusCreate(StatusCreate { id: format!("st_x{s}"), name: format!("Extra {s}"), category: Category::ALL[c], color: None, position: None })),
        1 => (0u8..9, 0u8..9).prop_map(|(s, r)| Op::StatusDelete(StatusDelete { status: status_ref(s), replacement: status_ref(r) })),
        2 => (0u8..4, t).prop_map(|(c, i)| Op::CommentAdd(CommentAdd { id: format!("cmt_{c}"), task: task(i), body: "hi".to_owned(), reply_to: None })),
        1 => (0u8..2).prop_map(|f| Op::SettingsUpdate(SettingsUpdate { agent_flow: Some(if f == 0 { cmux_tasks_core::AgentFlow::Forward } else { cmux_tasks_core::AgentFlow::Off }), ..SettingsUpdate::default() })),
    ]
}

#[derive(Debug, Clone)]
struct Step {
    actor: usize,
    key: u8,
    grant: bool,
    op: Op,
}

fn step_strategy() -> impl Strategy<Value = Step> {
    (
        prop_oneof![3 => Just(0usize), 1 => Just(1usize), 2 => Just(2usize), 1 => Just(3usize)],
        0u8..40,
        any::<bool>(),
        op_strategy(),
    )
        .prop_map(|(actor, key, grant, op)| Step { actor, key, grant, op })
}

/// Mostly fresh keys; `key < 6` retries the previous step's key, which
/// exercises replays and idempotency conflicts.
fn envelope_at(step: &Step, index: usize) -> Envelope {
    let mut env = envelope(step);
    env.key =
        if step.key < 6 && index > 0 { format!("k{}", index - 1) } else { format!("k{index}") };
    env
}

fn envelope(step: &Step) -> Envelope {
    let actors = actors();
    let mut grants = std::collections::BTreeSet::new();
    if step.grant {
        grants.insert(step.op.name().to_owned());
    }
    Envelope {
        actor: actors[step.actor].clone(),
        stamp: None,
        origin: Origin::Cli,
        key: format!("k{}", step.key),
        grants,
        op: step.op.clone(),
    }
}

proptest! {
    #![proptest_config(ProptestConfig { cases: 256, .. ProptestConfig::default() })]

    #[test]
    fn reducer_contract_holds(steps in prop::collection::vec(step_strategy(), 1..80)) {
        let mut state = State::new("team_t", "CMX");
        let mut log: Vec<(Envelope, Ctx)> = Vec::new();
        let mut commits = 0u64;
        let mut numbers_seen = std::collections::BTreeSet::new();
        for (i, step) in steps.iter().enumerate() {
            let env = envelope_at(step, i);
            let ctx = Ctx { now: 1_000 + i as i64 * 10 };
            let before = state.clone();
            match reduce(&mut state, &env, ctx) {
                Err(_) => prop_assert_eq!(&state, &before, "a reject changed the state"),
                Ok(commit) if commit.replay => {
                    prop_assert_eq!(&state, &before, "a replay changed the state");
                    prop_assert!(commit.events.is_empty());
                }
                Ok(commit) => {
                    commits += 1;
                    prop_assert_eq!(commit.seq, commits, "sequence must be gapless");
                    log.push((env.clone(), ctx));
                    let violations = invariants::check(&state);
                    prop_assert!(violations.is_empty(), "after {:?}: {:?}", env.op, violations);
                    for event in &commit.events {
                        if event.details.get("by_agent_flow") == Some(&serde_json::Value::Bool(true)) && event.kind == "task.status_changed" {
                            let from: Category = serde_json::from_value(event.details["from_category"].clone()).unwrap();
                            let to: Category = serde_json::from_value(event.details["to_category"].clone()).unwrap();
                            prop_assert!(to.rank() >= from.rank(), "agent flow moved backwards");
                        }
                        if let Change::Upsert { value: cmux_tasks_core::event::Entity::Task(t) } = &event.change {
                            prop_assert!(state.tasks.contains_key(&t.id));
                        }
                    }
                    // Idempotency: the same envelope again changes nothing.
                    let after = state.clone();
                    let again = reduce(&mut state, &env, ctx).expect("replay of a commit must succeed");
                    prop_assert!(again.replay);
                    prop_assert_eq!(&again.result, &commit.result);
                    prop_assert_eq!(&state, &after);
                }
            }
            // Numbers are never reused and tasks never leave the map.
            for t in state.tasks.values() {
                numbers_seen.insert((t.number, t.id.clone()));
            }
            prop_assert_eq!(numbers_seen.len(), state.tasks.len());
        }
        // Determinism: folding the committed log yields the same state.
        let mut replayed = State::new("team_t", "CMX");
        for (env, ctx) in &log {
            reduce(&mut replayed, env, *ctx).expect("a logged op must commit again");
        }
        prop_assert_eq!(replayed, state);
    }

    #[test]
    fn same_key_different_op_is_rejected(title_a in "[a-z]{1,8}", title_b in "[a-z]{1,8}") {
        prop_assume!(title_a != title_b);
        let mut state = State::new("team_t", "CMX");
        let actor = Principal::user("usr_a");
        let make = |title: &str| Envelope { actor: actor.clone(), stamp: None, origin: Origin::Cli, key: "same".to_owned(), grants: Default::default(), op: Op::TaskCreate(TaskCreate { id: "task_a".to_owned(), title: title.to_owned(), ..TaskCreate::default() }) };
        reduce(&mut state, &make(&title_a), Ctx { now: 1 }).unwrap();
        let err = reduce(&mut state, &make(&title_b), Ctx { now: 2 }).unwrap_err();
        prop_assert_eq!(err.code, cmux_tasks_core::RejectCode::IdempotencyConflict);
    }
}

/// Guard against a vacuous property: the generator must reach commits of
/// every important kind, not only rejects.
#[test]
fn generator_reaches_commits() {
    use proptest::strategy::ValueTree;
    use proptest::test_runner::TestRunner;
    let mut runner = TestRunner::deterministic();
    let mut kinds = std::collections::BTreeMap::<String, usize>::new();
    let (mut total, mut committed) = (0usize, 0usize);
    for _ in 0..64 {
        let steps =
            prop::collection::vec(step_strategy(), 60).new_tree(&mut runner).unwrap().current();
        let mut state = State::new("team_t", "CMX");
        for (i, step) in steps.iter().enumerate() {
            total += 1;
            if let Ok(commit) = reduce(&mut state, &envelope_at(step, i), Ctx { now: i as i64 })
                && !commit.replay
            {
                committed += 1;
                for event in commit.events {
                    *kinds.entry(event.kind).or_default() += 1;
                }
            }
        }
    }
    // Id collisions and missing references are generated on purpose, so
    // most ops reject; at least one in six must commit.
    assert!(committed * 6 > total, "only {committed} of {total} ops committed");
    for kind in [
        "task.created",
        "task.status_changed",
        "task.delegated",
        "task.agent_session.status_changed",
        "task.relation.added",
        "task.deleted",
    ] {
        assert!(kinds.get(kind).copied().unwrap_or(0) > 0, "no {kind} in {kinds:?}");
    }
}
