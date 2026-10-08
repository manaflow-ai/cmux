//! Replays the shared vectors in `schemas/remote-tab/`. Every other
//! implementation of `cmux.rb/1` replays the same files.

use cmux_remote_browser::cookie::{SyncContext, SyncOutcome, resolve};
use cmux_remote_browser::menu::{MenuEffect, MenuInput, MenuNote, MenuReject, MenuTokens};
use cmux_remote_browser::proto::{Control, CookieVersion, InputEvent, SessionState};
use cmux_remote_browser::scroll::{ScrollEffect, ScrollInput, ScrollReject, Scroller};
use cmux_remote_browser::session::{Session, SessionEffect, SessionInput, SessionReject};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

const SESSION: &str = include_str!("../../../../schemas/remote-tab/session.json");
const MENU: &str = include_str!("../../../../schemas/remote-tab/menu-token.json");
const SCROLL: &str = include_str!("../../../../schemas/remote-tab/scroll-writer.json");
const COOKIE: &str = include_str!("../../../../schemas/remote-tab/cookie-sync.json");
const MESSAGES: &str = include_str!("../../../../schemas/remote-tab/messages.json");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct VectorFile<C> {
    #[allow(dead_code)]
    description: String,
    version: u32,
    cases: Vec<C>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Case<S> {
    name: String,
    #[serde(default)]
    initial: Option<ScrollInitial>,
    steps: Vec<S>,
}

fn load<C: DeserializeOwned>(text: &str) -> Vec<C> {
    let file: VectorFile<C> = serde_json::from_str(text).expect("vector file parses");
    assert_eq!(file.version, 1);
    assert!(!file.cases.is_empty());
    file.cases
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionStep {
    input: SessionInput,
    expect: SessionExpect,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SessionExpect {
    state: SessionState,
    capturing: bool,
    reject: Option<SessionReject>,
    effects: Vec<SessionEffect>,
}

#[test]
fn session_vectors() {
    for case in load::<Case<SessionStep>>(SESSION) {
        let mut session = Session::default();
        for (i, step) in case.steps.into_iter().enumerate() {
            let before = session.clone();
            let (effects, reject) = match session.apply(step.input) {
                Ok(effects) => (effects, None),
                Err(reject) => (Vec::new(), Some(reject)),
            };
            let at = format!("{} step {i}", case.name);
            assert_eq!(reject, step.expect.reject, "{at}: reject");
            assert_eq!(effects, step.expect.effects, "{at}: effects");
            assert_eq!(session.state, step.expect.state, "{at}: state");
            assert_eq!(session.capturing, step.expect.capturing, "{at}: capturing");
            if reject.is_some() {
                assert_eq!(session, before, "{at}: a reject changed the session");
            }
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MenuStep {
    input: MenuInput,
    expect: MenuExpect,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MenuExpect {
    effects: Vec<MenuEffect>,
    note: Option<MenuNote>,
    reject: Option<MenuReject>,
    open: Option<u64>,
}

#[test]
fn menu_token_vectors() {
    for case in load::<Case<MenuStep>>(MENU) {
        let mut menus = MenuTokens::default();
        for (i, step) in case.steps.into_iter().enumerate() {
            let before = menus.clone();
            let at = format!("{} step {i}", case.name);
            match menus.apply(step.input) {
                Ok(out) => {
                    assert_eq!(step.expect.reject, None, "{at}: expected a reject");
                    assert_eq!(out.effects, step.expect.effects, "{at}: effects");
                    assert_eq!(out.note, step.expect.note, "{at}: note");
                }
                Err(reject) => {
                    assert_eq!(Some(reject), step.expect.reject, "{at}: reject");
                    assert!(step.expect.effects.is_empty() && step.expect.note.is_none(), "{at}");
                    assert_eq!(menus, before, "{at}: a reject changed the state");
                }
            }
            assert_eq!(menus.open.as_ref().map(|m| m.token), step.expect.open, "{at}: open token");
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScrollInitial {
    offset: f64,
    max: f64,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScrollStep {
    input: ScrollInput,
    expect: ScrollExpect,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScrollExpect {
    reject: Option<ScrollReject>,
    effects: Vec<ScrollEffect>,
    state: Scroller,
}

#[test]
fn scroll_writer_vectors() {
    for case in load::<Case<ScrollStep>>(SCROLL) {
        let initial = case.initial.as_ref().expect("scroll cases name an initial state");
        let mut scroller = Scroller::new(initial.offset, initial.max);
        for (i, step) in case.steps.into_iter().enumerate() {
            let at = format!("{} step {i}", case.name);
            let (effects, reject) = match scroller.apply(step.input) {
                Ok(effects) => (effects, None),
                Err(reject) => (Vec::new(), Some(reject)),
            };
            assert_eq!(reject, step.expect.reject, "{at}: reject");
            assert_eq!(effects, step.expect.effects, "{at}: effects");
            assert_eq!(scroller, step.expect.state, "{at}: state");
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CookieCase {
    name: String,
    local: Option<CookieVersion>,
    remote: Option<CookieVersion>,
    context: SyncContext,
    expect: SyncOutcome,
}

fn mirrored(outcome: SyncOutcome) -> SyncOutcome {
    match outcome {
        SyncOutcome::KeepLocal => SyncOutcome::TakeRemote,
        SyncOutcome::TakeRemote => SyncOutcome::KeepLocal,
        other => other,
    }
}

#[test]
fn cookie_sync_vectors() {
    for case in load::<CookieCase>(COOKIE) {
        let got = resolve(case.local.as_ref(), case.remote.as_ref(), &case.context);
        assert_eq!(got, case.expect, "{}", case.name);
        let swapped = resolve(case.remote.as_ref(), case.local.as_ref(), &case.context);
        assert_eq!(swapped, mirrored(case.expect), "{}: the two machines disagree", case.name);
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MessageFile {
    #[allow(dead_code)]
    description: String,
    version: u32,
    control: Vec<Value>,
    input: Vec<Value>,
}

fn round_trip<T: DeserializeOwned + serde::Serialize>(value: &Value) {
    let typed: T = serde_json::from_value(value.clone())
        .unwrap_or_else(|e| panic!("does not parse ({e}): {value}"));
    let back = serde_json::to_value(&typed).expect("serializes");
    assert_eq!(&back, value, "round trip changed the message");
}

#[test]
fn every_message_round_trips() {
    let file: MessageFile = serde_json::from_str(MESSAGES).expect("messages parse");
    assert_eq!(file.version, 1);
    for message in &file.control {
        assert!(message["t"].as_str().is_some_and(|t| t.starts_with("rb.")), "{message}");
        round_trip::<Control>(message);
    }
    for event in &file.input {
        round_trip::<InputEvent>(event);
    }
}

#[test]
fn control_text_round_trips() {
    let text = r#"{"t":"rb.key_unhandled","input_seq":7}"#;
    let parsed = Control::from_json(text).expect("parses");
    assert_eq!(parsed, Control::KeyUnhandled { input_seq: 7 });
    assert_eq!(Control::from_json(&parsed.to_json()).expect("parses again"), parsed);
    assert!(Control::from_json(r#"{"t":"rb.unknown"}"#).is_err());
}

#[test]
fn navigate_preserves_legacy_and_request_bearing_messages() {
    for (text, request) in [
        (r#"{"t":"rb.navigate","url":"https://example.com/"}"#, None),
        (r#"{"t":"rb.navigate","request":5,"url":"https://example.com/"}"#, Some(5)),
    ] {
        let parsed = Control::from_json(text).expect("parses");
        assert_eq!(parsed, Control::Navigate { request, url: "https://example.com/".into() });
        assert_eq!(
            serde_json::from_str::<Value>(&parsed.to_json()).expect("serializes"),
            serde_json::from_str::<Value>(text).expect("fixture parses")
        );
    }
}

#[test]
fn navigate_result_carries_a_refusal_or_null() {
    use cmux_remote_browser::proto::NavigateRefusal;
    let refused =
        Control::from_json(r#"{"t":"rb.navigate.result","request":6,"refused":"scheme"}"#)
            .expect("parses");
    assert_eq!(
        refused,
        Control::NavigateResult { request: 6, refused: Some(NavigateRefusal::Scheme) }
    );
    let started = Control::from_json(r#"{"t":"rb.navigate.result","request":5,"refused":null}"#)
        .expect("parses");
    assert_eq!(started, Control::NavigateResult { request: 5, refused: None });
    assert!(
        Control::from_json(r#"{"t":"rb.navigate.result","request":5,"refused":"other"}"#).is_err()
    );
}

const INPUT_MAPPING: &str = include_str!("../../../../schemas/remote-tab/input-mapping.json");

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct InputMappingCase {
    name: String,
    input: InputEvent,
    #[serde(default)]
    expect: Option<cmux_remote_browser::rp_input::RpCall>,
    #[serde(default)]
    reject: Option<cmux_remote_browser::rp_input::InputReject>,
}

#[test]
fn input_mapping_vectors() {
    for case in load::<InputMappingCase>(INPUT_MAPPING) {
        let got = cmux_remote_browser::rp_input::map_input(&case.input);
        match (&case.expect, &case.reject) {
            (Some(call), None) => assert_eq!(got.as_ref(), Ok(call), "{}", case.name),
            (None, Some(reject)) => assert_eq!(got.as_ref().err(), Some(reject), "{}", case.name),
            _ => panic!("{}: a case names exactly one of expect and reject", case.name),
        }
    }
}
