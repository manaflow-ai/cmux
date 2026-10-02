//! Named scenarios: the agent flow, claim races, cascades, version checks.

use cmux_tasks_core::ids::{AgentClass, AgentRef, Principal};
use cmux_tasks_core::model::{Attention, SessionStatus, State};
use cmux_tasks_core::op::*;
use cmux_tasks_core::{Ctx, Envelope, Origin, RejectCode, invariants, reduce};

struct World {
    state: State,
    now: i64,
    key: u32,
}

impl World {
    fn new() -> Self {
        Self { state: State::new("team_t", "CMX"), now: 1_000, key: 0 }
    }

    fn run(&mut self, actor: &Principal, op: Op) -> Result<cmux_tasks_core::Commit, cmux_tasks_core::Reject> {
        self.key += 1;
        self.now += 10;
        let env = Envelope { actor: actor.clone(), origin: Origin::Cli, key: format!("k{}", self.key), grants: Default::default(), op };
        let result = reduce(&mut self.state, &env, Ctx { now: self.now });
        assert!(invariants::check(&self.state).is_empty(), "{:?}", invariants::check(&self.state));
        result
    }

    fn status_of(&self, id: &str) -> String {
        self.state.tasks[id].status.clone()
    }
}

fn lawrence() -> Principal {
    Principal::user("usr_lawrence")
}

fn claude() -> Principal {
    Principal::Agent(AgentRef { principal: "agt_claude-lawrence".to_owned(), class: AgentClass::Ordinary, harness: "claude".to_owned(), on_behalf_of: "usr_lawrence".to_owned() })
}

fn create(w: &mut World, id: &str) {
    w.run(&lawrence(), Op::TaskCreate(TaskCreate { id: id.to_owned(), title: "Fix the drag bug".to_owned(), ..TaskCreate::default() })).unwrap();
}

fn delegate(w: &mut World, task: &str, session: &str) {
    w.run(&lawrence(), Op::TaskDelegate(TaskDelegate {
        task: task.to_owned(), session: session.to_owned(), harness: "claude".to_owned(),
        agent: None, class: None, target: None, prompt: None,
    })).unwrap();
}

#[test]
fn keys_are_allocated_in_order_and_resolve() {
    let mut w = World::new();
    create(&mut w, "task_a");
    create(&mut w, "task_b");
    assert_eq!(w.state.resolve_task("CMX-2").as_deref(), Some("task_b"));
    assert_eq!(w.state.resolve_task("cmx-1").as_deref(), Some("task_a"));
}

#[test]
fn status_follows_agent_activity() {
    let mut w = World::new();
    create(&mut w, "task_a");
    assert_eq!(w.status_of("task_a"), "st_backlog");
    delegate(&mut w, "task_a", "asess_1");
    let task = &w.state.tasks["task_a"];
    assert_eq!(task.delegate.as_ref().map(|d| d.principal.as_str()), Some("agt_claude-lawrence"));
    assert_eq!(task.assignee, Some(lawrence()));

    w.run(&lawrence(), Op::SessionClaim(SessionClaim { session: "asess_1".to_owned(), host: "mac-1".to_owned() })).unwrap();
    let race = w.run(&lawrence(), Op::SessionClaim(SessionClaim { session: "asess_1".to_owned(), host: "mac-2".to_owned() }));
    assert_eq!(race.unwrap_err().code, RejectCode::Conflict, "a second dispatcher must lose");

    w.run(&lawrence(), Op::SessionAttach(SessionAttach { session: "asess_1".to_owned(), acp_session: "acp_9".to_owned(), workspace: Some("ws_1".to_owned()), host: Some("mac-1".to_owned()) })).unwrap();
    assert_eq!(w.status_of("task_a"), "st_in_progress");

    w.run(&claude(), Op::SessionUpdate(SessionUpdate { session: "asess_1".to_owned(), status: Some(SessionStatus::AwaitingInput), plan: None, pr: None })).unwrap();
    assert_eq!(w.state.tasks["task_a"].attention, Some(Attention::NeedsInput));

    w.run(&claude(), Op::SessionUpdate(SessionUpdate { session: "asess_1".to_owned(), status: Some(SessionStatus::Working), plan: None, pr: None })).unwrap();
    assert_eq!(w.state.tasks["task_a"].attention, None);

    w.run(&claude(), Op::SessionUpdate(SessionUpdate { session: "asess_1".to_owned(), status: Some(SessionStatus::Done), plan: None, pr: Some("https://github.com/manaflow-ai/cmux/pull/1".to_owned()) })).unwrap();
    assert_eq!(w.status_of("task_a"), "st_in_review");
    assert_eq!(w.state.tasks["task_a"].attention, Some(Attention::Review));
    assert!(w.state.tasks["task_a"].completed_at.is_none(), "the agent flow never completes a task");
}

#[test]
fn agent_flow_never_overrides_a_later_manual_move() {
    let mut w = World::new();
    create(&mut w, "task_a");
    delegate(&mut w, "task_a", "asess_1");
    w.run(&lawrence(), Op::TaskUpdate(TaskUpdate { task: "task_a".to_owned(), status: Some("Todo".to_owned()), ..TaskUpdate::default() })).unwrap();
    w.run(&lawrence(), Op::SessionAttach(SessionAttach { session: "asess_1".to_owned(), acp_session: "acp_1".to_owned(), workspace: None, host: None })).unwrap();
    assert_eq!(w.status_of("task_a"), "st_todo");
}

#[test]
fn only_the_agent_or_a_mux_reports_status() {
    let mut w = World::new();
    create(&mut w, "task_a");
    delegate(&mut w, "task_a", "asess_1");
    w.run(&lawrence(), Op::SessionAttach(SessionAttach { session: "asess_1".to_owned(), acp_session: "acp_1".to_owned(), workspace: None, host: None })).unwrap();
    let err = w.run(&lawrence(), Op::SessionUpdate(SessionUpdate { session: "asess_1".to_owned(), status: Some(SessionStatus::Done), plan: None, pr: None })).unwrap_err();
    assert_eq!(err.code, RejectCode::Forbidden);
}

#[test]
fn ordinary_agents_need_a_grant_to_delete() {
    let mut w = World::new();
    create(&mut w, "task_a");
    let err = w.run(&claude(), Op::TaskDelete(TaskRef { task: "CMX-1".to_owned() })).unwrap_err();
    assert_eq!(err.code, RejectCode::Forbidden);
}

#[test]
fn delete_cascades_relations_children_and_sessions() {
    let mut w = World::new();
    create(&mut w, "task_a");
    create(&mut w, "task_b");
    w.run(&lawrence(), Op::TaskUpdate(TaskUpdate { task: "task_b".to_owned(), parent: Some("CMX-1".to_owned()), ..TaskUpdate::default() })).unwrap();
    w.run(&lawrence(), Op::RelationAdd(RelationAdd { id: "rel_1".to_owned(), kind: cmux_tasks_core::RelationKind::Blocks, from: "CMX-1".to_owned(), to: "CMX-2".to_owned() })).unwrap();
    delegate(&mut w, "task_a", "asess_1");
    w.run(&lawrence(), Op::TaskDelete(TaskRef { task: "CMX-1".to_owned() })).unwrap();
    assert!(w.state.relations.is_empty());
    assert_eq!(w.state.tasks["task_b"].parent, None);
    assert_eq!(w.state.sessions["asess_1"].status, SessionStatus::Canceled);
    assert_eq!(w.state.resolve_task("CMX-1"), None);
    create(&mut w, "task_c");
    assert_eq!(w.state.tasks["task_c"].number, 3, "numbers are never reused");
}

#[test]
fn blocks_cycles_are_rejected() {
    let mut w = World::new();
    create(&mut w, "task_a");
    create(&mut w, "task_b");
    let blocks = |id: &str, from: &str, to: &str| Op::RelationAdd(RelationAdd { id: id.to_owned(), kind: cmux_tasks_core::RelationKind::Blocks, from: from.to_owned(), to: to.to_owned() });
    w.run(&lawrence(), blocks("rel_1", "task_a", "task_b")).unwrap();
    assert_eq!(w.run(&lawrence(), blocks("rel_2", "task_b", "task_a")).unwrap_err().code, RejectCode::Invalid);
}

#[test]
fn stale_description_is_rejected() {
    let mut w = World::new();
    create(&mut w, "task_a");
    let edit = |v: u64| Op::TaskUpdate(TaskUpdate { task: "task_a".to_owned(), description: Some(format!("v{v}")), if_version: Some(v), ..TaskUpdate::default() });
    w.run(&lawrence(), edit(1)).unwrap();
    assert_eq!(w.run(&lawrence(), edit(1)).unwrap_err().code, RejectCode::Conflict);
    w.run(&lawrence(), edit(2)).unwrap();
}

#[test]
fn deleting_a_status_moves_its_tasks() {
    let mut w = World::new();
    create(&mut w, "task_a");
    w.run(&lawrence(), Op::TaskUpdate(TaskUpdate { task: "task_a".to_owned(), status: Some("Todo".to_owned()), ..TaskUpdate::default() })).unwrap();
    assert_eq!(
        w.run(&lawrence(), Op::StatusDelete(StatusDelete { status: "Todo".to_owned(), replacement: "Backlog".to_owned() })).unwrap_err().code,
        RejectCode::Invalid,
        "the last unstarted status cannot go"
    );
    w.run(&lawrence(), Op::StatusCreate(StatusCreate { id: "st_next".to_owned(), name: "Next".to_owned(), category: cmux_tasks_core::Category::Unstarted, color: None, position: None })).unwrap();
    w.run(&lawrence(), Op::StatusDelete(StatusDelete { status: "Todo".to_owned(), replacement: "Next".to_owned() })).unwrap();
    assert_eq!(w.status_of("task_a"), "st_next");
}
