use std::cell::RefCell;

use serde_json::{Value, json};

use super::super::command::RequestPlan;
use super::super::mcp::{CallFailure, FailureKind};
use super::super::terminal_talk::send::Daemon;
use super::super::wire::request_value;
use super::*;

const WS_A: &str = "ws_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const WS_B: &str = "ws_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const SCREEN_A: &str = "screen_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SCREEN_B: &str = "screen_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const SCREEN_NEW: &str = "screen_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
/// The pane that moves: three tabs, the middle one selected.
const PANE_S: &str = "pane_5555555555555555555555555555aaaa";
/// The focused pane, beside it; the caller's terminal is in it.
const PANE_F: &str = "pane_ffffffffffffffffffffffffffffaaaa";
/// A pane in the other workspace, with two tabs.
const PANE_T: &str = "pane_7777777777777777777777777777bbbb";
const PANE_NEW: &str = "pane_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const TAB_NEW: &str = "tab_eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee";
const CALLER: &str = "term_cccccccccccccccccccccccccccccccc";

fn tab_id(pane: &str, index: usize) -> String {
    format!("tab_{}{index:02}", &pane[5..35])
}

fn tab(pane: &str, index: usize, focused: bool, terminal: String) -> Value {
    json!({"id": tab_id(pane, index), "pane_id": pane, "name": null, "index": index,
           "focused": focused, "content_kind": "terminal", "content_id": terminal})
}

fn snapshot() -> Value {
    json!({
        "workspaces": [
            {"id": WS_A, "name": "main", "focused": true},
            {"id": WS_B, "name": "other", "focused": false},
        ],
        "screens": [
            {"id": SCREEN_A, "workspace_id": WS_A, "focused": true},
            {"id": SCREEN_B, "workspace_id": WS_B, "focused": false},
        ],
        "panes": [
            {"id": PANE_S, "screen_id": SCREEN_A, "name": "logs", "focused": false},
            {"id": PANE_F, "screen_id": SCREEN_A, "name": null, "focused": true},
            {"id": PANE_T, "screen_id": SCREEN_B, "name": null, "focused": false},
        ],
        "tabs": [
            tab(PANE_S, 0, false, format!("term_{}", "1".repeat(32))),
            tab(PANE_S, 1, true, format!("term_{}", "2".repeat(32))),
            tab(PANE_S, 2, false, format!("term_{}", "3".repeat(32))),
            tab(PANE_F, 0, true, CALLER.to_owned()),
            tab(PANE_T, 0, true, format!("term_{}", "4".repeat(32))),
            tab(PANE_T, 1, false, format!("term_{}", "5".repeat(32))),
        ],
    })
}

/// Answers from the snapshot above; records every request.
struct FakeDaemon {
    snapshot: Value,
    sent: RefCell<Vec<Value>>,
}

impl FakeDaemon {
    fn new() -> Self {
        Self { snapshot: snapshot(), sent: RefCell::new(Vec::new()) }
    }

    /// `operation selector` for each request, the selector being the
    /// request's own target.
    fn steps(&self) -> Vec<String> {
        self.sent
            .borrow()
            .iter()
            .map(|request| {
                let operation = request["operation"].as_str().unwrap_or_default();
                let params = &request["params"];
                let target = ["tab", "pane", "workspace"]
                    .iter()
                    .find_map(|scope| params.get(*scope).and_then(Value::as_str))
                    .unwrap_or_default();
                format!("{operation} {target}").trim_end().to_owned()
            })
            .collect()
    }

    fn params(&self, operation: &str) -> Vec<Value> {
        self.sent
            .borrow()
            .iter()
            .filter(|request| request["operation"] == operation)
            .map(|request| request["params"].clone())
            .collect()
    }

    fn record(&self, kind: &str, selector: &str) -> Result<Value, Value> {
        let focused = |kind: &str| {
            self.snapshot[kind]
                .as_array()
                .and_then(|records| records.iter().find(|record| record["focused"] == true))
                .cloned()
        };
        let found = match selector {
            "current" => focused(kind),
            selector => self.snapshot[kind].as_array().and_then(|records| {
                records
                    .iter()
                    .find(|record| record["id"] == selector || record["name"] == selector)
                    .cloned()
            }),
        };
        found.ok_or_else(|| {
            json!({"code": "selector.not_found", "message": format!("no {selector}"),
                   "details": {}, "retryable": false})
        })
    }

    fn answer(&self, operation: &str, params: &Value) -> Result<Value, Value> {
        let selector = |scope: &str| params[scope].as_str().unwrap_or_default().to_owned();
        let created = |workspace: &str, screen: &str| {
            json!({"value": {"kind": "terminal", "workspace_id": workspace,
                             "screen_id": screen, "pane_id": PANE_NEW, "tab_id": TAB_NEW,
                             "terminal_id": format!("term_{}", "e".repeat(32))},
                   "generation": "g", "revision": "2", "replayed": false})
        };
        match operation {
            "session.snapshot" => Ok(self.snapshot.clone()),
            "pane.get" => self.record("panes", &selector("pane")),
            "tab.get" => self.record("tabs", &selector("tab")),
            "workspace.get" => self.record("workspaces", &selector("workspace")),
            "screen.create" => Ok(created(&selector("workspace"), SCREEN_NEW)),
            "pane.split" => Ok(created(WS_B, SCREEN_B)),
            _ => Ok(json!({"value": {}, "generation": "g", "revision": "3", "replayed": false})),
        }
    }
}

impl Daemon for FakeDaemon {
    fn request(&self, _session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
        let request = request_value(&plan).expect("a valid request");
        let operation = request["operation"].as_str().unwrap_or_default().to_owned();
        let params = request["params"].clone();
        self.sent.borrow_mut().push(request);
        self.answer(&operation, &params).map_err(|error| CallFailure {
            kind: FailureKind::Rejected,
            error,
            idempotency_key: None,
        })
    }
}

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn request(target: &str, flags: &[&str]) -> MoveRequest {
    let mut request = parse(target, &strings(flags)).expect("parsed");
    request.caller_terminal = Some(CALLER.to_owned());
    request
}

/// The `tab.move` requests, as (tab, destination pane, index).
fn moves(daemon: &FakeDaemon) -> Vec<(String, String, u64)> {
    daemon
        .params("tab.move")
        .iter()
        .map(|params| {
            (
                params["tab"].as_str().unwrap_or_default().to_owned(),
                params["destination_pane"].as_str().unwrap_or_default().to_owned(),
                params["index"].as_u64().unwrap_or(u64::MAX),
            )
        })
        .collect()
}

#[test]
fn w4j_pane_move_parses_one_destination_and_refuses_the_rest() {
    let parsed = |flags: &[&str]| parse(PANE_S, &strings(flags));
    assert_eq!(
        parsed(&["--to-pane", PANE_T, "--split", "right"]).expect("parsed").destination,
        Destination::Pane { pane: PANE_T.into(), split: Some("right".into()) }
    );
    assert_eq!(
        parsed(&["--to-tab=tab_x"]).expect("parsed").destination,
        Destination::Tab("tab_x".into())
    );
    assert_eq!(
        parsed(&["--to-workspace", "other", "--name", "logs"]).expect("parsed").destination,
        Destination::NewScreen { workspace: Some("other".into()) }
    );
    for flag in ["--new-screen", "--new-tab"] {
        let request = parsed(&[flag, "--focus"]).expect("parsed");
        assert_eq!(request.destination, Destination::NewScreen { workspace: None });
        assert!(request.focus);
    }
    for bad in [
        &[][..],
        &["--new-screen", "--to-pane", PANE_T],
        &["--to-tab", "x", "--split", "right"],
        &["--to-pane", PANE_T, "--split", "sideways"],
        &["--to-pane", PANE_T, "--name", "logs"],
        &["--to-pane"],
        &["--new-screen", "--index", "2"],
    ] {
        assert!(parsed(bad).is_err(), "accepted {bad:?}");
    }
    assert!(parse("--new-screen", &[]).is_err(), "a flag is not a pane");
}

#[test]
fn w4j_pane_move_to_another_pane_appends_every_tab_in_order_and_keeps_the_focus() {
    let daemon = FakeDaemon::new();
    let result = move_pane(&daemon, &request(PANE_S, &["--to-pane", PANE_T]), "pane-move-test-key")
        .expect("moved");
    let tabs = (0..3).map(|index| tab_id(PANE_S, index)).collect::<Vec<_>>();
    assert_eq!(
        moves(&daemon),
        vec![
            (tabs[0].clone(), PANE_T.to_owned(), 2),
            (tabs[1].clone(), PANE_T.to_owned(), 3),
            (tabs[2].clone(), PANE_T.to_owned(), 4),
        ]
    );
    let first = &daemon.params("tab.move")[0];
    assert_eq!(first["destination_workspace"], WS_B);
    assert_eq!(first["destination_screen"], SCREEN_B);
    // The selected tab is selected again, then the focus goes back.
    let steps = daemon.steps();
    assert_eq!(
        &steps[steps.len() - 2..],
        [format!("tab.focus {}", tabs[1]), format!("pane.focus {PANE_F}")]
    );
    assert!(daemon.params("tab.close").is_empty(), "no shell tab to close");
    assert_eq!(result["pane"], PANE_S);
    assert_eq!(result["moved_tabs"], json!(tabs));
    assert_eq!(
        result["destination"],
        json!({"workspace": WS_B, "screen": SCREEN_B, "pane": PANE_T, "index": 2})
    );
    assert_eq!(result["created"], Value::Null);
    assert_eq!(result["focused_pane"], PANE_F);
}

#[test]
fn w4j_pane_move_with_split_moves_into_the_new_pane_and_closes_its_shell() {
    let daemon = FakeDaemon::new();
    let result = move_pane(
        &daemon,
        &request(PANE_S, &["--to-pane", PANE_T, "--split", "down", "--focus"]),
        "pane-move-test-key",
    )
    .expect("moved");
    let split = &daemon.params("pane.split")[0];
    assert_eq!(split["pane"], PANE_T);
    assert_eq!(split["direction"], "down");
    let indexes =
        moves(&daemon).iter().map(|(_, pane, index)| (pane.clone(), *index)).collect::<Vec<_>>();
    assert_eq!(indexes, vec![(PANE_NEW.into(), 1), (PANE_NEW.into(), 2), (PANE_NEW.into(), 3)]);
    // The shell tab closes only after the moved tabs are in.
    let steps = daemon.steps();
    let close = steps.iter().position(|step| *step == format!("tab.close {TAB_NEW}"));
    let last_move = steps.iter().rposition(|step| step.starts_with("tab.move"));
    assert!(close > last_move, "{steps:?}");
    // The new pane keeps the moved pane's name; --focus focuses it.
    let rename = &daemon.params("pane.rename")[0];
    assert_eq!(rename["pane"], PANE_NEW);
    assert_eq!(rename["name"], "logs");
    assert_eq!(steps.last().map(String::as_str), Some(format!("pane.focus {PANE_NEW}").as_str()));
    assert_eq!(result["created"], json!({"pane": PANE_NEW}));
    assert_eq!(result["focused_pane"], PANE_NEW);
}

#[test]
fn w4j_pane_move_to_a_tab_puts_the_tabs_after_it() {
    let daemon = FakeDaemon::new();
    let target = tab_id(PANE_T, 0);
    move_pane(&daemon, &request(PANE_S, &["--to-tab", &target]), "pane-move-test-key")
        .expect("moved");
    let indexes =
        moves(&daemon).iter().map(|(_, pane, index)| (pane.clone(), *index)).collect::<Vec<_>>();
    assert_eq!(indexes, vec![(PANE_T.into(), 1), (PANE_T.into(), 2), (PANE_T.into(), 3)]);
}

#[test]
fn w4j_pane_move_to_a_workspace_or_a_new_screen_makes_a_screen_without_focus() {
    for (flags, workspace) in [
        (vec!["--to-workspace", "other", "--name", "moved"], WS_B),
        (vec!["--new-screen", "--name", "moved"], WS_A),
    ] {
        let daemon = FakeDaemon::new();
        let result =
            move_pane(&daemon, &request(PANE_S, &flags), "pane-move-test-key").expect("moved");
        let create = &daemon.params("screen.create")[0];
        assert_eq!(create["workspace"], workspace, "{flags:?}");
        assert_eq!(create["name"], "moved");
        assert_eq!(create.get("focus"), None, "screen create keeps the focus");
        assert!(moves(&daemon).iter().all(|(_, pane, _)| pane == PANE_NEW));
        assert_eq!(daemon.params("tab.close")[0]["tab"], TAB_NEW);
        assert_eq!(result["created"], json!({"screen": SCREEN_NEW, "pane": PANE_NEW}));
        assert_eq!(result["focused_pane"], PANE_F, "{flags:?}");
    }
}

/// `current` is the caller's own pane (its terminal's), not the focused one.
#[test]
fn w4j_pane_move_current_is_the_callers_pane_and_the_focus_goes_with_it() {
    let daemon = FakeDaemon::new();
    let result =
        move_pane(&daemon, &request("current", &["--to-pane", PANE_T]), "pane-move-test-key")
            .expect("moved");
    assert_eq!(daemon.params("pane.get")[0]["pane"], PANE_F);
    assert_eq!(moves(&daemon), vec![(tab_id(PANE_F, 0), PANE_T.to_owned(), 2)]);
    // The moved pane had the focus: there is no pane to give it back to.
    assert!(daemon.params("pane.focus").is_empty());
    assert_eq!(result["focused_pane"], PANE_T);
}

#[test]
fn w4j_pane_move_refuses_a_destination_in_the_same_pane() {
    for flags in [
        vec!["--to-pane".to_owned(), PANE_S.to_owned()],
        vec!["--to-tab".to_owned(), tab_id(PANE_S, 2)],
    ] {
        let daemon = FakeDaemon::new();
        let flags = flags.iter().map(String::as_str).collect::<Vec<_>>();
        let error = move_pane(&daemon, &request(PANE_S, &flags), "pane-move-test-key")
            .expect_err("refused");
        assert_eq!(error.exit, 2);
        assert!(moves(&daemon).is_empty(), "{flags:?} moved a tab");
    }
}

/// A failed step names itself and what the steps before it moved.
#[test]
fn w4j_pane_move_failure_names_the_step_and_the_tabs_already_moved() {
    struct FailSecondMove(FakeDaemon);
    impl Daemon for FailSecondMove {
        fn request(&self, session: Option<&str>, plan: RequestPlan) -> Result<Value, CallFailure> {
            let moved = self.0.params("tab.move").len();
            let is_move = request_value(&plan).expect("valid")["operation"] == "tab.move";
            if is_move && moved == 1 {
                return Err(CallFailure {
                    kind: FailureKind::Rejected,
                    error: json!({"code": "operation.failed", "message": "no",
                                  "details": {}, "retryable": false}),
                    idempotency_key: None,
                });
            }
            self.0.request(session, plan)
        }
    }
    let daemon = FailSecondMove(FakeDaemon::new());
    let error = move_pane(&daemon, &request(PANE_S, &["--to-pane", PANE_T]), "pane-move-test-key")
        .expect_err("failed");
    let step = format!("move-{}", tab_id(PANE_S, 1));
    assert_eq!(error.error["details"]["step"], step);
    assert_eq!(error.error["details"]["made"]["moved_tabs"], json!([tab_id(PANE_S, 0)]));
    assert_eq!(error.error["details"]["idempotency_key"], "pane-move-test-key");
}
