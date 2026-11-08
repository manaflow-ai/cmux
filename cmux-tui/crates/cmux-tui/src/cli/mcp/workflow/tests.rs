use super::*;
use std::cell::{Cell, RefCell};

#[derive(Default)]
struct Fake {
    starts: RefCell<BTreeMap<String, String>>,
    effects: Cell<usize>,
    fenced: Cell<bool>,
    allowed: RefCell<Value>,
    upstream_names: RefCell<Option<Value>>,
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
            let mut answer = json!({"running":true,"allowedTools":self.allowed.borrow().clone()});
            if let Some(names) = self.upstream_names.borrow().as_ref() {
                answer["upstreamNames"] = names.clone();
            }
            return Ok(answer);
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

#[test]
fn native_workflow_host_rechecks_permissions_before_replaying_raw_tool_results() {
    let directory = tempfile::tempdir().unwrap();
    {
        let mut journal = Journal::open(directory.path(), "source", 1).unwrap();
        let Activity::Work { id, .. } = journal.begin("call", "window_list", &json!({})).unwrap()
        else {
            panic!("new call")
        };
        journal.complete(&id, Ok(json!({"ok":true,"value":"saved result"}))).unwrap();
        journal.finish().unwrap();
    }
    let mut journal = Journal::open(directory.path(), "source", 0).unwrap();
    let mut server = Server::new(Fake::default(), None);
    *server.backend.allowed.borrow_mut() = json!(["cmux_workflow"]);
    let result = handle(
        &mut server,
        &proof(),
        &mut journal,
        &mut BTreeMap::new(),
        &mut None,
        &mut Vec::new(),
        code_mode::Request::Call { name: "window_list".into(), arguments: Map::new() },
    )
    .unwrap();
    assert_eq!(result["ok"], false, "{result}");
    assert!(journal.last_id().is_none(), "denied replay advanced the journal");
    assert_eq!(server.backend.effects.get(), 0);
}

#[test]
fn native_workflow_host_journals_large_activity_results_without_mcp_preview_truncation() {
    let directory = tempfile::tempdir().unwrap();
    let source = "return await agent('x'.repeat(300000));";
    let mut server = Server::new(Fake::default(), None);
    for budget in [1, 0] {
        let mut journal = Journal::open(directory.path(), source, budget).unwrap();
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
        assert_eq!(result["structuredContent"]["result"].as_str().unwrap().len(), 300000);
        journal.finish().unwrap();
    }
    assert_eq!(server.backend.effects.get(), 1);
}

#[test]
fn native_workflow_host_drops_a_disabled_upstream_before_another_call() {
    let mut server = Server::new(Fake::default(), None);
    server.upstreams.push(upstream::Proxied::new(upstream::Upstream::new(upstream::Spec {
        name: "turned-off-server".into(),
        command: "/unused".into(),
        args: Vec::new(),
        env: Vec::new(),
        call_timeout: Duration::from_secs(1),
    })));
    refresh_tools(&mut server, &json!({"allowedTools":null,"upstreamNames":[]})).unwrap();
    assert!(server.upstreams.is_empty());
}

#[test]
fn native_workflow_host_refuses_saved_results_from_a_revoked_upstream() {
    let directory = tempfile::tempdir().unwrap();
    let name = "turned_off_tool";
    {
        let mut journal = Journal::open(directory.path(), "source", 1).unwrap();
        let Activity::Work { id, .. } = journal.begin("call", name, &json!({})).unwrap() else {
            panic!("new call")
        };
        journal.complete(&id, Ok(json!({"ok":true,"value":"saved private result"}))).unwrap();
    }
    let mut server = Server::new(Fake::default(), None);
    let mut proxied = upstream::Proxied::new(upstream::Upstream::new(upstream::Spec {
        name: "turned-off-server".into(),
        command: "/unused".into(),
        args: Vec::new(),
        env: Vec::new(),
        call_timeout: Duration::from_secs(1),
    }));
    proxied.listed.push(json!({"name":name}));
    server.upstreams.push(proxied);
    *server.backend.upstream_names.borrow_mut() = Some(json!([]));
    let mut journal = Journal::open(directory.path(), "source", 0).unwrap();
    let mut tools = Some(vec![json!({"name":name})]);
    let result = handle(
        &mut server,
        &proof(),
        &mut journal,
        &mut BTreeMap::new(),
        &mut tools,
        &mut Vec::new(),
        code_mode::Request::Call { name: name.into(), arguments: Map::new() },
    )
    .unwrap();
    assert_eq!(result["ok"], false, "revoked upstream replayed: {result}");
    assert!(server.upstreams.is_empty());
    assert!(journal.last_id().is_none(), "denied replay advanced the journal");
    assert_eq!(server.backend.effects.get(), 0);
}
