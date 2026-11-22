use super::*;

fn visit(tab: &str, workspace: &str) -> TabVisit {
    TabVisit { tab: tab.into(), workspace: workspace.into(), machine: String::new() }
}

fn history(visits: &[(&str, &str)]) -> TabHistory {
    let mut history = TabHistory::default();
    for (tab, workspace) in visits {
        history.record(visit(tab, workspace));
    }
    history
}

/// Shows `step`'s target the way the app does: step, then record the tab it showed.
fn go(
    history: &mut TabHistory,
    step: TabStep,
    scope: TabScope,
    current: &TabVisit,
) -> Option<String> {
    let target = history.step(step, scope, current)?;
    history.record(target.clone());
    Some(target.tab)
}

#[test]
fn record_keeps_one_visit_per_tab_newest_last() {
    let history = history(&[("a", "w1"), ("b", "w1"), ("a", "w1"), ("c", "w2")]);
    let tabs: Vec<_> = history.visits.iter().map(|visit| visit.tab.as_str()).collect();
    assert_eq!(tabs, ["b", "a", "c"]);
}

#[test]
fn back_walks_further_each_repeat_in_any_workspace() {
    let mut history = history(&[("a", "w1"), ("b", "w2"), ("c", "w1"), ("d", "w2")]);
    let mut current = visit("d", "w2");
    let mut walked = Vec::new();
    while let Some(tab) = go(&mut history, TabStep::Back, TabScope::Any, &current) {
        let workspace =
            history.visits.iter().find(|visit| visit.tab == tab).unwrap().workspace.clone();
        current = visit(&tab, &workspace);
        walked.push(tab);
    }
    assert_eq!(walked, ["c", "b", "a"]);
}

#[test]
fn workspace_scope_is_strict_tab_isolation() {
    // Tabs of w1 and w2 interleave: the workspace walk never leaves w1.
    let mut history = history(&[("a", "w1"), ("x", "w2"), ("b", "w1"), ("y", "w2"), ("c", "w1")]);
    let mut current = visit("c", "w1");
    let mut walked = Vec::new();
    while let Some(tab) = go(&mut history, TabStep::Back, TabScope::Workspace, &current) {
        current = visit(&tab, "w1");
        walked.push(tab);
    }
    assert_eq!(walked, ["b", "a"]);
    // The same workspace name on another machine is another workspace.
    let mut history = history_with_machine();
    assert_eq!(history.step(TabStep::Back, TabScope::Workspace, &visit("b", "w1")), None);
}

fn history_with_machine() -> TabHistory {
    let mut history = TabHistory::default();
    history.record(TabVisit { tab: "remote".into(), workspace: "w1".into(), machine: "m2".into() });
    history.record(visit("b", "w1"));
    history
}

#[test]
fn recent_toggles_between_the_last_two_tabs_in_scope() {
    let mut history = history(&[("a", "w1"), ("x", "w2"), ("b", "w1")]);
    assert_eq!(
        go(&mut history, TabStep::Recent, TabScope::Workspace, &visit("b", "w1")).as_deref(),
        Some("a")
    );
    assert_eq!(
        go(&mut history, TabStep::Recent, TabScope::Workspace, &visit("a", "w1")).as_deref(),
        Some("b")
    );
    assert_eq!(
        go(&mut history, TabStep::Recent, TabScope::Any, &visit("b", "w1")).as_deref(),
        Some("a")
    );
    assert_eq!(
        go(&mut history, TabStep::Recent, TabScope::Any, &visit("a", "w1")).as_deref(),
        Some("b")
    );
}

#[test]
fn a_walk_ends_where_it_stopped() {
    let mut history = history(&[("a", "w1"), ("b", "w1"), ("c", "w1")]);
    assert_eq!(
        go(&mut history, TabStep::Back, TabScope::Any, &visit("c", "w1")).as_deref(),
        Some("b")
    );
    assert_eq!(
        go(&mut history, TabStep::Back, TabScope::Any, &visit("b", "w1")).as_deref(),
        Some("a")
    );
    // The person stays on a, then opens d: a is where they left from.
    assert!(history.record(visit("d", "w1")));
    let tabs: Vec<_> = history.visits.iter().map(|visit| visit.tab.as_str()).collect();
    assert_eq!(tabs, ["b", "c", "a", "d"]);
    assert_eq!(
        go(&mut history, TabStep::Recent, TabScope::Any, &visit("d", "w1")).as_deref(),
        Some("a")
    );
}

#[test]
fn forget_drops_a_closed_tab_and_keeps_the_walk() {
    let mut history = history(&[("a", "w1"), ("b", "w1"), ("c", "w1"), ("d", "w1")]);
    assert_eq!(
        go(&mut history, TabStep::Back, TabScope::Any, &visit("d", "w1")).as_deref(),
        Some("c")
    );
    assert!(history.forget("a"));
    assert!(!history.forget("a"));
    assert_eq!(
        go(&mut history, TabStep::Back, TabScope::Any, &visit("c", "w1")).as_deref(),
        Some("b")
    );
    assert_eq!(history.step(TabStep::Back, TabScope::Any, &visit("b", "w1")), None);
}

#[test]
fn capacity_drops_the_oldest() {
    let mut history = TabHistory::default();
    for index in 0..CAPACITY + 5 {
        history.record(visit(&format!("t{index}"), "w"));
    }
    assert_eq!(history.visits.len(), CAPACITY);
    assert_eq!(history.visits[0].tab, "t5");
}

#[test]
fn the_ffi_request_round_trips() {
    let request: Request = serde_json::from_value(serde_json::json!({
        "op": "step", "step": "back", "scope": "workspace",
        "current": {"tab": "b", "workspace": "w1"},
        "history": {"visits": [{"tab": "a", "workspace": "w1"}, {"tab": "x", "workspace": "w2"}, {"tab": "b", "workspace": "w1"}]}
    }))
    .unwrap();
    let reply = apply(request);
    assert_eq!(reply.target, Some(visit("a", "w1")));
    assert!(reply.changed, "the walk started");
    let json = serde_json::to_value(&reply).unwrap();
    assert_eq!(json["history"]["walk"], serde_json::json!({"at": 0, "scope": "workspace"}));
}
