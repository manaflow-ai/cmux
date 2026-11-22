//! The finished components' contract: which scene nodes take a `variant` and a `state`, the
//! variants each draws, and what a `Chart` needs (RFD 0009 slice 4). The design check's
//! `component` findings come from here; the renderers draw the same table
//! (`webviews/src/apps/scene/sceneComponents.tsx`, `AppSceneComponentState.swift`) and the
//! runtime types it (`cmux-app-host/js/src/view.ts`, `ComponentVariant`, `ComponentState`).

use serde_json::Value;

use super::scene::Node;

/// Every variant a component can draw. `standard` is the default.
pub(super) const VARIANTS: [&str; 3] = ["standard", "prominent", "subtle"];

/// The states the host draws in place of a finished component.
pub(super) const STATES: [&str; 3] = ["loading", "error", "empty"];

/// The most values a `Chart` draws (`CHART_MAX_VALUES` in view.ts); past it the first ones drop.
pub(super) const CHART_MAX_VALUES: usize = 64;

/// The finished components and the variants each draws (the rest draw only `standard`).
pub(super) const COMPONENTS: [(&str, &[&str]); 11] = [
    ("Row", &VARIANTS),
    ("Badge", &VARIANTS),
    ("Button", &VARIANTS),
    ("ProgressView", &VARIANTS),
    ("Stat", &VARIANTS),
    ("Chart", &VARIANTS),
    ("Toggle", &["standard"]),
    ("Slider", &["standard"]),
    ("TextField", &["standard"]),
    ("Image", &["standard"]),
    ("EmptyState", &["standard"]),
];

/// The variants `kind` draws, or None when it is not a finished component.
pub(super) fn variants_of(kind: &str) -> Option<&'static [&'static str]> {
    COMPONENTS.iter().find(|(name, _)| *name == kind).map(|(_, variants)| *variants)
}

/// One `component` finding: its message and fix.
pub(super) type Problem = (String, String);

/// What is wrong with `node`'s `variant`, `state` and (for a Chart) its values.
pub(super) fn problems(node: &Node) -> Vec<Problem> {
    let mut out = Vec::new();
    let kind = node.kind.as_str();
    let variants = variants_of(kind);
    let variant = node.props.get("variant");
    let state = node.props.get("state");
    match (variants, variant) {
        (_, None | Some(Value::Null)) => {}
        (None, Some(_)) => out.push((
            format!("{kind} is not a finished component, so its variant draws nothing"),
            format!("drop .variant(...), or use a component that has one ({})", component_names()),
        )),
        (Some(variants), Some(value)) => {
            let name = value.as_str().unwrap_or_default();
            if !variants.contains(&name) {
                out.push((
                    format!("{kind} has no variant {value}, so it draws as standard"),
                    format!("use {}", quoted(variants)),
                ));
            }
        }
    }
    match (variants, state) {
        (_, None | Some(Value::Null)) => {}
        (None, Some(_)) => out.push((
            format!("{kind} is not a finished component, so its state draws nothing"),
            format!(
                "put .state(...) on the component the state is about ({}), or show an EmptyState",
                component_names()
            ),
        )),
        (Some(_), Some(value)) => {
            let name = value.as_str().unwrap_or_default();
            if !STATES.contains(&name) {
                out.push((
                    format!("{kind} has no state {value}, so the host draws the component"),
                    format!("use {} (or null for the component)", quoted(&STATES)),
                ));
            }
        }
    }
    if kind == "Chart" {
        chart(node, &mut out);
    }
    out
}

fn chart(node: &Node, out: &mut Vec<Problem>) {
    match node.props.get("kind").and_then(Value::as_str) {
        None | Some("line" | "bar") => {}
        Some(other) => out.push((
            format!("Chart kind \"{other}\" is not one the host draws"),
            "use \"line\" (a sparkline) or \"bar\"".into(),
        )),
    }
    // A chart in a state draws the state, so it needs no values yet.
    if node.props.get("state").and_then(Value::as_str).is_some() {
        return;
    }
    let values = node.props.get("values").and_then(Value::as_array);
    let finite =
        values.map_or(0, |v| v.iter().filter(|n| n.as_f64().is_some_and(f64::is_finite)).count());
    if finite == 0 {
        out.push((
            "Chart has no values, so it draws an empty box".into(),
            ".state(\"loading\") until the numbers come, or .state(\"empty\") when there are none"
                .into(),
        ));
    } else if values.is_some_and(|v| v.len() > CHART_MAX_VALUES) {
        out.push((
            format!("Chart has more than {CHART_MAX_VALUES} values; only the last {CHART_MAX_VALUES} draw"),
            format!("pass the last {CHART_MAX_VALUES} (values.slice(-{CHART_MAX_VALUES}))"),
        ));
    }
}

fn component_names() -> String {
    COMPONENTS.iter().map(|(name, _)| *name).collect::<Vec<_>>().join(", ")
}

fn quoted(names: &[&str]) -> String {
    names.iter().map(|n| format!("\"{n}\"")).collect::<Vec<_>>().join(", ")
}
