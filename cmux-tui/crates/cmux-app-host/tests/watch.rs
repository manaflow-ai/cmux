//! `cmux.watch` in the native QuickJS host (js/ABI.md, Signals): the bun tests in
//! `js/test/watch.test.ts` hold the full behavior; these check that the embedded runtime does the
//! same with real timers, subscriptions and microtask draining.

mod common;

use std::time::{Duration, Instant};

use common::{Harness, app};
use serde_json::{Value, json};

/// Module named `apps` so `verify-cmux-tui-hosted.sh --filter apps::` selects
/// every app platform test in the workspace.
mod apps {
    use super::*;

    const TWO_SECTIONS: &str = r#"
        const view = (name) => () => {
          const w = cmux.watch(name)
          return VStack([
            Text(() => "status=" + w.status()),
            ForEach({ items: () => w.value() ?? [], key: (p) => p.id }, (p) => Row({ title: () => p().title })),
          ])
        }
        return { workspaces: view("workspace.list"), pulls: view("github.pulls") }"#;

    fn reads(h: &Harness, name: &str) -> usize {
        h.calls.iter().filter(|c| c.name == name).count()
    }

    #[test]
    fn two_mounts_share_one_read_and_a_burst_of_pushes_is_one_more() {
        let mut h = Harness::new(&app(TWO_SECTIONS));
        h.handle("workspace.list", |_, _| {
            (true, json!({ "value": [{ "id": "w1", "title": "one" }] }))
        });
        assert_eq!(h.mount("a", "workspaces", json!({})), None);
        assert_eq!(h.mount("b", "workspaces", json!({})), None);
        assert_eq!(reads(&h, "workspace.list"), 1);
        assert!(h.texts("b").iter().any(|t| t == "one"), "{:?}", h.texts("b"));
        assert_eq!(h.subscriptions.len(), 1);
        let sub = *h.subscriptions.keys().next().expect("subscription");
        // The native host drains microtasks after every entry point, so the first event starts a
        // read and the other four, arriving while it is in flight, queue exactly one more.
        for _ in 0..5 {
            h.vm.event(sub, &json!({})).expect("event");
        }
        h.pump().expect("pump");
        assert_eq!(reads(&h, "workspace.list"), 3);
        h.vm.unmount("a").expect("unmount");
        h.pump().expect("pump");
        assert_eq!(h.subscriptions.len(), 1);
        h.vm.unmount("b").expect("unmount");
        h.pump().expect("pump");
        assert!(h.subscriptions.is_empty(), "{:?}", h.subscriptions);
    }

    #[test]
    fn a_polled_source_arms_one_timer_at_its_interval_and_drops_it_on_the_last_unmount() {
        let mut h = Harness::new(&app(TWO_SECTIONS));
        h.handle("integration.request", |_, _| (true, json!({ "value": { "items": [] } })));
        let before = Instant::now();
        assert_eq!(h.mount("a", "pulls", json!({})), None);
        assert_eq!(h.mount("b", "pulls", json!({})), None);
        // author and review-requested: two searches, one read.
        assert_eq!(reads(&h, "integration.request"), 2);
        let due = h.vm.next_timer_due().expect("poll timer");
        assert!(due >= before + Duration::from_secs(299), "polls no sooner than staleAfterSeconds");
        h.vm.unmount("a").expect("unmount");
        h.pump().expect("pump");
        assert!(h.vm.next_timer_due().is_some());
        h.vm.unmount("b").expect("unmount");
        h.pump().expect("pump");
        assert!(h.vm.next_timer_due().is_none(), "the last unmount stops the poll");
    }

    #[test]
    fn an_unknown_source_fails_the_mount_with_signal_unknown() {
        let mut h = Harness::new(&app(
            r#"return { render: () => { cmux.watch("nope.none"); return Text("x") } }"#,
        ));
        let error = h.mount("m", "render", json!({})).expect("mount error");
        assert!(error.contains("no signal source named nope.none"), "{error}");
        let code: Value =
            h.eval(r#"(() => { try { cmux.watch("nope") } catch (e) { return e.code } })()"#);
        assert_eq!(code, json!("signal.unknown"));
    }
}
