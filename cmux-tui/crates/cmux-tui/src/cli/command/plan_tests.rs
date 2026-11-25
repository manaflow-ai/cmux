use serde_json::json;

use super::*;

#[test]
fn terminal_status_prints_only_the_program_status_records() {
    let records = json!([{"id": "", "state": "working", "progress": 40}]);
    let terminal = json!({"id": "term_1", "extra": {"progress": null, "program_status": records}});
    assert_eq!(ResponseView::TerminalProgramStatus.project(terminal.clone()), records);
    assert_eq!(ResponseView::Full.project(terminal.clone()), terminal);
    assert_eq!(
        ResponseView::TerminalProgramStatus.project(json!({"id": "term_1"})),
        json!([]),
        "a terminal without records prints an empty list"
    );
}

#[test]
fn terminal_status_is_a_terminal_get_with_the_status_view() {
    let args = ["terminal", "term_0123456789abcdef0123456789abcdef", "status"].map(str::to_owned);
    let Ok(super::super::CommandPlan::Protocol(plan)) =
        super::super::parse(&args, crate::cli::Surface::Cmux)
    else {
        panic!("terminal status parses to a protocol request");
    };
    assert_eq!(plan.operation.name().unwrap(), "terminal.get");
    assert_eq!(plan.view, ResponseView::TerminalProgramStatus);
}

fn creation(operation: ResourceOperation, params: Value) -> RequestPlan {
    RequestPlan {
        operation: WireOperation::Typed(operation),
        params,
        idempotency_key: None,
        stream: false,
        resolve: Vec::new(),
        view: ResponseView::Full,
        filter: Default::default(),
    }
}

#[test]
fn a_persons_terminal_tab_with_no_place_asks_for_the_callers_place() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| {
            pairs.iter().find(|(name, _)| *name == key).map(|(_, value)| (*value).to_owned())
        }
    };
    let terminal = &[("CMUX_TUI_TERMINAL_ID", "term_a")];
    let plan = creation(ResourceOperation::TabCreateTerminal, json!({"machine": "current"}));
    assert!(terminal_caller_place(&plan, env(terminal)));
    // A Chief turn names the Home chat only with "1", as resolve.rs reads it.
    let off = &[("CMUX_TUI_TERMINAL_ID", "term_a"), ("CMUX_CALLER_HOME_CHAT", "0")];
    assert!(terminal_caller_place(&plan, env(off)));

    // A named place, another operation, an agent, a Chief turn or no
    // terminal: no lookup.
    let named = creation(ResourceOperation::TabCreateTerminal, json!({"pane": "pane_x"}));
    assert!(!terminal_caller_place(&named, env(terminal)));
    let browser = creation(ResourceOperation::TabCreateBrowser, json!({}));
    assert!(!terminal_caller_place(&browser, env(terminal)));
    for others in [
        &[("CMUX_TUI_TERMINAL_ID", "term_a"), ("CMUX_AGENT_SESSION", "s")][..],
        &[("CMUX_TUI_TERMINAL_ID", "term_a"), ("CMUX_CALLER_HOME_CHAT", "1")][..],
        &[][..],
    ] {
        let plan = creation(ResourceOperation::TabCreateTerminal, json!({}));
        assert!(!terminal_caller_place(&plan, env(others)));
    }
}
