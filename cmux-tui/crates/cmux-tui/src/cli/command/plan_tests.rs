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
