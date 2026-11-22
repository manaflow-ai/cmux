use serde_json::json;

use super::super::design::Tile;
use super::{Timer, check, run};

/// A widget script: `__cmuxAppExports.widget` built from the runtime's view globals.
fn widget(body: &str) -> String {
    format!("let t0; globalThis.__cmuxAppExports = {{ widget: (ctx) => {{ {body} }} }};")
}

fn small() -> Tile {
    Tile::of("small").unwrap()
}

#[test]
fn a_tick_redraws_from_ctx_now_and_the_probe_sees_both_scenes() {
    let script = widget(
        "t0 = ctx.now(); return HStack([Text(() => (ctx.now() > t0 ? '10' : '9')), Text('steps')])",
    );
    let ticked = run("dev.probe", &script, "widget", &json!({"size": "small"}), Some(60)).unwrap();
    assert!(!ticked.first.is_empty());
    assert!(
        ticked.tick.iter().any(|op| op["op"] == "update" && op["props"]["text"] == "10"),
        "{:?}",
        ticked.tick
    );
    let found =
        check("dev.probe", &script, "widget", &json!({"size": "small"}), &json!({}), &small());
    let shift: Vec<_> = found.iter().filter(|f| f.check == "layout-shift").collect();
    assert_eq!(shift.len(), 1, "{found:?}");
    assert_eq!(shift[0].sizes, vec!["small".to_string()]);
}

#[test]
fn an_app_timer_that_keeps_running_is_a_hidden_timer_and_ctx_now_is_not() {
    let every = widget("cmux.timer.every(1000, () => {}); return Text('hi').lineLimit(1)");
    let found = check("dev.probe", &every, "widget", &json!({}), &json!({}), &small());
    let timers: Vec<_> = found.iter().filter(|f| f.check == "hidden-timer").collect();
    assert_eq!(timers.len(), 1, "{found:?}");
    assert!(timers[0].message.contains("cmux.timer.every(1000)"), "{}", timers[0].message);
    assert!(timers[0].fix.contains("ctx.now()"), "{}", timers[0].fix);

    // A chain of `after`s is the same loop.
    let chain = widget(
        "const loop = () => cmux.timer.after(5000, loop); loop(); return Text('hi').lineLimit(1)",
    );
    let ticked = run("dev.probe", &chain, "widget", &json!({}), None).unwrap();
    assert!(
        ticked
            .timers
            .iter()
            .any(|t| *t == Timer { ms: 5000.0, repeat: false, pending: true, chained: true }),
        "{:?}",
        ticked.timers
    );
    let found = check("dev.probe", &chain, "widget", &json!({}), &json!({}), &small());
    assert!(found.iter().any(|f| f.check == "hidden-timer"), "{found:?}");

    // A one-shot `after` of a minute is the widget's own clock too.
    let once = widget("cmux.timer.after(60000, () => {}); return Text('hi').lineLimit(1)");
    let found = check("dev.probe", &once, "widget", &json!({}), &json!({}), &small());
    assert!(
        found.iter().any(|f| f.check == "hidden-timer" && f.message.contains("after(60000)")),
        "{found:?}"
    );

    // A short settle `after`, a cleared `every`, and ctx.now(): no finding.
    let quiet = widget(
        "cmux.timer.after(500, () => {}); const id = cmux.timer.every(1000, () => {}); cmux.timer.clear(id); return Text(String(ctx.now())).lineLimit(1)",
    );
    let found = check("dev.probe", &quiet, "widget", &json!({}), &json!({}), &small());
    assert!(found.iter().all(|f| f.check != "hidden-timer"), "{found:?}");
}

#[test]
fn a_timer_armed_when_the_script_loads_counts_too() {
    let script =
        format!("cmux.timer.every(2000, () => {{}}); {}", widget("return Text('hi').lineLimit(1)"));
    let ticked = run("dev.probe", &script, "widget", &json!({}), None).unwrap();
    assert!(ticked.timers.iter().any(|t| t.repeat && t.pending), "{:?}", ticked.timers);
}
