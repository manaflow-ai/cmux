//! The P8 actor stamp: its JSON shape, session authority through an attached
//! ACP session, and idempotency keys scoped to the accountable person.

use cmux_tasks_core::ids::{AgentClass, AgentRef, Principal};
use cmux_tasks_core::model::{SessionStatus, State};
use cmux_tasks_core::op::*;
use cmux_tasks_core::{Actor, Ctx, Envelope, Origin, RejectCode, UserActor, reduce};
use serde_json::json;

fn lawrence() -> Principal {
    Principal::user("usr_lawrence")
}

fn claude() -> Principal {
    Principal::Agent(AgentRef {
        principal: "agt_claude-lawrence".to_owned(),
        class: AgentClass::Ordinary,
        harness: "claude".to_owned(),
        on_behalf_of: "usr_lawrence".to_owned(),
    })
}

fn acp(id: &str, host: &str) -> Actor {
    Actor::AcpSession { id: id.to_owned(), host: host.to_owned(), agent: None }
}

struct World {
    state: State,
    now: i64,
}

impl World {
    fn new() -> Self {
        Self { state: State::new("team_t", "CMX"), now: 1_000 }
    }

    fn run(
        &mut self,
        actor: &Principal,
        stamp: Option<Actor>,
        key: &str,
        op: Op,
    ) -> Result<cmux_tasks_core::Commit, cmux_tasks_core::Reject> {
        self.now += 10;
        let env = Envelope {
            actor: actor.clone(),
            stamp,
            origin: Origin::Cli,
            key: key.to_owned(),
            grants: Default::default(),
            op,
        };
        reduce(&mut self.state, &env, Ctx { now: self.now })
    }

    /// A task with a working session attached to ACP session `acp_1` on `host_a`.
    fn attached(&mut self, host: Option<&str>) {
        let me = lawrence();
        self.run(
            &me,
            None,
            "create",
            Op::TaskCreate(TaskCreate {
                id: "task_a".to_owned(),
                title: "a".to_owned(),
                ..TaskCreate::default()
            }),
        )
        .unwrap();
        self.run(
            &me,
            None,
            "delegate",
            Op::TaskDelegate(TaskDelegate {
                task: "task_a".to_owned(),
                session: "asess_1".to_owned(),
                harness: "claude".to_owned(),
                agent: None,
                class: None,
                target: None,
                prompt: None,
            }),
        )
        .unwrap();
        self.run(
            &me,
            None,
            "attach",
            Op::SessionAttach(SessionAttach {
                session: "asess_1".to_owned(),
                acp_session: "acp_1".to_owned(),
                workspace: None,
                host: host.map(str::to_owned),
            }),
        )
        .unwrap();
    }
}

fn done() -> Op {
    Op::SessionUpdate(SessionUpdate {
        session: "asess_1".to_owned(),
        status: Some(SessionStatus::Done),
        plan: None,
        pr: None,
    })
}

#[test]
fn stamp_json_is_the_p8_shape() {
    let cases = [
        (Actor::local_user(), json!({"kind": "user", "id": "user_local"})),
        (
            Actor::Terminal { id: "term_1".into(), host: "sess_h".into(), agent: None },
            json!({"kind": "terminal", "id": "term_1", "host": "sess_h"}),
        ),
        (
            Actor::AcpSession {
                id: "acp_1".into(),
                host: "sess_h".into(),
                agent: Some("agent_mux".into()),
            },
            json!({"kind": "acp_session", "id": "acp_1", "host": "sess_h", "agent": "agent_mux"}),
        ),
        (
            Actor::App {
                id: "cmux/tasks".into(),
                host: "sess_h".into(),
                version: "1.0.0".into(),
                on_behalf_of: UserActor { id: "user_local".into() },
            },
            json!({"kind": "app", "id": "cmux/tasks", "host": "sess_h", "version": "1.0.0",
                   "on_behalf_of": {"kind": "user", "id": "user_local"}}),
        ),
    ];
    for (actor, wire) in cases {
        assert!(actor.is_well_formed(), "{actor:?}");
        assert_eq!(serde_json::to_value(&actor).unwrap(), wire);
        assert_eq!(serde_json::from_value::<Actor>(wire).unwrap(), actor);
    }
}

#[test]
fn malformed_stamps_are_detected() {
    assert!(!Actor::User { id: String::new() }.is_well_formed());
    assert!(!Actor::User { id: "a\nb".into() }.is_well_formed());
    assert!(!Actor::Terminal { id: "t".into(), host: String::new(), agent: None }.is_well_formed());
    let app = |id: &str| Actor::App {
        id: id.into(),
        host: "h".into(),
        version: "1".into(),
        on_behalf_of: UserActor { id: "user_local".into() },
    };
    assert!(!app("tasks").is_well_formed(), "app ids are <publisher>/<name>");
    assert!(app("cmux/tasks").is_well_formed());
}

#[test]
fn the_attached_acp_session_may_report_status() {
    let mut w = World::new();
    w.attached(Some("sess_h"));
    // The person (no stamp) may not report: invariant 10.
    let err = w.run(&lawrence(), None, "u1", done()).unwrap_err();
    assert_eq!(err.code, RejectCode::Forbidden);
    // Another ACP session may not.
    let err = w.run(&lawrence(), Some(acp("acp_2", "sess_h")), "u2", done()).unwrap_err();
    assert_eq!(err.code, RejectCode::Forbidden);
    // The same ACP session id on another host may not.
    let err = w.run(&lawrence(), Some(acp("acp_1", "sess_x")), "u3", done()).unwrap_err();
    assert_eq!(err.code, RejectCode::Forbidden);
    // A terminal stamp is not an ACP session.
    let terminal = Actor::Terminal { id: "acp_1".into(), host: "sess_h".into(), agent: None };
    let err = w.run(&lawrence(), Some(terminal), "u4", done()).unwrap_err();
    assert_eq!(err.code, RejectCode::Forbidden);
    // The attached ACP session may.
    w.run(&lawrence(), Some(acp("acp_1", "sess_h")), "u5", done()).unwrap();
    assert_eq!(w.state.sessions["asess_1"].status, SessionStatus::Done);
}

#[test]
fn an_attachment_without_a_host_accepts_the_acp_session_on_any_host() {
    let mut w = World::new();
    w.attached(None);
    w.run(&lawrence(), Some(acp("acp_1", "sess_any")), "u1", done()).unwrap();
}

#[test]
fn a_key_is_scoped_to_the_person_not_the_credential() {
    let mut w = World::new();
    let create = |title: &str| {
        Op::TaskCreate(TaskCreate {
            id: "task_a".to_owned(),
            title: title.to_owned(),
            ..TaskCreate::default()
        })
    };
    let first = w.run(&lawrence(), Some(Actor::local_user()), "k", create("a")).unwrap();
    assert!(!first.replay);
    // The same key from an agent of the same person, under another stamp: a
    // replay with the first result.
    let stamp = acp("acp_9", "sess_h");
    let again = w.run(&claude(), Some(stamp), "k", create("a")).unwrap();
    assert!(again.replay);
    assert_eq!(again.result, first.result);
    assert_eq!(w.state.tasks["task_a"].created_by, lawrence(), "the first actor stays");
    // A different op under the same person and key is a conflict.
    let err = w.run(&claude(), Some(acp("acp_9", "sess_h")), "k", create("b")).unwrap_err();
    assert_eq!(err.code, RejectCode::IdempotencyConflict);
    // A record without a stamp (written before the stamp existed) keeps the
    // old principal scope, so an old log replays unchanged.
    let legacy = Op::TaskCreate(TaskCreate {
        id: "task_l".to_owned(),
        title: "legacy".to_owned(),
        ..TaskCreate::default()
    });
    assert!(!w.run(&claude(), None, "k", legacy).unwrap().replay);
    // Another person may use the same key.
    let other = Principal::user("usr_other");
    let mut op = create("c");
    if let Op::TaskCreate(p) = &mut op {
        p.id = "task_c".to_owned();
    }
    assert!(!w.run(&other, None, "k", op).unwrap().replay);
}
