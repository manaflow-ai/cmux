use super::*;
use std::cell::{Cell, RefCell};

#[derive(Default)]
struct Fake {
    starts: RefCell<BTreeMap<String, String>>,
    effects: Cell<usize>,
    fenced: Cell<bool>,
    allowed: RefCell<Value>,
}

impl Backend for Fake {
    fn acpmux(
        &self,
        method: &str,
        params: Value,
        _: Duration,
        _: Option<&str>,
        _: bool,
    ) -> Result<Value, CallFailure> {
        if self.fenced.get() {
            return Err(CallFailure::local(
                FailureKind::Rejected,
                "workflow.stale",
                "stale runner",
            ));
        }
        if method == METHOD {
            return Ok(json!({"running":true,"allowedTools":self.allowed.borrow().clone()}));
        }
        assert_eq!(method, ACTIVITY_METHOD);
        if params["action"] == "start" {
            self.effects.set(self.effects.get() + 1);
            self.starts.borrow_mut().insert(
                params["activityId"].as_str().unwrap().into(),
                params["prompt"].as_str().unwrap().into(),
            );
            Ok(json!({"id":params["activityId"]}))
        } else {
            let pending = params["activityIds"].as_array().unwrap();
            let id = pending
                .iter()
                .find(|id| self.starts.borrow()[id.as_str().unwrap()] == "second")
                .unwrap_or(&pending[0]);
            Ok(json!({"activityId":id,"outcome":{"Ok":self.starts.borrow()[id.as_str().unwrap()]}}))
        }
    }
    fn resource(
        &self,
        _: Option<&str>,
        _: RequestPlan,
        _: &[Prefix],
    ) -> Result<Value, CallFailure> {
        panic!("unexpected effect")
    }
    fn app(
        &self,
        _: &str,
        _: Value,
        _: Duration,
        _: Option<&str>,
        _: bool,
    ) -> Result<Value, CallFailure> {
        Ok(json!({}))
    }
    fn browser(&self, _: browser_tools::Request, _: bool) -> Result<Value, CallFailure> {
        panic!("unexpected browser")
    }
    fn session_events(
        &self,
        _: Option<&str>,
        _: Option<&Value>,
        _: Instant,
        _: Duration,
        _: &mut dyn FnMut(Option<&Value>) -> bool,
    ) -> Result<(), CallFailure> {
        panic!("unexpected events")
    }
}

fn proof() -> Proof {
    Proof { run_id: "run".into(), generation: 1, token: "ephemeral".into() }
}

#[test]
fn native_workflow_host_replays_parallel_completion_order_without_effects() {
    let directory = tempfile::tempdir().unwrap();
    let source = "return await parallel([async () => machine(await agent('first')), () => agent('second')]);";
    let mut server = Server::new(Fake::default(), None);
    let mut results = Vec::new();
    for cap in [3, 0] {
        let mut journal = Journal::open(directory.path(), source, cap).unwrap();
        let mut pending = BTreeMap::new();
        let mut tools = None;
        let mut images = Vec::new();
        let result = code_mode::workflow_exec(
            source,
            json!([]),
            code_mode::Limits::default(),
            &mut |request| {
                handle(
                    &mut server,
                    &proof(),
                    &mut journal,
                    &mut pending,
                    &mut tools,
                    &mut images,
                    request,
                )
                .unwrap()
            },
        )
        .unwrap();
        assert_ne!(result["isError"], true, "{result}");
        journal.finish().unwrap();
        results.push(result["structuredContent"]["result"].clone());
    }
    assert_eq!(results, vec![json!(["first", "second"]), json!(["first", "second"])]);
    assert_eq!(server.backend.effects.get(), 3);
}

#[test]
fn native_workflow_host_raw_docs_budget_sticks_even_if_script_ignores_errors() {
    let directory = tempfile::tempdir().unwrap();
    let source = "for (let i=0;i<3;i++) cmux.docs('missing'); return 'caught';";
    let mut server = Server::new(Fake::default(), None);
    let mut journal = Journal::open(directory.path(), source, 2).unwrap();
    let mut pending = BTreeMap::new();
    let mut tools = None;
    let mut images = Vec::new();
    let _ =
        code_mode::workflow_exec(source, json!([]), code_mode::Limits::default(), &mut |request| {
            handle(
                &mut server,
                &proof(),
                &mut journal,
                &mut pending,
                &mut tools,
                &mut images,
                request,
            )
            .unwrap_or_else(|message| refused("workflow.host", &message))
        })
        .unwrap();
    assert_eq!(journal.stop_reason(), Some(Stop::CallBudget));
    assert!(journal.finish().is_err());
}

#[test]
fn native_workflow_host_fences_before_raw_call_and_catalog_blocks_primitives() {
    let directory = tempfile::tempdir().unwrap();
    let mut journal = Journal::open(directory.path(), "source", 2).unwrap();
    let mut server = Server::new(Fake::default(), None);
    server.backend.fenced.set(true);
    let mut pending = BTreeMap::new();
    let mut tools = None;
    let mut images = Vec::new();
    assert!(
        handle(
            &mut server,
            &proof(),
            &mut journal,
            &mut pending,
            &mut tools,
            &mut images,
            code_mode::Request::Call { name: "terminal_input_write".into(), arguments: Map::new() }
        )
        .is_err()
    );
    assert!(journal.last_id().is_none());
    server.backend.fenced.set(false);
    *server.backend.allowed.borrow_mut() = json!(["agent_dispatch"]);
    let result = handle(
        &mut server,
        &proof(),
        &mut journal,
        &mut pending,
        &mut tools,
        &mut images,
        code_mode::Request::ActivityStart {
            kind: "agent".into(),
            prompt: "hello".into(),
            options: Map::new(),
        },
    )
    .unwrap();
    assert_eq!(result["ok"], false);
    assert_eq!(server.backend.effects.get(), 0);
    assert!(server.workflow_activity.is_none());
}
