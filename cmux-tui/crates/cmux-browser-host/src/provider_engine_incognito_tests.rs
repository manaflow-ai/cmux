//! Agent sessions' opt-in incognito on the cmux app (decision D1 keeps the
//! person's login as the default; private data P1): `tabs.open {incognito:
//! true}` and `session.configure {incognito: true}` open the session's tabs
//! in an in-memory store of the session's own, which the app drops when the
//! session ends (`session.ended`). The app must confirm the store; an app
//! that does not (an older one) gets its tab closed and the call refused.

use super::tests::{FakeApp, calls, session, tab};
use super::*;
use crate::protocol::ErrorCode;
use crate::provider::{Frame, TabAnnounce};

/// The params of every call named `method` the app got, in order.
fn params_of(app: &FakeApp, method: &str) -> Vec<Value> {
    app.frames
        .lock()
        .unwrap()
        .iter()
        .filter_map(|f| match f {
            Frame::Call { method: m, params, .. } if m == method => Some(params.clone()),
            _ => None,
        })
        .collect()
}

/// The order of the app calls named in `methods`.
fn call_order(app: &FakeApp, methods: &[&str]) -> Vec<String> {
    app.frames
        .lock()
        .unwrap()
        .iter()
        .filter_map(|f| match f {
            Frame::Call { method, .. } if methods.contains(&method.as_str()) => {
                Some(method.clone())
            }
            _ => None,
        })
        .collect()
}

/// An incognito tab goes to the app with the flag and the session's id, and
/// without its URL: the page loads only after the app answered that the tab
/// is in a private store, so nothing reaches the person's profile.
#[test]
fn an_incognito_tab_opens_in_the_sessions_own_app_store() {
    for kind in ["cef", "webkit"] {
        let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("new", kind)]);
        let agent = session(&provider, kind, "s1");
        let opened = agent
            .call("tabs.open", &json!({"url": "https://b.test/x", "incognito": true}))
            .unwrap_or_else(|error| panic!("{kind}: {error}"));
        assert_eq!(opened["targetId"], "new", "{kind}");
        let open = params_of(&app, "tabs.open");
        assert_eq!(open.len(), 1, "{kind}");
        assert_eq!(open[0]["incognito"], true, "{kind}: {}", open[0]);
        assert!(
            open[0]["session"].as_str().is_some_and(|id| !id.is_empty()),
            "{kind}: no session id in {}",
            open[0]
        );
        assert!(open[0].get("url").is_none(), "{kind}: the URL went with the open: {}", open[0]);
    }
}

/// Two sessions get two stores: their ids differ.
#[test]
fn two_sessions_name_two_stores() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("new", "webkit")]);
    let first = session(&provider, "webkit", "s1");
    let second = session(&provider, "webkit", "s2");
    first.call("tabs.open", &json!({"incognito": true})).unwrap();
    second.call("tabs.open", &json!({"incognito": true})).unwrap();
    let open = params_of(&app, "tabs.open");
    assert_eq!(open.len(), 2);
    assert_ne!(open[0]["session"], open[1]["session"]);
}

/// `session.configure {incognito: true}`: every later tab opens incognito, and
/// the session cannot leave it (one way).
#[test]
fn a_session_configured_incognito_opens_every_later_tab_incognito() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("new", "cef")]);
    let agent = session(&provider, "cef", "s1");
    let answer = agent.call("session.configure", &json!({"incognito": true})).unwrap();
    assert_eq!(answer["incognito"], true);
    agent.call("tabs.open", &json!({})).unwrap();
    assert_eq!(params_of(&app, "tabs.open")[0]["incognito"], true);
    let refused = agent.call("tabs.open", &json!({"incognito": false})).unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
    let refused = agent.call("session.configure", &json!({"incognito": false})).unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
    assert_eq!(calls(&app, "tabs.open"), 1);
}

/// The session's end closes its tabs, then tells the app the store ends.
#[test]
fn the_sessions_end_tells_the_app_to_drop_its_store() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("new", "webkit")]);
    let agent = session(&provider, "webkit", "s1");
    agent.call("tabs.open", &json!({"incognito": true})).unwrap();
    let id = params_of(&app, "tabs.open")[0]["session"].clone();
    agent.end_session();
    let ended = params_of(&app, "session.ended");
    assert_eq!(ended.len(), 1, "the app was not told the session ended");
    assert_eq!(ended[0]["session"], id);
    assert_eq!(call_order(&app, &["tabs.close", "session.ended"]), ["tabs.close", "session.ended"]);
    // Once only, also when the engine drops after the close.
    drop(agent);
    assert_eq!(calls(&app, "session.ended"), 1);
}

/// A session that opened no incognito tab tells the app nothing.
#[test]
fn a_session_without_incognito_tabs_sends_no_session_end() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("new", "webkit")]);
    let agent = session(&provider, "webkit", "s1");
    agent.call("tabs.open", &json!({})).unwrap();
    agent.end_session();
    assert_eq!(calls(&app, "session.ended"), 0);
}

/// The default is unchanged: a tab that does not ask for incognito opens in
/// the person's profile, with no flag and no session store.
#[test]
fn a_plain_tab_carries_no_incognito_or_session() {
    let (app, provider) = FakeApp::start(vec![tab("W", "webkit"), tab("page", "webkit")]);
    let agent = session(&provider, "webkit", "s1");
    agent.call("tabs.open", &json!({"url": "https://b.test/page"})).unwrap();
    assert_eq!(
        params_of(&app, "tabs.open")[0],
        json!({"url": "https://b.test/page", "engine": "webkit"})
    );
}

/// Private data P1 against an older app that ignores the flag: the tab it
/// opened (blank, in the person's profile) closes at once, no page loads,
/// and the call is refused.
#[test]
fn an_app_that_ignores_incognito_gets_its_tab_closed_and_the_call_refused() {
    for kind in ["cef", "webkit"] {
        let (app, provider) =
            FakeApp::start_with(vec![tab("W", "webkit"), tab("new", kind)], false);
        let agent = session(&provider, kind, "s1");
        let refused = agent
            .call("tabs.open", &json!({"url": "https://b.test/x", "incognito": true}))
            .unwrap_err();
        assert_eq!(refused.code, ErrorCode::Unsupported, "{kind}: {refused}");
        let closes = params_of(&app, "tabs.close");
        assert_eq!(closes.len(), 1, "{kind}: the tab in the person's profile stayed");
        assert_eq!(closes[0]["targetId"], "new");
        assert_eq!(calls(&app, "tab.navigate"), 0, "{kind}: a page loaded");
    }
}

/// An incognito tab closes with its session: it cannot be kept.
#[test]
fn an_incognito_app_tab_cannot_be_kept() {
    let private: TabAnnounce = serde_json::from_value(json!({
        "targetId": "P", "engine": "webkit", "workspace": "w", "profile": "p",
        "url": "https://a.test/", "title": "A", "visible": false, "incognito": true,
    }))
    .unwrap();
    let (_app, provider) = FakeApp::start(vec![tab("W", "webkit"), private]);
    let agent = session(&provider, "webkit", "s1");
    let row = agent
        .call("tabs.list", &json!({"all": true}))
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["targetId"] == "P")
        .cloned()
        .unwrap();
    assert_eq!(row["incognito"], true, "{row}");
    let refused = agent.call("tab.keep", &json!({"targetId": "P"})).unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
}
