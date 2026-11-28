//! Parity with `MacScreenViewerLook*` (`MacScreenViewerLookFollowUpTests`, `MacScreenQuietCardTests`):
//! styles, look A's marks and toolbar, look B's strip and look C's full-pane states.

use serde_json::{Value, json};

use super::*;

fn card(v: Value) -> Card {
    serde_json::from_value(v).unwrap()
}

#[test]
fn styles() {
    assert_eq!(style("current"), Style::default());
    assert_eq!(style("unknown"), Style::default());
    let a = style("a");
    assert!(
        a.toolbar_auto_hide && a.picture_marks && a.card_quiet_transient && a.outage_keeps_picture
    );
    assert_eq!((a.toolbar_corner_radius, a.toolbar_row_height), (14.0, Some(28.0)));
    let b = style("b");
    assert!(b.status_strip && b.backdrop == "page" && b.toolbar_placement == "topBar");
    let c = style("c");
    assert_eq!(
        (c.card_layout, c.card_width, c.card_veil_opacity, c.quiet_outage),
        ("fullPane", Some(440.0), 0.7, true)
    );
    assert_eq!(
        handle("style", &json!({"look": "b"})).unwrap().unwrap()["statusStrip"],
        json!(true)
    );
}

#[test]
fn quiet_outage_only_reconnecting_over_a_live_picture() {
    let reconnecting = card(json!({"kind": "connecting", "reconnecting": true}));
    let s = |look: &str, c: Card| StateArgs {
        look: look.into(),
        is_live: true,
        has_frame: true,
        card: Some(c),
        ..StateArgs::default()
    };
    assert!(is_quiet_outage(&s("c", reconnecting.clone())));
    assert!(!is_quiet_outage(&s("a", reconnecting.clone())));
    assert!(!is_quiet_outage(&s("c", card(json!({"kind": "connecting"})))));
    assert!(!is_quiet_outage(&StateArgs { has_frame: false, ..s("c", reconnecting) }));
}

#[test]
fn look_a_toolbar_and_marks() {
    let live =
        StateArgs { look: "a".into(), is_live: true, has_frame: true, ..StateArgs::default() };
    assert!(!toolbar_pinned(&live));
    assert!(toolbar_pinned(&StateArgs {
        has_card: true,
        ..StateArgs { look: "a".into(), is_live: true, ..StateArgs::default() }
    }));
    assert!(!toolbar_pinned(&StateArgs {
        has_card: true,
        outage: true,
        look: "a".into(),
        is_live: true,
        ..StateArgs::default()
    }));
    assert!(toolbar_pinned(&StateArgs {
        pointer_at_top: true,
        look: "a".into(),
        is_live: true,
        ..StateArgs::default()
    }));
    assert!(toolbar_pinned(&StateArgs { look: "b".into(), is_live: true, ..StateArgs::default() }));

    let mark = |f: fn(&mut StateArgs)| {
        let mut s =
            StateArgs { look: "a".into(), is_live: true, has_frame: true, ..StateArgs::default() };
        f(&mut s);
        picture_mark(&s)
    };
    assert_eq!(mark(|_| {}), "none");
    assert_eq!(mark(|s| s.captures_keyboard = true), "controlling");
    assert_eq!(mark(|s| s.view_only = true), "viewOnly");
    assert_eq!(
        mark(|s| {
            s.view_only = true;
            s.has_card = true
        }),
        "none"
    );
    assert_eq!(mark(|s| s.outage = true), "none");
    assert_eq!(
        mark(|s| {
            s.outage = true;
            s.outage_mark_due = true;
            s.has_card = true
        }),
        "reconnecting"
    );
    assert_eq!(
        mark(|s| {
            s.look = "c".into();
            s.view_only = true
        }),
        "none"
    );
    assert_eq!(
        handle("outageOverPicture", &json!({"isLive": true, "hasFrame": true, "stalled": true})),
        Some(Ok(json!(true)))
    );
}

#[test]
fn look_b_strip() {
    let s = |c: Value| strip(&StripArgs { card: card(c), ..StripArgs::default() });
    let st = s(json!({"kind": "connecting"}));
    assert!(st.mark.loading);
    assert_eq!(st.actions[0].id, None);
    let st = s(json!({"kind": "failed"}));
    assert_eq!(
        (st.ink, st.mark.glyph, st.caption),
        ("danger", Some("exclamationmark.triangle"), Some(token("$failedDetail")))
    );
    let st = s(json!({"kind": "hubRevoked", "end": {"removesAccess": true, "canReconnect": true}}));
    assert_eq!((st.ink, st.mark.glyph), ("danger", Some("lock")));
    assert_eq!(st.actions[1].id, Some("macScreen.hub.connectAgain"));
    assert_eq!(st.caption, Some(token("$endText")));
    let st = s(json!({"kind": "hubEnded", "end": {"canReconnect": true}}));
    assert_eq!(st.actions[1].id, Some("macScreen.card.reconnect"));
    let st = s(json!({"kind": "hubRefused", "refusal": "notSignedIn"}));
    assert!(st.sign_in && !st.actions[1].primary);
    let st = s(json!({"kind": "hubRefused", "refusal": "hostOffline"}));
    assert_eq!(st.mark.glyph, Some("wifi.slash"));
    assert!(st.actions[1].primary);
    assert_eq!(s(json!({"kind": "hubRefused", "refusal": "notFound"})).actions.len(), 1);
    assert_eq!(s(json!({"kind": "hubWaiting"})).ink, "attention");
}

#[test]
fn look_c_full_pane() {
    let f = |c: Value| FullPaneArgs { card: card(c), ..FullPaneArgs::default() };
    let p = full_pane(&f(json!({"kind": "connecting"})));
    assert_eq!((p.symbol, p.steps.len(), p.active_step), ("desktopcomputer", 3, 1));
    let p = full_pane(&FullPaneArgs {
        link_connected: true,
        platform: Some("linux".into()),
        ..f(json!({"kind": "connecting"}))
    });
    assert_eq!((p.symbol, p.active_step), ("display", 2));
    let p = full_pane(&f(json!({"kind": "hubWaiting", "scope": "full"})));
    assert_eq!((p.steps.len(), p.active_step), (4, 1));
    let p = full_pane(&f(json!({"kind": "hubRefused", "refusal": "permissionNone"})));
    assert!(p.secondary.is_empty() && p.primary.unwrap().run == "closeTab");
    let p = full_pane(&f(json!({"kind": "hubRefused", "refusal": "notSignedIn"})));
    assert!(p.sign_in_primary && p.secondary.len() == 2 && p.primary.is_none());
    let p = full_pane(&f(json!({"kind": "hubRevoked", "end": {"removesAccess": true}})));
    assert_eq!((p.symbol, p.primary), ("lock", None));
}

#[test]
fn look_c_failures() {
    let failed = |cause: Option<Cause>, link: bool, timed_out: bool| {
        full_pane(&FullPaneArgs {
            card: card(json!({"kind": "failed"})),
            cause,
            link_connected: link,
            timed_out,
            ..FullPaneArgs::default()
        })
    };
    let host = |r: &str| Some(Cause { kind: "host".into(), reason: Some(r.into()) });
    assert_eq!(failed(host("Display went to Sleep"), false, false).symbol, "moon.zzz");
    assert_eq!(failed(host("screen is locked"), false, false).symbol, "lock");
    let p = failed(None, true, false);
    assert_eq!((p.symbol, p.details), ("display", None));
    let p = failed(None, false, false);
    assert_eq!((p.symbol, p.why), ("exclamationmark.triangle", Some(token("$failedDetail"))));
    let link = || Some(Cause { kind: "link".into(), reason: None });
    let p = failed(link(), true, false);
    assert_eq!(p.why, Some(keyed("macScreen.card.failedHub", &["$name"])));
    assert_eq!(p.details, Some(token("$failedDetail")));
    assert_eq!(failed(link(), false, true).why, Some(token("$timeoutDetail")));
    assert_eq!(
        failed(host("crashed"), true, false).headline,
        keyed("macScreen.full.errorTitle", &["$name"])
    );
    assert_eq!(p.primary.unwrap().id, Some("macScreen.card.retry"));
}
